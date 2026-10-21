#include "latinime_engine.h"
#include "gesture_decoder.h"

#include <sys/stat.h>

#include <algorithm>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <ctime>
#include <cstdio>

#include "defines.h"
#include "dictionary/header/header_read_write_utils.h"
#include "dictionary/property/historical_info.h"
#include "dictionary/property/ngram_context.h"
#include "dictionary/property/word_property.h"
#include "dictionary/structure/dictionary_structure_with_buffer_policy_factory.h"
#include "jni.h"
#include "suggest/core/dictionary/dictionary.h"
#include "suggest/core/layout/proximity_info.h"
#include "suggest/core/result/suggestion_results.h"
#include "suggest/core/session/dic_traverse_session.h"
#include "suggest/core/suggest_options.h"
#include "utils/autocorrection_threshold_utils.h"
#include "utils/int_array_view.h"

namespace keyboard {

namespace {

// Same grid and search radius as HeliBoard's ProximityInfo (config_keyboard_grid_*, SEARCH_DISTANCE).
constexpr int kGridWidth = 32;
constexpr int kGridHeight = 16;
constexpr float kSearchDistance = 1.2f;
constexpr float kNotAWeightOfLangModelVsSpatialModel = -1.0f;
// Option layout as in HeliBoard's NativeSuggestOptions.java (indices are private in the core).
constexpr int kOptionUseFullEditDistance = 1;
constexpr int kOptionWeightForLocaleInThousands = 4;
constexpr int kOptionsSize = 5;
// FormatSpec.VERSION403: the updatable format HeliBoard uses for its user history dictionary.
constexpr int kHistoryFormatVersion = 403;
// Write the history to disk after this many learned words (and when the keyboard hides).
constexpr int kFlushEveryUpdates = 20;
// Gesture typing: candidates taken from the spatial decoder for language-model rescoring, and the
// prior (probability / 255) of words the user taught the keyboard.
constexpr int kGestureCandidates = 40;
constexpr float kLearnedGesturePrior = 0.55f;
constexpr int kGestureMaxWords = 120000;
constexpr int kGestureMinProbability = 16;
constexpr uint32_t kGestureCacheMagic = 0x31575347;  // "GSW1"

std::vector<int> utf8ToCodePoints(const std::string &utf8) {
    std::vector<int> out;
    for (size_t i = 0; i < utf8.size();) {
        const unsigned char c = static_cast<unsigned char>(utf8[i]);
        int cp;
        size_t n;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c >> 5) == 0x6) { cp = c & 0x1F; n = 2; }
        else if ((c >> 4) == 0xE) { cp = c & 0x0F; n = 3; }
        else { cp = c & 0x07; n = 4; }
        for (size_t k = 1; k < n && i + k < utf8.size(); ++k) {
            cp = (cp << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        }
        out.push_back(cp);
        i += n;
    }
    return out;
}

std::string codePointsToUtf8(const int *codePoints, int count) {
    std::string out;
    for (int i = 0; i < count && codePoints[i] != 0; ++i) {
        const unsigned int cp = static_cast<unsigned int>(codePoints[i]);
        if (cp < 0x80) {
            out += static_cast<char>(cp);
        } else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }
    return out;
}

int squaredDistanceToEdge(const KeyGeometry &key, int x, int y) {
    const int edgeX = x < key.x ? key.x : std::min(x, key.x + key.width);
    const int edgeY = y < key.y ? key.y : std::min(y, key.y + key.height);
    const int dx = x - edgeX;
    const int dy = y - edgeY;
    return dx * dx + dy * dy;
}

bool pathExists(const std::string &path, off_t *size) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return false;
    if (size) *size = st.st_size;
    return true;
}

void putAttribute(latinime::DictionaryHeaderStructurePolicy::AttributeMap *map, const char *key,
        const std::string &value) {
    std::vector<int> k, v;
    latinime::HeaderReadWriteUtils::insertCharactersIntoVector(key, &k);
    latinime::HeaderReadWriteUtils::insertCharactersIntoVector(value.c_str(), &v);
    (*map)[k] = v;
}

latinime::NgramContext makeContext(const std::vector<int> &previousWord, bool beginningOfSentence) {
    if (previousWord.empty()) {
        return beginningOfSentence ? latinime::NgramContext(nullptr, 0, true) : latinime::NgramContext();
    }
    return latinime::NgramContext(previousWord.data(), static_cast<int>(previousWord.size()), false);
}

}  // namespace

/** One dictionary with its traverse session (sessions are per dictionary, as in BinaryDictionary). */
struct DictHandle {
    std::unique_ptr<latinime::Dictionary> dictionary;
    latinime::DicTraverseSession *session = nullptr;

    ~DictHandle() { release(); }

    void release() {
        if (session) {
            latinime::DicTraverseSession::releaseSessionInstance(session);
            session = nullptr;
        }
        dictionary.reset();
    }

    bool open(JNIEnv *env, latinime::DictionaryStructureWithBufferPolicy::StructurePolicyPtr policy,
            const std::string &locale) {
        release();
        if (!policy) return false;
        dictionary.reset(new latinime::Dictionary(env, std::move(policy)));
        jstring localeStr = env->NewStringUTF(locale.c_str());
        session = static_cast<latinime::DicTraverseSession *>(
                latinime::DicTraverseSession::getSessionInstance(env, localeStr, false));
        return session != nullptr;
    }

    bool valid() const { return dictionary && session; }
};

// Gesture word list of a main dictionary, read on a background thread with its own Dictionary
// instance (scanning a large dictionary takes seconds) and cached next to the dictionary file.
struct GestureLoad {
    std::mutex mutex;
    std::condition_variable done;
    bool finished = false;
    GestureWordList words;
};

bool readGestureCache(const std::string &path, uint64_t dictSize, GestureWordList *out) {
    FILE *file = fopen(path.c_str(), "rb");
    if (!file) return false;
    uint32_t magic = 0, count = 0, codePointCount = 0;
    uint64_t size = 0;
    bool ok = fread(&magic, 4, 1, file) == 1 && magic == kGestureCacheMagic && fread(&size, 8, 1, file) == 1
            && size == dictSize && fread(&count, 4, 1, file) == 1 && fread(&codePointCount, 4, 1, file) == 1;
    if (ok) {
        out->ends.resize(count);
        out->priors.resize(count);
        out->codePoints.resize(codePointCount);
        std::vector<uint8_t> probabilities(count);
        ok = fread(out->ends.data(), 4, count, file) == count
                && fread(probabilities.data(), 1, count, file) == count
                && fread(out->codePoints.data(), 4, codePointCount, file) == codePointCount
                && (count == 0 || out->ends.back() == codePointCount);
        for (uint32_t i = 0; ok && i < count; ++i) out->priors[i] = probabilities[i] / 255.0f;
    }
    fclose(file);
    if (!ok) *out = GestureWordList();
    return ok;
}

void writeGestureCache(const std::string &path, uint64_t dictSize, const GestureWordList &words) {
    const std::string temp = path + ".tmp";
    FILE *file = fopen(temp.c_str(), "wb");
    if (!file) return;
    const uint32_t magic = kGestureCacheMagic;
    const uint32_t count = static_cast<uint32_t>(words.size());
    const uint32_t codePointCount = static_cast<uint32_t>(words.codePoints.size());
    std::vector<uint8_t> probabilities;
    for (float prior : words.priors) probabilities.push_back(static_cast<uint8_t>(prior * 255.0f + 0.5f));
    bool ok = fwrite(&magic, 4, 1, file) == 1 && fwrite(&dictSize, 8, 1, file) == 1
            && fwrite(&count, 4, 1, file) == 1 && fwrite(&codePointCount, 4, 1, file) == 1
            && fwrite(words.ends.data(), 4, count, file) == count
            && fwrite(probabilities.data(), 1, count, file) == count
            && fwrite(words.codePoints.data(), 4, codePointCount, file) == codePointCount;
    ok = fclose(file) == 0 && ok;
    if (ok) {
        rename(temp.c_str(), path.c_str());
    } else {
        remove(temp.c_str());
    }
}

// The most frequent words of a main dictionary (at most kGestureMaxWords): big dictionaries are
// mostly rare compounds that would only cost memory and produce odd gesture matches.
GestureWordList scanGestureWords(const std::string &dictPath, off_t dictSize) {
    GestureWordList all;
    JNIEnv env;
    auto policy = latinime::DictionaryStructureWithBufferPolicyFactory::newPolicyForExistingDictFile(
            dictPath.c_str(), 0, static_cast<int>(dictSize), false /* isUpdatable */);
    if (!policy) return all;
    latinime::Dictionary dictionary(&env, std::move(policy));
    std::vector<int> histogram(MAX_PROBABILITY + 1, 0);
    int codePoints[MAX_WORD_LENGTH];
    int token = 0;
    do {
        int length = 0;
        token = dictionary.getNextWordAndNextToken(token, codePoints, &length);
        if (length <= 0) continue;
        const int probability = dictionary.getProbability(latinime::CodePointArrayView(codePoints, length));
        if (probability < kGestureMinProbability || probability > MAX_PROBABILITY) continue;
        all.add(codePoints, length, probability / 255.0f);
        ++histogram[probability];
    } while (token != 0);
    int threshold = kGestureMinProbability;
    int kept = 0;
    for (int p = MAX_PROBABILITY; p >= kGestureMinProbability; --p) {
        if (kept + histogram[p] > kGestureMaxWords) {
            threshold = p + 1;
            break;
        }
        kept += histogram[p];
    }
    if (threshold == kGestureMinProbability) return all;
    GestureWordList words;
    for (size_t i = 0; i < all.size(); ++i) {
        if (all.priors[i] * 255.0f + 0.5f < threshold) continue;
        const uint32_t begin = i == 0 ? 0 : all.ends[i - 1];
        words.add(all.codePoints.data() + begin, static_cast<int>(all.ends[i] - begin), all.priors[i]);
    }
    return words;
}

std::shared_ptr<GestureLoad> startGestureLoad(const std::string &dictPath, off_t dictSize) {
    auto load = std::make_shared<GestureLoad>();
    std::thread([load, dictPath, dictSize] {
        GestureWordList words;
        const std::string cachePath = dictPath + ".gesture";
        if (!readGestureCache(cachePath, static_cast<uint64_t>(dictSize), &words)) {
            words = scanGestureWords(dictPath, dictSize);
            writeGestureCache(cachePath, static_cast<uint64_t>(dictSize), words);
        }
        std::lock_guard<std::mutex> lock(load->mutex);
        load->words = std::move(words);
        load->finished = true;
        load->done.notify_all();
    }).detach();
    return load;
}

struct Language {
    std::string locale;
    DictHandle main;
    DictHandle history;
    DictHandle emoji;
    std::string historyPath;
    float weight = 1.0f;
    int pendingUpdates = 0;
    bool gestureWordsLoaded = false;
    std::shared_ptr<GestureLoad> gestureLoad;
};

struct LatinImeEngine::Impl {
    JNIEnv env;
    std::vector<std::unique_ptr<Language>> languages;
    std::unique_ptr<latinime::ProximityInfo> proximityInfo;
    std::vector<KeyGeometry> keys;
    GestureDecoder gesture;

    Language *find(const std::string &locale) {
        for (auto &lang : languages) {
            if (lang->locale == locale) return lang.get();
        }
        return nullptr;
    }

    const KeyGeometry *keyFor(int codePoint) const {
        for (const KeyGeometry &key : keys) {
            if (key.code == codePoint) return &key;
        }
        return nullptr;
    }

    bool openHistory(Language *lang) {
        if (lang->historyPath.empty()) return false;
        off_t size = 0;
        if (pathExists(lang->historyPath, &size)) {
            auto policy = latinime::DictionaryStructureWithBufferPolicyFactory::newPolicyForExistingDictFile(
                    lang->historyPath.c_str(), 0, static_cast<int>(size), true /* isUpdatable */);
            const bool ok = lang->history.open(&env, std::move(policy), lang->locale);
            env.clear();
            if (ok) return true;
        }
        // Missing or unreadable: start a fresh history (HeliBoard's UserHistoryDictionary header).
        latinime::DictionaryHeaderStructurePolicy::AttributeMap attributes;
        putAttribute(&attributes, "dictionary", "UserHistoryDictionary." + lang->locale);
        putAttribute(&attributes, "locale", lang->locale);
        putAttribute(&attributes, "version", std::to_string(time(nullptr)));
        putAttribute(&attributes, "USES_FORGETTING_CURVE", "1");
        putAttribute(&attributes, "HAS_HISTORICAL_INFO", "1");
        std::vector<int> localeCodePoints;
        latinime::HeaderReadWriteUtils::insertCharactersIntoVector(lang->locale.c_str(), &localeCodePoints);
        auto policy = latinime::DictionaryStructureWithBufferPolicyFactory::newPolicyForOnMemoryDict(
                kHistoryFormatVersion, localeCodePoints, &attributes);
        const bool ok = lang->history.open(&env, std::move(policy), lang->locale);
        env.clear();
        return ok;
    }

    void flushHistory(Language *lang) {
        if (!lang->history.valid() || lang->historyPath.empty() || lang->pendingUpdates == 0) return;
        // Like BinaryDictionary.flushWithGC(): write with garbage collection, then reopen the file.
        if (lang->history.dictionary->flushWithGC(lang->historyPath.c_str())) {
            lang->pendingUpdates = 0;
            openHistory(lang);
        }
    }

    int indexOf(const Language *lang) const {
        for (size_t i = 0; i < languages.size(); ++i) {
            if (languages[i].get() == lang) return static_cast<int>(i);
        }
        return -1;
    }

    // Gesture typing needs the word lists: the main dictionary's comes from the background load
    // (waited for here on the first swipe), learned words are added from the history dictionary.
    void loadGestureWords() {
        for (size_t i = 0; i < languages.size(); ++i) {
            Language &lang = *languages[i];
            if (lang.gestureWordsLoaded) continue;
            lang.gestureWordsLoaded = true;
            GestureWordList words;
            if (lang.gestureLoad) {
                std::unique_lock<std::mutex> lock(lang.gestureLoad->mutex);
                lang.gestureLoad->done.wait(lock, [&] { return lang.gestureLoad->finished; });
                words = std::move(lang.gestureLoad->words);
            }
            lang.gestureLoad.reset();
            if (lang.history.valid()) {
                int codePoints[MAX_WORD_LENGTH];
                int token = 0;
                do {
                    int length = 0;
                    token = lang.history.dictionary->getNextWordAndNextToken(token, codePoints, &length);
                    if (length <= 0) continue;
                    const int probability = lang.history.dictionary->getProbability(
                            latinime::CodePointArrayView(codePoints, length));
                    if (probability == NOT_A_PROBABILITY) continue;
                    // Learned words count like fairly common words.
                    words.add(codePoints, length, std::max(kLearnedGesturePrior, probability / 255.0f));
                } while (token != 0);
            }
            gesture.setWords(static_cast<int>(i), std::move(words));
        }
    }

    // Runs one dictionary and appends its results to `out`.
    void collect(DictHandle &handle, const std::string &locale, bool fromHistory, float weight,
            const std::vector<int> &codePoints, std::vector<int> &xs, std::vector<int> &ys,
            const latinime::NgramContext &ngramContext, std::vector<Suggestion> *out) {
        // Typing suggestions need the key geometry (setKeyboardLayout); without it the core crashes.
        if (!handle.valid() || (!codePoints.empty() && !proximityInfo)) return;
        handle.session->init(handle.dictionary.get(), &ngramContext, nullptr /* suggestOptions */);
        const int inputSize = static_cast<int>(codePoints.size());
        std::vector<int> times(inputSize, 0), pointerIds(inputSize, 0);
        std::vector<int> input(codePoints);
        int options[kOptionsSize] = {};
        // HeliBoard opens its user history dictionary with useFullEditDistance = true.
        options[kOptionUseFullEditDistance] = fromHistory ? 1 : 0;
        options[kOptionWeightForLocaleInThousands] = static_cast<int>(weight * 1000);
        const latinime::SuggestOptions suggestOptions(options, NELEMS(options));
        latinime::SuggestionResults results(MAX_RESULTS);
        if (inputSize > 0) {
            handle.dictionary->getSuggestions(proximityInfo.get(), handle.session, xs.data(), ys.data(),
                    times.data(), pointerIds.data(), input.data(), inputSize, &ngramContext,
                    &suggestOptions, kNotAWeightOfLangModelVsSpatialModel, &results);
        } else {
            handle.dictionary->getPredictions(&ngramContext, &results);
        }

        jintArray outCount = env.NewIntArray(1);
        jintArray outCodePoints = env.NewIntArray(MAX_WORD_LENGTH * MAX_RESULTS);
        jintArray outScores = env.NewIntArray(MAX_RESULTS);
        jintArray outSpaceIndices = env.NewIntArray(MAX_RESULTS);
        jintArray outTypes = env.NewIntArray(MAX_RESULTS);
        jintArray outAutoCommit = env.NewIntArray(1);
        float lmWeight = kNotAWeightOfLangModelVsSpatialModel;
        jfloatArray inOutWeight = env.wrapFloats(&lmWeight, 1);
        results.outputSuggestions(&env, outCount, outCodePoints, outScores, outSpaceIndices, outTypes,
                outAutoCommit, inOutWeight);
        const int count = outCount->data[0];
        for (int i = 0; i < count; ++i) {
            const int *word = outCodePoints->data.data() + i * MAX_WORD_LENGTH;
            int length = 0;
            while (length < MAX_WORD_LENGTH && word[length] != 0) ++length;
            const int type = outTypes->data[i];
            // Like BinaryDictionary.java: the core only uses the locale weight to limit its search,
            // the caller scales the scores so less likely languages rank lower.
            const int score = static_cast<int>(outScores->data[i] * weight);
            const float normalized = inputSize > 0
                    ? latinime::AutocorrectionThresholdUtils::calcNormalizedScore(codePoints.data(),
                            inputSize, word, length, score)
                    : 0.0f;
            out->push_back({codePointsToUtf8(word, length), score, type, normalized,
                    (type & latinime::Dictionary::KIND_FLAG_APPROPRIATE_FOR_AUTOCORRECTION) != 0, locale,
                    fromHistory});
        }
        env.clear();
    }
};

LatinImeEngine::LatinImeEngine() : mImpl(new Impl()) {}

LatinImeEngine::~LatinImeEngine() {
    flush();
}

bool LatinImeEngine::addLanguage(const std::string &locale, const std::string &mainDictPath,
        const std::string &historyPath) {
    off_t size = 0;
    if (!pathExists(mainDictPath, &size) || size <= 0) return false;
    Language *lang = mImpl->find(locale);
    if (!lang) {
        mImpl->languages.emplace_back(new Language());
        lang = mImpl->languages.back().get();
        lang->locale = locale;
    } else {
        mImpl->flushHistory(lang);
    }
    auto policy = latinime::DictionaryStructureWithBufferPolicyFactory::newPolicyForExistingDictFile(
            mainDictPath.c_str(), 0, static_cast<int>(size), false /* isUpdatable */);
    const bool ok = lang->main.open(&mImpl->env, std::move(policy), locale);
    mImpl->env.clear();
    lang->historyPath = historyPath;
    mImpl->openHistory(lang);
    lang->gestureWordsLoaded = false;
    lang->gestureLoad = ok ? startGestureLoad(mainDictPath, size) : nullptr;
    return ok;
}

bool LatinImeEngine::addEmojiDictionary(const std::string &locale, const std::string &path) {
    Language *lang = mImpl->find(locale);
    off_t size = 0;
    if (!lang || !pathExists(path, &size) || size <= 0) return false;
    auto policy = latinime::DictionaryStructureWithBufferPolicyFactory::newPolicyForExistingDictFile(
            path.c_str(), 0, static_cast<int>(size), false /* isUpdatable */);
    const bool ok = lang->emoji.open(&mImpl->env, std::move(policy), locale);
    mImpl->env.clear();
    return ok;
}

std::vector<std::string> LatinImeEngine::emojiFor(const std::string &word, int max) {
    struct Candidate {
        std::string emoji;
        int probability;
        size_t length;
    };
    std::vector<Candidate> candidates;
    // Exact entries only (as typed and lower-case): the emoji are the word's shortcut targets.
    std::vector<std::vector<int>> forms = {utf8ToCodePoints(word)};
    std::vector<int> lower = forms[0];
    for (int &cp : lower) {
        if ((cp >= 'A' && cp <= 'Z') || (cp >= 0xC0 && cp <= 0xDE && cp != 0xD7)) cp += 32;
    }
    if (lower != forms[0]) forms.push_back(lower);
    // German nouns are capitalised in the emoji dictionaries ("Katze").
    std::vector<int> capitalized = lower;
    if (!capitalized.empty()) {
        int &cp = capitalized[0];
        if ((cp >= 'a' && cp <= 'z') || (cp >= 0xE0 && cp <= 0xFE && cp != 0xF7)) cp -= 32;
    }
    if (capitalized != forms[0] && capitalized != lower) forms.push_back(capitalized);
    for (auto &lang : mImpl->languages) {
        if (!lang->emoji.valid()) continue;
        for (const std::vector<int> &form : forms) {
            if (form.empty() || static_cast<int>(form.size()) > MAX_WORD_LENGTH) continue;
            const latinime::WordProperty property = lang->emoji.dictionary->getWordProperty(
                    latinime::CodePointArrayView(form.data(), form.size()));
            for (const auto &shortcut : property.getUnigramProperty().getShortcuts()) {
                const std::vector<int> *target = shortcut.getTargetCodePoints();
                std::string emoji = codePointsToUtf8(target->data(), static_cast<int>(target->size()));
                if (emoji.empty()) continue;
                candidates.push_back({emoji, static_cast<int>(shortcut.getProbability() * lang->weight),
                        target->size()});
            }
        }
    }
    // Most probable first; on ties the simpler emoji (❤️ rather than ❤️‍🔥). The keyboard moves the
    // user's recently used emoji to the front on top of this.
    std::stable_sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        return a.probability != b.probability ? a.probability > b.probability : a.length < b.length;
    });
    std::vector<std::string> out;
    for (const Candidate &c : candidates) {
        if (std::find(out.begin(), out.end(), c.emoji) == out.end()) out.push_back(c.emoji);
        if (static_cast<int>(out.size()) >= max) break;
    }
    return out;
}

void LatinImeEngine::removeAllLanguages() {
    flush();
    mImpl->languages.clear();
    mImpl->gesture.clear();
}

void LatinImeEngine::setLanguageWeight(const std::string &locale, float weight) {
    if (Language *lang = mImpl->find(locale)) lang->weight = weight;
}

void LatinImeEngine::setKeyboardLayout(int keyboardWidth, int keyboardHeight,
        int mostCommonKeyWidth, int mostCommonKeyHeight, const std::vector<KeyGeometry> &keys) {
    mImpl->keys = keys;
    mImpl->gesture.setLayout(keys);
    const int cellWidth = (keyboardWidth + kGridWidth - 1) / kGridWidth;
    const int cellHeight = (keyboardHeight + kGridHeight - 1) / kGridHeight;
    const int threshold = static_cast<int>(mostCommonKeyWidth * kSearchDistance);
    const int thresholdSquared = threshold * threshold;

    // Port of ProximityInfo#computeNearestNeighbors: every grid cell lists the keys whose edge
    // lies within the search threshold of the cell centre (brute force; the key count is small).
    std::vector<int> proximityChars(kGridWidth * kGridHeight * MAX_PROXIMITY_CHARS_SIZE,
            NOT_A_CODE_POINT);
    for (int cell = 0; cell < kGridWidth * kGridHeight; ++cell) {
        const int centerX = (cell % kGridWidth) * cellWidth + cellWidth / 2;
        const int centerY = (cell / kGridWidth) * cellHeight + cellHeight / 2;
        int slot = 0;
        for (const KeyGeometry &key : keys) {
            if (slot >= MAX_PROXIMITY_CHARS_SIZE) break;
            if (squaredDistanceToEdge(key, centerX, centerY) < thresholdSquared) {
                proximityChars[cell * MAX_PROXIMITY_CHARS_SIZE + slot++] = key.code;
            }
        }
    }

    const int keyCount = static_cast<int>(keys.size());
    std::vector<int> xs, ys, widths, heights, codes;
    for (const KeyGeometry &key : keys) {
        xs.push_back(key.x);
        ys.push_back(key.y);
        widths.push_back(key.width);
        heights.push_back(key.height);
        codes.push_back(key.code);
    }
    JNIEnv &env = mImpl->env;
    mImpl->proximityInfo.reset(new latinime::ProximityInfo(&env, keyboardWidth, keyboardHeight,
            kGridWidth, kGridHeight, mostCommonKeyWidth, mostCommonKeyHeight,
            env.wrapInts(proximityChars.data(), static_cast<jsize>(proximityChars.size())), keyCount,
            env.wrapInts(xs.data(), keyCount), env.wrapInts(ys.data(), keyCount),
            env.wrapInts(widths.data(), keyCount), env.wrapInts(heights.data(), keyCount),
            env.wrapInts(codes.data(), keyCount), nullptr /* sweetSpotCenterXs */,
            nullptr /* sweetSpotCenterYs */, nullptr /* sweetSpotRadii */));
    env.clear();
}

std::vector<Suggestion> LatinImeEngine::suggest(const SuggestQuery &query) {
    std::vector<Suggestion> results;
    const std::vector<int> prevWord = utf8ToCodePoints(query.previousWord);
    const latinime::NgramContext ngramContext = makeContext(prevWord, query.beginningOfSentence);

    const int inputSize = std::min(static_cast<int>(query.codePoints.size()), MAX_WORD_LENGTH);
    std::vector<int> codePoints(query.codePoints.begin(), query.codePoints.begin() + inputSize);
    std::vector<int> xs(inputSize, NOT_A_COORDINATE), ys(inputSize, NOT_A_COORDINATE);
    for (int i = 0; i < inputSize; ++i) {
        const bool hasTouch = i < static_cast<int>(query.xs.size()) && i < static_cast<int>(query.ys.size())
                && query.xs[i] >= 0 && query.ys[i] >= 0;
        if (hasTouch) {
            xs[i] = query.xs[i];
            ys[i] = query.ys[i];
        } else if (const KeyGeometry *key = mImpl->keyFor(codePoints[i])) {
            // No touch data (e.g. accent from a popup): assume a tap in the key centre.
            xs[i] = key->x + key->width / 2;
            ys[i] = key->y + key->height / 2;
        }
    }

    for (auto &lang : mImpl->languages) {
        mImpl->collect(lang->main, lang->locale, false, lang->weight, codePoints, xs, ys, ngramContext,
                &results);
        mImpl->collect(lang->history, lang->locale, true, lang->weight, codePoints, xs, ys, ngramContext,
                &results);
    }

    // Best first; the same word can come from several dictionaries: keep the best occurrence.
    std::stable_sort(results.begin(), results.end(),
            [](const Suggestion &a, const Suggestion &b) { return a.score > b.score; });
    std::vector<Suggestion> unique;
    for (Suggestion &suggestion : results) {
        auto existing = std::find_if(unique.begin(), unique.end(),
                [&](const Suggestion &u) { return u.word == suggestion.word; });
        if (existing == unique.end()) {
            unique.push_back(std::move(suggestion));
        } else if (!suggestion.fromHistory && existing->fromHistory) {
            // Prefer the main dictionary's flags (appropriateness) for the same word.
            existing->appropriateForAutoCorrection = suggestion.appropriateForAutoCorrection;
            existing->fromHistory = false;
        }
    }
    return unique;
}

std::vector<Suggestion> LatinImeEngine::gesture(const GestureQuery &query) {
    std::vector<Suggestion> results;
    if (mImpl->languages.empty()) return results;
    mImpl->loadGestureWords();
    GestureDecoder &decoder = mImpl->gesture;
    std::vector<float> penalties;
    for (auto &lang : mImpl->languages) {
        penalties.push_back(1.0f - lang->weight);
    }
    const std::vector<GestureMatch> matches = decoder.decode(query.xs, query.ys, penalties, kGestureCandidates);

    // Rescore the spatially plausible words with the language model in context (bigrams).
    const std::vector<int> prevWord = utf8ToCodePoints(query.previousWord);
    const latinime::NgramContext ngramContext = makeContext(prevWord, query.beginningOfSentence);
    struct Scored {
        const GestureMatch *match;
        float score;
    };
    std::vector<Scored> scored;
    for (const GestureMatch &match : matches) {
        Language &lang = *mImpl->languages[match.lang];
        const std::vector<int> word = decoder.word(match.lang, match.wordIndex);
        const latinime::CodePointArrayView view(word.data(), word.size());
        // Unigram probability, raised by a bigram with the previous word when the dictionary has
        // one (v2 dictionaries answer NOT_A_PROBABILITY for a context without that bigram).
        float lm = -1.0f;
        if (lang.main.valid()) {
            const int p = std::max(lang.main.dictionary->getProbability(view),
                    lang.main.dictionary->getNgramProbability(&ngramContext, view));
            if (p != NOT_A_PROBABILITY) lm = p / 255.0f;
        }
        if (lang.history.valid()) {
            const int p = std::max(lang.history.dictionary->getProbability(view),
                    lang.history.dictionary->getNgramProbability(&ngramContext, view));
            if (p != NOT_A_PROBABILITY) lm = std::max(lm, std::max(kLearnedGesturePrior, p / 255.0f));
        }
        if (lm < 0.0f) lm = kLearnedGesturePrior;
        const float score = decoder.priorWeight * (lm - (1.0f - lang.weight)) - match.spatialCost;
        scored.push_back({&match, score});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const Scored &a, const Scored &b) { return a.score > b.score; });
    for (const Scored &s : scored) {
        const std::vector<int> word = decoder.word(s.match->lang, s.match->wordIndex);
        const std::string utf8 = codePointsToUtf8(word.data(), static_cast<int>(word.size()));
        if (std::any_of(results.begin(), results.end(), [&](const Suggestion &r) { return r.word == utf8; })) {
            continue;
        }
        Language &lang = *mImpl->languages[s.match->lang];
        const bool inMain = lang.main.valid() && lang.main.dictionary->getProbability(
                latinime::CodePointArrayView(word.data(), word.size())) != NOT_A_PROBABILITY;
        results.push_back({utf8, static_cast<int>(s.score * 1000), 0, s.score, true, lang.locale, !inMain});
        if (static_cast<int>(results.size()) >= query.max) break;
    }
    return results;
}

void LatinImeEngine::setGestureWeights(float align, float location, float languageModel) {
    mImpl->gesture.alignWeight = align;
    mImpl->gesture.locationWeight = location;
    mImpl->gesture.priorWeight = languageModel;
}

bool LatinImeEngine::isValidWord(const std::string &word) {
    for (auto &lang : mImpl->languages) {
        if (isValidWordIn(lang->locale, word)) return true;
    }
    return false;
}

bool LatinImeEngine::isValidWordIn(const std::string &locale, const std::string &word) {
    Language *lang = mImpl->find(locale);
    if (!lang) return false;
    const std::vector<int> codePoints = utf8ToCodePoints(word);
    const latinime::CodePointArrayView view(codePoints.data(), codePoints.size());
    if (lang->main.valid() && lang->main.dictionary->getProbability(view) != NOT_A_PROBABILITY) {
        return true;
    }
    // History entries only count once the forgetting curve considers them valid (typed often).
    return lang->history.valid() && lang->history.dictionary->getProbability(view) != NOT_A_PROBABILITY;
}

void LatinImeEngine::learn(const std::string &locale, const std::string &word,
        const std::string &previousWord, bool beginningOfSentence, bool isValid) {
    Language *lang = mImpl->find(locale);
    if (!lang || !lang->history.valid() || word.empty()) return;
    const std::vector<int> codePoints = utf8ToCodePoints(word);
    if (static_cast<int>(codePoints.size()) > MAX_WORD_LENGTH) return;
    const std::vector<int> prevWord = utf8ToCodePoints(previousWord);
    const latinime::NgramContext ngramContext = makeContext(prevWord, beginningOfSentence);
    const latinime::HistoricalInfo historicalInfo(static_cast<int>(time(nullptr)), 0 /* level */, 1 /* count */);
    lang->history.dictionary->updateEntriesForWordWithNgramContext(&ngramContext,
            latinime::CodePointArrayView(codePoints.data(), codePoints.size()), isValid, historicalInfo);
    if (isValid && lang->gestureWordsLoaded) {
        mImpl->gesture.addWord(mImpl->indexOf(lang), codePoints, kLearnedGesturePrior);
    }
    if (++lang->pendingUpdates >= kFlushEveryUpdates) {
        mImpl->flushHistory(lang);
    }
}

void LatinImeEngine::flush() {
    for (auto &lang : mImpl->languages) {
        mImpl->flushHistory(lang.get());
    }
}

}  // namespace keyboard
