/**
 * Keyboard themes, modelled on Gboard's theme picker: the default light/dark themes, plain colours,
 * gradients, landscape pictures and the user's own picture. The catalogue is shared by the settings
 * app (picker previews) and the keyboard (rendering).
 */

/** Resolved colours and background of the keyboard panel. */
export class KeyboardTheme {
  id: string = 'dark';
  dark: boolean = true;
  /** Plain background colour (also behind gradients and pictures). */
  background: string = '#FF202124';
  /** Gradient stops (top-left to bottom-right); empty for a plain background. */
  gradient: string[] = [];
  /** Background picture as a file:// URI; '' for none. */
  image: string = '';
  /** Darkening over the picture, 0 … 0.8 (keeps the letters readable). */
  dim: number = 0;
  /** Keys drawn as rounded tiles ("Tastenumrandung"); otherwise only the labels are shown. */
  keyBorders: boolean = true;
  key: string = '#FF3C4043';
  functionKey: string = '#FF2D2F33';
  accentKey: string = '#FF8AB4F8';
  pressedKey: string = '#FF5F6368';
  text: string = '#FFE8EAED';
  hint: string = '#FF9AA0A6';
  accent: string = '#FF8AB4F8';
  accentText: string = '#FF202124';
  popup: string = '#FF5F6368';
  popupSelected: string = '#FF8AB4F8';
  divider: string = '#FF3C4043';
  /** Labels get a soft shadow on pictures and busy gradients. */
  textShadow: boolean = false;
}

export enum ThemeGroup {
  DEFAULT,
  COLOR,
  GRADIENT,
  LANDSCAPE,
  CUSTOM
}

/** Theme ids that existed before the catalogue (stored in older settings files). */
export const THEME_SYSTEM = 'system';
export const THEME_LIGHT = 'light';
export const THEME_DARK = 'dark';
export const THEME_CUSTOM = 'custom';

export class ThemeDef {
  id: string;
  group: ThemeGroup;
  /** Colour, or gradient stops. */
  colors: string[];
  /** Landscape picture in rawfile/themes ('' for none). */
  picture: string;
  /** Light background: dark labels. */
  lightBackground: boolean;

  constructor(id: string, group: ThemeGroup, colors: string[], lightBackground: boolean = false,
    picture: string = '') {
    this.id = id;
    this.group = group;
    this.colors = colors;
    this.lightBackground = lightBackground;
    this.picture = picture;
  }
}

export const THEME_DEFS: ThemeDef[] = [
  new ThemeDef(THEME_SYSTEM, ThemeGroup.DEFAULT, ['#FF202124']),
  new ThemeDef(THEME_LIGHT, ThemeGroup.DEFAULT, ['#FFE8EAED'], true),
  new ThemeDef(THEME_DARK, ThemeGroup.DEFAULT, ['#FF202124']),
  new ThemeDef('color_blue', ThemeGroup.COLOR, ['#FF1E5BD8']),
  new ThemeDef('color_indigo', ThemeGroup.COLOR, ['#FF303F9F']),
  new ThemeDef('color_purple', ThemeGroup.COLOR, ['#FF6A1B9A']),
  new ThemeDef('color_pink', ThemeGroup.COLOR, ['#FFC2185B']),
  new ThemeDef('color_red', ThemeGroup.COLOR, ['#FFC62828']),
  new ThemeDef('color_orange', ThemeGroup.COLOR, ['#FFE65100']),
  new ThemeDef('color_brown', ThemeGroup.COLOR, ['#FF5D4037']),
  new ThemeDef('color_green', ThemeGroup.COLOR, ['#FF2E7D32']),
  new ThemeDef('color_teal', ThemeGroup.COLOR, ['#FF00796B']),
  new ThemeDef('color_slate', ThemeGroup.COLOR, ['#FF455A64']),
  new ThemeDef('color_black', ThemeGroup.COLOR, ['#FF000000']),
  new ThemeDef('color_sand', ThemeGroup.COLOR, ['#FFF3E5C8'], true),
  new ThemeDef('color_rose', ThemeGroup.COLOR, ['#FFF8D7DF'], true),
  new ThemeDef('color_mint', ThemeGroup.COLOR, ['#FFD3EFDD'], true),
  new ThemeDef('color_lavender', ThemeGroup.COLOR, ['#FFE2DAF5'], true),
  new ThemeDef('gradient_sunset', ThemeGroup.GRADIENT, ['#FFFF6A3D', '#FFFF9A5A', '#FFFFC371']),
  new ThemeDef('gradient_ocean', ThemeGroup.GRADIENT, ['#FF0B4F8A', '#FF1C92B0', '#FF56C5D0']),
  new ThemeDef('gradient_aurora', ThemeGroup.GRADIENT, ['#FF0F2027', '#FF1F4A5A', '#FF2BAF8E']),
  new ThemeDef('gradient_berry', ThemeGroup.GRADIENT, ['#FF4A00E0', '#FF8E2DE2', '#FFD94FA0']),
  new ThemeDef('gradient_dusk', ThemeGroup.GRADIENT, ['#FF2C3E50', '#FF6C4A73', '#FFE0726C']),
  new ThemeDef('gradient_peach', ThemeGroup.GRADIENT, ['#FFFFDEE9', '#FFE8E6FF', '#FFC9F4F2'], true),
  new ThemeDef('landscape_mountains', ThemeGroup.LANDSCAPE, ['#FF1B2440'], false, 'mountains.jpg'),
  new ThemeDef('landscape_lake', ThemeGroup.LANDSCAPE, ['#FF0E1A2B'], false, 'lake.jpg'),
  new ThemeDef('landscape_dunes', ThemeGroup.LANDSCAPE, ['#FF6B3A22'], false, 'dunes.jpg'),
  new ThemeDef('landscape_forest', ThemeGroup.LANDSCAPE, ['#FF16302A'], false, 'forest.jpg'),
  new ThemeDef('landscape_coast', ThemeGroup.LANDSCAPE, ['#FF123B52'], false, 'coast.jpg'),
  new ThemeDef(THEME_CUSTOM, ThemeGroup.CUSTOM, ['#FF202124'])
];

export function themeDef(id: string): ThemeDef {
  return THEME_DEFS.find((t: ThemeDef) => t.id === id) ?? THEME_DEFS[0];
}

/** #AARRGGBB of `color` mixed with `other` (t = share of other). */
function mix(color: string, other: string, t: number): string {
  const a = parseInt(color.substring(3), 16);
  const b = parseInt(other.substring(3), 16);
  let out = '#FF';
  for (const shift of [16, 8, 0]) {
    const ca = (a >> shift) & 0xff;
    const cb = (b >> shift) & 0xff;
    const c = Math.round(ca + (cb - ca) * t);
    out += (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
  }
  return out;
}

/** Same colour with alpha (0 … 1). */
function alpha(color: string, a: number): string {
  const v = Math.round(a * 255);
  return '#' + (v < 16 ? '0' : '') + v.toString(16).toUpperCase() + color.substring(3);
}

function gboardDefault(dark: boolean): KeyboardTheme {
  const t = new KeyboardTheme();
  t.dark = dark;
  if (dark) {
    return t;
  }
  t.background = '#FFE8EAED';
  t.key = '#FFFFFFFF';
  t.functionKey = '#FFC5C9D0';
  t.accentKey = '#FF1A73E8';
  t.pressedKey = '#FFBDC1C6';
  t.text = '#FF202124';
  t.hint = '#FF5F6368';
  t.accent = '#FF1A73E8';
  t.accentText = '#FFFFFFFF';
  t.popup = '#FFFFFFFF';
  t.popupSelected = '#FF1A73E8';
  t.divider = '#FFC5C9D0';
  return t;
}

/**
 * Colours for a theme. Coloured, gradient and picture themes use translucent white (or black on
 * light backgrounds) key tiles like Gboard, so the background shows through.
 */
export function buildTheme(id: string, systemDark: boolean, keyBorders: boolean, imageUri: string,
  dim: number): KeyboardTheme {
  const def = themeDef(id);
  let t: KeyboardTheme;
  if (def.group === ThemeGroup.DEFAULT) {
    const dark = def.id === THEME_DARK || (def.id === THEME_SYSTEM && systemDark);
    t = gboardDefault(dark);
  } else {
    t = new KeyboardTheme();
    const light = def.lightBackground;
    const base = def.colors[0];
    const mid = def.colors[Math.floor(def.colors.length / 2)];
    t.dark = !light;
    t.background = base;
    t.gradient = def.group === ThemeGroup.GRADIENT ? def.colors.slice() : [];
    t.textShadow = def.group === ThemeGroup.LANDSCAPE || def.group === ThemeGroup.CUSTOM ||
      (def.group === ThemeGroup.GRADIENT && !light);
    const ink = light ? '#FF202124' : '#FFFFFFFF';
    t.text = ink;
    t.hint = alpha(ink, light ? 0.6 : 0.72);
    t.key = alpha(light ? '#FFFFFFFF' : '#FFFFFFFF', light ? 0.75 : 0.18);
    t.functionKey = alpha(light ? '#FF000000' : '#FFFFFFFF', light ? 0.08 : 0.1);
    t.pressedKey = alpha(light ? '#FF000000' : '#FFFFFFFF', light ? 0.18 : 0.34);
    t.accentKey = light ? mix(mid, '#FF000000', 0.55) : mix(mid, '#FFFFFFFF', 0.82);
    t.accentText = light ? '#FFFFFFFF' : mix(mid, '#FF000000', 0.35);
    t.accent = light ? mix(mid, '#FF000000', 0.55) : '#FFFFFFFF';
    t.popup = light ? '#FFFFFFFF' : mix(base, '#FF000000', 0.35);
    t.popupSelected = t.accentKey;
    t.divider = alpha(ink, 0.25);
    if (def.group === ThemeGroup.LANDSCAPE || def.group === ThemeGroup.CUSTOM) {
      t.image = imageUri;
      t.dim = dim;
      t.popup = '#FF2D2F33';
      t.popupSelected = '#FFFFFFFF';
      t.accentKey = '#FFFFFFFF';
      t.accentText = '#FF202124';
    }
  }
  t.id = def.id;
  t.keyBorders = keyBorders;
  if (!keyBorders) {
    // Without borders only the labels stand on the background (Gboard "Tastenumrandung" off).
    t.key = '#00000000';
    t.functionKey = '#00000000';
  }
  return t;
}

export const DARK_THEME: KeyboardTheme = buildTheme(THEME_DARK, true, true, '', 0);
export const LIGHT_THEME: KeyboardTheme = buildTheme(THEME_LIGHT, false, true, '', 0);
