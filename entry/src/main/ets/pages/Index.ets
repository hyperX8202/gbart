import { bundleManager, common } from '@kit.AbilityKit';
import { inputMethod } from '@kit.IMEKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { AutoCorrectStrength, KeyboardSettings, KeyboardStatus, SettingsStore, SplitMode } from '../inputmethod/Settings';
import { buildTheme, KeyboardTheme, THEME_CUSTOM, THEME_DARK, THEME_DEFS, THEME_LIGHT, THEME_SYSTEM, ThemeDef, themeDef,
  ThemeGroup } from '../inputmethod/Theme';
import { customImagePath, themeImageUri } from '../inputmethod/ThemeAssets';
import { KeyboardPreview, ThemeTile } from './ThemeTile';
import { LANGUAGES, LanguageDef, languageById } from '../inputmethod/LanguageData';
import { ChoiceItem, CARD_BG, groupHeader, hint, NavRow, PAGE_BG, RadioRow, SliderRow, SwitchRow, TEXT_PRIMARY,
  TEXT_SECONDARY } from './SettingsRows';

const STRENGTHS: ChoiceItem[] = [
  new ChoiceItem($r('app.string.strength_modest'), AutoCorrectStrength.MODEST),
  new ChoiceItem($r('app.string.strength_aggressive'), AutoCorrectStrength.AGGRESSIVE),
  new ChoiceItem($r('app.string.strength_very'), AutoCorrectStrength.VERY_AGGRESSIVE)
];

const SPLIT_MODES: ChoiceItem[] = [
  new ChoiceItem($r('app.string.split_auto'), SplitMode.AUTO),
  new ChoiceItem($r('app.string.split_always'), SplitMode.ALWAYS),
  new ChoiceItem($r('app.string.split_never'), SplitMode.NEVER)
];

class ThemeSection {
  group: ThemeGroup;
  title: Resource;

  constructor(group: ThemeGroup, title: Resource) {
    this.group = group;
    this.title = title;
  }
}

const THEME_SECTIONS: ThemeSection[] = [
  new ThemeSection(ThemeGroup.DEFAULT, $r('app.string.theme_group_default')),
  new ThemeSection(ThemeGroup.COLOR, $r('app.string.theme_group_colors')),
  new ThemeSection(ThemeGroup.GRADIENT, $r('app.string.theme_group_gradients')),
  new ThemeSection(ThemeGroup.LANDSCAPE, $r('app.string.theme_group_landscapes'))
];

/** Longest side of the own picture after scaling (keyboard panels are at most ~2200 px wide). */
const CUSTOM_IMAGE_MAX_PX = 2200;

/** inputMethodEngine.SecurityMode.BASIC: vibration needs the full experience mode. */
const SECURITY_MODE_BASIC = 0;

/**
 * Settings app, built like Gboard's: setup state, then the settings groups. The keyboard reads
 * the settings file each time it opens, so changes apply the next time it is shown.
 */
@Entry
@Component
struct Index {
  @State settings: KeyboardSettings = new KeyboardSettings();
  @State isCurrent: boolean = true;
  @State status: KeyboardStatus = new KeyboardStatus();
  @State tryText: string = '';
  @State languageQuery: string = '';
  @State licenseText: string = '';
  /** Resolved theme per THEME_DEFS entry (picker tiles), refreshed when borders or picture change. */
  @State tileThemes: KeyboardTheme[] = [];
  private stack: NavPathStack = new NavPathStack();
  private store: SettingsStore | null = null;
  private version: string = '';

  aboutToAppear(): void {
    this.store = new SettingsStore(getContext(this) as common.UIAbilityContext);
    try {
      this.version = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      this.version = '';
    }
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  private reload(): void {
    if (!this.store) {
      return;
    }
    this.settings = this.store.load();
    this.refreshThemes();
    this.status = this.store.readStatus();
    try {
      const current = inputMethod.getCurrentInputMethod();
      this.isCurrent = current !== undefined && current.name === getContext(this).applicationInfo.name;
    } catch (e) {
      this.isCurrent = false;
    }
  }

  private edit(mutate: (s: KeyboardSettings) => void): void {
    const changed = this.settings.copy();
    mutate(changed);
    this.store?.save(changed);
    const appearance = changed.keyBorders !== this.settings.keyBorders ||
      changed.customImageAt !== this.settings.customImageAt || changed.customDim !== this.settings.customDim;
    this.settings = changed;
    if (appearance) {
      this.refreshThemes();
    }
  }

  private systemDark(): boolean {
    try {
      return getContext(this).resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
    } catch (e) {
      return true;
    }
  }

  private refreshThemes(): void {
    const context = getContext(this);
    const dark = this.systemDark();
    this.tileThemes = THEME_DEFS.map((d: ThemeDef) => buildTheme(d.id, dark, this.settings.keyBorders,
      themeImageUri(context, d.id, this.settings), d.id === THEME_CUSTOM ? this.settings.customDim : 0));
  }

  private tileTheme(id: string): KeyboardTheme {
    const index = THEME_DEFS.findIndex((d: ThemeDef) => d.id === id);
    return index >= 0 && index < this.tileThemes.length ? this.tileThemes[index] : new KeyboardTheme();
  }

  /**
   * Own picture: picked from the gallery, scaled down and stored in the directory the keyboard can
   * read; then selected as theme.
   */
  private async pickCustomImage(): Promise<void> {
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await new photoAccessHelper.PhotoViewPicker().select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      const file = fs.openSync(result.photoUris[0], fs.OpenMode.READ_ONLY);
      try {
        const source = image.createImageSource(file.fd);
        const info = await source.getImageInfo();
        const scale = Math.min(1, CUSTOM_IMAGE_MAX_PX / Math.max(info.size.width, info.size.height));
        const pixels = await source.createPixelMap({
          desiredSize: { width: Math.round(info.size.width * scale), height: Math.round(info.size.height * scale) }
        });
        const data = await image.createImagePacker().packToData(pixels, { format: 'image/jpeg', quality: 88 });
        const out = fs.openSync(customImagePath(getContext(this)),
          fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(out.fd, data);
        } finally {
          fs.closeSync(out);
        }
        pixels.release();
        source.release();
      } finally {
        fs.closeSync(file);
      }
      this.edit((s: KeyboardSettings) => {
        s.customImageAt = Date.now();
        s.theme = THEME_CUSTOM;
      });
    } catch (e) {
      hilog.error(0x4b42, 'Index', 'own picture failed: %{public}s', JSON.stringify(e));
    }
  }

  private setLanguage(languageId: string, on: boolean): void {
    this.edit((s: KeyboardSettings) => {
      let langs = s.languages.filter((l: string) => l !== languageId);
      if (on) {
        langs = langs.concat([languageId]);
      }
      // At least one language stays enabled.
      s.languages = langs.length > 0 ? langs : [languageId];
    });
  }

  /** Makes a language the one the keyboard starts with (first in the list). */
  private makeDefault(languageId: string): void {
    this.edit((s: KeyboardSettings) => {
      s.languages = [languageId].concat(s.languages.filter((l: string) => l !== languageId));
    });
  }

  /**
   * Third-party apps may not switch the input method themselves (CONNECT_IME_ABILITY is a system
   * permission), so the setup opens System › Input methods, where the user picks the keyboard.
   */
  private openSystemInputSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
      uri: 'system_and_updates'
    }).catch((e: Error) => {
      hilog.warn(0x4b42, 'Index', 'opening system settings failed: %{public}s', JSON.stringify(e));
    });
  }

  build() {
    Navigation(this.stack) {
      Scroll() {
        Column({ space: 12 }) {
          this.setupCard()
          Column() {
            NavRow({ icon: $r('sys.symbol.globe_and_keyboard'), title: $r('app.string.sec_languages'),
              subtitle: this.settings.languages.map((id: string) => languageById(id).label).join(', '),
              onTap: () => this.stack.pushPathByName('languages', null) })
            Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 52 })
            NavRow({ icon: $r('sys.symbol.keyboard'), title: $r('app.string.sec_preferences'),
              subtitleResource: $r('app.string.sec_preferences_desc'),
              onTap: () => this.stack.pushPathByName('preferences', null) })
            Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 52 })
            NavRow({ icon: $r('sys.symbol.paintpalette'), title: $r('app.string.sec_theme'),
              subtitleResource: this.themeName(), onTap: () => this.stack.pushPathByName('theme', null) })
            Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 52 })
            NavRow({ icon: $r('sys.symbol.checkmark_circle'), title: $r('app.string.sec_correction'),
              subtitleResource: $r('app.string.sec_correction_desc'),
              onTap: () => this.stack.pushPathByName('correction', null) })
            Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 52 })
            NavRow({ icon: $r('sys.symbol.hand_draw'), title: $r('app.string.sec_glide'),
              subtitleResource: $r('app.string.glide_enable_desc'),
              onTap: () => this.stack.pushPathByName('glide', null) })
          }
          .card()

          Column() {
            NavRow({ icon: $r('sys.symbol.lock'), title: $r('app.string.sec_privacy'),
              subtitleResource: $r('app.string.sec_privacy_desc'),
              onTap: () => this.stack.pushPathByName('privacy', null) })
            Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 52 })
            NavRow({ icon: $r('sys.symbol.square_and_pencil'), title: $r('app.string.sec_try'),
              onTap: () => this.stack.pushPathByName('try', null) })
            Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 52 })
            NavRow({ icon: $r('sys.symbol.info_circle'), title: $r('app.string.sec_about'), subtitle: this.version,
              onTap: () => this.stack.pushPathByName('about', null) })
          }
          .card()
        }
        .width('100%')
        .padding({ top: 8, bottom: 32 })
      }
      .scrollBar(BarState.Off)
    .align(Alignment.Top)
      .height('100%')
    }
    .title($r('app.string.app_name'))
    .titleMode(NavigationTitleMode.Full)
    .mode(NavigationMode.Stack)
    .backgroundColor(PAGE_BG)
    .navDestination(this.pages)
  }

  private themeName(): Resource {
    switch (this.settings.theme) {
      case THEME_SYSTEM:
        return $r('app.string.theme_system');
      case THEME_LIGHT:
        return $r('app.string.theme_light');
      case THEME_DARK:
        return $r('app.string.theme_dark');
      default:
        break;
    }
    const group = themeDef(this.settings.theme).group;
    if (group === ThemeGroup.CUSTOM) {
      return $r('app.string.theme_group_custom');
    }
    return THEME_SECTIONS.find((t: ThemeSection) => t.group === group)?.title ?? $r('app.string.theme_system');
  }

  private defaultThemeLabel(id: string): ResourceStr {
    return id === THEME_SYSTEM ? $r('app.string.theme_system') : id === THEME_LIGHT ? $r('app.string.theme_light') :
      id === THEME_DARK ? $r('app.string.theme_dark') : '';
  }

  // --- setup -----------------------------------------------------------------------------------

  @Builder
  setupCard() {
    if (!this.isCurrent) {
      Column() {
        NavRow({ icon: $r('sys.symbol.keyboard'), title: $r('app.string.setup_select'),
          subtitleResource: $r('app.string.setup_select_desc'), onTap: () => this.openSystemInputSettings() })
      }
      .card()
    } else if (this.status.securityMode === SECURITY_MODE_BASIC && this.settings.vibrate) {
      Column() {
        NavRow({ icon: $r('sys.symbol.keyboard'), title: $r('app.string.setup_full'),
          subtitleResource: $r('app.string.setup_full_desc'), onTap: () => this.openSystemInputSettings() })
      }
      .card()
    }
  }

  // --- sub pages -------------------------------------------------------------------------------

  @Builder
  pages(name: string) {
    if (name === 'languages') {
      NavDestination() {
        this.languagesPage()
      }
      .title($r('app.string.sec_languages'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'preferences') {
      NavDestination() {
        this.preferencesPage()
      }
      .title($r('app.string.sec_preferences'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'theme') {
      NavDestination() {
        this.themePage()
      }
      .title($r('app.string.sec_theme'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'correction') {
      NavDestination() {
        this.correctionPage()
      }
      .title($r('app.string.sec_correction'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'glide') {
      NavDestination() {
        this.glidePage()
      }
      .title($r('app.string.sec_glide'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'privacy') {
      NavDestination() {
        this.privacyPage()
      }
      .title($r('app.string.sec_privacy'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'try') {
      NavDestination() {
        this.tryPage()
      }
      .title($r('app.string.sec_try'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'about') {
      NavDestination() {
        this.aboutPage()
      }
      .title($r('app.string.sec_about'))
      .backgroundColor(PAGE_BG)
    } else if (name === 'licenses') {
      NavDestination() {
        this.licensesPage()
      }
      .title($r('app.string.about_licenses'))
      .backgroundColor(PAGE_BG)
      .onShown(() => this.loadLicenses())
    }
  }

  private otherLanguages(): LanguageDef[] {
    const q = this.languageQuery.trim().toLowerCase();
    return LANGUAGES
      .filter((l: LanguageDef) => !this.settings.languages.includes(l.id))
      .filter((l: LanguageDef) => q === '' || l.label.toLowerCase().includes(q) || l.id.toLowerCase().includes(q))
      .sort((a: LanguageDef, b: LanguageDef) => a.label.localeCompare(b.label));
  }

  @Builder
  languagesPage() {
    Column() {
      // The search stays on top so it remains visible above the keyboard.
      Search({ value: this.languageQuery, placeholder: $r('app.string.languages_search') })
        .margin({ left: 12, right: 12, top: 4, bottom: 4 })
        .onChange((value: string) => {
          this.languageQuery = value;
        })
      Scroll() {
        Column() {
          if (this.languageQuery.trim() === '') {
            groupHeader($r('app.string.languages_active'))
            Column() {
              ForEach(this.settings.languages, (id: string, index: number) => {
                if (index > 0) {
                  Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 16 })
                }
                Row() {
                  SwitchRow({ title: languageById(id).label,
                    subtitle: index === 0 && this.settings.languages.length > 1 ? $r('app.string.languages_first') : '',
                    value: true, onToggle: (on: boolean) => this.setLanguage(id, on) })
                    .layoutWeight(1)
                }
                .gesture(LongPressGesture().onAction(() => this.makeDefault(id)))
              }, (id: string, index: number) => `${id}-${index}-${this.settings.languages.length}`)
            }
            .card()
            hint($r('app.string.languages_hint'))
            groupHeader($r('app.string.languages_all'))
          }
          Column() {
            ForEach(this.otherLanguages(), (lang: LanguageDef, index: number) => {
              if (index > 0) {
                Divider().color($r('sys.color.ohos_id_color_list_separator')).margin({ left: 16 })
              }
              SwitchRow({ title: lang.label, value: false, onToggle: (on: boolean) => this.setLanguage(lang.id, on) })
            }, (lang: LanguageDef) => lang.id)
          }
          .card()
          .margin({ left: 12, right: 12, top: 8 })
        }
        .padding({ bottom: 32 })
      }
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .layoutWeight(1)
    }
    .height('100%')
  }

  @Builder
  preferencesPage() {
    Scroll() {
      Column() {
        Column() {
          SwitchRow({ title: $r('app.string.number_row'), subtitle: $r('app.string.number_row_desc'),
            value: this.settings.numberRow,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.numberRow = on; }) })
          SwitchRow({ title: $r('app.string.emoji_key'), value: this.settings.showEmojiKey,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.showEmojiKey = on; }) })
          SwitchRow({ title: $r('app.string.language_key'), value: this.settings.showLanguageKey,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.showLanguageKey = on; }) })
          SwitchRow({ title: $r('app.string.key_popup'), value: this.settings.keyPopup,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.keyPopup = on; }) })
        }
        .card()

        groupHeader($r('app.string.split_keyboard'))
        Column() {
          ForEach(SPLIT_MODES, (c: ChoiceItem) => {
            RadioRow({ title: c.label, checked: this.settings.splitMode === c.value,
              onPick: () => this.edit((s: KeyboardSettings) => { s.splitMode = c.value as SplitMode; }) })
          }, (c: ChoiceItem) => c.value)
        }
        .card()
        .margin({ left: 12, right: 12, top: 8 })

        Column() {
          SwitchRow({ title: $r('app.string.vibrate'), value: this.settings.vibrate,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.vibrate = on; }) })
          if (this.settings.vibrate) {
            SliderRow({ title: $r('app.string.vibration_strength'),
              valueText: `${Math.round(this.settings.vibrationMs * 2.5)} %`, value: this.settings.vibrationMs,
              min: 1, max: 40, step: 1,
              onDone: (v: number) => this.edit((s: KeyboardSettings) => { s.vibrationMs = Math.round(v); }) })
          }
        }
        .card()
        .margin({ left: 12, right: 12, top: 12 })

        Column() {
          SliderRow({ title: $r('app.string.keyboard_height'),
            valueText: `${Math.round(this.settings.heightScale * 100)} %`, value: this.settings.heightScale * 100,
            min: 80, max: 130, step: 5,
            onDone: (v: number) => this.edit((s: KeyboardSettings) => { s.heightScale = Math.round(v) / 100; }) })
          SliderRow({ title: $r('app.string.long_press'), valueText: `${this.settings.longPressMs} ms`,
            value: this.settings.longPressMs, min: 200, max: 700, step: 50,
            onDone: (v: number) => this.edit((s: KeyboardSettings) => { s.longPressMs = Math.round(v); }) })
        }
        .card()
        .margin({ left: 12, right: 12, top: 12 })
      }
      .padding({ bottom: 32 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .height('100%')
  }

  @Builder
  themePage() {
    Scroll() {
      Column() {
        // Live preview of the chosen theme.
        Column() {
          Column() {
            KeyboardPreview({ theme: this.tileTheme(this.settings.theme), sizeFactor: 1.6 })
          }
          .width('100%')
          .aspectRatio(2.2)
          .borderRadius(20)
          .clip(true)
        }
        .padding({ left: 12, right: 12, top: 8 })

        Column() {
          SwitchRow({ title: $r('app.string.key_borders'), subtitle: $r('app.string.key_borders_desc'),
            value: this.settings.keyBorders,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.keyBorders = on; }) })
        }
        .card()
        .margin({ left: 12, right: 12, top: 12 })

        ForEach(THEME_SECTIONS, (section: ThemeSection) => {
          groupHeader(section.title)
          Grid() {
            ForEach(THEME_DEFS.filter((d: ThemeDef) => d.group === section.group), (d: ThemeDef) => {
              GridItem() {
                ThemeTile({ theme: this.tileTheme(d.id), selected: this.settings.theme === d.id,
                  label: this.defaultThemeLabel(d.id),
                  onPick: () => this.edit((s: KeyboardSettings) => { s.theme = d.id; }) })
              }
            }, (d: ThemeDef) => `${d.id}-${this.settings.keyBorders}-${this.settings.customImageAt}`)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(10)
          .rowsGap(12)
          .padding({ left: 16, right: 16 })
          .maxCount(3)
          .layoutDirection(GridDirection.Row)
        }, (section: ThemeSection) => `${section.group}`)

        groupHeader($r('app.string.theme_group_custom'))
        Row({ space: 10 }) {
          if (this.settings.customImageAt > 0) {
            Column() {
              ThemeTile({ theme: this.tileTheme(THEME_CUSTOM), selected: this.settings.theme === THEME_CUSTOM,
                onPick: () => this.edit((s: KeyboardSettings) => { s.theme = THEME_CUSTOM; }) })
            }
            .layoutWeight(1)
          }
          Column({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(26)
              .fontColor([$r('sys.color.ohos_id_color_emphasize')])
            Text($r('app.string.theme_pick_image'))
              .fontSize(13)
              .fontColor(TEXT_PRIMARY)
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
          .aspectRatio(1.45)
          .borderRadius(14)
          .backgroundColor(CARD_BG)
          .onClick(() => {
            this.pickCustomImage();
          })
          if (this.settings.customImageAt === 0) {
            Blank().layoutWeight(1)
          }
        }
        .padding({ left: 16, right: 16 })
        if (this.settings.theme === THEME_CUSTOM) {
          Column() {
            SliderRow({ title: $r('app.string.theme_dim'),
              valueText: `${Math.round((1 - this.settings.customDim) * 100)} %`,
              value: Math.round((1 - this.settings.customDim) * 100), min: 20, max: 100, step: 5,
              onDone: (v: number) => this.edit((s: KeyboardSettings) => { s.customDim = (100 - Math.round(v)) / 100; }) })
          }
          .card()
          .margin({ left: 12, right: 12, top: 12 })
        }
      }
      .padding({ bottom: 32 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .height('100%')
  }

  @Builder
  correctionPage() {
    Scroll() {
      Column() {
        groupHeader($r('app.string.sec_correction'))
        Column() {
          SwitchRow({ title: $r('app.string.show_suggestions'), value: this.settings.showSuggestions,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.showSuggestions = on; }) })
          SwitchRow({ title: $r('app.string.emoji_suggestions'), subtitle: $r('app.string.emoji_suggestions_desc'),
            value: this.settings.emojiSuggestions,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.emojiSuggestions = on; }) })
          SwitchRow({ title: $r('app.string.autocorrect'), subtitle: $r('app.string.autocorrect_desc'),
            value: this.settings.autoCorrect,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.autoCorrect = on; }) })
          SwitchRow({ title: $r('app.string.backspace_undo'), value: this.settings.backspaceRevertsAutocorrect,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.backspaceRevertsAutocorrect = on; }) })
        }
        .card()

        if (this.settings.autoCorrect) {
          groupHeader($r('app.string.autocorrect_strength'))
          Column() {
            ForEach(STRENGTHS, (c: ChoiceItem) => {
              RadioRow({ title: c.label, checked: this.settings.autoCorrectStrength === c.value,
                onPick: () => this.edit((s: KeyboardSettings) => {
                  s.autoCorrectStrength = c.value as AutoCorrectStrength;
                }) })
            }, (c: ChoiceItem) => c.value)
          }
          .card()
        }

        groupHeader($r('app.string.sec_more'))
        Column() {
          SwitchRow({ title: $r('app.string.auto_cap'), subtitle: $r('app.string.auto_cap_desc'),
            value: this.settings.autoCapitalize,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.autoCapitalize = on; }) })
          SwitchRow({ title: $r('app.string.double_space'), value: this.settings.doubleSpacePeriod,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.doubleSpacePeriod = on; }) })
          SwitchRow({ title: $r('app.string.space_cursor'), subtitle: $r('app.string.space_cursor_desc'),
            value: this.settings.spaceCursorControl,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.spaceCursorControl = on; }) })
        }
        .card()
      }
      .padding({ bottom: 32 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .height('100%')
  }

  @Builder
  glidePage() {
    Column() {
      Column() {
        SwitchRow({ title: $r('app.string.glide_enable'), subtitle: $r('app.string.glide_enable_desc'),
          value: this.settings.gestureTyping,
          onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.gestureTyping = on; }) })
        if (this.settings.gestureTyping) {
          SwitchRow({ title: $r('app.string.glide_trail'), value: this.settings.gestureTrail,
            onToggle: (on: boolean) => this.edit((s: KeyboardSettings) => { s.gestureTrail = on; }) })
        }
      }
      .card()
      .margin({ left: 12, right: 12, top: 8 })
    }
    .height('100%')
  }

  @Builder
  privacyPage() {
    Column() {
      hint($r('app.string.privacy_text'))
      Column() {
        Text($r('app.string.reset_learning'))
          .fontSize(16)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .width('100%')
          .height(56)
          .padding({ left: 16 })
          .onClick(() => this.confirmReset())
      }
      .card()
      .margin({ left: 12, right: 12, top: 12 })
    }
    .height('100%')
  }

  private confirmReset(): void {
    const context = getContext(this);
    promptAction.showDialog({
      message: context.resourceManager.getStringSync($r('app.string.reset_confirm').id),
      buttons: [
        { text: context.resourceManager.getStringSync($r('app.string.cancel').id), color: '#007DFF' },
        { text: context.resourceManager.getStringSync($r('app.string.delete').id), color: '#E84026' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.edit((s: KeyboardSettings) => { s.resetLearningAt = Date.now(); });
        promptAction.showToast({ message: $r('app.string.reset_done') });
      }
    }).catch((e: Error) => {
      hilog.warn(0x4b42, 'Index', 'dialog failed: %{public}s', e.message);
    });
  }

  @Builder
  tryPage() {
    Column() {
      TextArea({ placeholder: $r('app.string.try_placeholder'), text: this.tryText })
        .height(200)
        .margin(12)
        .onChange((value: string) => {
          this.tryText = value;
        })
    }
    .height('100%')
  }

  @Builder
  aboutPage() {
    Column() {
      Column({ space: 6 }) {
        Text($r('app.string.app_name'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_PRIMARY)
        Text(this.version)
          .fontSize(14)
          .fontColor(TEXT_SECONDARY)
      }
      .padding({ top: 24, bottom: 12 })
      hint($r('app.string.about_engine'))
      Column() {
        NavRow({ title: $r('app.string.about_licenses'), onTap: () => this.stack.pushPathByName('licenses', null) })
      }
      .card()
      .margin({ left: 12, right: 12, top: 12 })
    }
    .height('100%')
  }

  private loadLicenses(): void {
    if (this.licenseText.length > 0) {
      return;
    }
    try {
      const rm = getContext(this).resourceManager;
      const decoder = util.TextDecoder.create('utf-8');
      const notices = decoder.decodeToString(rm.getRawFileContentSync('licenses/THIRD_PARTY_NOTICES.txt'));
      const gpl = decoder.decodeToString(rm.getRawFileContentSync('licenses/LICENSE'));
      this.licenseText = `${notices}\n\n${gpl}`;
    } catch (e) {
      hilog.error(0x4b42, 'Index', 'licenses: %{public}s', JSON.stringify(e));
    }
  }

  @Builder
  licensesPage() {
    Scroll() {
      Text(this.licenseText)
        .fontSize(12)
        .fontColor(TEXT_PRIMARY)
        .padding(16)
    }
    .height('100%')
  }
}

@Extend(Column)
function card() {
  .width('auto')
  .backgroundColor(CARD_BG)
  .borderRadius(20)
  .margin({ left: 12, right: 12 })
  .padding({ top: 4, bottom: 4 })
}
