import { inputMethodEngine } from '@kit.IMEKit';
import { vibrator } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import engine, { Suggestion } from 'libkeyboard_engine.so';
import { buildLetters, buildSymbols, engineGeometry, KeyboardLayout, KEY_UNIT_HEIGHT, KEY_UNIT_WIDTH,
  languageLabel, LayoutKind, NUMBER_ROW_HEIGHT } from './Layouts';
import { KeyboardSettings, SettingsStore } from './Settings';
import { emojiPopularityRank, MAX_RECENT_EMOJIS } from './Emoji';
import { languageById } from './LanguageData';

const TAG = 'KeyboardController';
const DOMAIN = 0x4b42;
const SENTENCE_END = '.!?';
/** Characters that end a word. Everything else (letters, digits, @ _ - ') belongs to it. */
const SEPARATORS = ' \n\t.,!?;:"()[]{}<>«»„“”/\\|*';
/** Punctuation that swaps with a preceding auto/commit space ("word ." -> "word. "). */
const SWAP_PUNCTUATION = '.,!?;:';
/** HeliBoard multilingual typing: per-language confidence 0..MAX steers the dictionary weights. */
const MAX_CONFIDENCE = 2;
const CONFIDENCE_STEP = 0.15;
/** Missing-space corrections ("ichbin" -> "ich bin") are accepted at this lower threshold. */
const SPLIT_WORD_THRESHOLD = 0.05;
/** Preset haptic effects in order of preference for key presses. */
const HAPTIC_EFFECTS: string[] = ['haptic.effect.soft', 'haptic.clock.timer', 'haptic.effect.sharp'];
const CONTEXT_LENGTH = 64;
/** Chat words missing from the dictionaries that are typed on purpose; never autocorrected. */
const CHAT_WORDS: Set<string> = new Set<string>(['lol', 'xd', 'omg', 'btw', 'imho', 'idk', 'thx', 'pls', 'plz',
  'haha', 'hahaha', 'hihi', 'hehe', 'lmao', 'rofl', 'wtf', 'brb', 'afk', 'asap', 'fyi', 'np', 'ok', 'okay', 'lg',
  'vg', 'mfg', 'gn8', 'hdl', 'hdgdl', 'kp', 'wb', 'jk', 'tbh', 'smh', 'yolo', 'xoxo', 'mega', 'nö', 'jo', 'joa',
  'vlt', 'vllt', 'jmd', 'jmdn', 'jmdm', 'evtl', 'iwie', 'iwas', 'iwo', 'nix', 'nen', 'nem', 'ne', 'ka', 'gn', 'gm', 'mmn',
  'wg', 'wgn', 'bissl', 'grad', 'sry', 'dsl', 'kk', 'ofc', 'ig', 'tf', 'irl', 'dm', 'bday', 'gz', 'gg', 'wp']);
const EDIT_CONFIRM_TIMEOUT_MS = 600;
/**
 * Editor calls that do not answer within this time count as failed. Android apps in the
 * HarmonyOS container are reached through a bridge (AncoIme) whose answers to queries such as
 * getTextIndexAtCursor() can be refused and then never arrive; without a bound the key queue
 * would wait forever and no key would be typed any more.
 */
const CLIENT_CALL_TIMEOUT_MS = 400;

export enum PanelMode {
  KEYS,
  EMOJI
}

/** Keys of the LocalStorage shared with pages/KeyboardPanel. */
export class StorageKeys {
  static readonly LAYOUT: string = 'kb_layout';
  static readonly STRIP: string = 'kb_strip';
  static readonly SHIFT: string = 'kb_shift';
  static readonly CAPS_LOCK: string = 'kb_caps_lock';
  static readonly ENTER_LABEL: string = 'kb_enter_label';
  static readonly SPACE_LABEL: string = 'kb_space_label';
  static readonly MODE: string = 'kb_mode';
  static readonly SETTINGS: string = 'kb_settings';
  static readonly RECENT_EMOJIS: string = 'kb_recent_emojis';
}

/** Gboard-style suggestion strip: typed word left, best/autocorrection centre, next right. */
export class StripState {
  left: string = '';
  center: string = '';
  right: string = '';
  leftWord: string = '';
  centerWord: string = '';
  rightWord: string = '';
  /** Centre is what space will autocorrect to (rendered bold/accent). */
  centerIsAutocorrect: boolean = false;
  /** Right slot is an emoji for the word; picking it replaces the word. */
  rightIsEmoji: boolean = false;

  isEmpty(): boolean {
    return this.left.length === 0 && this.center.length === 0 && this.right.length === 0;
  }
}

export enum StripSlot {
  LEFT,
  CENTER,
  RIGHT
}

class Correction {
  typed: string;
  corrected: string;
  separator: string;

  constructor(typed: string, corrected: string, separator: string) {
    this.typed = typed;
    this.corrected = corrected;
    this.separator = separator;
  }
}

class Candidate {
  word: string;
  normalizedScore: number;
  appropriate: boolean;
  locale: string;

  constructor(word: string, normalizedScore: number, appropriate: boolean, locale: string) {
    this.word = word;
    this.normalizedScore = normalizedScore;
    this.appropriate = appropriate;
    this.locale = locale;
  }
}

class ClientTimeout extends Error {
}

/** `call` with a time limit: rejects with a ClientTimeout after CLIENT_CALL_TIMEOUT_MS. */
function bounded<T>(call: Promise<T>, name: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new ClientTimeout(`${name} timed out`));
    }, CLIENT_CALL_TIMEOUT_MS);
    call.then((value: T) => {
      clearTimeout(timer);
      resolve(value);
    }).catch((e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

function isSeparator(c: string): boolean {
  return SEPARATORS.includes(c);
}

function isLetter(c: string): boolean {
  return c.toLowerCase() !== c.toUpperCase();
}

function isUpper(c: string): boolean {
  return isLetter(c) && c === c.toUpperCase();
}

/** Word directly before the cursor. Emoji (surrogate pairs) end a word as well. */
function trailingWord(before: string): string {
  let i = before.length;
  while (i > 0) {
    const c = before.charAt(i - 1);
    const code = c.charCodeAt(0);
    if (isSeparator(c) || (code >= 0xD800 && code <= 0xDFFF)) {
      break;
    }
    i--;
  }
  return before.substring(i);
}

function codePointLength(s: string): number {
  let n = 0;
  for (const c of s) {
    n += c.length > 0 ? 1 : 0;
  }
  return n;
}

function capitalizeFirst(word: string): string {
  return word.length === 0 ? word : word.charAt(0).toUpperCase() + word.substring(1);
}

function hasDigit(word: string): boolean {
  for (const c of word) {
    if (c >= '0' && c <= '9') {
      return true;
    }
  }
  return false;
}

function upperCount(word: string): number {
  let n = 0;
  for (const c of word) {
    if (isUpper(c)) {
      n++;
    }
  }
  return n;
}

function isAllCaps(word: string): boolean {
  return word.length > 1 && upperCount(word) > 0 && word === word.toUpperCase();
}

/**
 * Turns key presses into edits on the focused text field. The word being typed (with its touch
 * points) is tracked from our own key presses; the editor text is mirrored from HarmonyOS events
 * for context (previous word, sentence start, resumed words). All edits run through one queue so
 * fast typing never interleaves.
 */
export class KeyboardController {
  private client: inputMethodEngine.InputClient | null = null;
  private storage: LocalStorage;
  private settingsStore: SettingsStore;
  private settings: KeyboardSettings = new KeyboardSettings();
  private locale: string = 'de';
  private letters: KeyboardLayout;
  private queue: Promise<void> = Promise.resolve();

  private enterKeyType: number = inputMethodEngine.ENTER_KEY_TYPE_UNSPECIFIED;
  /** False for e-mail, URL and password fields: no auto-capitalisation and no autocorrect. */
  private proseField: boolean = true;
  private capitalizeWords: boolean = false;

  /** Letters typed by us for the current word; empty if the word was not typed in this session. */
  private composing: string = '';
  /** Touch point per composing character in engine units (-1 when unknown, e.g. popup accents). */
  private composingXs: number[] = [];
  private composingYs: number[] = [];
  /** Multilingual typing: how sure we are that the user is writing in each enabled language. */
  private confidence: Map<string, number> = new Map<string, number>();
  private candidates: Candidate[] = [];
  private lastCorrection: Correction | null = null;
  /** A word the user reverted with backspace: never autocorrect it again. */
  private rejectedWord: string = '';
  /** The last commit ended with a space we (or the space key) put there: punctuation may swap. */
  private spaceCommitted: boolean = false;
  private lastSpaceAt: number = 0;
  /**
   * Gesture typing: the word the last swipe inserted and its alternatives (shown in the strip).
   * While gesturePending, the next letter gets a space first and backspace removes the whole
   * word, like Gboard.
   */
  private gestureWord: string = '';
  private gestureAlternatives: string[] = [];
  private gesturePending: boolean = false;
  private recentEmojis: string[] = [];
  /** Index into HAPTIC_EFFECTS; == length means timed vibration; beyond that haptics are off. */
  private hapticIndex: number = 0;
  // Mirror of the editor content. HarmonyOS 7 returns '' from getBackward() for third-party
  // keyboards, but delivers the full text via the 'textChange' event; our own edits are applied
  // to the mirror immediately and events only overwrite it once all our edits are confirmed.
  private mirrorText: string = '';
  private mirrorCursor: number = 0;
  private mirrorSelectionEnd: number = 0;
  private mirrorKnown: boolean = false;
  /** Our own edits whose 'textChange' / 'selectionChange' events have not arrived yet. */
  private pendingTextEvents: number = 0;
  private pendingSelectionEvents: number = 0;
  private lastEditAt: number = 0;
  /**
   * False once the editor left a call unanswered (Android apps behind the AncoIme bridge execute
   * edits but never confirm them): edits are then sent without waiting, so typing stays fast.
   */
  private clientResponsive: boolean = true;

  /** Set by the input method ability: (re)load main + history dictionaries for these languages. */
  languagesHandler: ((languages: string[]) => void) | null = null;
  /** Set by the input method ability: opens the settings app. */
  openSettingsHandler: (() => void) | null = null;
  /** The letter layout changed (e.g. Armenian has four rows): the panel height must follow. */
  layoutChangedHandler: (() => void) | null = null;
  hideKeyboardHandler: (() => void) | null = null;

  constructor(storage: LocalStorage, settingsStore: SettingsStore) {
    this.storage = storage;
    this.settingsStore = settingsStore;
    this.letters = buildLetters('de', this.settings);
    storage.setOrCreate<KeyboardLayout>(StorageKeys.LAYOUT, this.letters);
    storage.setOrCreate<StripState>(StorageKeys.STRIP, new StripState());
    storage.setOrCreate<boolean>(StorageKeys.SHIFT, false);
    storage.setOrCreate<boolean>(StorageKeys.CAPS_LOCK, false);
    storage.setOrCreate<string>(StorageKeys.ENTER_LABEL, 'return');
    storage.setOrCreate<string>(StorageKeys.SPACE_LABEL, languageLabel('de'));
    storage.setOrCreate<PanelMode>(StorageKeys.MODE, PanelMode.KEYS);
    storage.setOrCreate<KeyboardSettings>(StorageKeys.SETTINGS, this.settings);
    storage.setOrCreate<string[]>(StorageKeys.RECENT_EMOJIS, []);
  }

  // --- lifecycle -----------------------------------------------------------------------------

  applySettings(settings: KeyboardSettings): void {
    this.settings = settings;
    this.recentEmojis = settings.recentEmojis.slice();
    this.storage.set<KeyboardSettings>(StorageKeys.SETTINGS, settings);
    this.storage.set<string[]>(StorageKeys.RECENT_EMOJIS, this.recentEmojis);
    this.letters = buildLetters(this.locale, settings);
    this.storage.set<KeyboardLayout>(StorageKeys.LAYOUT, this.letters);
    this.pickHapticMode();
  }

  currentSettings(): KeyboardSettings {
    return this.settings;
  }

  /** Height of the letter layout in key rows (the number row is shorter, like Gboard's). */
  rowCount(): number {
    return this.letters.rows.length - (this.letters.hasNumberRow ? 1 - NUMBER_ROW_HEIGHT : 0);
  }

  /** Switches the letter layout (the dictionaries of all enabled languages stay active). */
  setLayoutLanguage(languageId: string): void {
    this.locale = languageId;
    this.letters = buildLetters(languageId, this.settings);
    engine.setKeyboardLayout(this.letters.unitsWide() * KEY_UNIT_WIDTH,
      languageById(languageId).rows.length * KEY_UNIT_HEIGHT, KEY_UNIT_WIDTH, KEY_UNIT_HEIGHT,
      engineGeometry(this.letters));
    this.storage.set<KeyboardLayout>(StorageKeys.LAYOUT, this.letters);
    this.storage.set<string>(StorageKeys.SPACE_LABEL, languageLabel(languageId));
    this.layoutChangedHandler?.();
    this.resetComposing();
    this.publishStrip(new StripState());
    // Choosing a layout is a strong hint about the language being typed.
    this.confidence.set(languageId, MAX_CONFIDENCE);
    this.applyLanguageWeights();
  }

  /** HeliBoard DictionaryGroup.getWeightForLocale(): lower weight for languages we are unsure about. */
  private applyLanguageWeights(): void {
    const langs = this.settings.languages;
    for (const lang of langs) {
      let weight = 1;
      if (langs.length > 1) {
        const conf = this.confidence.get(lang) ?? 1;
        if (conf < MAX_CONFIDENCE) {
          weight = 1 - CONFIDENCE_STEP * (MAX_CONFIDENCE - conf);
        } else if (langs.some((other: string) => other !== lang && (this.confidence.get(other) ?? 1) >= conf)) {
          weight = 1 - CONFIDENCE_STEP / 2;
        }
      }
      engine.setLanguageWeight(lang, weight);
    }
  }

  /** After each committed word: languages that know it gain confidence, the others lose some. */
  private updateConfidence(word: string): void {
    const langs = this.settings.languages;
    if (langs.length < 2 || word.length < 2) {
      return;
    }
    const knownIn = langs.filter((l: string) => this.isValidIn(l, word));
    if (knownIn.length === 0 || knownIn.length === langs.length) {
      return;
    }
    for (const lang of langs) {
      const conf = this.confidence.get(lang) ?? 1;
      this.confidence.set(lang, knownIn.includes(lang) ? Math.min(MAX_CONFIDENCE, conf + 1) : Math.max(0, conf - 1));
    }
    this.applyLanguageWeights();
  }

  /** The language the user is most likely typing in (ties go to the current layout). */
  private dominantLanguage(): string {
    let best = this.locale;
    let bestConf = this.confidence.get(this.locale) ?? 1;
    for (const lang of this.settings.languages) {
      const conf = this.confidence.get(lang) ?? 1;
      if (conf > bestConf) {
        best = lang;
        bestConf = conf;
      }
    }
    return best;
  }

  private isValidIn(lang: string, word: string): boolean {
    return engine.isValidWordIn(lang, word) || engine.isValidWordIn(lang, word.toLowerCase());
  }

  currentLocale(): string {
    return this.locale;
  }

  attach(client: inputMethodEngine.InputClient): void {
    this.client = client;
    this.clientResponsive = true;
    this.resetComposing();
    this.lastCorrection = null;
    this.rejectedWord = '';
    this.spaceCommitted = false;
    this.storage.set<PanelMode>(StorageKeys.MODE, PanelMode.KEYS);
    this.storage.set<boolean>(StorageKeys.CAPS_LOCK, false);
    this.storage.set<KeyboardLayout>(StorageKeys.LAYOUT, this.letters);
    this.mirrorText = '';
    this.mirrorKnown = false;
    this.pendingTextEvents = 0;
    this.pendingSelectionEvents = 0;
    this.enqueue(async () => {
      try {
        // Until the first textChange arrives we only know the cursor; at index 0 nothing precedes it.
        this.mirrorCursor = await bounded(client.getTextIndexAtCursor(), 'getTextIndexAtCursor');
        this.mirrorSelectionEnd = this.mirrorCursor;
        this.mirrorKnown = this.mirrorCursor === 0;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'getTextIndexAtCursor failed: %{public}s', (e as Error)?.message ?? JSON.stringify(e));
        this.mirrorCursor = 0;
        if (e instanceof ClientTimeout) {
          // Android app behind the AncoIme bridge: no answers, but edits work. Track the text from
          // our own edits (assuming an empty field) so capitalisation and predictions follow the
          // sentence instead of treating every word as a sentence start.
          this.clientResponsive = false;
          this.mirrorKnown = true;
        }
      }
      try {
        const attribute = await bounded(client.getEditorAttribute(), 'getEditorAttribute');
        this.enterKeyType = attribute.enterKeyType;
        const pattern = attribute.inputPattern;
        this.proseField = pattern !== inputMethodEngine.PATTERN_EMAIL &&
          pattern !== inputMethodEngine.PATTERN_URI && pattern !== inputMethodEngine.PATTERN_PASSWORD;
        // Most apps never set capitalizeMode (it then reads NONE), so only honour the explicit hints.
        this.capitalizeWords = attribute.capitalizeMode === inputMethodEngine.CapitalizeMode.WORDS;
        if (pattern === inputMethodEngine.PATTERN_NUMBER || pattern === inputMethodEngine.PATTERN_PHONE) {
          this.storage.set<KeyboardLayout>(StorageKeys.LAYOUT, buildSymbols(this.locale, this.settings, false));
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'getEditorAttribute failed: %{public}s', JSON.stringify(e));
      }
      this.storage.set<string>(StorageKeys.ENTER_LABEL, this.enterLabel());
      await this.refresh();
    });
  }

  detach(): void {
    this.client = null;
    this.resetComposing();
    this.publishStrip(new StripState());
    // Keyboard hidden: a good moment to write what was learned to disk.
    engine.flush();
  }

  private resetComposing(): void {
    this.composing = '';
    this.composingXs = [];
    this.composingYs = [];
    this.clearGesture();
  }

  private clearGesture(): void {
    this.gestureWord = '';
    this.gestureAlternatives = [];
    this.gesturePending = false;
  }

  /** Full editor text from the 'textChange' event. */
  onEditorText(text: string): void {
    if (this.acceptEditorEvent()) {
      this.mirrorText = text;
      this.mirrorKnown = true;
      this.mirrorCursor = Math.min(this.mirrorCursor, text.length);
      this.mirrorSelectionEnd = Math.min(Math.max(this.mirrorSelectionEnd, this.mirrorCursor), text.length);
    }
  }

  /**
   * Each of our edits causes one text and one selection event, which may arrive late and out of
   * step with each other. Events are only trusted once all events for our edits are in (or after a
   * timeout), so stale ones never move the mirror back.
   */
  private acceptEditorEvent(): boolean {
    if (this.pendingTextEvents > 0 && Date.now() - this.lastEditAt < EDIT_CONFIRM_TIMEOUT_MS) {
      this.pendingTextEvents--;
      return this.pendingTextEvents === 0 && this.pendingSelectionEvents === 0;
    }
    this.pendingTextEvents = 0;
    return this.pendingSelectionEvents === 0 || Date.now() - this.lastEditAt >= EDIT_CONFIRM_TIMEOUT_MS;
  }

  private acceptSelectionEvent(): boolean {
    if (this.pendingSelectionEvents > 0 && Date.now() - this.lastEditAt < EDIT_CONFIRM_TIMEOUT_MS) {
      this.pendingSelectionEvents--;
      return this.pendingSelectionEvents === 0 && this.pendingTextEvents === 0;
    }
    this.pendingSelectionEvents = 0;
    return this.pendingTextEvents === 0 || Date.now() - this.lastEditAt >= EDIT_CONFIRM_TIMEOUT_MS;
  }

  /** Cursor moved or text changed by the app: re-read the context (no autocorrect for it). */
  onSelectionChange(newBegin: number, newEnd: number): void {
    if (this.acceptSelectionEvent()) {
      if (newBegin !== this.mirrorCursor || newEnd !== newBegin) {
        // The user moved the cursor or selected text: the word we were typing is finished.
        this.resetComposing();
        this.lastCorrection = null;
        this.spaceCommitted = false;
      }
      this.mirrorCursor = newBegin;
      this.mirrorSelectionEnd = Math.max(newBegin, newEnd);
    }
    this.enqueue(async () => {
      await this.refresh();
    });
  }

  // --- key handling (called by the panel) ------------------------------------------------------

  /** A character key; x/y is the touch point in engine units (-1 when not from a direct tap). */
  onText(text: string, x: number = -1, y: number = -1): void {
    this.enqueue(async () => {
      await this.handleText(text, x, y);
    });
  }

  onSpace(): void {
    this.enqueue(async () => {
      await this.handleSpace();
    });
  }

  onBackspace(): void {
    this.enqueue(async () => {
      await this.handleBackspace();
    });
  }

  /** Gesture typing is offered on the letter keys of prose fields (not for passwords, URLs …). */
  gestureAllowed(): boolean {
    return this.settings.gestureTyping && this.proseField;
  }

  /** A finished swipe over the letter keys; xs/ys are the trace in engine units. */
  onGesture(xs: number[], ys: number[]): void {
    this.enqueue(async () => {
      await this.handleGesture(xs, ys);
    });
  }

  /** Gboard: swipe left from backspace deletes the previous word. */
  onDeleteWord(): void {
    this.enqueue(async () => {
      const before = await this.textBefore();
      let end = before.length;
      while (end > 0 && before.charAt(end - 1) === ' ') {
        end--;
      }
      const word = trailingWord(before.substring(0, end));
      // Delete the word plus trailing spaces; without a word, delete the separator before them.
      const start = word.length > 0 ? end - word.length : Math.max(0, end - 1);
      const count = before.length - start;
      if (count > 0) {
        await this.deleteBefore(count);
      }
      this.resetComposing();
      this.lastCorrection = null;
      await this.refresh();
    });
  }

  onEnter(): void {
    this.enqueue(async () => {
      await this.commitWord('', true);
      if (!this.client) {
        return;
      }
      if (this.enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_UNSPECIFIED ||
        this.enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_NEWLINE) {
        await this.insert('\n');
      } else {
        await this.editorCall('sendKeyFunction', this.client.sendKeyFunction(this.enterKeyType));
      }
      this.spaceCommitted = false;
      await this.refresh();
    });
  }

  onSuggestion(slot: StripSlot): void {
    this.enqueue(async () => {
      const strip = this.storage.get<StripState>(StorageKeys.STRIP) ?? new StripState();
      const word = slot === StripSlot.LEFT ? strip.leftWord : slot === StripSlot.CENTER ? strip.centerWord :
        strip.rightWord;
      if (word.length === 0) {
        return;
      }
      const before = await this.textBefore();
      const current = this.composing.length > 0 ? this.composing : trailingWord(before);
      if (current.length > 0) {
        await this.deleteBefore(current.length);
      }
      if (slot === StripSlot.RIGHT && strip.rightIsEmoji) {
        // Emoji suggestion replaces the word (like Gboard) and counts as recently used.
        await this.insert(word);
        this.rememberEmoji(word);
        this.resetComposing();
        this.lastCorrection = null;
        this.spaceCommitted = false;
        await this.refresh();
        return;
      }
      await this.insert(word + ' ');
      // A word the user explicitly picked (including the literal typed word) is learned as valid.
      this.learnCommitted(before.substring(0, before.length - current.length), word, true);
      this.resetComposing();
      this.lastCorrection = null;
      this.spaceCommitted = true;
      await this.refresh();
    });
  }

  onEmoji(emoji: string): void {
    this.enqueue(async () => {
      this.resetComposing();
      this.lastCorrection = null;
      await this.insert(emoji);
      this.spaceCommitted = false;
      this.rememberEmoji(emoji);
    });
  }

  private rememberEmoji(emoji: string): void {
    this.recentEmojis = [emoji].concat(this.recentEmojis.filter((e: string) => e !== emoji)).slice(0, MAX_RECENT_EMOJIS);
    this.storage.set<string[]>(StorageKeys.RECENT_EMOJIS, this.recentEmojis);
    this.settingsStore.saveList('recentEmojis', this.recentEmojis);
  }

  /** Space-bar swipe: move the cursor one character left/right. */
  onMoveCursor(right: boolean): void {
    this.enqueue(async () => {
      if (!this.client) {
        return;
      }
      // Update the mirror before the call: the selection event may arrive while we await it.
      this.mirrorCursor = Math.max(0, Math.min(this.mirrorText.length, this.mirrorCursor + (right ? 1 : -1)));
      this.mirrorSelectionEnd = this.mirrorCursor;
      this.noteEdit(false);
      await this.editorCall('moveCursor', this.client.moveCursor(right ? inputMethodEngine.Direction.CURSOR_RIGHT :
        inputMethodEngine.Direction.CURSOR_LEFT));
      this.resetComposing();
      this.lastCorrection = null;
      this.spaceCommitted = false;
    });
  }

  onCursorMoveFinished(): void {
    this.enqueue(async () => {
      await this.refresh();
    });
  }

  /** Georgian: upper case (Mtavruli) is not used in running text, so shift does nothing. */
  private caseless(): boolean {
    return languageById(this.locale).caseless;
  }

  onShift(): void {
    if (this.caseless()) {
      return;
    }
    const capsLock = this.storage.get<boolean>(StorageKeys.CAPS_LOCK) ?? false;
    if (capsLock) {
      this.storage.set<boolean>(StorageKeys.CAPS_LOCK, false);
      this.storage.set<boolean>(StorageKeys.SHIFT, false);
      return;
    }
    const shift = this.storage.get<boolean>(StorageKeys.SHIFT) ?? false;
    this.storage.set<boolean>(StorageKeys.SHIFT, !shift);
  }

  onCapsLock(): void {
    if (this.caseless()) {
      return;
    }
    this.storage.set<boolean>(StorageKeys.CAPS_LOCK, true);
    this.storage.set<boolean>(StorageKeys.SHIFT, true);
  }

  showLayout(kind: LayoutKind): void {
    if (kind === LayoutKind.LETTERS) {
      this.storage.set<KeyboardLayout>(StorageKeys.LAYOUT, this.letters);
    } else {
      this.storage.set<KeyboardLayout>(StorageKeys.LAYOUT,
        buildSymbols(this.locale, this.settings, kind === LayoutKind.SYMBOLS_MORE));
    }
    this.storage.set<PanelMode>(StorageKeys.MODE, PanelMode.KEYS);
  }

  showEmoji(show: boolean): void {
    this.storage.set<PanelMode>(StorageKeys.MODE, show ? PanelMode.EMOJI : PanelMode.KEYS);
  }

  /** Globe key / long-press space: next enabled language's layout. */
  nextLanguage(): void {
    const langs = this.settings.languages;
    if (langs.length < 2) {
      return;
    }
    const index = langs.indexOf(this.locale);
    this.setLayoutLanguage(langs[(index + 1) % langs.length]);
  }

  /** Toolbar gear: like Gboard, the settings are an app (they apply when the keyboard shows again). */
  openSettings(): void {
    this.openSettingsHandler?.();
  }

  hideKeyboard(): void {
    this.hideKeyboardHandler?.();
  }

  /**
   * Short haptic tick on key down, if enabled. Plain timed vibrations are rejected on the Mate XT
   * ("Device operation failed"), so prefer the system's preset haptic effects and fall back step
   * by step if the device does not support one.
   */
  haptic(): void {
    if (!this.settings.vibrate || this.settings.vibrationMs <= 0 || this.hapticIndex >= HAPTIC_EFFECTS.length + 1) {
      return;
    }
    const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
    const intensity = Math.max(1, Math.min(100, Math.round(this.settings.vibrationMs * 2.5)));
    const index = this.hapticIndex;
    try {
      let request: Promise<void>;
      if (index < HAPTIC_EFFECTS.length) {
        const preset: vibrator.VibratePreset = { type: 'preset', effectId: HAPTIC_EFFECTS[index], count: 1,
          intensity: intensity };
        request = vibrator.startVibration(preset, attribute);
      } else {
        const timed: vibrator.VibrateTime = { type: 'time', duration: Math.max(5, Math.round(intensity / 4)) };
        request = vibrator.startVibration(timed, attribute);
      }
      request.catch((e: Error) => {
        this.onHapticFailed(index, e);
      });
    } catch (e) {
      this.onHapticFailed(index, e as Error);
    }
  }

  private onHapticFailed(index: number, e: Error): void {
    if (index === this.hapticIndex) {
      hilog.warn(DOMAIN, TAG, 'haptic mode %{public}d failed: %{public}s', index, e?.message ?? '');
      this.hapticIndex++;
    }
  }

  private pickHapticMode(): void {
    this.hapticIndex = HAPTIC_EFFECTS.length;
    for (let i = 0; i < HAPTIC_EFFECTS.length; i++) {
      try {
        if (vibrator.isSupportEffectSync(HAPTIC_EFFECTS[i])) {
          this.hapticIndex = i;
          return;
        }
      } catch (e) {
        // Unsupported query: try the next effect.
      }
    }
  }

  // --- editing logic ---------------------------------------------------------------------------

  private async handleGesture(xs: number[], ys: number[]): Promise<void> {
    if (!this.client) {
      return;
    }
    // A word being typed is finished first, as if space had been pressed.
    if (this.composing.length > 0) {
      await this.commitWord(' ', true);
    }
    const before = await this.textBefore();
    const trimmed = before.trimEnd();
    const beginningOfSentence = trimmed.length === 0 || SENTENCE_END.includes(trimmed.charAt(trimmed.length - 1));
    const results: Suggestion[] = engine.gesture(xs, ys, beginningOfSentence ? '' : trailingWord(trimmed),
      beginningOfSentence, 8);
    const shift = this.storage.get<boolean>(StorageKeys.SHIFT) ?? false;
    const capsLock = this.storage.get<boolean>(StorageKeys.CAPS_LOCK) ?? false;
    const words: string[] = [];
    for (const r of results) {
      // Acronyms only when swiping in caps lock (like typed input: dsa -> das, not DSA).
      if (!capsLock && r.word.length > 1 && isAllCaps(r.word)) {
        continue;
      }
      const w = capsLock ? r.word.toUpperCase() : shift ? capitalizeFirst(r.word) : r.word;
      if (!words.includes(w)) {
        words.push(w);
      }
      if (words.length >= 3) {
        break;
      }
    }
    if (words.length === 0) {
      return;
    }
    // Gboard puts a space between swiped words (and after a typed word).
    const last = before.length > 0 ? before.charAt(before.length - 1) : ' ';
    const needsSpace = !' \n\t([{„“"\'/-'.includes(last);
    const prefix = needsSpace ? before + ' ' : before;
    this.resetComposing();
    this.lastCorrection = null;
    this.rejectedWord = '';
    await this.insert((needsSpace ? ' ' : '') + words[0]);
    this.learnCommitted(prefix, words[0], false);
    this.gestureWord = words[0];
    this.gestureAlternatives = words.slice(1);
    this.gesturePending = true;
    this.spaceCommitted = false;
    if (shift && !capsLock) {
      this.storage.set<boolean>(StorageKeys.SHIFT, false);
    }
    await this.refresh();
  }

  private async handleText(text: string, x: number, y: number): Promise<void> {
    const shift = this.storage.get<boolean>(StorageKeys.SHIFT) ?? false;
    const capsLock = this.storage.get<boolean>(StorageKeys.CAPS_LOCK) ?? false;
    const output = (shift || capsLock) ? text.toUpperCase() : text;
    this.lastCorrection = null;
    if (this.gesturePending) {
      // After a swiped word the next letter starts a new word (Gboard's automatic space);
      // punctuation attaches to the word.
      this.clearGesture();
      if (!(output.length === 1 && isSeparator(output))) {
        await this.insert(' ');
      }
    }

    if (output.length === 1 && isSeparator(output)) {
      const autocorrect = SWAP_PUNCTUATION.includes(output);
      if (this.spaceCommitted && SWAP_PUNCTUATION.includes(output)) {
        const before = await this.textBefore();
        if (before.endsWith(' ')) {
          // "word ." -> "word. " like Gboard.
          await this.deleteBefore(1);
          await this.insert(output + ' ');
          this.spaceCommitted = true;
          await this.refresh();
          return;
        }
      }
      await this.commitWord(output, autocorrect);
      this.spaceCommitted = false;
      await this.refresh();
      return;
    }

    await this.insert(output);
    this.composing += output;
    this.composingXs.push(x);
    this.composingYs.push(y);
    this.spaceCommitted = false;
    if (shift && !capsLock) {
      this.storage.set<boolean>(StorageKeys.SHIFT, false);
    }
    await this.refresh();
  }

  private async handleSpace(): Promise<void> {
    const now = Date.now();
    if (this.settings.doubleSpacePeriod && this.spaceCommitted && now - this.lastSpaceAt < 1500) {
      const before = await this.textBefore();
      const beforeSpace = before.length >= 2 ? before.charAt(before.length - 2) : '';
      if (before.endsWith(' ') && beforeSpace.length > 0 && !isSeparator(beforeSpace)) {
        await this.deleteBefore(1);
        await this.insert('. ');
        this.spaceCommitted = false;
        this.lastSpaceAt = 0;
        await this.refresh();
        return;
      }
    }
    await this.commitWord(' ', true);
    this.spaceCommitted = true;
    this.lastSpaceAt = now;
    await this.refresh();
  }

  private async handleBackspace(): Promise<void> {
    if (!this.client) {
      return;
    }
    const correction = this.lastCorrection;
    this.lastCorrection = null;
    this.spaceCommitted = false;
    if (this.gesturePending) {
      // Gboard: backspace right after a swipe removes the whole swiped word.
      const word = this.gestureWord;
      this.clearGesture();
      const before = await this.textBefore();
      if (word.length > 0 && before.endsWith(word)) {
        await this.deleteBefore(word.length);
        await this.refresh();
        return;
      }
    }
    if (correction && this.settings.backspaceRevertsAutocorrect) {
      const tail = correction.corrected + correction.separator;
      const before = await this.textBefore();
      if (before.endsWith(tail)) {
        // Gboard: the first backspace after an autocorrection restores what was typed, and the
        // keyboard remembers the word so it is not corrected again.
        await this.deleteBefore(tail.length);
        await this.insert(correction.typed);
        this.learnCommitted(before.substring(0, before.length - tail.length), correction.typed, true);
        this.resetComposing();
        this.composing = correction.typed;
        for (let i = 0; i < correction.typed.length; i++) {
          this.composingXs.push(-1);
          this.composingYs.push(-1);
        }
        this.rejectedWord = correction.typed;
        await this.refresh();
        return;
      }
    }
    const before = await this.textBefore();
    // Delete one user-perceived character (emoji are surrogate pairs).
    const last = before.length > 0 ? before.charCodeAt(before.length - 1) : 0;
    const width = (last >= 0xDC00 && last <= 0xDFFF && before.length >= 2) ? 2 : 1;
    await this.deleteBefore(width);
    if (this.composing.length > 0) {
      const keep = Math.max(0, this.composing.length - width);
      this.composing = this.composing.substring(0, keep);
      this.composingXs = this.composingXs.slice(0, keep);
      this.composingYs = this.composingYs.slice(0, keep);
    }
    await this.refresh();
  }

  /** Ends the current word: applies autocorrect (if allowed), inserts the separator, learns. */
  private async commitWord(separator: string, allowAutocorrect: boolean): Promise<void> {
    const before = await this.textBefore();
    const fresh = this.composing.length > 0;
    const word = fresh ? this.composing : trailingWord(before);
    const prefix = before.endsWith(word) ? before.substring(0, before.length - word.length) : before;
    let target: string | null = null;
    if (allowAutocorrect && fresh && word !== this.rejectedWord) {
      // Fresh suggestions for exactly this input (with touch points), not a stale strip.
      this.computeCandidates(prefix, word);
      target = this.autocorrectTarget(word);
    }
    if (target !== null) {
      await this.deleteBefore(word.length);
      await this.insert(target + separator);
      this.lastCorrection = new Correction(word, target, separator);
      this.learnCommitted(prefix, target, true);
    } else {
      if (separator.length > 0) {
        await this.insert(separator);
      }
      if (fresh && word.length > 0) {
        // Re-typing a word after reverting its correction means the user wants it: learn it as valid.
        this.learnCommitted(prefix, word, word === this.rejectedWord);
      }
    }
    this.resetComposing();
    this.rejectedWord = '';
  }

  /**
   * Feeds a committed word (or words, for "das ist") into the history dictionary of the language
   * it belongs to, with the previous word as n-gram context, and updates language confidence.
   */
  private learnCommitted(prefix: string, committed: string, userConfirmed: boolean): void {
    // Passwords, e-mail addresses and URLs are never learned.
    if (!this.proseField) {
      return;
    }
    const trimmed = prefix.trimEnd();
    let previous = trailingWord(trimmed);
    let beginningOfSentence = trimmed.length === 0 || SENTENCE_END.includes(trimmed.charAt(trimmed.length - 1));
    for (const word of committed.split(' ')) {
      if (word.length === 0 || hasDigit(word)) {
        continue;
      }
      const knownIn = this.settings.languages.filter((l: string) => this.isValidIn(l, word));
      const lang = knownIn.includes(this.dominantLanguage()) ? this.dominantLanguage() :
        knownIn.length > 0 ? knownIn[0] : this.dominantLanguage();
      // Lower-case sentence starters so "Das" at the start of a sentence is learned as "das".
      const learned = beginningOfSentence && word.length > 1 && !isAllCaps(word) &&
        this.isValidIn(lang, word.toLowerCase()) ? word.toLowerCase() : word;
      engine.learn(lang, learned, beginningOfSentence ? '' : previous, beginningOfSentence,
        userConfirmed || knownIn.length > 0);
      this.updateConfidence(word);
      previous = word;
      beginningOfSentence = false;
    }
  }

  // --- suggestions -----------------------------------------------------------------------------

  private async refresh(): Promise<void> {
    const before = await this.textBefore();
    // The word we are typing comes from our own key presses; otherwise the word at the cursor
    // (a resumed word: suggestions, but no autocorrect).
    const word = this.composing.length > 0 ? this.composing : trailingWord(before);
    const prefix = before.endsWith(word) ? before.substring(0, before.length - word.length) : before;
    if (this.gesturePending && word === this.gestureWord) {
      this.publishStrip(this.gestureStrip());
      this.updateAutoShift(before);
      return;
    }
    this.updateStrip(prefix, word);
    this.updateAutoShift(this.composing.length > 0 ? prefix + word : before);
  }

  private isKnownWord(word: string): boolean {
    return CHAT_WORDS.has(word.toLowerCase()) || engine.isValidWord(word) || engine.isValidWord(word.toLowerCase());
  }

  /** Engine suggestions for `word` (typed after `prefix`), adapted to the typed capitalisation. */
  private computeCandidates(prefix: string, word: string): void {
    const trimmed = prefix.trimEnd();
    const previousWord = trailingWord(trimmed);
    const beginningOfSentence = trimmed.length === 0 || SENTENCE_END.includes(trimmed.charAt(trimmed.length - 1));
    const fresh = this.composing.length > 0 && word === this.composing;
    const results: Suggestion[] = engine.suggest(word, fresh ? this.composingXs : [], fresh ? this.composingYs : [],
      beginningOfSentence ? '' : previousWord, beginningOfSentence);
    const capitalize = isUpper(word.charAt(0));
    const allCaps = isAllCaps(word);
    const list: Candidate[] = [];
    const seen = new Set<string>();
    seen.add(word);
    for (const r of results) {
      // Lower-case input never turns into an all-caps acronym (dsa -> das, not DSA).
      if (!allCaps && isAllCaps(r.word.replace(' ', ''))) {
        continue;
      }
      const w = allCaps ? r.word.toUpperCase() : capitalize ? capitalizeFirst(r.word) : r.word;
      if (seen.has(w)) {
        continue;
      }
      seen.add(w);
      list.push(new Candidate(w, r.normalizedScore, r.appropriateForAutoCorrection, r.locale));
    }
    this.candidates = list;
  }

  private updateStrip(prefix: string, word: string): void {
    const strip = new StripState();
    if (!this.proseField || !this.settings.showSuggestions) {
      this.candidates = [];
      this.publishStrip(strip);
      return;
    }
    if (word.length === 0) {
      this.candidates = [];
      this.publishStrip(this.predictions(prefix));
      return;
    }
    this.computeCandidates(prefix, word);
    const list = this.candidates;
    const known = this.isKnownWord(word);
    const fresh = this.composing.length > 0 && word === this.composing;
    const target = fresh && word !== this.rejectedWord ? this.autocorrectTarget(word) : null;
    if (target !== null) {
      strip.left = `"${word}"`;
      strip.leftWord = word;
      strip.center = target;
      strip.centerWord = target;
      strip.centerIsAutocorrect = true;
      const other = list.find((c: Candidate) => c.word !== target);
      if (other) {
        strip.right = other.word;
        strip.rightWord = other.word;
      }
    } else if (known || list.length === 0) {
      strip.center = word;
      strip.centerWord = word;
      if (list.length > 0) {
        strip.left = list[0].word;
        strip.leftWord = list[0].word;
      }
      if (list.length > 1) {
        strip.right = list[1].word;
        strip.rightWord = list[1].word;
      }
    } else {
      // No autocorrection: like Gboard the centre shows what space will commit (the typed word),
      // so a suggestion in the centre always means "space applies it".
      strip.center = word;
      strip.centerWord = word;
      strip.left = list[0].word;
      strip.leftWord = list[0].word;
      if (list.length > 1) {
        strip.right = list[1].word;
        strip.rightWord = list[1].word;
      }
    }
    this.addEmojiSuggestion(strip, target ?? (known ? word : ''));
    this.publishStrip(strip);
  }

  /** After a swipe: the inserted word in the centre, the decoder's alternatives left and right. */
  private gestureStrip(): StripState {
    const strip = new StripState();
    if (!this.settings.showSuggestions) {
      return strip;
    }
    strip.center = this.gestureWord;
    strip.centerWord = this.gestureWord;
    if (this.gestureAlternatives.length > 0) {
      strip.left = this.gestureAlternatives[0];
      strip.leftWord = this.gestureAlternatives[0];
    }
    if (this.gestureAlternatives.length > 1) {
      strip.right = this.gestureAlternatives[1];
      strip.rightWord = this.gestureAlternatives[1];
    } else {
      this.addEmojiSuggestion(strip, this.gestureWord);
    }
    return strip;
  }

  /** Gboard-style emoji suggestion in the right slot; the user's recent emoji come first. */
  private addEmojiSuggestion(strip: StripState, word: string): void {
    if (!this.settings.emojiSuggestions || word.length < 2 || word.includes(' ')) {
      return;
    }
    const emoji: string[] = engine.emojiFor(word, 64);
    if (emoji.length === 0) {
      return;
    }
    // Recently used by the user first, then by general popularity, then the engine's order.
    const rank = (e: string): number => {
      const recent = this.recentEmojis.indexOf(e);
      return recent >= 0 ? recent - MAX_RECENT_EMOJIS : emojiPopularityRank(e);
    };
    const best = emoji.reduce((a: string, b: string) => rank(b) < rank(a) ? b : a);
    strip.right = best;
    strip.rightWord = best;
    strip.rightIsEmoji = true;
  }

  /** Next-word predictions after a completed word (from the main dictionaries and what was learned). */
  private predictions(prefix: string): StripState {
    const strip = new StripState();
    const trimmed = prefix.trimEnd();
    if (trimmed.length === 0 || !prefix.endsWith(' ')) {
      return strip;
    }
    const previousWord = trailingWord(trimmed);
    const beginningOfSentence = SENTENCE_END.includes(trimmed.charAt(trimmed.length - 1));
    if (previousWord.length === 0 && !beginningOfSentence) {
      return strip;
    }
    const words: string[] = [];
    for (const r of engine.suggest('', [], [], beginningOfSentence ? '' : previousWord, beginningOfSentence)) {
      const w = beginningOfSentence ? capitalizeFirst(r.word) : r.word;
      if (!words.includes(w) && !w.includes(' ')) {
        words.push(w);
      }
      if (words.length >= 3) {
        break;
      }
    }
    if (words.length > 0) {
      strip.center = words[0];
      strip.centerWord = words[0];
    }
    if (words.length > 1) {
      strip.left = words[1];
      strip.leftWord = words[1];
    }
    if (words.length > 2) {
      strip.right = words[2];
      strip.rightWord = words[2];
    }
    return strip;
  }

  /**
   * Which word space would turn `word` into. HeliBoard's rules (Suggest.kt / AutoCorrectionUtils)
   * plus multilingual handling and Gboard-like missing-space corrections.
   */
  private autocorrectTarget(word: string): string | null {
    if (!this.settings.autoCorrect || !this.proseField || word.length < 2) {
      return null;
    }
    if (hasDigit(word) || word.includes('@') || word.includes('_')) {
      return null;
    }
    if (CHAT_WORDS.has(word.toLowerCase())) {
      return null;
    }
    // Mostly-caps but not all-caps input is almost certainly intentional.
    if (upperCount(word) > 1 && !isAllCaps(word)) {
      return null;
    }
    // One wrong key costs a short word a much larger share of LatinIME's normalised score
    // ("Yoo" -> "You" scores ~0.1, a slip in a long word ~0.4), so short words get a lower bar.
    const typedChars = codePointLength(word);
    const threshold = this.settings.autoCorrectThreshold() * (typedChars <= 3 ? 0.6 : typedChars === 4 ? 0.8 : 1);
    const dominant = this.dominantLanguage();
    const knownIn = this.settings.languages.filter((l: string) => this.isValidIn(l, word));
    if (knownIn.includes(dominant)) {
      return null;
    }
    // Autocorrect fixes typos; it does not complete words ("Insta" must not become "Instanz").
    // One extra letter is allowed for a missed key ("Kaffe" -> "Kaffee").
    const first = this.candidates.find((c: Candidate) => c.appropriate &&
      codePointLength(c.word.replace(' ', '')) <= typedChars + 1);
    if (!first || first.word === word) {
      return null;
    }
    if (knownIn.length > 0) {
      // Valid only in a language the user is not typing right now ("butte" while writing German):
      // correct only towards a clearly better word of the dominant language.
      return first.locale === dominant && first.normalizedScore >= threshold * 2 ? first.word : null;
    }
    if (first.word.includes(' ')) {
      // Missing space: accept when every part is a real word of the same language.
      const parts = first.word.split(' ');
      const allValid = parts.every((p: string) => p.length > 0 && this.isValidIn(first.locale, p));
      return allValid && first.normalizedScore >= Math.min(threshold, SPLIT_WORD_THRESHOLD) ? first.word : null;
    }
    if (first.normalizedScore >= threshold) {
      return first.word;
    }
    // The engine ranks by raw score; a split-word candidate further down may still be the fix.
    const split = this.candidates.find((c: Candidate) => c.appropriate && c.word.includes(' ') &&
      c.word.split(' ').every((p: string) => p.length > 0 && this.isValidIn(c.locale, p)) &&
      c.normalizedScore >= SPLIT_WORD_THRESHOLD);
    return split ? split.word : null;
  }

  private publishStrip(strip: StripState): void {
    this.storage.set<StripState>(StorageKeys.STRIP, strip);
  }

  /** Enables shift at the start of a sentence (or of every word for name fields). */
  private updateAutoShift(before: string): void {
    if (this.caseless()) {
      this.storage.set<boolean>(StorageKeys.SHIFT, false);
      return;
    }
    if (!this.settings.autoCapitalize || !this.proseField) {
      return;
    }
    if (this.storage.get<boolean>(StorageKeys.CAPS_LOCK) ?? false) {
      return;
    }
    if (trailingWord(before).length > 0) {
      this.storage.set<boolean>(StorageKeys.SHIFT, false);
      return;
    }
    const trimmed = before.trimEnd();
    const startOfSentence = trimmed.length === 0 || before.endsWith('\n') ||
      (SENTENCE_END.includes(trimmed.charAt(trimmed.length - 1)) && before.endsWith(' '));
    const startOfWord = this.capitalizeWords && (before.length === 0 || before.endsWith(' '));
    this.storage.set<boolean>(StorageKeys.SHIFT, startOfSentence || startOfWord);
  }

  // --- editor access ---------------------------------------------------------------------------

  private enqueue(op: () => Promise<void>): void {
    this.queue = this.queue.then(op).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'key handling failed: %{public}s', e?.message ?? JSON.stringify(e));
    });
  }

  private async textBefore(): Promise<string> {
    if (!this.client || !this.mirrorKnown) {
      // Unknown context: fall back to what we typed ourselves in this session.
      return this.composing;
    }
    const cursor = Math.min(this.mirrorCursor, this.mirrorText.length);
    return this.mirrorText.substring(Math.max(0, cursor - CONTEXT_LENGTH), cursor);
  }

  private noteEdit(textChanges: boolean = true): void {
    if (textChanges) {
      this.pendingTextEvents++;
    }
    this.pendingSelectionEvents++;
    this.lastEditAt = Date.now();
  }

  private async insert(text: string): Promise<void> {
    if (!this.client || text.length === 0) {
      return;
    }
    const cursor = Math.min(this.mirrorCursor, this.mirrorText.length);
    const selectionEnd = Math.min(Math.max(this.mirrorSelectionEnd, cursor), this.mirrorText.length);
    this.mirrorText = this.mirrorText.substring(0, cursor) + text + this.mirrorText.substring(selectionEnd);
    this.mirrorCursor = cursor + text.length;
    this.mirrorSelectionEnd = this.mirrorCursor;
    this.noteEdit();
    await this.editorCall('insertText', this.client.insertText(text));
  }

  private async deleteBefore(length: number): Promise<void> {
    if (!this.client || length <= 0) {
      return;
    }
    const cursor = Math.min(this.mirrorCursor, this.mirrorText.length);
    const start = Math.max(0, cursor - length);
    this.mirrorText = this.mirrorText.substring(0, start) + this.mirrorText.substring(cursor);
    this.mirrorCursor = start;
    this.mirrorSelectionEnd = start;
    this.noteEdit();
    // HarmonyOS naming: deleteForward() removes text *before* the cursor (what backspace does);
    // deleteBackward() removes text after it.
    await this.editorCall('deleteForward', this.client.deleteForward(length));
  }

  /**
   * Waits for an editor call while the editor confirms calls; after the first unanswered one only
   * sends (calls from this thread reach the editor in order either way).
   */
  private async editorCall<T>(name: string, call: Promise<T>): Promise<void> {
    if (!this.clientResponsive) {
      call.catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}s', name, e?.message ?? JSON.stringify(e));
      });
      return;
    }
    try {
      await bounded(call, name);
    } catch (e) {
      if (e instanceof ClientTimeout) {
        this.clientResponsive = false;
      }
      hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}s', name, (e as Error)?.message ?? JSON.stringify(e));
    }
  }

  /** Which icon the enter key shows; the panel maps it to a system symbol. */
  private enterLabel(): string {
    switch (this.enterKeyType) {
      case inputMethodEngine.ENTER_KEY_TYPE_SEARCH:
        return 'search';
      case inputMethodEngine.ENTER_KEY_TYPE_SEND:
        return 'send';
      case inputMethodEngine.ENTER_KEY_TYPE_GO:
      case inputMethodEngine.ENTER_KEY_TYPE_NEXT:
        return 'next';
      case inputMethodEngine.ENTER_KEY_TYPE_DONE:
        return 'done';
      default:
        return 'return';
    }
  }
}
