import { KeyboardTheme } from '../inputmethod/Theme';
import { ACCENT, TEXT_SECONDARY } from './SettingsRows';

/** Gradient of a theme (one colour for plain themes). */
function gradientOf(theme: KeyboardTheme): LinearGradientOptions {
  const stops = theme.gradient.length > 1 ? theme.gradient : [theme.background, theme.background];
  const colors: Array<[ResourceColor, number]> = stops.map(
    (c: string, i: number) => [c, i / (stops.length - 1)] as [ResourceColor, number]);
  return { angle: 135, colors: colors };
}

const PREVIEW_ROWS: number[] = [10, 9, 7];

/**
 * A theme as a miniature keyboard (background, key tiles or bare keys, space bar and enter key),
 * like the tiles in Gboard's theme picker.
 */
@Component
export struct KeyboardPreview {
  @Prop theme: KeyboardTheme = new KeyboardTheme();
  /** Scale of keys and gaps (1 = picker tile). */
  sizeFactor: number = 1;

  build() {
    Stack() {
      if (this.theme.image !== '') {
        Image(this.theme.image)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        if (this.theme.dim > 0) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(`rgba(0,0,0,${this.theme.dim})`)
        }
      }
      Column({ space: 3 * this.sizeFactor }) {
        ForEach(PREVIEW_ROWS, (count: number) => {
          Row({ space: 3 * this.sizeFactor }) {
            ForEach(Array.from<number>({ length: count }), (n: number, i: number) => {
              Column() {
                if (!this.theme.keyBorders) {
                  // Without borders Gboard shows only the label: a small dot stands for it.
                  Column()
                    .width(3 * this.sizeFactor)
                    .height(3 * this.sizeFactor)
                    .borderRadius(2 * this.sizeFactor)
                    .backgroundColor(this.theme.text)
                }
              }
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .height('100%')
              .borderRadius(2 * this.sizeFactor)
              .backgroundColor(this.theme.key)
            }, (n: number, i: number) => `${count}-${i}`)
          }
          .width(`${count * 10}%`)
          .layoutWeight(1)
        }, (count: number) => `${count}`)
        Row({ space: 3 * this.sizeFactor }) {
          Column()
            .layoutWeight(1)
            .height('100%')
            .borderRadius(2 * this.sizeFactor)
            .backgroundColor(this.theme.functionKey)
          Column()
            .layoutWeight(4)
            .height('100%')
            .borderRadius(2 * this.sizeFactor)
            .backgroundColor(this.theme.keyBorders ? this.theme.key : this.theme.functionKey)
          Column()
            .layoutWeight(1)
            .height('100%')
            .borderRadius(2 * this.sizeFactor)
            .backgroundColor(this.theme.accentKey)
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .padding(5 * this.sizeFactor)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.background)
    .linearGradient(gradientOf(this.theme))
    .clip(true)
  }
}

/** Picker tile: preview, optional name, ring when selected. */
@Component
export struct ThemeTile {
  @Prop theme: KeyboardTheme = new KeyboardTheme();
  @Prop selected: boolean = false;
  label: ResourceStr = '';
  onPick: () => void = () => {};

  build() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        KeyboardPreview({ theme: this.theme })
          .borderRadius(12)
          .clip(true)
        if (this.selected) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(20)
            .fontColor([ACCENT, Color.White])
            .margin(5)
        }
      }
      .width('100%')
      .aspectRatio(1.45)
      .borderRadius(14)
      .border({ width: this.selected ? 2.5 : 0, color: ACCENT })
      .padding(this.selected ? 2.5 : 0)
      if (this.label !== '') {
        Text(this.label)
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .maxLines(1)
      }
    }
    .onClick(() => this.onPick())
  }
}
