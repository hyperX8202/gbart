#include "gesture_decoder.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "utils/char_utils.h"

namespace keyboard {

namespace {

constexpr int kSamples = 48;
// A trace starts where the finger went down (as precise as a tap) and ends less precisely.
constexpr float kStartRadius = 0.45f;  // distance to the key's edge, in key units
constexpr float kEndRadius = 0.65f;

uint64_t hashWord(const std::vector<int> &word) {
    uint64_t h = 1469598103934665603ULL;
    for (int c : word) {
        h = (h ^ static_cast<uint64_t>(c)) * 1099511628211ULL;
    }
    return h;
}

}  // namespace

void GestureDecoder::setLayout(const std::vector<KeyGeometry> &keys) {
    mKeys.clear();
    mKeyByCode.clear();
    int widthSum = 0;
    int heightSum = 0;
    for (const KeyGeometry &key : keys) {
        // Only letter keys take part (at most 255 so key sequences fit in a byte).
        if (mKeys.size() >= 255) break;
        mKeyByCode[latinime::CharUtils::toLowerCase(key.code)] = static_cast<int>(mKeys.size());
        mKeys.push_back(key);
        widthSum += key.width;
        heightSum += key.height;
    }
    if (!mKeys.empty()) {
        // Letter keys are all the same size; the average is robust against wider extra keys.
        mKeyWidth = static_cast<float>(widthSum) / mKeys.size();
        mKeyHeight = static_cast<float>(heightSum) / mKeys.size();
    }
    mIndexDirty = true;
}

void GestureDecoder::setWords(int lang, GestureWordList &&words) {
    if (lang >= static_cast<int>(mLanguages.size())) mLanguages.resize(lang + 1);
    mLanguages[lang].words = std::move(words);
    mLanguages[lang].learned.clear();
    mIndexDirty = true;
}

void GestureDecoder::addWord(int lang, const std::vector<int> &word, float prior) {
    if (lang < 0 || lang >= static_cast<int>(mLanguages.size())) return;
    LanguageWords &target = mLanguages[lang];
    if (!target.learned.insert(hashWord(word)).second) return;
    target.words.add(word.data(), static_cast<int>(word.size()), prior);
    if (!mIndexDirty) indexWord(lang, static_cast<int>(target.words.size()) - 1);
}

void GestureDecoder::clear() {
    mLanguages.clear();
    mEntries.clear();
    mKeySeqs.clear();
    mBuckets.clear();
    mIndexDirty = true;
}

int GestureDecoder::keyIndexFor(int codePoint) const {
    const int lower = latinime::CharUtils::toLowerCase(codePoint);
    auto it = mKeyByCode.find(lower);
    if (it != mKeyByCode.end()) return it->second;
    // Accented letters are typed on their base key (ä on a, ß on s) when there is no own key.
    int base = latinime::CharUtils::toBaseLowerCase(codePoint);
    if (lower == 0xDF) base = 's';
    it = mKeyByCode.find(base);
    if (it != mKeyByCode.end()) return it->second;
    return -1;
}

bool GestureDecoder::keySequence(const int *word, int length, std::vector<uint8_t> *out) const {
    out->clear();
    for (int i = 0; i < length; ++i) {
        const int c = word[i];
        if (latinime::CharUtils::isIntentionalOmissionCodePoint(c)) continue;  // ' and -
        const int key = keyIndexFor(c);
        if (key < 0) return false;
        // Double letters are one key on the path ("hallo" = h-a-l-o).
        if (out->empty() || out->back() != key) out->push_back(static_cast<uint8_t>(key));
    }
    return out->size() >= 2 && out->size() < 255;
}

GestureDecoder::Point GestureDecoder::center(int key) const {
    const KeyGeometry &k = mKeys[key];
    return {(k.x + k.width / 2.0f) / mKeyWidth, (k.y + k.height / 2.0f) / mKeyHeight};
}

void GestureDecoder::indexWord(int lang, int wordIndex) {
    std::vector<uint8_t> seq;
    const GestureWordList &words = mLanguages[lang].words;
    const uint32_t begin = wordIndex == 0 ? 0 : words.ends[wordIndex - 1];
    if (!keySequence(words.codePoints.data() + begin, static_cast<int>(words.ends[wordIndex] - begin), &seq)) return;
    Entry entry;
    entry.lang = lang;
    entry.wordIndex = wordIndex;
    entry.keyOffset = static_cast<uint32_t>(mKeySeqs.size());
    entry.keyCount = static_cast<uint8_t>(seq.size());
    entry.pathLength = 0.0f;
    for (size_t i = 1; i < seq.size(); ++i) {
        const Point a = center(seq[i - 1]);
        const Point b = center(seq[i]);
        entry.pathLength += std::hypot(b.x - a.x, b.y - a.y);
    }
    mKeySeqs.insert(mKeySeqs.end(), seq.begin(), seq.end());
    const size_t keyCount = mKeys.size();
    mBuckets[seq.front() * keyCount + seq.back()].push_back(static_cast<int>(mEntries.size()));
    mEntries.push_back(entry);
}

void GestureDecoder::buildIndex() {
    mEntries.clear();
    mKeySeqs.clear();
    mBuckets.assign(mKeys.size() * mKeys.size(), {});
    if (!mKeys.empty()) {
        for (size_t lang = 0; lang < mLanguages.size(); ++lang) {
            for (size_t i = 0; i < mLanguages[lang].words.size(); ++i) {
                indexWord(static_cast<int>(lang), static_cast<int>(i));
            }
        }
    }
    mIndexDirty = false;
}

namespace {

struct P {
    float x;
    float y;
};

// Resamples a polyline into `count` points spaced evenly along its length.
void resample(const std::vector<P> &in, int count, std::vector<P> *out) {
    out->assign(count, in.empty() ? P{0, 0} : in.front());
    if (in.size() < 2) return;
    std::vector<float> cumulative(in.size(), 0.0f);
    for (size_t i = 1; i < in.size(); ++i) {
        cumulative[i] = cumulative[i - 1] + std::hypot(in[i].x - in[i - 1].x, in[i].y - in[i - 1].y);
    }
    const float total = cumulative.back();
    if (total <= 0.0f) return;
    size_t seg = 1;
    for (int s = 0; s < count; ++s) {
        const float target = total * s / (count - 1);
        while (seg < in.size() - 1 && cumulative[seg] < target) ++seg;
        const float segLength = cumulative[seg] - cumulative[seg - 1];
        const float t = segLength > 0.0f ? (target - cumulative[seg - 1]) / segLength : 0.0f;
        (*out)[s] = {in[seg - 1].x + (in[seg].x - in[seg - 1].x) * t,
                in[seg - 1].y + (in[seg].y - in[seg - 1].y) * t};
    }
}

float edgeDistance(const KeyGeometry &key, float keyWidth, float keyHeight, P p) {
    const float left = key.x / keyWidth;
    const float right = (key.x + key.width) / keyWidth;
    const float top = key.y / keyHeight;
    const float bottom = (key.y + key.height) / keyHeight;
    const float dx = p.x < left ? left - p.x : (p.x > right ? p.x - right : 0.0f);
    const float dy = p.y < top ? top - p.y : (p.y > bottom ? p.y - bottom : 0.0f);
    return std::hypot(dx, dy);
}

}  // namespace

std::vector<GestureMatch> GestureDecoder::decode(const std::vector<int> &xs, const std::vector<int> &ys,
        const std::vector<float> &langPenalty, int max) {
    std::vector<GestureMatch> matches;
    if (mKeys.empty() || xs.size() < 2 || xs.size() != ys.size()) return matches;
    if (mIndexDirty) buildIndex();

    // Trace in key units.
    std::vector<P> raw;
    raw.reserve(xs.size());
    for (size_t i = 0; i < xs.size(); ++i) {
        raw.push_back({xs[i] / mKeyWidth, ys[i] / mKeyHeight});
    }
    float traceLength = 0.0f;
    for (size_t i = 1; i < raw.size(); ++i) {
        traceLength += std::hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y);
    }
    std::vector<P> trace;
    resample(raw, kSamples, &trace);

    // Keys near the start and the end of the trace (the nearest one always counts).
    auto keysNear = [&](P p, float radius) {
        std::vector<int> out;
        int nearest = 0;
        float best = std::numeric_limits<float>::max();
        for (size_t k = 0; k < mKeys.size(); ++k) {
            const float d = edgeDistance(mKeys[k], mKeyWidth, mKeyHeight, p);
            if (d < best) {
                best = d;
                nearest = static_cast<int>(k);
            }
            if (d <= radius) out.push_back(static_cast<int>(k));
        }
        if (std::find(out.begin(), out.end(), nearest) == out.end()) out.push_back(nearest);
        return out;
    };
    const std::vector<int> startKeys = keysNear(raw.front(), kStartRadius);
    const std::vector<int> endKeys = keysNear(raw.back(), kEndRadius);

    std::vector<P> ideal;
    std::vector<P> idealSampled;
    std::vector<float> previous(kSamples), current(kSamples);
    const size_t keyCount = mKeys.size();
    for (int s : startKeys) {
        for (int e : endKeys) {
            for (int entryIndex : mBuckets[s * keyCount + e]) {
                const Entry &entry = mEntries[entryIndex];
                // Paths much longer or shorter than the trace cannot be this word.
                if (entry.pathLength > traceLength * 1.7f + 1.0f || entry.pathLength < traceLength * 0.45f - 1.0f) {
                    continue;
                }
                const uint8_t *seq = mKeySeqs.data() + entry.keyOffset;
                const int count = entry.keyCount;

                // Alignment: keys matched in order to trace points; first and last are pinned to
                // the trace's ends. prefix-min DP, O(keys * samples).
                ideal.clear();
                for (int k = 0; k < count; ++k) {
                    const Point c = center(seq[k]);
                    ideal.push_back({c.x, c.y});
                }
                auto cost = [&](int k, int i) {
                    const float dx = trace[i].x - ideal[k].x;
                    const float dy = trace[i].y - ideal[k].y;
                    return dx * dx + dy * dy;
                };
                const float inf = std::numeric_limits<float>::max() / 4;
                for (int i = 0; i < kSamples; ++i) previous[i] = i == 0 ? cost(0, 0) : inf;
                for (int k = 1; k < count; ++k) {
                    float best = inf;
                    for (int i = 0; i < kSamples; ++i) {
                        best = std::min(best, previous[i]);
                        current[i] = best + cost(k, i);
                    }
                    std::swap(previous, current);
                }
                const float align = previous[kSamples - 1] / count;

                // Location: resampled ideal path against the resampled trace.
                resample(ideal, kSamples, &idealSampled);
                float location = 0.0f;
                for (int i = 0; i < kSamples; ++i) {
                    location += std::hypot(trace[i].x - idealSampled[i].x, trace[i].y - idealSampled[i].y);
                }
                location /= kSamples;

                const float spatial = alignWeight * align + locationWeight * location;
                const float penalty = entry.lang < static_cast<int>(langPenalty.size()) ? langPenalty[entry.lang] : 0.0f;
                const float prior = mLanguages[entry.lang].words.priors[entry.wordIndex] - penalty;
                matches.push_back({entry.lang, entry.wordIndex, spatial, priorWeight * prior - spatial});
            }
        }
    }
    const size_t keep = std::min(matches.size(), static_cast<size_t>(std::max(0, max)));
    std::partial_sort(matches.begin(), matches.begin() + keep, matches.end(),
            [](const GestureMatch &a, const GestureMatch &b) { return a.score > b.score; });
    matches.resize(keep);
    return matches;
}

}  // namespace keyboard
