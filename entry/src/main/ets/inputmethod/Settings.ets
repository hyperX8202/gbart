import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LANGUAGES, LanguageDef } from './LanguageData';

/** Local preferences of the keyboard process (recent emoji, settings from older versions). */
const PREFS_NAME = 'keyboard_settings';
/**
 * Shared settings file. The input method runs in an isolated sandbox; the distributed files
 * directory is the one location both the settings app and the keyboard can read and write.
 */
const SETTINGS_FILE = 'keyboard_settings.json';
/** Written by the keyboard so the settings app can show its state (e.g. basic vs. full mode). */
const STATUS_FILE = 'keyboard_status.json';
const TAG = 'Settings';
const DOMAIN = 0x4b42;

export enum AutoCorrectStrength {
  MODEST = 'modest',
  AGGRESSIVE = 'aggressive',
  VERY_AGGRESSIVE = 'very_aggressive'
}

export enum ThemeMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

/**
 * User settings of the keyboard. They live in the input method's own sandbox: HarmonyOS isolates
 * InputMethodExtension processes from the app's other abilities, so the settings screen inside the
 * keyboard (toolbar gear) is the only place that can change them.
 */
export class KeyboardSettings {
  // Tastatur
  numberRow: boolean = false;
  showEmojiKey: boolean = true;
  showLanguageKey: boolean = false;
  keyPopup: boolean = true;
  vibrate: boolean = true;
  /** Vibration length in ms (Gboard: "Stärke der Vibration bei Tastendruck"). */
  vibrationMs: number = 12;
  /** Relative keyboard height, 0.8 … 1.3. */
  heightScale: number = 1.0;
  longPressMs: number = 300;
  theme: ThemeMode = ThemeMode.SYSTEM;
  // Textkorrektur
  showSuggestions: boolean = true;
  /** Gboard: matching emoji in the suggestion strip ("Pizza" -> 🍕). */
  emojiSuggestions: boolean = true;
  autoCorrect: boolean = true;
  autoCorrectStrength: AutoCorrectStrength = AutoCorrectStrength.MODEST;
  autoCapitalize: boolean = true;
  doubleSpacePeriod: boolean = true;
  backspaceRevertsAutocorrect: boolean = true;
  spaceCursorControl: boolean = true;
  // Gleitende Eingabe
  gestureTyping: boolean = true;
  /** Gboard: "Bewegungspfad anzeigen". */
  gestureTrail: boolean = true;
  // Sprachen
  languages: string[] = ['de'];
  // Daten
  /** Set by "Gelerntes löschen" in the app; the keyboard clears its history when this is newer. */
  resetLearningAt: number = 0;
  /**
   * UI language override for app and keyboard ('' = follow the system). Not shown in the UI; set
   * with `aa start -b com.ab.keyboard -a EntryAbility --ps uiLanguage en` (e.g. for store
   * screenshots) and reset with `--ps uiLanguage system`.
   */
  uiLanguage: string = '';
  /** Kept on the keyboard side only (not in the shared settings file). */
  recentEmojis: string[] = [];

  copy(): KeyboardSettings {
    const c = new KeyboardSettings();
    c.numberRow = this.numberRow;
    c.showEmojiKey = this.showEmojiKey;
    c.showLanguageKey = this.showLanguageKey;
    c.keyPopup = this.keyPopup;
    c.vibrate = this.vibrate;
    c.vibrationMs = this.vibrationMs;
    c.heightScale = this.heightScale;
    c.longPressMs = this.longPressMs;
    c.theme = this.theme;
    c.showSuggestions = this.showSuggestions;
    c.emojiSuggestions = this.emojiSuggestions;
    c.autoCorrect = this.autoCorrect;
    c.autoCorrectStrength = this.autoCorrectStrength;
    c.autoCapitalize = this.autoCapitalize;
    c.doubleSpacePeriod = this.doubleSpacePeriod;
    c.backspaceRevertsAutocorrect = this.backspaceRevertsAutocorrect;
    c.spaceCursorControl = this.spaceCursorControl;
    c.gestureTyping = this.gestureTyping;
    c.gestureTrail = this.gestureTrail;
    c.languages = this.languages.slice();
    c.resetLearningAt = this.resetLearningAt;
    c.uiLanguage = this.uiLanguage;
    c.recentEmojis = this.recentEmojis.slice();
    return c;
  }

  /**
   * HeliBoard: confidence -> threshold = 0.5 - 0.5 * confidence^0.33. "Moderat" is more eager
   * than HeliBoard's 0.24 (threshold 0.189 -> 0.11), closer to Gboard: short slips like
   * "Yoo" -> "You" (0.14) are fixed. Dictionary words are never touched, completions are never
   * applied (KeyboardController), and a reverted correction is learned.
   */
  autoCorrectThreshold(): number {
    let confidence = 0.47;
    if (this.autoCorrectStrength === AutoCorrectStrength.AGGRESSIVE) {
      confidence = 0.7;
    } else if (this.autoCorrectStrength === AutoCorrectStrength.VERY_AGGRESSIVE) {
      confidence = 0.9;
    }
    return 0.5 - 0.5 * Math.pow(confidence, 0.33);
  }
}

/** What the keyboard reports to the settings app. */
export class KeyboardStatus {
  /** inputMethodEngine.SecurityMode: 0 = basic, 1 = full (vibration needs full). */
  securityMode: number = -1;
  updatedAt: number = 0;
}

/** Language of the system (e.g. "de-CH", "sr-Latn-RS") mapped to a keyboard language. */
export function systemLanguageId(): string {
  let tag = 'en-US';
  try {
    tag = i18n.System.getSystemLocale();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'getSystemLocale failed: %{public}s', JSON.stringify(e));
  }
  const parts = tag.split('-');
  const lang = parts[0].toLowerCase();
  const candidates: string[] = [];
  for (let i = parts.length; i > 1; i--) {
    candidates.push(parts.slice(0, i).join('-'));
  }
  for (let i = 1; i < parts.length; i++) {
    candidates.push(`${lang}-${parts[i]}`);
  }
  candidates.push(lang);
  for (const candidate of candidates) {
    const match = LANGUAGES.find((l: LanguageDef) => l.systemLocales.some(
      (s: string) => s.toLowerCase() === candidate.toLowerCase()));
    if (match) {
      return match.id;
    }
  }
  return 'en_US';
}

function readJson(path: string): Record<string, Object> | null {
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    return JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'reading %{public}s failed: %{public}s', path, JSON.stringify(e));
    return null;
  }
}

function writeJson(path: string, value: Object): void {
  const temp = `${path}.tmp`;
  try {
    const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(value));
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, path);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'writing %{public}s failed: %{public}s', path, JSON.stringify(e));
  }
}

function asBoolean(value: Object | undefined, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value as boolean : fallback;
}

function asNumber(value: Object | undefined, fallback: number): number {
  return typeof value === 'number' ? value as number : fallback;
}

function asString(value: Object | undefined, fallback: string): string {
  return typeof value === 'string' ? value as string : fallback;
}

function asStrings(value: Object | undefined, fallback: string[]): string[] {
  if (!Array.isArray(value)) {
    return fallback;
  }
  return (value as Object[]).filter((v: Object) => typeof v === 'string').map((v: Object) => v as string);
}

export class SettingsStore {
  private context: common.Context;
  private settingsPath: string;
  private statusPath: string;

  constructor(context: common.Context) {
    this.context = context.getApplicationContext();
    this.settingsPath = `${context.distributedFilesDir}/${SETTINGS_FILE}`;
    this.statusPath = `${context.distributedFilesDir}/${STATUS_FILE}`;
  }

  /** Reads the settings fresh from disk (the other process may have changed them). */
  load(): KeyboardSettings {
    const json = readJson(this.settingsPath);
    const s = json ? this.fromJson(json) : this.loadLegacy();
    s.recentEmojis = this.loadRecentEmojis();
    if (!json) {
      this.save(s);
    }
    return s;
  }

  save(s: KeyboardSettings): void {
    const value: Record<string, Object> = {
      'numberRow': s.numberRow, 'showEmojiKey': s.showEmojiKey, 'showLanguageKey': s.showLanguageKey,
      'keyPopup': s.keyPopup, 'vibrate': s.vibrate, 'vibrationMs': s.vibrationMs, 'heightScale': s.heightScale,
      'longPressMs': s.longPressMs, 'theme': s.theme, 'showSuggestions': s.showSuggestions,
      'emojiSuggestions': s.emojiSuggestions, 'autoCorrect': s.autoCorrect,
      'autoCorrectStrength': s.autoCorrectStrength, 'autoCapitalize': s.autoCapitalize,
      'doubleSpacePeriod': s.doubleSpacePeriod, 'backspaceRevertsAutocorrect': s.backspaceRevertsAutocorrect,
      'spaceCursorControl': s.spaceCursorControl, 'gestureTyping': s.gestureTyping, 'gestureTrail': s.gestureTrail,
      'languages': s.languages, 'resetLearningAt': s.resetLearningAt, 'uiLanguage': s.uiLanguage
    };
    writeJson(this.settingsPath, value);
  }

  /** Recent emoji stay in the keyboard's own preferences (frequent writes, not a setting). */
  saveList(key: string, values: string[]): void {
    try {
      const p = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      p.putSync(key, values);
      p.flushSync();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveList %{public}s failed: %{public}s', key, JSON.stringify(e));
    }
  }

  /** Last "Gelerntes löschen" request the keyboard has carried out (keyboard-local). */
  handledResetAt(): number {
    try {
      const p = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      return p.getSync('handledResetAt', 0) as number;
    } catch (e) {
      return 0;
    }
  }

  setHandledResetAt(at: number): void {
    try {
      const p = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      p.putSync('handledResetAt', at);
      p.flushSync();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setHandledResetAt failed: %{public}s', JSON.stringify(e));
    }
  }

  writeStatus(status: KeyboardStatus): void {
    writeJson(this.statusPath, status);
  }

  readStatus(): KeyboardStatus {
    const json = readJson(this.statusPath);
    const status = new KeyboardStatus();
    if (json) {
      status.securityMode = asNumber(json['securityMode'], -1);
      status.updatedAt = asNumber(json['updatedAt'], 0);
    }
    return status;
  }

  private fromJson(j: Record<string, Object>): KeyboardSettings {
    const s = new KeyboardSettings();
    s.numberRow = asBoolean(j['numberRow'], s.numberRow);
    s.showEmojiKey = asBoolean(j['showEmojiKey'], s.showEmojiKey);
    s.showLanguageKey = asBoolean(j['showLanguageKey'], s.showLanguageKey);
    s.keyPopup = asBoolean(j['keyPopup'], s.keyPopup);
    s.vibrate = asBoolean(j['vibrate'], s.vibrate);
    s.vibrationMs = asNumber(j['vibrationMs'], s.vibrationMs);
    s.heightScale = asNumber(j['heightScale'], s.heightScale);
    s.longPressMs = asNumber(j['longPressMs'], s.longPressMs);
    s.theme = asString(j['theme'], s.theme) as ThemeMode;
    s.showSuggestions = asBoolean(j['showSuggestions'], s.showSuggestions);
    s.emojiSuggestions = asBoolean(j['emojiSuggestions'], s.emojiSuggestions);
    s.autoCorrect = asBoolean(j['autoCorrect'], s.autoCorrect);
    s.autoCorrectStrength = asString(j['autoCorrectStrength'], s.autoCorrectStrength) as AutoCorrectStrength;
    s.autoCapitalize = asBoolean(j['autoCapitalize'], s.autoCapitalize);
    s.doubleSpacePeriod = asBoolean(j['doubleSpacePeriod'], s.doubleSpacePeriod);
    s.backspaceRevertsAutocorrect = asBoolean(j['backspaceRevertsAutocorrect'], s.backspaceRevertsAutocorrect);
    s.spaceCursorControl = asBoolean(j['spaceCursorControl'], s.spaceCursorControl);
    s.gestureTyping = asBoolean(j['gestureTyping'], s.gestureTyping);
    s.gestureTrail = asBoolean(j['gestureTrail'], s.gestureTrail);
    s.resetLearningAt = asNumber(j['resetLearningAt'], 0);
    s.uiLanguage = asString(j['uiLanguage'], '');
    const known = asStrings(j['languages'], []).filter((id: string) => LANGUAGES.some((l: LanguageDef) => l.id === id));
    s.languages = known.length > 0 ? known : [systemLanguageId()];
    return s;
  }

  /** First start: settings of an older version (keyboard preferences) or system defaults. */
  private loadLegacy(): KeyboardSettings {
    const s = new KeyboardSettings();
    s.languages = [systemLanguageId()];
    try {
      const p = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      if (!p.hasSync('languages')) {
        return s;
      }
      const j: Record<string, Object> = {};
      for (const key of ['numberRow', 'showEmojiKey', 'showLanguageKey', 'keyPopup', 'vibrate', 'vibrationMs',
        'heightScale', 'longPressMs', 'theme', 'showSuggestions', 'emojiSuggestions', 'autoCorrect',
        'autoCorrectStrength', 'autoCapitalize', 'doubleSpacePeriod', 'backspaceRevertsAutocorrect',
        'spaceCursorControl', 'gestureTyping', 'gestureTrail', 'languages']) {
        if (p.hasSync(key)) {
          j[key] = p.getSync(key, '') as Object;
        }
      }
      return this.fromJson(j);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'legacy settings unreadable: %{public}s', JSON.stringify(e));
      return s;
    }
  }

  private loadRecentEmojis(): string[] {
    try {
      const p = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      return p.getSync('recentEmojis', []) as string[];
    } catch (e) {
      return [];
    }
  }
}

/**
 * Applies the UI language override (or the system language) to a process; app and keyboard run
 * in separate processes and each applies it for itself.
 */
export function applyUiLanguage(context: common.Context, uiLanguage: string): void {
  try {
    if (deviceInfo.sdkApiVersion < 21) {
      return;
    }
    const language = uiLanguage !== '' ? uiLanguage : i18n.System.getSystemLanguage();
    context.getApplicationContext().setLanguage(language);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'setLanguage failed: %{public}s', JSON.stringify(e));
  }
}
