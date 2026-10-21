#!/usr/bin/env python3
"""
Generates entry/src/main/ets/inputmethod/LanguageData.ets and the gzip-compressed dictionaries in
entry/src/main/resources/rawfile/{dicts,emoji_dicts} from HeliBoard's sources (GPL-3.0) and the
Helium314/aosp-dictionaries repository.

  tools/gen_languages.py <HeliBoard checkout> [--download]

Letter rows come from HeliBoard's layouts (assets/layouts/main) plus the locale's extra keys,
long-press popups from the locale key texts plus HeliBoard's common accents. Only languages whose
script works with the keyboard's simple letter grid are listed (Latin, Cyrillic, Greek, Armenian,
Georgian); right-to-left and complex scripts need their own input logic.

--download fetches dictionaries that are not in the project yet; existing ones are kept (they
may be newer builds than the repository's), only compressed.
"""
import gzip
import json
import os
import re
import shutil
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile')
OUT_ETS = os.path.join(ROOT, 'entry', 'src', 'main', 'ets', 'inputmethod', 'LanguageData.ets')
DICT_URL = 'https://codeberg.org/Helium314/aosp-dictionaries/raw/branch/main/dictionaries/'
EMOJI_URL = 'https://codeberg.org/Helium314/aosp-dictionaries/raw/branch/main/emoji_cldr_signal_dictionaries/'

# id, HeliBoard locale (layout + key texts), endonym, dictionary in the repository, emoji
# dictionary, system locales that select this language on first start.
LANGUAGES = [
    ('de', 'de-DE', 'Deutsch', 'main_de', 'de', ['de']),
    ('de_CH', 'de-CH', 'Deutsch (Schweiz)', 'main_de_ch', 'de_ch', ['de-CH', 'de-LI']),
    ('en_US', 'en_US', 'English (US)', 'main_en_us__experimental', 'en', ['en']),
    ('en_GB', 'en_GB', 'English (UK)', 'main_en_gb__experimental', 'en_gb', ['en-GB', 'en-IE', 'en-AU', 'en-NZ', 'en-IN']),
    ('fr', 'fr', 'Français', 'main_fr__experimental', 'fr', ['fr']),
    ('es', 'es', 'Español', 'main_es__experimental', 'es', ['es']),
    ('it', 'it', 'Italiano', 'main_it__experimental', 'it', ['it']),
    ('nl', 'nl', 'Nederlands', 'main_nl__experimental', 'nl', ['nl']),
    ('pt_PT', 'pt', 'Português (PT)', 'main_pt_pt__experimental', 'pt', ['pt']),
    ('pt_BR', 'pt', 'Português (BR)', 'main_pt_br', 'pt', ['pt-BR']),
    ('pl', 'pl', 'Polski', 'main_pl__experimental', 'pl', ['pl']),
    ('ro', 'ro', 'Română', 'main_ro__experimental', 'ro', ['ro']),
    ('sv', 'sv', 'Svenska', 'main_sv__experimental', 'sv', ['sv']),
    ('hu', 'hu', 'Magyar', 'main_hu__experimental', 'hu', ['hu']),
    ('tr', 'tr', 'Türkçe', 'main_tr', 'tr', ['tr']),
    ('ru', 'ru', 'Русский', 'main_ru__experimental', 'ru', ['ru']),
    ('bg', 'bg', 'Български', 'main_bg__experimental', 'bg', ['bg']),
    ('el', 'el', 'Ελληνικά', 'main_el', 'el', ['el']),
    ('af', 'af', 'Afrikaans', 'main_af__experimental', 'af', ['af']),
    ('az', 'az', 'Azərbaycan', 'main_az', 'az', ['az']),
    ('be', 'be', 'Беларуская', 'main_be', 'be', ['be']),
    ('bs', 'hr', 'Bosanski', 'main_bs', 'bs', ['bs']),
    ('ca', 'ca', 'Català', 'main_ca__experimental', 'ca', ['ca']),
    ('cs', 'cs', 'Čeština', 'main_cs__experimental', 'cs', ['cs']),
    ('da', 'da', 'Dansk', 'main_da__experimental', 'da', ['da']),
    ('eo', 'eo', 'Esperanto', 'main_eo__experimental', 'eo', ['eo']),
    ('et', 'et', 'Eesti', 'main_et__experimental', 'et', ['et']),
    ('eu', 'eu', 'Euskara', 'main_eu', 'eu', ['eu']),
    ('fi', 'fi', 'Suomi', 'main_fi__experimental', 'fi', ['fi']),
    ('ga', 'ga', 'Gaeilge', 'main_ga', 'ga', ['ga']),
    ('gl', 'gl', 'Galego', 'main_gl__experimental', 'gl', ['gl']),
    ('hr', 'hr', 'Hrvatski', 'main_hr__experimental', 'hr', ['hr']),
    ('hy', 'hy', 'Հայերեն', 'main_hy_east__experimental', 'hy', ['hy']),
    ('id', 'in', 'Bahasa Indonesia', 'main_id__experimental', 'id', ['id', 'in']),
    ('is', 'is', 'Íslenska', 'main_is__experimental', 'is', ['is']),
    ('ka', 'ka', 'ქართული', 'main_ka', 'ka', ['ka']),
    ('kk', 'kk', 'Қазақ тілі', 'main_kk__experimental', 'kk', ['kk']),
    ('la', 'la', 'Latina', 'main_la', '', ['la']),
    ('lb', 'lb', 'Lëtzebuergesch', 'main_lb', 'lb', ['lb']),
    ('lt', 'lt', 'Lietuvių', 'main_lt__experimental', 'lt', ['lt']),
    ('lv', 'lv', 'Latviešu', 'main_lv__experimental', 'lv', ['lv']),
    ('mk', 'mk', 'Македонски', 'main_mk', 'mk', ['mk']),
    ('nb', 'nb', 'Norsk bokmål', 'main_nb__experimental', 'nb', ['nb', 'no']),
    ('nn', 'nb', 'Norsk nynorsk', 'main_nn', 'nn', ['nn']),
    ('sk', 'sk', 'Slovenčina', 'main_sk', 'sk', ['sk']),
    ('sl', 'sl', 'Slovenščina', 'main_sl__experimental', 'sl', ['sl']),
    ('sr', 'sr', 'Српски', 'main_sr', 'sr', ['sr', 'sr-Cyrl']),
    ('sr_Latn', 'sr-Latn', 'Srpski (latinica)', 'main_sr_zz', 'sr', ['sr-Latn']),
    ('uk', 'uk', 'Українська', 'main_uk__experimental', 'uk', ['uk']),
    ('tl', 'tl', 'Filipino', 'main_tl__experimental', 'fil', ['fil', 'tl']),
]

# Dictionaries that were tuned or picked by hand before this script existed (kept as they are).
EXISTING_NAMES = {'de': 'main_de', 'en_US': 'main_en-US', 'en_GB': 'main_en-GB', 'fr': 'main_fr',
                  'es': 'main_es', 'it': 'main_it', 'nl': 'main_nl', 'pt_PT': 'main_pt-PT',
                  'pt_BR': 'main_pt-BR', 'pl': 'main_pl', 'ro': 'main_ro', 'sv': 'main_sv',
                  'hu': 'main_hu', 'tr': 'main_tr', 'ru': 'main_ru', 'bg': 'main_bg', 'el': 'main_el'}

# Popups that would only clutter the keyboard: a German keyboard has no ß key in the third row.
SKIP_EXTRA_KEYS = {'ß'}
# HeliBoard's French extra keys (è é à) are for Swiss French; Gboard's French AZERTY has none.
NO_EXTRA_KEYS = {'fr'}
# Layouts the subtype list does not name for the locale.
LAYOUT_OVERRIDES = {'sr_Latn': 'qwertz'}
# Scripts whose upper case is not used in running text (Georgian Mtavruli): no shift, no auto-caps.
CASELESS = {'ka'}


def subtype_layouts(heliboard):
    xml = open(os.path.join(heliboard, 'app/src/main/res/xml/method.xml'), encoding='utf-8').read()
    layouts = {}
    for m in re.finditer(r'imeSubtypeLocale="([^"]+)".*?imeSubtypeExtraValue="([^"]*)"', xml, re.S):
        loc, extra = m.groups()
        lay = re.search(r'KeyboardLayoutSet=MAIN:([a-z_0-9]+)', extra)
        layouts.setdefault(loc.replace('_', '-'), lay.group(1) if lay else 'qwerty')
    return layouts


def layout_for(locale, layouts):
    for key in (locale, locale.replace('_', '-')):
        if key in layouts:
            return layouts[key]
    base = locale.split('-')[0].split('_')[0]
    for key, value in layouts.items():
        if key.split('-')[0] == base:
            return value
    return 'qwerty'


def read_layout(heliboard, name):
    """Letter rows: [[(label, [popups])...], ...]."""
    base = os.path.join(heliboard, 'app/src/main/assets/layouts/main', name)
    rows = []
    if os.path.exists(base + '.txt'):
        current = []
        for line in open(base + '.txt', encoding='utf-8').read().split('\n'):
            line = line.strip()
            if not line:
                if current:
                    rows.append(current)
                    current = []
                continue
            parts = line.split()
            current.append((parts[0], parts[1:]))
        if current:
            rows.append(current)
    else:
        data = json.load(open(base + '.json', encoding='utf-8'))
        for row in data:
            keys = []
            for key in row:
                label = key.get('label') or (key.get('default') or {}).get('label')
                if not label or len(label) != 1 or not label.isalpha():
                    continue
                popups = [p.get('label', p) if isinstance(p, dict) else p
                          for p in (key.get('popup') or {}).get('relevant', [])]
                # Georgian: shift gives other letters (ჭ on წ); offer them on long press.
                shifted = (key.get('manualOrLocked') or {}).get('label', '')
                if len(shifted) == 1 and shifted.isalpha() and ord(shifted) > 0x24f and shifted != label:
                    popups.insert(0, shifted)
                keys.append((label, [p for p in popups if isinstance(p, str)]))
            if keys:
                rows.append(keys)
    return rows


def read_key_texts(heliboard, locale):
    """[popup_keys] and [extra_keys] of a locale (falls back to the language's file)."""
    folder = os.path.join(heliboard, 'app/src/main/assets/locale_key_texts')
    popups, extras = {}, {}
    candidates = [locale.replace('_', '-'), locale.split('-')[0].split('_')[0]]
    for name in candidates:
        path = os.path.join(folder, name + '.txt')
        if not os.path.exists(path):
            continue
        section = None
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if line.startswith('['):
                section = line
                continue
            if not line:
                continue
            if section == '[popup_keys]':
                parts = line.split()
                if len(parts[0]) == 1 and parts[0].isalpha():
                    popups.setdefault(parts[0], parts[1:])
            elif section == '[extra_keys]':
                row, _, key = line.partition(':')
                extras.setdefault(int(row), []).append(key.strip().split()[0])
        break
    return popups, extras


def common_popups(heliboard):
    path = os.path.join(heliboard, 'app/src/main/assets/locale_key_texts/more_popups_main.txt')
    result = {}
    section = None
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if line.startswith('['):
            section = line
        elif line and section == '[popup_keys]':
            parts = line.split()
            result[parts[0]] = parts[1:]
    return result


def build_language(heliboard, layouts, common, entry):
    lang_id, locale, label, _, _, _ = entry
    rows = read_layout(heliboard, LAYOUT_OVERRIDES.get(lang_id) or layout_for(locale, layouts))
    popups, extras = read_key_texts(heliboard, locale)
    if lang_id in NO_EXTRA_KEYS:
        extras = {}
    letter_rows = []
    popup_map = {}
    latin = all(ord(k[0]) < 0x250 for row in rows for k in row)
    for index, row in enumerate(rows):
        letters = [k for k, _ in row]
        for key, key_popups in row:
            if key_popups:
                popup_map.setdefault(key, []).extend(key_popups)
        for extra in extras.get(index + 1, []):
            if extra not in letters and extra not in SKIP_EXTRA_KEYS:
                letters.append(extra)
        letter_rows.append(''.join(letters).lower())
    for key, values in popups.items():
        popup_map.setdefault(key, [])[:0] = values
    if latin:
        for key, values in common.items():
            if any(key in r for r in letter_rows):
                popup_map.setdefault(key, []).extend(values)
    on_keys = set(''.join(letter_rows))
    clean = {}
    for key, values in popup_map.items():
        seen = []
        for v in values:
            if len(v) == 1 and v.isalpha() and v not in seen and v not in on_keys and v != key:
                seen.append(v)
        if seen and key in on_keys:
            clean[key] = ''.join(seen[:8])
    return letter_rows, clean


def compress(src, dst):
    with open(src, 'rb') as fin, gzip.open(dst, 'wb', compresslevel=9) as fout:
        shutil.copyfileobj(fin, fout)


def fetch(url, path):
    print('download', url)
    with urllib.request.urlopen(url) as response, open(path, 'wb') as out:
        shutil.copyfileobj(response, out)


def main():
    heliboard = sys.argv[1]
    download = '--download' in sys.argv
    dry = '--dry' in sys.argv  # only print the generated rows
    layouts = subtype_layouts(heliboard)
    common = common_popups(heliboard)
    dict_dir = os.path.join(RAW, 'dicts')
    emoji_dir = os.path.join(RAW, 'emoji_dicts')
    defs = []
    for entry in LANGUAGES:
        lang_id, _, label, dict_name, emoji_name, system = entry
        rows, popups = build_language(heliboard, layouts, common, entry)
        if dry:
            print(f'{lang_id:8} {" / ".join(rows)}   {popups}')
            continue
        dict_file = f'main_{lang_id}.dict.gz'
        raw_existing = os.path.join(dict_dir, EXISTING_NAMES.get(lang_id, '') + '.dict')
        target = os.path.join(dict_dir, dict_file)
        if not os.path.exists(target):
            if lang_id in EXISTING_NAMES and os.path.exists(raw_existing):
                compress(raw_existing, target)
                os.remove(raw_existing)
            elif download:
                tmp = target[:-3]
                fetch(DICT_URL + dict_name + '.dict', tmp)
                compress(tmp, target)
                os.remove(tmp)
        emoji_file = ''
        if emoji_name:
            emoji_file = f'emoji_{emoji_name}.dict.gz'
            emoji_target = os.path.join(emoji_dir, emoji_file)
            plain = emoji_target[:-3]
            if not os.path.exists(emoji_target):
                if not os.path.exists(plain) and download:
                    fetch(EMOJI_URL + f'emoji_{emoji_name}.dict', plain)
                if os.path.exists(plain):
                    compress(plain, emoji_target)
                    os.remove(plain)
            if not os.path.exists(emoji_target):
                emoji_file = ''
        if not os.path.exists(target):
            print('skipping', lang_id, '(no dictionary; run with --download)')
            continue
        defs.append((lang_id, label, dict_file, emoji_file, rows, popups, system))
        print(f'{lang_id:8} {" / ".join(rows)}')

    lines = ['/**',
             ' * Generated by tools/gen_languages.py from HeliBoard assets (layouts/main, locale_key_texts;',
             ' * GPL-3.0): letter rows (incl. per-language extra keys), long-press popups and dictionaries.',
             ' * Do not edit by hand.',
             ' */',
             'export class LanguageDef {',
             '  id: string;',
             '  label: string;',
             '  /** gzip-compressed main dictionary in rawfile/dicts. */',
             '  dict: string;',
             "  /** gzip-compressed word -> emoji dictionary in rawfile/emoji_dicts ('' if none). */",
             '  emojiDict: string;',
             '  rows: string[];',
             '  popups: Record<string, string>;',
             '  /** System locales (BCP 47 prefixes) that pick this language on first start. */',
             '  systemLocales: string[];',
             '  /** No upper case in running text (Georgian): shift and auto-capitalisation are off. */',
             '  caseless: boolean;',
             '',
             '  constructor(id: string, label: string, dict: string, emojiDict: string, rows: string[],',
             '    popups: Record<string, string>, systemLocales: string[], caseless: boolean = false) {',
             '    this.id = id;',
             '    this.label = label;',
             '    this.dict = dict;',
             '    this.emojiDict = emojiDict;',
             '    this.rows = rows;',
             '    this.popups = popups;',
             '    this.systemLocales = systemLocales;',
             '    this.caseless = caseless;',
             '  }',
             '}',
             '',
             'export const LANGUAGES: LanguageDef[] = [']
    body = []
    for lang_id, label, dict_file, emoji_file, rows, popups, system in defs:
        popup_text = ', '.join(f"'{k}': '{v}'" for k, v in popups.items())
        body.append(f"  new LanguageDef('{lang_id}', '{label}', '{dict_file}', '{emoji_file}', "
                    f"[{', '.join(repr(r) for r in rows)}], {{ {popup_text} }}, "
                    f"[{', '.join(repr(s) for s in system)}]" + (', true)' if lang_id in CASELESS else ')'))
    lines.append(',\n'.join(body))
    lines += ['];',
              '',
              'export function languageById(id: string): LanguageDef {',
              '  return LANGUAGES.find((l: LanguageDef) => l.id === id) ?? LANGUAGES[0];',
              '}',
              '']
    if not dry:
        open(OUT_ETS, 'w', encoding='utf-8').write('\n'.join(lines))


if __name__ == '__main__':
    main()
