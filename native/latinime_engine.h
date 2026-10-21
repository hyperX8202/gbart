/*
 * Plain C++ facade over the LatinIME native core. This is the only API the HarmonyOS layer
 * (NAPI bridge) and the host tests talk to; JNI types never leak beyond latinime_engine.cpp.
 *
 * Like HeliBoard's DictionaryFacilitator it supports several languages at once (multilingual
 * typing): every language has a read-only main dictionary and a learning user-history dictionary,
 * all are queried for each input and the results are merged, weighted per language.
 */
#ifndef KEYBOARD_LATINIME_ENGINE_H
#define KEYBOARD_LATINIME_ENGINE_H

#include <memory>
#include <string>
#include <vector>

namespace keyboard {

struct KeyGeometry {
    int code;    // Unicode code point produced by the key
    int x;       // left edge in keyboard units
    int y;       // top edge in keyboard units
    int width;
    int height;
};

struct Suggestion {
    std::string word;    // UTF-8, may contain a space for missing-space corrections ("das ist")
    int score;
    int type;            // SuggestedWordInfo kind and flags as defined by the native core
    // Score normalised against the typed word (AutocorrectionThresholdUtils), compared with the
    // autocorrect threshold like HeliBoard's AutoCorrectionUtils.suggestionExceedsThreshold().
    float normalizedScore;
    bool appropriateForAutoCorrection;
    std::string locale;  // language whose dictionary produced the word
    bool fromHistory;    // learned from the user rather than from the main dictionary
};

struct SuggestQuery {
    std::vector<int> codePoints;  // typed code points (case as typed)
    std::vector<int> xs;          // touch x per code point in keyboard units, -1 = unknown
    std::vector<int> ys;          // touch y per code point in keyboard units, -1 = unknown
    std::string previousWord;     // UTF-8, empty at the beginning of a sentence
    bool beginningOfSentence = false;
};

struct GestureQuery {
    std::vector<int> xs;          // trace points in keyboard units
    std::vector<int> ys;
    std::string previousWord;     // UTF-8, empty at the beginning of a sentence
    bool beginningOfSentence = false;
    int max = 5;
};

class LatinImeEngine {
 public:
    LatinImeEngine();
    ~LatinImeEngine();
    LatinImeEngine(const LatinImeEngine &) = delete;
    LatinImeEngine &operator=(const LatinImeEngine &) = delete;

    // Adds a language: read-only main dictionary plus a learning history dictionary stored at
    // historyPath (created if missing; empty path = no learning). Replaces an existing entry.
    bool addLanguage(const std::string &locale, const std::string &mainDictPath,
            const std::string &historyPath);
    // Optional word -> emoji dictionary of a language (HeliBoard emoji_cldr_signal dictionaries).
    bool addEmojiDictionary(const std::string &locale, const std::string &path);
    void removeAllLanguages();
    // Multilingual weighting (1.0 = the language currently being typed).
    void setLanguageWeight(const std::string &locale, float weight);

    // Describes the current keyboard layout so typos are weighted by key distance.
    void setKeyboardLayout(int keyboardWidth, int keyboardHeight, int mostCommonKeyWidth,
            int mostCommonKeyHeight, const std::vector<KeyGeometry> &keys);

    // Corrections/completions for the word being typed (all languages merged, best first), or
    // next-word predictions when query.codePoints is empty.
    std::vector<Suggestion> suggest(const SuggestQuery &query);

    // Words for a gesture ("glide typing") trace, best first (all languages merged).
    std::vector<Suggestion> gesture(const GestureQuery &query);
    // Weights of the gesture score (alignment, location, language model); for tuning in tests.
    void setGestureWeights(float align, float location, float languageModel);

    // Emoji for a complete word ("pizza" -> 🍕), best first, at most `max`.
    std::vector<std::string> emojiFor(const std::string &word, int max);

    // In any main dictionary (or learned often enough in a history dictionary).
    bool isValidWord(const std::string &word);
    bool isValidWordIn(const std::string &locale, const std::string &word);

    // Records a committed word in the language's history (unigram + n-gram with the previous
    // word); this is how the keyboard learns new words and next-word predictions.
    void learn(const std::string &locale, const std::string &word, const std::string &previousWord,
            bool beginningOfSentence, bool isValid);
    // Writes pending history changes to disk.
    void flush();

 private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};

}  // namespace keyboard

#endif  // KEYBOARD_LATINIME_ENGINE_H
