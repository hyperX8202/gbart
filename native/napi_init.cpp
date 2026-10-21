// NAPI bridge exposing LatinImeEngine to ArkTS as module "libkeyboard_engine.so".
// See entry/src/main/cpp/types/libkeyboard_engine/index.d.ts for the TypeScript surface.
#include <string>
#include <vector>

#include <cstdio>

#include <zlib.h>

#include "latinime_engine.h"
#include "napi/native_api.h"

namespace {

keyboard::LatinImeEngine &engine() {
    static keyboard::LatinImeEngine instance;
    return instance;
}

std::string getString(napi_env env, napi_value value) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return {};
    std::string out(length, '\0');
    napi_get_value_string_utf8(env, value, &out[0], length + 1, &length);
    return out;
}

int getInt(napi_env env, napi_value value) {
    int32_t out = 0;
    napi_get_value_int32(env, value, &out);
    return out;
}

std::vector<int> getIntArray(napi_env env, napi_value value) {
    std::vector<int> out;
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) return out;
    uint32_t length = 0;
    napi_get_array_length(env, value, &length);
    out.reserve(length);
    for (uint32_t i = 0; i < length; ++i) {
        napi_value element;
        napi_get_element(env, value, i, &element);
        out.push_back(getInt(env, element));
    }
    return out;
}

std::vector<int> utf8ToCodePoints(const std::string &utf8) {
    std::vector<int> out;
    for (size_t i = 0; i < utf8.size();) {
        const unsigned char c = static_cast<unsigned char>(utf8[i]);
        const size_t n = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : 4;
        int cp = n == 1 ? c : n == 2 ? (c & 0x1F) : n == 3 ? (c & 0x0F) : (c & 0x07);
        for (size_t k = 1; k < n && i + k < utf8.size(); ++k) {
            cp = (cp << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        }
        out.push_back(cp);
        i += n;
    }
    return out;
}

napi_value makeBool(napi_env env, bool value) {
    napi_value out;
    napi_get_boolean(env, value, &out);
    return out;
}

bool getBool(napi_env env, napi_value value) {
    bool out = false;
    napi_get_value_bool(env, value, &out);
    return out;
}

// addLanguage(locale: string, mainDictPath: string, historyPath: string): boolean
napi_value AddLanguage(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return makeBool(env, false);
    return makeBool(env, engine().addLanguage(getString(env, args[0]), getString(env, args[1]),
            getString(env, args[2])));
}

// addEmojiDictionary(locale: string, path: string): boolean
napi_value AddEmojiDictionary(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return makeBool(env, false);
    return makeBool(env, engine().addEmojiDictionary(getString(env, args[0]), getString(env, args[1])));
}

// emojiFor(word: string, max: number): string[]
napi_value EmojiFor(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::vector<std::string> emoji;
    if (argc >= 2) emoji = engine().emojiFor(getString(env, args[0]), getInt(env, args[1]));
    napi_value result;
    napi_create_array_with_length(env, emoji.size(), &result);
    for (size_t i = 0; i < emoji.size(); ++i) {
        napi_value value;
        napi_create_string_utf8(env, emoji[i].c_str(), emoji[i].size(), &value);
        napi_set_element(env, result, i, value);
    }
    return result;
}

// removeAllLanguages(): void
napi_value RemoveAllLanguages(napi_env env, napi_callback_info info) {
    engine().removeAllLanguages();
    return nullptr;
}

// setLanguageWeight(locale: string, weight: number): void
napi_value SetLanguageWeight(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullptr;
    double weight = 1.0;
    napi_get_value_double(env, args[1], &weight);
    engine().setLanguageWeight(getString(env, args[0]), static_cast<float>(weight));
    return nullptr;
}

// isValidWordIn(locale: string, word: string): boolean
napi_value IsValidWordIn(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return makeBool(env, false);
    return makeBool(env, engine().isValidWordIn(getString(env, args[0]), getString(env, args[1])));
}

// learn(locale: string, word: string, previousWord: string, beginningOfSentence: boolean, isValid: boolean)
napi_value Learn(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) return nullptr;
    engine().learn(getString(env, args[0]), getString(env, args[1]), getString(env, args[2]),
            getBool(env, args[3]), getBool(env, args[4]));
    return nullptr;
}

// flush(): void — writes learned words to disk
napi_value Flush(napi_env env, napi_callback_info info) {
    engine().flush();
    return nullptr;
}

// setKeyboardLayout(width, height, keyWidth, keyHeight, keys: number[]) with keys flattened as
// [code, x, y, width, height, code, x, ...]
napi_value SetKeyboardLayout(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) return nullptr;
    const std::vector<int> flat = getIntArray(env, args[4]);
    std::vector<keyboard::KeyGeometry> keys;
    for (size_t i = 0; i + 4 < flat.size(); i += 5) {
        keys.push_back({flat[i], flat[i + 1], flat[i + 2], flat[i + 3], flat[i + 4]});
    }
    engine().setKeyboardLayout(getInt(env, args[0]), getInt(env, args[1]), getInt(env, args[2]),
            getInt(env, args[3]), keys);
    return nullptr;
}

napi_value makeSuggestions(napi_env env, const std::vector<keyboard::Suggestion> &suggestions) {
    napi_value result;
    napi_create_array_with_length(env, suggestions.size(), &result);
    for (size_t i = 0; i < suggestions.size(); ++i) {
        napi_value item, word, score, normalizedScore, appropriate, locale, fromHistory;
        napi_create_object(env, &item);
        napi_create_string_utf8(env, suggestions[i].word.c_str(), suggestions[i].word.size(), &word);
        napi_create_int32(env, suggestions[i].score, &score);
        napi_create_double(env, suggestions[i].normalizedScore, &normalizedScore);
        napi_get_boolean(env, suggestions[i].appropriateForAutoCorrection, &appropriate);
        napi_set_named_property(env, item, "word", word);
        napi_set_named_property(env, item, "score", score);
        napi_set_named_property(env, item, "normalizedScore", normalizedScore);
        napi_set_named_property(env, item, "appropriateForAutoCorrection", appropriate);
        napi_create_string_utf8(env, suggestions[i].locale.c_str(), suggestions[i].locale.size(), &locale);
        napi_get_boolean(env, suggestions[i].fromHistory, &fromHistory);
        napi_set_named_property(env, item, "locale", locale);
        napi_set_named_property(env, item, "fromHistory", fromHistory);
        napi_set_element(env, result, i, item);
    }
    return result;
}

// suggest(typed: string, xs: number[], ys: number[], previousWord: string,
//         beginningOfSentence: boolean): Suggestion[]
napi_value Suggest(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    keyboard::SuggestQuery query;
    if (argc > 0) query.codePoints = utf8ToCodePoints(getString(env, args[0]));
    if (argc > 2) {
        query.xs = getIntArray(env, args[1]);
        query.ys = getIntArray(env, args[2]);
    }
    if (argc > 3) query.previousWord = getString(env, args[3]);
    if (argc > 4) napi_get_value_bool(env, args[4], &query.beginningOfSentence);

    return makeSuggestions(env, engine().suggest(query));
}

// gesture(xs: number[], ys: number[], previousWord: string, beginningOfSentence: boolean,
//         max: number): Suggestion[]
napi_value Gesture(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return makeSuggestions(env, {});
    keyboard::GestureQuery query;
    query.xs = getIntArray(env, args[0]);
    query.ys = getIntArray(env, args[1]);
    if (argc > 2) query.previousWord = getString(env, args[2]);
    if (argc > 3) napi_get_value_bool(env, args[3], &query.beginningOfSentence);
    if (argc > 4) query.max = getInt(env, args[4]);
    return makeSuggestions(env, engine().gesture(query));
}

// inflateGzip(data: ArrayBuffer, path: string): boolean
// Dictionaries ship gzip-compressed (HAP rawfiles are stored uncompressed); unpacked once per language.
napi_value InflateGzip(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return makeBool(env, false);
    void *data = nullptr;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &length) != napi_ok || !data) return makeBool(env, false);
    const std::string path = getString(env, args[1]);
    const std::string temp = path + ".part";
    FILE *out = fopen(temp.c_str(), "wb");
    if (!out) return makeBool(env, false);
    z_stream stream = {};
    bool ok = inflateInit2(&stream, 16 + MAX_WBITS) == Z_OK;  // 16: gzip header
    stream.next_in = static_cast<Bytef *>(data);
    stream.avail_in = static_cast<uInt>(length);
    std::vector<unsigned char> buffer(1 << 16);
    int status = Z_OK;
    while (ok && status != Z_STREAM_END) {
        stream.next_out = buffer.data();
        stream.avail_out = static_cast<uInt>(buffer.size());
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            ok = false;
            break;
        }
        const size_t produced = buffer.size() - stream.avail_out;
        ok = fwrite(buffer.data(), 1, produced, out) == produced;
    }
    inflateEnd(&stream);
    ok = fclose(out) == 0 && ok;
    ok = ok && rename(temp.c_str(), path.c_str()) == 0;
    if (!ok) remove(temp.c_str());
    return makeBool(env, ok);
}

// isValidWord(word: string): boolean
napi_value IsValidWord(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return makeBool(env, false);
    return makeBool(env, engine().isValidWord(getString(env, args[0])));
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
            {"addLanguage", nullptr, AddLanguage, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"removeAllLanguages", nullptr, RemoveAllLanguages, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"addEmojiDictionary", nullptr, AddEmojiDictionary, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"emojiFor", nullptr, EmojiFor, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setLanguageWeight", nullptr, SetLanguageWeight, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"isValidWordIn", nullptr, IsValidWordIn, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"learn", nullptr, Learn, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"flush", nullptr, Flush, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setKeyboardLayout", nullptr, SetKeyboardLayout, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"suggest", nullptr, Suggest, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"gesture", nullptr, Gesture, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"inflateGzip", nullptr, InflateGzip, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"isValidWord", nullptr, IsValidWord, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module keyboardEngineModule = {
        1,         // nm_version
        0,         // nm_flags
        nullptr,   // nm_filename
        Init,      // nm_register_func
        "keyboard_engine",
        nullptr,   // nm_priv
        {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterKeyboardEngineModule() {
    napi_module_register(&keyboardEngineModule);
}
