import { InputMethodExtensionAbility, InputMethodSubtype, inputMethodEngine } from '@kit.IMEKit';
import { ConfigurationConstant, Want } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardController } from './KeyboardController';
import engine from 'libkeyboard_engine.so';
import { dictionaryForLanguage, emojiDictionaryForLanguage } from './Layouts';
import { applyUiLanguage, KeyboardSettings, KeyboardStatus, SettingsStore } from './Settings';
import { DARK_THEME, KeyboardTheme } from './Theme';
import { resolveTheme } from './ThemeAssets';
import { EmojiCategory, loadEmojiCategories } from './Emoji';

const TAG = 'KeyboardExtAbility';
const DOMAIN = 0x4b42;
const STRIP_HEIGHT_VP = 44;
const KEY_HEIGHT_VP = 54;
const BOTTOM_PADDING_VP = 6;
/** Landscape keys are lower (the screen is short), like Gboard's. */
const LANDSCAPE_KEY_SCALE = 0.78;
/** Bump when the bundled dictionaries change (v2: HeliBoard dictionaries with next-word data). */
const DICTIONARY_VERSION = 3;

export const THEME_KEY = 'kb_theme';
export const KEY_HEIGHT_KEY = 'kb_key_height';
export const EMOJI_CATEGORIES_KEY = 'kb_emoji_categories';
export const CONTROLLER_KEY = 'kb_controller';

export default class KeyboardExtAbility extends InputMethodExtensionAbility {
  private panel: inputMethodEngine.Panel | null = null;
  private storage: LocalStorage = new LocalStorage();
  private controller: KeyboardController | null = null;
  private settingsStore: SettingsStore | null = null;
  private keyboardController: inputMethodEngine.KeyboardController | null = null;
  private loadedLanguages: string[] = [];

  private onInputStart = (kbController: inputMethodEngine.KeyboardController,
    client: inputMethodEngine.InputClient): void => {
    this.keyboardController = kbController;
    this.reloadSettings();
    this.controller?.attach(client);
    this.showPanel();
  };
  private onInputStop = (): void => {
    this.controller?.detach();
  };
  private onSetSubtype = (subtype: InputMethodSubtype): void => {
    // A single system subtype ("all active languages"); languages are chosen in the settings app.
    if (this.controller?.currentSettings().languages.includes(subtype.id)) {
      this.controller?.setLayoutLanguage(subtype.id);
    }
  };
  /** Re-shown without a new input session (e.g. after Back): settings may have changed meanwhile. */
  private onKeyboardShow = (): void => {
    this.reloadSettings();
    this.resizePanel();
  };
  private onTextChange = (text: string): void => {
    this.controller?.onEditorText(text);
  };
  private onSelectionChange = (oldBegin: number, oldEnd: number, newBegin: number, newEnd: number): void => {
    this.controller?.onSelectionChange(newBegin, newEnd);
  };

  onCreate(want: Want): void {
    const store = new SettingsStore(this.context);
    this.settingsStore = store;
    const controller = new KeyboardController(this.storage, store);
    this.controller = controller;
    this.storage.setOrCreate<KeyboardController>(CONTROLLER_KEY, controller);
    this.storage.setOrCreate<KeyboardTheme>(THEME_KEY, DARK_THEME);
    this.storage.setOrCreate<number>(KEY_HEIGHT_KEY, KEY_HEIGHT_VP);
    this.storage.setOrCreate<EmojiCategory[]>(EMOJI_CATEGORIES_KEY, loadEmojiCategories(this.context));

    controller.languagesHandler = (languages: string[]) => {
      this.loadLanguages(languages);
    };
    controller.layoutChangedHandler = () => {
      this.resizePanel();
    };
    controller.openSettingsHandler = () => {
      this.keyboardController?.hideKeyboard();
      this.context.startAbility({ bundleName: this.context.applicationInfo.name, abilityName: 'EntryAbility' })
        .catch((e: Error) => {
          hilog.error(DOMAIN, TAG, 'opening settings failed: %{public}s', JSON.stringify(e));
        });
    };
    controller.hideKeyboardHandler = () => {
      this.keyboardController?.hideKeyboard();
    };

    this.removeOutdatedDictionaries();
    const settings = store.load();
    controller.applySettings(settings);
    this.applyAppearance(settings);
    this.loadLanguages(settings.languages);
    controller.setLayoutLanguage(settings.languages[0]);

    const ability = inputMethodEngine.getInputMethodAbility();
    ability.on('inputStart', this.onInputStart);
    ability.on('inputStop', this.onInputStop);
    ability.on('setSubtype', this.onSetSubtype);
    ability.on('keyboardShow', this.onKeyboardShow);
    inputMethodEngine.getKeyboardDelegate().on('selectionChange', this.onSelectionChange);
    inputMethodEngine.getKeyboardDelegate().on('textChange', this.onTextChange);
    this.createPanel();
    try {
      display.on('change', this.onDisplayChange);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'display events: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    engine.flush();
    try {
      display.off('change', this.onDisplayChange);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'display events: %{public}s', JSON.stringify(e));
    }
    const ability = inputMethodEngine.getInputMethodAbility();
    ability.off('inputStart', this.onInputStart);
    ability.off('inputStop', this.onInputStop);
    ability.off('setSubtype', this.onSetSubtype);
    ability.off('keyboardShow', this.onKeyboardShow);
    inputMethodEngine.getKeyboardDelegate().off('selectionChange', this.onSelectionChange);
    inputMethodEngine.getKeyboardDelegate().off('textChange', this.onTextChange);
    if (this.panel) {
      ability.destroyPanel(this.panel);
      this.panel = null;
    }
  }

  /** Settings may have been changed in the settings screen (another process). */
  private reloadSettings(): void {
    const controller = this.controller;
    const store = this.settingsStore;
    if (!controller || !store) {
      return;
    }
    const settings = store.load();
    controller.applySettings(settings);
    this.reportStatus(store);
    applyUiLanguage(this.context, settings.uiLanguage);
    if (settings.resetLearningAt > store.handledResetAt()) {
      // "Gelerntes löschen" in the settings app.
      store.setHandledResetAt(settings.resetLearningAt);
      this.resetLearning();
    } else if (settings.languages.join(',') !== this.loadedLanguages.join(',')) {
      this.loadLanguages(settings.languages);
    }
    if (!settings.languages.includes(controller.currentLocale())) {
      controller.setLayoutLanguage(settings.languages[0]);
    }
    this.applyAppearance(settings);
  }

  /** Lets the settings app show whether the keyboard runs in full mode (needed for vibration). */
  private reportStatus(store: SettingsStore): void {
    const status = new KeyboardStatus();
    try {
      status.securityMode = inputMethodEngine.getInputMethodAbility().getSecurityMode();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getSecurityMode failed: %{public}s', JSON.stringify(e));
    }
    status.updatedAt = Date.now();
    store.writeStatus(status);
  }

  private applyAppearance(settings: KeyboardSettings): void {
    this.storage.set<KeyboardTheme>(THEME_KEY, this.pickTheme(settings));
    this.storage.set<number>(KEY_HEIGHT_KEY, Math.round(KEY_HEIGHT_VP * settings.heightScale));
  }

  private pickTheme(settings: KeyboardSettings): KeyboardTheme {
    return resolveTheme(this.context, settings, this.systemDark());
  }

  /**
   * The extension's own config often reports "not set"; the resource configuration follows the
   * system's light/dark mode.
   */
  private systemDark(): boolean {
    let dark = this.context.config?.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    try {
      dark = this.context.resourceManager.getConfigurationSync().colorMode !== resourceManager.ColorMode.LIGHT;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'color mode unknown: %{public}s', JSON.stringify(e));
    }
    return dark;
  }

  /**
   * Multilingual typing: main dictionary + learning history dictionary of every enabled language
   * are loaded together; the engine merges their suggestions.
   */
  private loadLanguages(languages: string[]): void {
    engine.removeAllLanguages();
    const historyRoot = `${this.context.filesDir}/history`;
    try {
      if (!fs.accessSync(historyRoot)) {
        fs.mkdirSync(historyRoot);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'history dir failed: %{public}s', JSON.stringify(e));
    }
    for (const id of languages) {
      try {
        const path = this.ensureDictionary(dictionaryForLanguage(id));
        if (!engine.addLanguage(id, path, `${historyRoot}/${id}`)) {
          hilog.error(DOMAIN, TAG, 'cannot load language %{public}s', id);
        }
        const emojiDict = emojiDictionaryForLanguage(id);
        if (emojiDict.length > 0) {
          engine.addEmojiDictionary(id, this.ensureDictionary(emojiDict, 'emoji_dicts'));
        }
      } catch (e) {
        // Without a dictionary the keyboard still types; it just cannot suggest in that language.
        hilog.error(DOMAIN, TAG, 'loading %{public}s failed: %{public}s', id, JSON.stringify(e));
      }
    }
    this.loadedLanguages = languages.slice();
  }

  /** Settings → "Gelerntes löschen": drop all history dictionaries and start fresh. */
  private resetLearning(): void {
    engine.removeAllLanguages();
    try {
      fs.rmdirSync(`${this.context.filesDir}/history`);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'removing history failed: %{public}s', JSON.stringify(e));
    }
    this.loadLanguages(this.controller?.currentSettings().languages ?? ['de']);
  }

  /** Copies from earlier versions (flat files or older dicts-v* directories) waste space. */
  private removeOutdatedDictionaries(): void {
    try {
      for (const name of fs.listFileSync(this.context.filesDir)) {
        const path = `${this.context.filesDir}/${name}`;
        if (name.endsWith('.dict')) {
          fs.unlinkSync(path);
        } else if (name.startsWith('dicts-v') && name !== `dicts-v${DICTIONARY_VERSION}`) {
          fs.rmdirSync(path);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cleanup failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Dictionaries ship gzip-compressed as rawfiles; the native engine needs a real file, so each
   * enabled language's dictionary is unpacked once.
   */
  private ensureDictionary(fileName: string, rawDir: string = 'dicts'): string {
    // Versioned directory: a new app version with updated dictionaries unpacks them again.
    const dir = `${this.context.filesDir}/dicts-v${DICTIONARY_VERSION}`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const target = `${dir}/${fileName.replace(/\.gz$/, '')}`;
    if (fs.accessSync(target)) {
      return target;
    }
    const bytes = this.context.resourceManager.getRawFileContentSync(`${rawDir}/${fileName}`);
    const data = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    if (!engine.inflateGzip(data, target)) {
      throw new Error(`unpacking ${fileName} failed`);
    }
    return target;
  }

  private async createPanel(): Promise<void> {
    try {
      const panelInfo: inputMethodEngine.PanelInfo = {
        type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
        flag: inputMethodEngine.PanelFlag.FLG_FIXED
      };
      this.panel = await inputMethodEngine.getInputMethodAbility().createPanel(this.context, panelInfo);
      await this.panel.setUiContent('pages/KeyboardPanel', this.storage);
      await this.resizePanel();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'createPanel failed: %{public}s', JSON.stringify(e));
    }
  }

  private async showPanel(): Promise<void> {
    if (!this.panel) {
      await this.createPanel();
    }
    if (this.panel) {
      // The Mate XT folds into three widths, so size the panel for the current display each time.
      await this.resizePanel();
      await this.panel.show();
    }
  }

  /**
   * Panel size for both orientations at once (the system switches on rotation). Landscape keys are
   * lower, like Gboard's; the panel page lets its rows share whatever height it gets. Called again
   * when the Mate XT's fold state changes the display.
   */
  private async resizePanel(): Promise<void> {
    if (!this.panel || !this.controller) {
      return;
    }
    try {
      const screen = display.getDefaultDisplaySync();
      const keyHeight = this.storage.get<number>(KEY_HEIGHT_KEY) ?? KEY_HEIGHT_VP;
      const rows = this.controller.rowCount();
      const density = screen.densityPixels;
      const portraitVp = STRIP_HEIGHT_VP + rows * keyHeight + BOTTOM_PADDING_VP;
      const landscapeVp = STRIP_HEIGHT_VP + rows * keyHeight * LANDSCAPE_KEY_SCALE + BOTTOM_PADDING_VP;
      const shortSide = Math.min(screen.width, screen.height);
      const longSide = Math.max(screen.width, screen.height);
      this.panel.adjustPanelRect(inputMethodEngine.PanelFlag.FLG_FIXED, {
        portraitRect: { left: 0, top: 0, width: shortSide, height: Math.round(portraitVp * density) },
        landscapeRect: { left: 0, top: 0, width: longSide, height: Math.round(landscapeVp * density) }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'resize failed: %{public}s', JSON.stringify(e));
    }
  }

  private onDisplayChange = (): void => {
    this.resizePanel();
  };
}
