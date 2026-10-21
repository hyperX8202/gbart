export interface Suggestion {
  /** May contain a space for missing-space corrections ("das ist"). */
  word: string;
  score: number;
  /** Score normalised against the typed word; autocorrect when >= threshold (HeliBoard logic). */
  normalizedScore: number;
  /** False e.g. when the suggestion only differs by a missing explicit accent. */
  appropriateForAutoCorrection: boolean;
  /** Language whose dictionary produced the word. */
  locale: string;
  /** Learned from the user (history dictionary) rather than from the main dictionary. */
  fromHistory: boolean;
}

/** Adds a language: main dictionary + learning history dictionary (directory, created on demand). */
export const addLanguage: (locale: string, mainDictPath: string, historyPath: string) => boolean;

export const removeAllLanguages: () => void;

/** Multilingual weighting; 1.0 for the language currently being typed. */
export const setLanguageWeight: (locale: string, weight: number) => void;

/**
 * Describes the key geometry so typos are weighted by key distance.
 * keys is flattened as [code, x, y, width, height, code, x, ...] in keyboard units.
 */
export const setKeyboardLayout: (width: number, height: number, keyWidth: number, keyHeight: number,
  keys: number[]) => void;

/**
 * Corrections for the typed word (all languages merged, best first), or next-word predictions
 * when typed is empty. xs/ys are touch points per character in keyboard units (-1 = unknown).
 */
export const suggest: (typed: string, xs: number[], ys: number[], previousWord: string,
  beginningOfSentence: boolean) => Suggestion[];

export const isValidWord: (word: string) => boolean;

export const isValidWordIn: (locale: string, word: string) => boolean;

/** Records a committed word (and the word before it) in the language's history dictionary. */
export const learn: (locale: string, word: string, previousWord: string, beginningOfSentence: boolean,
  isValid: boolean) => void;

/** Writes learned words to disk. */
export const flush: () => void;

/** Word -> emoji dictionary of a language (HeliBoard emoji_cldr_signal). */
export const addEmojiDictionary: (locale: string, path: string) => boolean;

/** Emoji for a complete word ("Pizza" -> 🍕), best first. */
export const emojiFor: (word: string, max: number) => string[];

/**
 * Words for a gesture (glide typing) trace in keyboard units, best first (all languages merged).
 * The first call after loading languages may wait for the background word-list load.
 */
export const gesture: (xs: number[], ys: number[], previousWord: string, beginningOfSentence: boolean,
  max: number) => Suggestion[];

/** Unpacks gzip data (a bundled dictionary) to a file; false on error. */
export const inflateGzip: (data: ArrayBuffer, path: string) => boolean;
