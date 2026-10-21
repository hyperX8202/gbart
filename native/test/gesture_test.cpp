// Host test for gesture ("glide") typing: synthetic swipe traces through the keys of a word
// (key centres scattered, corners cut, touch samples with noise) are decoded and the share of
// traces that yield the intended word is reported (top 1 and top 3), plus timing.
//   gesture_test <de dict> <en dict> [align location lm]
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

#include "latinime_engine.h"

namespace {

constexpr int kKeyWidth = 100;
constexpr int kKeyHeight = 150;

std::vector<int> toCodePoints(const std::string &utf8) {
    std::vector<int> out;
    for (size_t i = 0; i < utf8.size();) {
        const unsigned char c = static_cast<unsigned char>(utf8[i]);
        const size_t n = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : 4;
        int cp = n == 1 ? c : n == 2 ? (c & 0x1F) : n == 3 ? (c & 0x0F) : (c & 0x07);
        for (size_t k = 1; k < n; ++k) cp = (cp << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        out.push_back(cp);
        i += n;
    }
    return out;
}

std::vector<keyboard::KeyGeometry> qwertzLayout() {
    const std::vector<std::string> rows = {"qwertzuiopü", "asdfghjklöä", "yxcvbnm"};
    std::vector<keyboard::KeyGeometry> keys;
    for (size_t row = 0; row < rows.size(); ++row) {
        const std::vector<int> codes = toCodePoints(rows[row]);
        int x = (11 - static_cast<int>(codes.size())) * kKeyWidth / 2;
        for (int code : codes) {
            keys.push_back({code, x, static_cast<int>(row) * kKeyHeight, kKeyWidth, kKeyHeight});
            x += kKeyWidth;
        }
    }
    return keys;
}

struct Pt {
    double x;
    double y;
};

const keyboard::KeyGeometry *keyFor(const std::vector<keyboard::KeyGeometry> &keys, int code) {
    if (code == 0xDF) code = 's';
    for (const auto &k : keys) {
        if (k.code == code) return &k;
    }
    return nullptr;
}

// A swipe as a person draws it: through (scattered) key centres, corners rounded, sampled densely.
bool makeTrace(const std::vector<keyboard::KeyGeometry> &keys, const std::string &word, double sigma,
        std::mt19937 &rng, std::vector<int> *xs, std::vector<int> *ys) {
    std::normal_distribution<double> noise(0.0, 1.0);
    std::vector<Pt> path;
    for (int c : toCodePoints(word)) {
        const keyboard::KeyGeometry *k = keyFor(keys, c);
        if (!k) return false;
        Pt p{k->x + k->width / 2.0 + noise(rng) * sigma * kKeyWidth,
                k->y + k->height / 2.0 + noise(rng) * sigma * kKeyHeight};
        if (!path.empty() && std::hypot(p.x - path.back().x, p.y - path.back().y) < 1) continue;
        path.push_back(p);
    }
    if (path.size() < 2) return false;
    // Corners are rounded: the finger turns about a third of a key before the key centre.
    std::vector<Pt> rounded{path.front()};
    for (size_t i = 1; i + 1 < path.size(); ++i) {
        const Pt p = path[i - 1], v = path[i], n = path[i + 1];
        auto towards = [&](Pt to) {
            const double d = std::hypot(to.x - v.x, to.y - v.y);
            const double t = d > 0 ? std::min(0.45, 35.0 / d) : 0.0;
            return Pt{v.x + (to.x - v.x) * t, v.y + (to.y - v.y) * t};
        };
        const Pt a = towards(p), b = towards(n);
        for (int s = 0; s <= 4; ++s) {
            const double t = s / 4.0;
            rounded.push_back({(1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * v.x + t * t * b.x,
                    (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * v.y + t * t * b.y});
        }
    }
    rounded.push_back(path.back());
    path = rounded;
    // Touch samples every ~15 units with 4 units jitter.
    xs->clear();
    ys->clear();
    for (size_t i = 0; i + 1 < path.size(); ++i) {
        const double length = std::hypot(path[i + 1].x - path[i].x, path[i + 1].y - path[i].y);
        const int steps = std::max(1, static_cast<int>(length / 15));
        for (int s = 0; s < steps; ++s) {
            const double t = static_cast<double>(s) / steps;
            xs->push_back(static_cast<int>(path[i].x + (path[i + 1].x - path[i].x) * t + noise(rng) * 4));
            ys->push_back(static_cast<int>(path[i].y + (path[i + 1].y - path[i].y) * t + noise(rng) * 4));
        }
    }
    xs->push_back(static_cast<int>(path.back().x));
    ys->push_back(static_cast<int>(path.back().y));
    return true;
}

bool sameIgnoringCase(const std::string &a, const std::string &b) {
    std::vector<int> x = toCodePoints(a), y = toCodePoints(b);
    if (x.size() != y.size()) return false;
    for (size_t i = 0; i < x.size(); ++i) {
        auto lower = [](int c) { return (c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0xDE) ? c + 32 : c; };
        if (lower(x[i]) != lower(y[i])) return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <de dict> <en dict> [align location lm]\n", argv[0]);
        return 2;
    }
    keyboard::LatinImeEngine engine;
    engine.addLanguage("de", argv[1], "");
    engine.addLanguage("en_US", argv[2], "");
    engine.setLanguageWeight("en_US", 0.85f);
    const std::vector<keyboard::KeyGeometry> keys = qwertzLayout();
    engine.setKeyboardLayout(11 * kKeyWidth, 3 * kKeyHeight, kKeyWidth, kKeyHeight, keys);
    if (argc >= 6) engine.setGestureWeights(atof(argv[3]), atof(argv[4]), atof(argv[5]));

    // Loads the word lists (timed separately: happens once on the first swipe).
    keyboard::GestureQuery warmup;
    warmup.xs = {50, 950};
    warmup.ys = {75, 75};
    auto t0 = std::chrono::steady_clock::now();
    engine.gesture(warmup);
    auto t1 = std::chrono::steady_clock::now();
    printf("word lists loaded in %.0f ms\n", std::chrono::duration<double, std::milli>(t1 - t0).count());

    // Common German words, a few English ones (multilingual), with the previous word as context.
    const std::vector<std::pair<std::string, std::string>> words = {
        {"", "hallo"}, {"", "danke"}, {"ich", "bin"}, {"das", "ist"}, {"ist", "gut"}, {"", "heute"},
        {"wir", "sind"}, {"und", "die"}, {"in", "der"}, {"nicht", "mehr"}, {"", "morgen"}, {"bis", "morgen"},
        {"", "tastatur"}, {"die", "zeit"}, {"", "vielleicht"}, {"", "wirklich"}, {"", "einfach"},
        {"ich", "habe"}, {"habe", "keine"}, {"", "schreiben"}, {"", "telefon"}, {"", "termin"},
        {"", "nachricht"}, {"", "gerne"}, {"", "bitte"}, {"", "schön"}, {"", "für"}, {"", "über"},
        {"", "später"}, {"", "groß"}, {"", "wasser"}, {"", "arbeiten"}, {"", "fahren"}, {"", "gehen"},
        {"", "kommen"}, {"", "machen"}, {"", "wissen"}, {"", "sprechen"}, {"", "zusammen"},
        {"", "eigentlich"}, {"", "leider"}, {"", "genau"}, {"", "frage"}, {"", "antwort"}, {"", "woche"},
        {"", "abend"}, {"", "nacht"}, {"", "schnell"}, {"", "wichtig"}, {"", "richtig"}, {"", "haus"},
        {"", "auto"}, {"", "stadt"}, {"", "essen"}, {"", "trinken"}, {"", "spielen"}, {"", "lesen"},
        {"", "sehen"}, {"", "laufen"}, {"", "jetzt"}, {"", "immer"}, {"", "wieder"}, {"", "schon"},
        {"", "noch"}, {"", "aber"}, {"", "oder"}, {"", "auch"}, {"", "wenn"}, {"", "dann"}, {"", "weil"},
        {"", "the"}, {"", "keyboard"}, {"", "thanks"}, {"", "meeting"}, {"", "tomorrow"}, {"", "hello"},
        {"", "with"}, {"", "about"}, {"", "would"}, {"", "people"}};

    for (double sigma : {0.15, 0.25, 0.35}) {
        std::mt19937 rng(42);
        int total = 0, top1 = 0, top3 = 0;
        double ms = 0;
        std::string misses;
        for (int round = 0; round < 3; ++round) {
            for (const auto &entry : words) {
                if (getenv("GT_WORD") && entry.second != getenv("GT_WORD")) continue;
                keyboard::GestureQuery query;
                if (!makeTrace(keys, entry.second, sigma, rng, &query.xs, &query.ys)) continue;
                query.previousWord = entry.first;
                query.beginningOfSentence = entry.first.empty();
                auto a = std::chrono::steady_clock::now();
                const std::vector<keyboard::Suggestion> result = engine.gesture(query);
                ms += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - a).count();
                ++total;
                for (size_t i = 0; i < result.size() && i < 3; ++i) {
                    if (sameIgnoringCase(result[i].word, entry.second)) {
                        if (i == 0) ++top1;
                        ++top3;
                        break;
                    }
                }
                if (round == 0 && (result.empty() || !sameIgnoringCase(result[0].word, entry.second))) {
                    misses += " " + entry.second + "->" + (result.empty() ? "-" : result[0].word);
                }
            }
        }
        printf("sigma %.2f: top1 %d/%d (%.0f%%), top3 %.0f%%, %.1f ms/trace\n  misses:%s\n", sigma, top1, total,
                100.0 * top1 / total, 100.0 * top3 / total, ms / total, misses.c_str());
    }
    return 0;
}
