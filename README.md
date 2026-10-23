# gBart – keyboard for HarmonyOS

[English](README.md) · [Deutsch](README.de.md)

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-TeamHX-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/TeamHX)

System-wide keyboard (input method) for HarmonyOS NEXT (tested: Mate XT 2, HarmonyOS 7 / API 26),
modelled on Gboard. The suggestion and correction engine is the C++ core of
[HeliBoard](https://github.com/Helium314/HeliBoard) (AOSP LatinIME), taken over unchanged;
glide typing uses a decoder written for this project.

License: GPL-3.0 (like HeliBoard). The AOSP core is additionally licensed under Apache-2.0,
see `third_party/latinime/` and `THIRD_PARTY_NOTICES.md`.
Privacy policy: <https://hyperx8202.github.io/gbart/privacy.html>

## Features

- Autocorrect like HeliBoard/Gboard (key distances from real touch positions, threshold
  "Moderate/Aggressive/Very aggressive", backspace undoes a correction, missing spaces
  "ichbin → ich bin")
- 50 languages (Latin, Cyrillic, Greek, Armenian and Georgian scripts), several at once with
  language confidence as in HeliBoard; the system language is active on first start
- Next-word prediction (word pairs from the dictionaries) and learning from what you type
- Glide typing (swipe) with a movement trail, alternatives in the suggestion strip, automatic
  space and "backspace deletes the whole word"
- Emoji key and emoji panel, emoji suggestions ("pizza" → 🍕)
- Themes like Gboard: system/light/dark, colours, gradients, landscapes
  (`tools/themes/make_landscapes.py`), your own picture with a brightness slider, key borders on/off
- Split keyboard (Automatic: in landscape and when unfolded on the Mate XT, or Always/Never);
  lower keys in landscape
- Number row, haptic feedback, capitalisation at the start of a sentence, full stop on double
  space, cursor control with the space bar, delete a word by swiping on backspace
- Settings app like Gboard's (app icon or gear in the keyboard), follows the light or dark system
  theme; interface in 20 languages according to the system language (`tools/ui_translations.py`,
  English otherwise). Set-up through System › Input methods (apps are not allowed to switch the
  keyboard themselves)
- Privacy: no internet permission; everything learned stays on the device

## Layout of the project

```
third_party/latinime/src     HeliBoard/AOSP core (unchanged, revision in SOURCE.txt)
native/ohos_jni/jni.h        replacement for the JNI types so the core builds without Android
native/latinime_engine.*     C++ interface (languages, learning, suggestions, emoji, gestures)
native/gesture_decoder.*     glide typing: path matching (SHARK2 principle) + language model
native/napi_init.cpp         NAPI bridge → ArkTS module "libkeyboard_engine.so"
native/test/                 host tests (macOS/Linux) with the real dictionaries
entry/src/main/cpp           CMake build of the native library for the device
entry/src/main/ets
  inputmethod/KeyboardExtAbility.ets   input method extension (panel, events, dictionaries)
  inputmethod/KeyboardController.ets   typing logic (suggestions, autocorrect, gestures, learning)
  inputmethod/Layouts.ets, LanguageData.ets   key layouts of the languages
  inputmethod/Settings.ets             settings (shared JSON file in distributedFilesDir:
                                       the only folder the app and the input method sandbox share)
  pages/KeyboardPanel.ets              keyboard UI including emoji
  pages/Index.ets, SettingsRows.ets    settings app
tools/gen_languages.py                 generates LanguageData.ets and the packed dictionaries
entry/src/main/resources/rawfile       dictionaries (dicts/*.dict.gz, unpacked the first time a language
                                       is activated), emoji dictionaries, emoji lists, licence texts
```

## Build and install

1. Install DevEco Studio, open the `keyboard/` project folder, sign in with a Huawei ID and choose
   "Automatically generate signature" under *File → Project Structure → Signing Configs*.
2. Build and install (or *Run* in DevEco):

   ```sh
   C=/Applications/DevEco-Studio.app/Contents
   DEVECO_SDK_HOME=$C/sdk PATH=$C/tools/node/bin:$PATH node $C/tools/hvigor/bin/hvigorw.js \
     --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon assembleHap
   hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
   hdc shell "ime -e com.ab.keyboard -f; ime -s com.ab.keyboard"   # full mode (vibration)
   ```
3. On the device, open the app and tap *Select keyboard*.

## Testing

```sh
native/test/run_host_test.sh            # typo simulation + gesture simulation on the Mac
native/test/run_host_test.sh hallp      # your own words
```

On the device hdc can only inject straight swipes
(`hdc shell "uinput -T -m x1 y1 x2 y2 600"`); please test swipe words across several keys with a
finger.

## Adding languages

`tools/gen_languages.py <HeliBoard-checkout> --download` generates `LanguageData.ets` (key rows
and popups from HeliBoard's `assets/layouts` and `assets/locale_key_texts`) and downloads missing
dictionaries from codeberg.org/Helium314/aosp-dictionaries. Then copy `THIRD_PARTY_NOTICES.md` and
`LICENSE` to `rawfile/licenses/` (the app shows them under About › Licences) and raise
`DICTIONARY_VERSION` in `KeyboardExtAbility.ets` if dictionaries changed.

## Publishing

AppGallery needs a release certificate and profile from AppGallery Connect; DevEco's automatic
signature only works for debug builds on registered devices.

1. Create a local product `release` without `signingConfig` in `build-profile.json5` (the file in
   the repo has no signing data) and build unsigned:
   `hvigorw --mode project -p product=release -p buildMode=release assembleApp`
2. `tools/sign_release.sh <signing-folder>` signs `build/outputs/release/*-unsigned.app` with the
   key (`keyboard-release.p12`, password in `PASSWORT.txt`), the AGC certificate (`*.cer`) and the
   AGC release profile (`*.p7b`) and verifies the signature. Upload the result in AGC.

## Support

gBart is free and has no ads. If you like the keyboard, you can support its development with a
coffee: [buymeacoffee.com/TeamHX](https://buymeacoffee.com/TeamHX)
