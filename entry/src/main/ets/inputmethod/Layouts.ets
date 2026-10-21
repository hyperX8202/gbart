/**
 * Key layouts. Every row is laid out on a virtual grid of KEY_UNIT_WIDTH x KEY_UNIT_HEIGHT units;
 * the letter rows' geometry is handed to the native engine so typo correction knows which keys
 * are neighbours. The UI scales the grid to the real panel size.
 */
import { KeyboardSettings } from './Settings';
import { LanguageDef, languageById } from './LanguageData';

export const KEY_UNIT_WIDTH: number = 100;
export const KEY_UNIT_HEIGHT: number = 150;
/** Gboard's number row is a bit lower than the letter rows. */
export const NUMBER_ROW_HEIGHT: number = 0.8;

export enum KeyKind {
  CHAR,
  SHIFT,
  BACKSPACE,
  SYMBOLS,
  SYMBOLS_MORE,
  LETTERS,
  LANGUAGE,
  EMOJI,
  SPACE,
  ENTER
}

export enum LayoutKind {
  LETTERS,
  SYMBOLS,
  SYMBOLS_MORE
}

export class KeyDef {
  label: string;
  kind: KeyKind;
  /** Width in key units (1 = normal letter key). */
  width: number;
  /** Characters offered on long press, first one is preselected. */
  popup: string[];
  /** Small hint in the key corner (Gboard shows the long-press digit). */
  hint: string;
  /** Key frame in engine units (letter keys only, set by engineGeometry); -1 when not a letter key. */
  engineX: number = -1;
  engineY: number = -1;
  engineWidth: number = 0;
  engineHeight: number = 0;

  constructor(label: string, kind: KeyKind = KeyKind.CHAR, width: number = 1, popup: string[] = [],
    hint: string = '') {
    this.label = label;
    this.kind = kind;
    this.width = width;
    this.popup = popup;
    this.hint = hint;
  }
}

export class KeyboardLayout {
  id: string;
  kind: LayoutKind;
  locale: string;
  rows: KeyDef[][];
  /** First row is the (lower) number row. */
  hasNumberRow: boolean;

  constructor(id: string, kind: LayoutKind, locale: string, rows: KeyDef[][], hasNumberRow: boolean = false) {
    this.id = id;
    this.kind = kind;
    this.locale = locale;
    this.rows = rows;
    this.hasNumberRow = hasNumberRow;
  }

  static rowUnits(row: KeyDef[]): number {
    let sum = 0;
    for (const key of row) {
      sum += key.width;
    }
    return sum;
  }

  /** Widest row in key units; all rows are scaled against it. */
  unitsWide(): number {
    let widest = 0;
    for (const row of this.rows) {
      widest = Math.max(widest, KeyboardLayout.rowUnits(row));
    }
    return widest;
  }
}

/** Splits a string into user-perceived characters (keeps combined emoji/accents together). */
function chars(s: string): string[] {
  const out: string[] = [];
  for (const c of s) {
    out.push(c);
  }
  return out;
}

const DIGITS = '1234567890';

const SYMBOL_POPUPS: Record<string, string> = {
  '.': '.,?!:;…',
  ',': ',;:',
  '-': '–—_·',
  '+': '±',
  '(': '<[{',
  ')': '>]}',
  '€': '$£¥¢₹',
  '\'': '‚‘’‹›',
  '"': '„“”«»',
  '!': '¡',
  '?': '¿',
  '%': '‰',
  '/': '\\',
  '*': '★†‡',
  '0': 'ⁿ∅',
  '1': '¹½⅓¼⅛',
  '2': '²⅔',
  '3': '³¾⅜',
  '=': '≠≈∞'
};

function letterRow(letters: string, popups: Record<string, string>, withDigitHints: boolean): KeyDef[] {
  const row: KeyDef[] = [];
  const list = chars(letters);
  for (let i = 0; i < list.length; i++) {
    const c = list[i];
    const popup: string[] = [];
    let hint = '';
    if (withDigitHints && i < DIGITS.length) {
      hint = DIGITS.charAt(i);
      popup.push(hint);
    }
    for (const a of chars(popups[c] ?? '')) {
      popup.push(a);
    }
    row.push(new KeyDef(c, KeyKind.CHAR, 1, popup, hint));
  }
  return row;
}

function symbolRow(symbols: string): KeyDef[] {
  const row: KeyDef[] = [];
  for (const c of chars(symbols)) {
    row.push(new KeyDef(c, KeyKind.CHAR, 1, chars(SYMBOL_POPUPS[c] ?? '')));
  }
  return row;
}

/** Like Gboard: ten equally wide digit keys spanning the full keyboard width. */
function numberRow(totalUnits: number): KeyDef[] {
  const row = symbolRow(DIGITS);
  for (const key of row) {
    key.width = totalUnits / DIGITS.length;
  }
  return row;
}

/** ?123 , [😊] [🌐] space . ⏎ — the space key takes whatever width is left. */
function bottomRow(totalUnits: number, settings: KeyboardSettings, modeKey: KeyDef): KeyDef[] {
  const row: KeyDef[] = [modeKey, new KeyDef(',', KeyKind.CHAR, 1, chars(SYMBOL_POPUPS[','] ?? ''))];
  if (settings.showEmojiKey) {
    row.push(new KeyDef('☺', KeyKind.EMOJI, 1));
  }
  if (settings.showLanguageKey && settings.languages.length > 1) {
    row.push(new KeyDef('🌐', KeyKind.LANGUAGE, 1));
  }
  const dot = new KeyDef('.', KeyKind.CHAR, 1, chars(SYMBOL_POPUPS['.'] ?? ''));
  const enter = new KeyDef('⏎', KeyKind.ENTER, 1.5);
  const used = KeyboardLayout.rowUnits(row) + dot.width + enter.width;
  row.push(new KeyDef('', KeyKind.SPACE, Math.max(3, totalUnits - used)));
  row.push(dot, enter);
  return row;
}

/** Letter layout of a language (HeliBoard rows incl. extra keys), Gboard-style bottom row. */
export function buildLetters(languageId: string, settings: KeyboardSettings): KeyboardLayout {
  const lang: LanguageDef = languageById(languageId);
  const hints = !settings.numberRow;
  let total = 10;
  for (const r of lang.rows) {
    total = Math.max(total, chars(r).length);
  }
  const rows: KeyDef[][] = [];
  if (settings.numberRow) {
    rows.push(numberRow(total));
  }
  // All but the last letter row stand alone (Armenian has four); shift and backspace share what
  // is left of the last row (1.5 units each when there is room).
  const last = lang.rows.length - 1;
  for (let i = 0; i < last; i++) {
    rows.push(letterRow(lang.rows[i], lang.popups, hints && i === 0));
  }
  const bottom = letterRow(lang.rows[last], lang.popups, false);
  const side = Math.max(1, Math.min(1.5, (total - bottom.length) / 2));
  rows.push([new KeyDef('⇧', KeyKind.SHIFT, side)].concat(bottom).concat([new KeyDef('⌫', KeyKind.BACKSPACE, side)]));
  rows.push(bottomRow(total, settings, new KeyDef('?123', KeyKind.SYMBOLS, 1.5)));
  const layout = new KeyboardLayout(`letters-${lang.id}-${settings.numberRow}-${settings.showEmojiKey}-` +
    `${settings.showLanguageKey}`, LayoutKind.LETTERS, lang.id, rows, settings.numberRow);
  engineGeometry(layout);
  return layout;
}

export function buildSymbols(locale: string, settings: KeyboardSettings, more: boolean): KeyboardLayout {
  const rows: KeyDef[][] = [];
  if (!more) {
    rows.push(symbolRow('1234567890'));
    rows.push(symbolRow('@#€_&-+()/'));
    rows.push([new KeyDef('=\\<', KeyKind.SYMBOLS_MORE, 1.5)].concat(symbolRow('*"\':;!?'))
      .concat([new KeyDef('⌫', KeyKind.BACKSPACE, 1.5)]));
  } else {
    rows.push(symbolRow('~`|•√π÷×¶∆'));
    rows.push(symbolRow('£¥$¢^°={}\\'));
    rows.push([new KeyDef('?123', KeyKind.SYMBOLS, 1.5)].concat(symbolRow('%©®™✓[]'))
      .concat([new KeyDef('⌫', KeyKind.BACKSPACE, 1.5)]));
  }
  rows.push(bottomRow(10, settings, new KeyDef('ABC', KeyKind.LETTERS, 1.5)));
  return new KeyboardLayout(`symbols-${more}-${settings.showEmojiKey}`,
    more ? LayoutKind.SYMBOLS_MORE : LayoutKind.SYMBOLS, locale, rows);
}

/**
 * Flattened [code, x, y, width, height, ...] geometry of the letter keys for setKeyboardLayout().
 * Rows are centred like the UI renders them; the optional number row is left out. Also stores
 * each key's frame on the KeyDef so touch points can be converted into engine units.
 */
export function engineGeometry(layout: KeyboardLayout): number[] {
  const out: number[] = [];
  const total = layout.unitsWide();
  let rowIndex = 0;
  for (const row of layout.rows) {
    const hasLetters = row.some((k: KeyDef) => k.kind === KeyKind.CHAR && k.label.toLowerCase() !== k.label.toUpperCase());
    if (!hasLetters) {
      continue;
    }
    let x = (total - KeyboardLayout.rowUnits(row)) * KEY_UNIT_WIDTH / 2;
    for (const key of row) {
      const width = key.width * KEY_UNIT_WIDTH;
      if (key.kind === KeyKind.CHAR && key.label.length === 1) {
        key.engineX = Math.round(x);
        key.engineY = rowIndex * KEY_UNIT_HEIGHT;
        key.engineWidth = Math.round(width);
        key.engineHeight = KEY_UNIT_HEIGHT;
        out.push(key.label.codePointAt(0) as number, key.engineX, key.engineY, key.engineWidth, key.engineHeight);
      }
      x += width;
    }
    rowIndex++;
  }
  return out;
}

export function dictionaryForLanguage(languageId: string): string {
  return languageById(languageId).dict;
}

/** HeliBoard emoji_cldr_signal dictionary (word -> emoji) for a language, '' if none. */
export function emojiDictionaryForLanguage(languageId: string): string {
  return languageById(languageId).emojiDict;
}

export function languageLabel(languageId: string): string {
  return languageById(languageId).label;
}
