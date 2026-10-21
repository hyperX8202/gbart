import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** One emoji with its skin-tone / gender variants (offered on long press). */
export class EmojiItem {
  base: string;
  variants: string[];

  constructor(base: string, variants: string[]) {
    this.base = base;
    this.variants = variants;
  }
}

export class EmojiCategory {
  id: string;
  icon: string;
  label: Resource;
  items: EmojiItem[];

  constructor(id: string, icon: string, label: Resource, items: EmojiItem[]) {
    this.id = id;
    this.icon = icon;
    this.label = label;
    this.items = items;
  }
}

export const RECENT_CATEGORY_ID = 'recent';
export const MAX_RECENT_EMOJIS = 32;

class CategorySource {
  file: string;
  icon: string;
  label: Resource;

  constructor(file: string, icon: string, label: Resource) {
    this.file = file;
    this.icon = icon;
    this.label = label;
  }
}

// Order and icons follow Gboard's emoji tabs.
const SOURCES: CategorySource[] = [
  new CategorySource('SMILEYS_AND_EMOTION', '😀', $r('app.string.emoji_cat_smileys')),
  new CategorySource('PEOPLE_AND_BODY', '👋', $r('app.string.emoji_cat_people')),
  new CategorySource('ANIMALS_AND_NATURE', '🐻', $r('app.string.emoji_cat_animals')),
  new CategorySource('FOOD_AND_DRINK', '🍔', $r('app.string.emoji_cat_food')),
  new CategorySource('TRAVEL_AND_PLACES', '🚗', $r('app.string.emoji_cat_travel')),
  new CategorySource('ACTIVITIES', '⚽', $r('app.string.emoji_cat_activities')),
  new CategorySource('OBJECTS', '💡', $r('app.string.emoji_cat_objects')),
  new CategorySource('SYMBOLS', '❤️', $r('app.string.emoji_cat_symbols')),
  new CategorySource('FLAGS', '🏳️', $r('app.string.emoji_cat_flags'))
];

/** Emoji lists ship as rawfiles from HeliBoard: one line per emoji, variants separated by spaces. */
export function loadEmojiCategories(context: common.Context): EmojiCategory[] {
  const out: EmojiCategory[] = [];
  const decoder = util.TextDecoder.create('utf-8');
  for (const source of SOURCES) {
    try {
      const bytes = context.resourceManager.getRawFileContentSync(`emoji/${source.file}.txt`);
      const text = decoder.decodeToString(bytes);
      const items: EmojiItem[] = [];
      for (const line of text.split('\n')) {
        const parts = line.trim().split(' ').filter((p: string) => p.length > 0);
        if (parts.length > 0) {
          items.push(new EmojiItem(parts[0], parts.slice(1)));
        }
      }
      out.push(new EmojiCategory(source.file, source.icon, source.label, items));
    } catch (e) {
      hilog.error(0x4b42, 'Emoji', 'loading %{public}s failed: %{public}s', source.file, JSON.stringify(e));
    }
  }
  return out;
}

export function recentCategory(recent: string[]): EmojiCategory {
  const items: EmojiItem[] = [];
  for (const e of recent) {
    items.push(new EmojiItem(e, []));
  }
  return new EmojiCategory(RECENT_CATEGORY_ID, '🕘', $r('app.string.emoji_cat_recent'), items);
}

/**
 * Emoji ranked by popularity (after Unicode's emoji frequency data, extended with common food,
 * animal, weather and object emoji). Used to order emoji suggestions: the word dictionaries give
 * all emoji of a word the same probability.
 */
export const POPULAR_EMOJI: string[] = ['😂', '❤️', '🤣', '👍', '😭', '🙏', '😘', '🥰', '😍', '😊', '🎉', '😁', '💕', '🥺', '😅', '🔥', '☺️', '🤦', '♥️', '🤷', '🙄', '😆', '🤗', '😉', '🎂', '🤔', '👏', '🙂', '😳', '🥳', '😎', '👌', '💜', '😔', '💪', '✨', '💖', '👀', '😋', '😏', '😢', '👉', '💗', '😩', '💯', '🌹', '💞', '🎈', '💙', '😃', '😡', '💐', '😜', '🙈', '🤞', '😄', '🤤', '🙌', '🤪', '❣️', '😀', '💋', '💀', '👇', '💔', '😌', '💓', '🤩', '🙃', '😬', '😱', '😴', '🤭', '😐', '🌞', '😒', '😇', '🌸', '😈', '🎶', '✌️', '🎊', '🥵', '😞', '💚', '☀️', '🖤', '💰', '😚', '👑', '🎁', '💥', '🙋', '☹️', '😑', '🥴', '👈', '💩', '✅', '👋', '🤝', '💃', '🍕', '🍺', '🍻', '☕', '🍷', '🥂', '🍾', '🍰', '🍔', '🍟', '🍝', '🍣', '🍦', '🍫', '🍎', '🍓', '🍌', '🐶', '🐱', '🐕', '🐈', '🐾', '🦄', '🐻', '🐼', '🐰', '🦊', '🐴', '🐷', '🐮', '🐸', '🐵', '🐔', '🐧', '🐦', '🦋', '🐝', '🐞', '🐟', '🐬', '🐳', '🌍', '🌈', '⭐', '🌟', '🌙', '☁️', '⛅', '🌧️', '❄️', '⛄', '🌊', '🌺', '🌻', '🌷', '🍀', '🌲', '🎄', '🎃', '🏠', '🏡', '🚗', '🚲', '✈️', '🚀', '🏖️', '⛰️', '📱', '💻', '📷', '🎵', '🎮', '⚽', '🏀', '🎾', '🏆', '🎓', '💼', '📚', '✏️', '📅', '⏰', '💡', '🔑', '🎤', '🎧', '🛒', '💸', '🏥', '💊', '🚑', '👶', '👧', '👦', '👩', '👨', '👪', '💍', '💒', '🙆', '🙅', '🤙', '🫶', '🫂', '👊', '✊', '🤘', '🤟', '🖐️', '🍹', '🍸'];

export function emojiPopularityRank(emoji: string): number {
  const index = POPULAR_EMOJI.indexOf(emoji);
  return index < 0 ? POPULAR_EMOJI.length : index;
}
