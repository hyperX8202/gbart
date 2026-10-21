// Host tests for the LatinIME engine:
//  * sample corrections (German + English loaded together, like multilingual typing)
//  * learning through the user history dictionary
//  * simulated sloppy typing: touch points scattered around the intended keys, measuring how often
//    the autocorrect decision restores the intended word, with and without touch coordinates.
//   engine_smoke_test <de dict> <en dict> <history dir> [typed words...]
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

#include "latinime_engine.h"

namespace {

constexpr int kKeyWidth = 100;
constexpr int kKeyHeight = 150;
// Keyboard default "Moderat": confidence 0.47 -> threshold 0.5 - 0.5 * 0.47^0.33 = 0.11
// (AUTOCORRECT_THRESHOLD in the environment overrides it for tuning.)
const float kAutocorrectThreshold = getenv("AUTOCORRECT_THRESHOLD") ? atof(getenv("AUTOCORRECT_THRESHOLD")) : 0.11f;

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

std::string fromCodePoints(const std::vector<int> &cps) {
    std::string out;
    for (int cp : cps) {
        if (cp < 0x80) {
            out += static_cast<char>(cp);
        } else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }
    return out;
}

// German QWERTZ as rendered by the app: 11 units wide, rows centred.
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

void printSuggestions(const std::string &label, const std::vector<keyboard::Suggestion> &suggestions) {
    printf("%-14s ->", label.c_str());
    for (size_t i = 0; i < suggestions.size() && i < 4; ++i) {
        printf(" %s(%.2f%s%s)", suggestions[i].word.c_str(), suggestions[i].normalizedScore,
                suggestions[i].locale.c_str(), suggestions[i].fromHistory ? ",hist" : "");
    }
    printf("\n");
}

int gTopN = 1;

// HeliBoard takes the first appropriate candidate; with gTopN > 1 the candidate with the best
// normalised score among the first N appropriate ones wins.
// Like the keyboard: one wrong key costs a short word a much larger share of its normalised score.
float lengthFactor(const std::string &typed) {
    const size_t n = toCodePoints(typed).size();
    return n <= 3 ? 0.6f : n == 4 ? 0.8f : 1.0f;
}

std::string autocorrect(keyboard::LatinImeEngine &engine, const std::string &typed,
        const std::vector<keyboard::Suggestion> &suggestions) {
    if (engine.isValidWord(typed) || suggestions.empty()) return typed;
    const keyboard::Suggestion *best = nullptr;
    int seen = 0;
    for (const keyboard::Suggestion &s : suggestions) {
        if (s.word == typed) break;
        if (!s.appropriateForAutoCorrection) continue;
        // Like the keyboard: autocorrect fixes typos, it does not complete words.
        if (toCodePoints(s.word).size() > toCodePoints(typed).size() + 1) continue;
        if (!best || s.normalizedScore > best->normalizedScore) best = &s;
        if (++seen >= gTopN) break;
    }
    return best && best->normalizedScore >= kAutocorrectThreshold * lengthFactor(typed) ? best->word : typed;
}

bool sameIgnoringCase(const std::string &a, const std::string &b) {
    std::vector<int> x = toCodePoints(a), y = toCodePoints(b);
    if (x.size() != y.size()) return false;
    for (size_t i = 0; i < x.size(); ++i) {
        int p = x[i], q = y[i];
        if (p >= 'A' && p <= 'Z') p += 32;
        if (q >= 'A' && q <= 'Z') q += 32;
        if (p == 0xC4 || p == 0xD6 || p == 0xDC) p += 32;
        if (q == 0xC4 || q == 0xD6 || q == 0xDC) q += 32;
        if (p != q) return false;
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <de dict> <en dict> <history dir> [typed words...]\n", argv[0]);
        return 2;
    }
    const std::string historyDir = argv[3];
    keyboard::LatinImeEngine engine;
    if (!engine.addLanguage("de", argv[1], historyDir + "/history_de")) {
        fprintf(stderr, "failed to open %s\n", argv[1]);
        return 1;
    }
    engine.addLanguage("en_US", argv[2], historyDir + "/history_en_US");
    engine.setLanguageWeight("en_US", 0.7f);
    const std::vector<keyboard::KeyGeometry> keys = qwertzLayout();
    engine.setKeyboardLayout(11 * kKeyWidth, 3 * kKeyHeight, kKeyWidth, kKeyHeight, keys);

    std::vector<std::string> typed;
    for (int i = 4; i < argc; ++i) typed.push_back(argv[i]);
    if (typed.empty()) {
        typed = {"hallp", "Dasist", "tesr", "ichbin", "morgrn", "keybaord", "wprld", "thw", "schoen"};
    }
    printf("== Vorschläge (Deutsch + Englisch gleichzeitig, Tastenmitten)\n");
    for (const std::string &word : typed) {
        keyboard::SuggestQuery query;
        query.codePoints = toCodePoints(word);
        const auto suggestions = engine.suggest(query);
        printSuggestions(word, suggestions);
    }

    printf("\n== Vorhersage des nächsten Worts (ohne Lernen)\n");
    for (const char *prev : {"guten", "vielen", "ich", "wie", "bis", "thank", "see"}) {
        keyboard::SuggestQuery next;
        next.previousWord = prev;
        printSuggestions(std::string("nach ") + prev, engine.suggest(next));
    }

    printf("\n== Lernen: 'Baranyai' dreimal getippt, danach 'Barany' + Vorhersage nach 'Andreas'\n");
    for (int i = 0; i < 3; ++i) {
        engine.learn("de", "Andreas", "", true, true);
        engine.learn("de", "Baranyai", "Andreas", false, false);
    }
    {
        keyboard::SuggestQuery query;
        query.codePoints = toCodePoints("Barany");
        printSuggestions("Barany", engine.suggest(query));
        keyboard::SuggestQuery next;
        next.previousWord = "Andreas";
        printSuggestions("nach Andreas", engine.suggest(next));
        printf("isValidWord(Baranyai)=%d\n", engine.isValidWord("Baranyai"));
    }
    engine.flush();

    for (gTopN = 1; gTopN <= 3; ++gTopN) {
    printf("\n== Simulierte ungenaue Finger (sigma = 0.3 Tastenbreite), bester aus Top-%d\n", gTopN);
    const std::vector<std::string> words = {"der", "die", "und", "in", "den", "von", "zu", "das", "mit", "sich", "des", "auf", "für", "ist", "im", "dem", "nicht", "ein", "eine", "als", "auch", "es", "an", "werden", "aus", "er", "hat", "dass", "sie", "nach", "wird", "bei", "einer", "um", "am", "sind", "noch", "wie", "einem", "über", "einen", "so", "zum", "war", "haben", "nur", "oder", "aber", "vor", "zur", "bis", "mehr", "durch", "man", "sein", "wurde", "sei", "hatte", "kann", "gegen", "vom", "können", "schon", "wenn", "habe", "seine", "ihre", "dann", "unter", "wir", "soll", "ich", "eines", "jahr", "zwei", "jahre", "diese", "dieser", "wieder", "keine", "seiner", "worden", "will", "zwischen", "immer", "was", "sagte", "gibt", "alle", "diesem", "seit", "muss", "doch", "jetzt", "heute", "drei", "neue", "damit", "bereits", "da", "weil", "ab", "ohne", "sondern", "selbst", "ersten", "nun", "etwa", "hier", "sagt", "rund", "lange", "leben", "besser", "bleiben", "wenig", "später", "gerade", "wirklich", "vielleicht", "einfach", "eigentlich", "zusammen", "arbeit", "leider", "bitte", "termin", "nachricht", "genau", "kommen", "machen", "gesagt", "wissen", "zeit", "welt", "schreiben", "tastatur", "telefon", "computer", "morgen", "danke", "hallo", "test", "fest", "gut", "gerne", "frage", "antwort", "woche", "abend", "nacht", "tag", "stunde", "minute", "schnell", "langsam", "groß", "klein", "schön", "wichtig", "richtig", "falsch", "heute", "gestern", "geld", "haus", "auto", "stadt", "land", "wasser", "essen", "trinken", "schlafen", "arbeiten", "spielen", "lesen", "sprechen", "hören", "sehen", "fahren", "gehen", "laufen"};
    std::mt19937 rng(42);
    std::normal_distribution<float> noise(0.0f, 0.3f);
    int trials = 0, typos = 0, fixedWithTouch = 0, fixedCenters = 0, brokenWithTouch = 0;
    for (int round = 0; round < 4; ++round) {
        for (const std::string &intended : words) {
            std::vector<int> typedCodes, xs, ys;
            for (int cp : toCodePoints(intended)) {
                const keyboard::KeyGeometry *target = nullptr;
                for (const auto &k : keys) {
                    if (k.code == cp) target = &k;
                }
                if (!target) continue;
                const int x = target->x + target->width / 2 + static_cast<int>(noise(rng) * kKeyWidth);
                const int y = target->y + target->height / 2 + static_cast<int>(noise(rng) * kKeyHeight * 0.6f);
                // The key that was actually hit.
                const keyboard::KeyGeometry *hit = target;
                long best = -1;
                for (const auto &k : keys) {
                    const long dx = x - (k.x + k.width / 2), dy = (y - (k.y + k.height / 2)) * kKeyWidth / kKeyHeight;
                    const long d = dx * dx + dy * dy;
                    if (best < 0 || d < best) { best = d; hit = &k; }
                }
                typedCodes.push_back(hit->code);
                xs.push_back(x);
                ys.push_back(y);
            }
            const std::string typedWord = fromCodePoints(typedCodes);
            ++trials;
            keyboard::SuggestQuery withTouch;
            withTouch.codePoints = typedCodes;
            withTouch.xs = xs;
            withTouch.ys = ys;
            keyboard::SuggestQuery centers;
            centers.codePoints = typedCodes;
            const std::string a = autocorrect(engine, typedWord, engine.suggest(withTouch));
            const std::string b = autocorrect(engine, typedWord, engine.suggest(centers));
            if (typedWord != intended) {
                ++typos;
                if (sameIgnoringCase(a, intended)) ++fixedWithTouch;
                if (sameIgnoringCase(b, intended)) ++fixedCenters;
                if (round == 0 && gTopN == 3 && !sameIgnoringCase(a, intended)) {
                    printf("  verfehlt: %s getippt als %s -> %s\n", intended.c_str(), typedWord.c_str(), a.c_str());
                }
            } else if (!sameIgnoringCase(a, intended)) {
                ++brokenWithTouch;
                if (brokenWithTouch <= 8) printf("  falsch korrigiert: %s -> %s\n", intended.c_str(), a.c_str());
            }
        }
    }
    printf("Wörter: %d, davon vertippt: %d\n", trials, typos);
    printf("korrigiert mit Touch-Positionen: %d (%.0f%%)\n", fixedWithTouch, 100.0 * fixedWithTouch / typos);
    printf("korrigiert nur mit Tastenmitten: %d (%.0f%%)\n", fixedCenters, 100.0 * fixedCenters / typos);
    printf("richtig getippt, aber falsch 'korrigiert': %d\n", brokenWithTouch);
    }
    return 0;
}
