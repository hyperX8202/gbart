# gBart – Tastatur für HarmonyOS

**Deutsch** · [English](README.md)

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-TeamHX-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/TeamHX)

Systemweite Tastatur (Input Method) für HarmonyOS NEXT (getestet: Mate XT 2, HarmonyOS 7 / API 26),
gebaut nach dem Vorbild von Gboard. Die Vorschlags- und Korrektur-Engine ist der C++-Kern von
[HeliBoard](https://github.com/Helium314/HeliBoard) (AOSP LatinIME), unverändert übernommen;
die Gleiteingabe ist ein eigener Decoder.

Lizenz: GPL-3.0 (wie HeliBoard). Der AOSP-Kern steht zusätzlich unter Apache-2.0,
siehe `third_party/latinime/` und `THIRD_PARTY_NOTICES.md`.

## Funktionen

- Autokorrektur wie HeliBoard/Gboard (Tastenabstände aus echten Touch-Positionen, Schwelle
  „Moderat/Aggressiv/Sehr aggressiv“, Rücktaste macht die Korrektur rückgängig, fehlende
  Leerzeichen „ichbin → ich bin“)
- 50 Sprachen (lateinische, kyrillische, griechische, armenische und georgische Schrift), mehrere
  gleichzeitig mit Sprach-Konfidenz wie HeliBoard; beim ersten Start ist die Systemsprache aktiv
- Wortvorhersage (Wortpaare aus den Wörterbüchern) und Lernen aus dem Tippverlauf
- Gleitende Eingabe (Swipe) mit Bewegungspfad, Alternativen in der Leiste, automatischem
  Leerzeichen und „Rücktaste löscht ganzes Wort“
- Emoji-Taste und Emoji-Panel, Emoji-Vorschläge („Pizza“ → 🍕)
- Designs wie bei Gboard: System/Hell/Dunkel, Farben, Farbverläufe, Landschaften
  (`tools/themes/make_landscapes.py`), eigenes Bild mit Helligkeitsregler, Tastenumrandung an/aus
- Geteilte Tastatur (Automatisch: im Querformat und aufgeklappt beim Mate XT, oder Immer/Nie);
  Querformat mit niedrigeren Tasten
- Zahlenreihe, Haptik, Großschreibung am Satzanfang, Punkt durch doppeltes Leerzeichen,
  Cursor per Leertaste, Wort löschen durch Wischen auf der Rücktaste
- Einstellungs-App wie bei Gboard (App-Symbol oder Zahnrad in der Tastatur), folgt dem hellen bzw.
  dunklen Systemdesign; Oberfläche in 20 Sprachen nach Systemsprache (`tools/ui_translations.py`,
  sonst Englisch). Einrichtung über System › Eingabemethoden (Apps dürfen die Tastatur nicht selbst
  umschalten)
- Datenschutz: keine Internet-Berechtigung; Gelerntes bleibt auf dem Gerät

## Aufbau

```
third_party/latinime/src     HeliBoard/AOSP-Kern (unverändert, Stand in SOURCE.txt)
native/ohos_jni/jni.h        Ersatz für die JNI-Typen, damit der Kern ohne Android baut
native/latinime_engine.*     C++-Schnittstelle (Sprachen, Lernen, Vorschläge, Emoji, Gesten)
native/gesture_decoder.*     Gleiteingabe: Pfadabgleich (SHARK2-Prinzip) + Sprachmodell
native/napi_init.cpp         NAPI-Brücke → ArkTS-Modul "libkeyboard_engine.so"
native/test/                 Host-Tests (macOS/Linux) mit echten Wörterbüchern
entry/src/main/cpp           CMake-Build der nativen Bibliothek für das Gerät
entry/src/main/ets
  inputmethod/KeyboardExtAbility.ets   Input-Method-Erweiterung (Panel, Ereignisse, Wörterbücher)
  inputmethod/KeyboardController.ets   Eingabelogik (Vorschläge, Autokorrektur, Gesten, Lernen)
  inputmethod/Layouts.ets, LanguageData.ets   Tastenlayouts der Sprachen
  inputmethod/Settings.ets             Einstellungen (gemeinsame JSON-Datei im distributedFilesDir:
                                       der einzige Ordner, den App und Eingabemethoden-Sandbox teilen)
  pages/KeyboardPanel.ets              Tastatur-Oberfläche inkl. Emoji
  pages/Index.ets, SettingsRows.ets    Einstellungs-App
tools/gen_languages.py                 erzeugt LanguageData.ets und die gepackten Wörterbücher
entry/src/main/resources/rawfile       Wörterbücher (dicts/*.dict.gz, beim ersten Aktivieren einer Sprache
                                       entpackt), Emoji-Wörterbücher, Emoji-Listen, Lizenztexte
```

## Bauen und installieren

1. DevEco Studio installieren, Projektordner `keyboard/` öffnen, mit Huawei-ID anmelden und unter
   *File → Project Structure → Signing Configs* „Automatically generate signature“ wählen.
2. Bauen und installieren (oder *Run* in DevEco):

   ```sh
   C=/Applications/DevEco-Studio.app/Contents
   DEVECO_SDK_HOME=$C/sdk PATH=$C/tools/node/bin:$PATH node $C/tools/hvigor/bin/hvigorw.js \
     --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon assembleHap
   hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
   hdc shell "ime -e com.ab.keyboard -f; ime -s com.ab.keyboard"   # Vollmodus (Vibration)
   ```
3. Auf dem Gerät in der App „Tastatur“ auf *Tastatur auswählen* tippen.

## Testen

```sh
native/test/run_host_test.sh            # Tippfehler-Simulation + Gesten-Simulation auf dem Mac
native/test/run_host_test.sh hallp      # eigene Wörter
```

Auf dem Gerät lassen sich per hdc nur gerade Wischstriche einspielen
(`hdc shell "uinput -T -m x1 y1 x2 y2 600"`); Wischwörter über mehrere Tasten bitte mit dem Finger
testen.

## Sprachen ergänzen

`tools/gen_languages.py <HeliBoard-Checkout> --download` erzeugt `LanguageData.ets` (Tastenreihen
und Popups aus HeliBoards `assets/layouts` und `assets/locale_key_texts`) und lädt fehlende
Wörterbücher aus codeberg.org/Helium314/aosp-dictionaries. Danach `THIRD_PARTY_NOTICES.md` und
`LICENSE` nach `rawfile/licenses/` kopieren (die App zeigt sie unter Info › Lizenzen) und in
`KeyboardExtAbility.ets` `DICTIONARY_VERSION` erhöhen, wenn sich Wörterbücher geändert haben.

## Veröffentlichen

Für AppGallery wird ein Release-Zertifikat und -Profil aus AppGallery Connect benötigt; die
automatische Signatur von DevEco gilt nur für Debug-Builds auf registrierten Geräten.

1. Lokal ein Produkt `release` ohne `signingConfig` in `build-profile.json5` anlegen (die Datei ist
   im Repo ohne Signaturdaten) und unsigniert bauen:
   `hvigorw --mode project -p product=release -p buildMode=release assembleApp`
2. `tools/sign_release.sh <Signatur-Ordner>` signiert `build/outputs/release/*-unsigned.app` mit
   Schlüssel (`keyboard-release.p12`, Passwort in `PASSWORT.txt`), AGC-Zertifikat (`*.cer`) und
   AGC-Release-Profil (`*.p7b`) und prüft die Signatur. Das Ergebnis wird in AGC hochgeladen.

## Unterstützen

gBart ist kostenlos und ohne Werbung. Wenn dir die Tastatur gefällt, kannst du die Entwicklung mit
einem Kaffee unterstützen: [buymeacoffee.com/TeamHX](https://buymeacoffee.com/TeamHX)
