/*
 * Gesture ("glide") typing decoder. AOSP LatinIME ships without a gesture policy (HeliBoard loads
 * Google's closed library for it), so this is an own decoder after the SHARK2 idea: the swipe
 * trace is compared with the ideal path through the key centres of every dictionary word that
 * starts and ends near the trace's ends. Two spatial channels are combined:
 *   - alignment: every letter's key must be passed in order (monotonic DP over trace points),
 *   - location:  the whole resampled trace must follow the word's resampled ideal path.
 * Language model scores are added by the caller (LatinImeEngine).
 */
#ifndef KEYBOARD_GESTURE_DECODER_H
#define KEYBOARD_GESTURE_DECODER_H

#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "latinime_engine.h"

namespace keyboard {

struct GestureMatch {
    int lang;                     // language index given to setWords()
    int wordIndex;                // index into that language's word list
    float spatialCost;            // alignment + location cost in key units (lower is better)
    float score;                  // -spatialCost + prior weight (higher is better)
};

// Words of one language, stored flat (a dictionary has up to ~10^5 gesture words).
struct GestureWordList {
    std::vector<int> codePoints;
    std::vector<uint32_t> ends;   // end offset of each word in codePoints
    std::vector<float> priors;    // unigram probability / 255

    size_t size() const { return ends.size(); }
    void add(const int *word, int length, float prior) {
        codePoints.insert(codePoints.end(), word, word + length);
        ends.push_back(static_cast<uint32_t>(codePoints.size()));
        priors.push_back(prior);
    }
    std::vector<int> word(size_t index) const {
        const uint32_t begin = index == 0 ? 0 : ends[index - 1];
        return std::vector<int>(codePoints.begin() + begin, codePoints.begin() + ends[index]);
    }
};

class GestureDecoder {
 public:
    // Letter keys of the current layout (engine units). Rebuilds the word index lazily.
    void setLayout(const std::vector<KeyGeometry> &keys);
    // Words of one language with a prior in [0, 1] (unigram probability / 255).
    void setWords(int lang, GestureWordList &&words);
    // Adds a learned word (once per language).
    void addWord(int lang, const std::vector<int> &word, float prior);
    void clear();
    std::vector<int> word(int lang, int index) const { return mLanguages[lang].words.word(index); }

    // Best candidates for the trace (engine units), at most `max`. langPenalty[lang] is subtracted
    // from the prior of each language (multilingual weighting); missing entries count as 0.
    std::vector<GestureMatch> decode(const std::vector<int> &xs, const std::vector<int> &ys,
            const std::vector<float> &langPenalty, int max);

    // Tuning knobs (exposed for the host test).
    float alignWeight = 2.0f;
    float locationWeight = 1.5f;
    float priorWeight = 2.5f;

 private:
    struct Point {
        float x;
        float y;
    };
    struct LanguageWords {
        GestureWordList words;
        std::unordered_set<uint64_t> learned;  // hashes of words added by addWord()
    };
    struct Entry {
        int lang;
        int wordIndex;
        uint32_t keyOffset;   // into mKeySeqs
        uint8_t keyCount;     // keys after collapsing repeats
        float pathLength;     // ideal path length in key units
    };

    int keyIndexFor(int codePoint) const;
    bool keySequence(const int *word, int length, std::vector<uint8_t> *out) const;
    void indexWord(int lang, int wordIndex);
    void buildIndex();
    Point center(int key) const;

    std::vector<KeyGeometry> mKeys;
    std::unordered_map<int, int> mKeyByCode;
    float mKeyWidth = 100.0f;
    float mKeyHeight = 150.0f;
    std::vector<LanguageWords> mLanguages;
    bool mIndexDirty = true;
    std::vector<Entry> mEntries;
    std::vector<uint8_t> mKeySeqs;
    // (first key, last key) -> entries
    std::vector<std::vector<int>> mBuckets;
};

}  // namespace keyboard

#endif  // KEYBOARD_GESTURE_DECODER_H
