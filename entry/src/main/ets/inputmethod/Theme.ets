/** Colours modelled on Gboard's default light and dark themes. */
export class KeyboardTheme {
  dark: boolean;
  background: string;
  key: string;
  functionKey: string;
  accentKey: string;
  pressedKey: string;
  text: string;
  hint: string;
  accent: string;
  accentText: string;
  popup: string;
  popupSelected: string;
  divider: string;

  constructor(dark: boolean) {
    this.dark = dark;
    if (dark) {
      this.background = '#FF202124';
      this.key = '#FF3C4043';
      this.functionKey = '#FF2D2F33';
      this.accentKey = '#FF8AB4F8';
      this.pressedKey = '#FF5F6368';
      this.text = '#FFE8EAED';
      this.hint = '#FF9AA0A6';
      this.accent = '#FF8AB4F8';
      this.accentText = '#FF202124';
      this.popup = '#FF5F6368';
      this.popupSelected = '#FF8AB4F8';
      this.divider = '#FF3C4043';
    } else {
      this.background = '#FFE8EAED';
      this.key = '#FFFFFFFF';
      this.functionKey = '#FFC5C9D0';
      this.accentKey = '#FF1A73E8';
      this.pressedKey = '#FFBDC1C6';
      this.text = '#FF202124';
      this.hint = '#FF5F6368';
      this.accent = '#FF1A73E8';
      this.accentText = '#FFFFFFFF';
      this.popup = '#FFFFFFFF';
      this.popupSelected = '#FF1A73E8';
      this.divider = '#FFC5C9D0';
    }
  }
}

export const DARK_THEME: KeyboardTheme = new KeyboardTheme(true);
export const LIGHT_THEME: KeyboardTheme = new KeyboardTheme(false);
