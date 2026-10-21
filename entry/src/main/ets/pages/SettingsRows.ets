/**
 * Building blocks of the settings app. They only use system colours, so the app follows the
 * system's light/dark mode. Values that change are @Prop: @Builder parameters are copies that
 * ArkUI does not refresh (toggles would snap back).
 */
export const TEXT_PRIMARY: ResourceColor = $r('sys.color.ohos_id_color_text_primary');
export const TEXT_SECONDARY: ResourceColor = $r('sys.color.ohos_id_color_text_secondary');
export const CARD_BG: ResourceColor = $r('sys.color.ohos_id_color_card_bg');
export const PAGE_BG: ResourceColor = $r('sys.color.ohos_id_color_sub_background');
export const ACCENT: ResourceColor = $r('sys.color.ohos_id_color_emphasize');
export const DIVIDER: ResourceColor = $r('sys.color.ohos_id_color_list_separator');

export class ChoiceItem {
  label: Resource;
  value: string;

  constructor(label: Resource, value: string) {
    this.label = label;
    this.value = value;
  }
}

@Component
export struct SwitchRow {
  title: ResourceStr = '';
  subtitle: ResourceStr = '';
  @Prop value: boolean = false;
  onToggle: (on: boolean) => void = () => {};

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(16)
          .fontColor(TEXT_PRIMARY)
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(ACCENT)
        .onChange((isOn: boolean) => {
          if (isOn !== this.value) {
            this.onToggle(isOn);
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 12, top: 8, bottom: 8 })
  }
}

@Component
export struct NavRow {
  icon: Resource | null = null;
  title: ResourceStr = '';
  @Prop subtitle: string = '';
  subtitleResource: ResourceStr = '';
  onTap: () => void = () => {};

  build() {
    Row({ space: 14 }) {
      if (this.icon !== null) {
        SymbolGlyph(this.icon)
          .fontSize(22)
          .fontColor([ACCENT])
      }
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(16)
          .fontColor(TEXT_PRIMARY)
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
        } else if (this.subtitleResource !== '') {
          Text(this.subtitleResource)
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([TEXT_SECONDARY])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 12, top: 8, bottom: 8 })
    .onClick(() => {
      this.onTap();
    })
  }
}

@Component
export struct SliderRow {
  title: ResourceStr = '';
  @Prop valueText: string = '';
  @Prop value: number = 0;
  min: number = 0;
  max: number = 100;
  step: number = 1;
  onDone: (v: number) => void = () => {};

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)
        Text(this.valueText)
          .fontSize(14)
          .fontColor(TEXT_SECONDARY)
      }
      .width('100%')
      Slider({ value: this.value, min: this.min, max: this.max, step: this.step })
        .selectedColor(ACCENT)
        .width('100%')
        .onChange((v: number, mode: SliderChangeMode) => {
          if ((mode === SliderChangeMode.End || mode === SliderChangeMode.Click) && v !== this.value) {
            this.onDone(v);
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 10, bottom: 6 })
  }
}

/** One option of a single choice (radio list, like the system settings). */
@Component
export struct RadioRow {
  title: ResourceStr = '';
  @Prop checked: boolean = false;
  onPick: () => void = () => {};

  build() {
    Row() {
      Text(this.title)
        .fontSize(16)
        .fontColor(TEXT_PRIMARY)
        .layoutWeight(1)
      Radio({ value: '', group: '' })
        .checked(this.checked)
        .radioStyle({ checkedBackgroundColor: ACCENT })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 12 })
    .onClick(() => {
      if (!this.checked) {
        this.onPick();
      }
    })
  }
}

/** A rounded group of rows with an optional header, like HarmonyOS settings. */
@Builder
export function groupHeader(title: ResourceStr) {
  Text(title)
    .fontSize(14)
    .fontWeight(FontWeight.Medium)
    .fontColor(TEXT_SECONDARY)
    .width('100%')
    .padding({ left: 28, right: 16, top: 16, bottom: 6 })
}

@Builder
export function hint(text: ResourceStr) {
  Text(text)
    .fontSize(13)
    .fontColor(TEXT_SECONDARY)
    .width('100%')
    .padding({ left: 28, right: 28, top: 8, bottom: 4 })
}
