#!/bin/sh
# Builds the LatinIME engine for the host (macOS/Linux) and runs the engine tests against the
# bundled dictionaries (typing/autocorrect test, then the gesture typing simulation).
# Usage: native/test/run_host_test.sh [typed words...]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${TMPDIR:-/tmp}/keyboard-host-test
mkdir -p "$OUT"
rm -rf "$OUT/history"
mkdir -p "$OUT/history"
find "$ROOT/third_party/latinime/src" -name '*.cpp' > "$OUT/sources.txt"
# shellcheck disable=SC2046
clang++ -std=c++17 -O2 -w \
  -I"$ROOT/native/ohos_jni" -I"$ROOT/third_party/latinime/src" -I"$ROOT/native" \
  $(cat "$OUT/sources.txt") "$ROOT/native/latinime_engine.cpp" "$ROOT/native/gesture_decoder.cpp" \
  "$ROOT/native/test/engine_smoke_test.cpp" -o "$OUT/engine_smoke_test"
# Work on copies: the engine writes gesture word-list caches next to the dictionaries.
DICTS="$OUT/dicts"
mkdir -p "$DICTS"
# Bundled dictionaries are gzip-compressed (unpacked by the keyboard on first use).
gunzip -c "$ROOT/entry/src/main/resources/rawfile/dicts/main_de.dict.gz" > "$DICTS/main_de.dict"
gunzip -c "$ROOT/entry/src/main/resources/rawfile/dicts/main_en_US.dict.gz" > "$DICTS/main_en-US.dict"
rm -f "$DICTS"/*.gesture
"$OUT/engine_smoke_test" "$DICTS/main_de.dict" "$DICTS/main_en-US.dict" "$OUT/history" "$@"
clang++ -std=c++17 -O2 -w \
  -I"$ROOT/native/ohos_jni" -I"$ROOT/third_party/latinime/src" -I"$ROOT/native" \
  $(cat "$OUT/sources.txt") "$ROOT/native/latinime_engine.cpp" "$ROOT/native/gesture_decoder.cpp" \
  "$ROOT/native/test/gesture_test.cpp" -o "$OUT/gesture_test"
"$OUT/gesture_test" "$DICTS/main_de.dict" "$DICTS/main_en-US.dict"
