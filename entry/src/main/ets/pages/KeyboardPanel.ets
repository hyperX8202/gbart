import { KeyboardController, PanelMode, StorageKeys, StripSlot, StripState } from '../inputmethod/KeyboardController';
import { buildLetters, KeyboardLayout, KeyDef, KeyKind, LayoutKind, NUMBER_ROW_HEIGHT } from '../inputmethod/Layouts';
import { KeyboardSettings } from '../inputmethod/Settings';
import { DARK_THEME, KeyboardTheme } from '../inputmethod/Theme';
import { EmojiCategory, EmojiItem, RECENT_CATEGORY_ID, recentCategory } from '../inputmethod/Emoji';
import { CONTROLLER_KEY, EMOJI_CATEGORIES_KEY, KEY_HEIGHT_KEY, THEME_KEY } from '../inputmethod/KeyboardExtAbility';

const STRIP_HEIGHT_VP = 44;
const SIDE_PADDING_VP = 3;
const KEY_GAP_VP = 3;
const SPACE_CURSOR_START_VP = 14;
const SPACE_CURSOR_STEP_VP = 11;
const BACKSPACE_SWIPE_VP = 40;
const BACKSPACE_REPEAT_MS = 55;
const DOUBLE_TAP_MS = 300;
const EMOJI_COLUMNS = 8;
/** A touch that leaves its key by this share of the key width becomes a swipe (gesture typing). */
const GESTURE_START_KEY_WIDTHS = 0.6;
/** Trail points kept on screen (Gboard's trail fades behind the finger). */
const TRAIL_POINTS = 64;

/** Time of the last tap on shift, for double-tap caps lock (shared by all shift keys). */
let lastShiftTap: number = 0;

enum OverlayKind {
  NONE,
  PREVIEW,
  POPUP
}

/** Key frame in window coordinates (vp). */
class KeyRect {
  x: number = 0;
  y: number = 0;
  width: number = 0;
  height: number = 0;
}

/** Callbacks from a key to the panel, which draws previews and popups above all keys. */
class KeyHost {
  showPreview: (rect: KeyRect, label: string) => void = () => {};
  showPopup: (rect: KeyRect, chars: string[]) => number = () => 0;
  selectPopup: (index: number) => void = () => {};
  hideOverlay: () => void = () => {};
  popupCellWidth: () => number = () => 0;
  /** Gesture trail in window coordinates (vp). */
  trailStart: (x: number, y: number) => void = () => {};
  trailMove: (x: number, y: number) => void = () => {};
  trailEnd: () => void = () => {};
}

@Component
struct KeyView {
  keyDef: KeyDef = new KeyDef('');
  controller: KeyboardController | undefined = undefined;
  host: KeyHost = new KeyHost();
  @Prop shift: boolean = false;
  @Prop capsLock: boolean = false;
  @Prop enterLabel: string = 'return';
  @Prop spaceLabel: string = '';
  @Prop theme: KeyboardTheme = DARK_THEME;
  @Prop settings: KeyboardSettings = new KeyboardSettings();
  @State pressed: boolean = false;

  private rect: KeyRect = new KeyRect();
  private longPressTimer: number = -1;
  private repeatTimer: number = -1;
  private longPressFired: boolean = false;
  private popupOpen: boolean = false;
  private popupX: number = 0;
  private popupIndex: number = 0;
  private popupChars: string[] = [];
  private downX: number = 0;
  private downY: number = 0;
  private cursorMode: boolean = false;
  private cursorAnchorX: number = 0;
  private swipeDelete: boolean = false;
  private gliding: boolean = false;
  private pointerId: number = -1;
  private gestureXs: number[] = [];
  private gestureYs: number[] = [];

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        if (this.symbol() !== null) {
          SymbolGlyph(this.symbol() as Resource)
            .fontSize(this.keyDef.kind === KeyKind.ENTER ? 22 : 24)
            .fontColor([this.textColor()])
        } else {
          Text(this.label())
            .fontSize(this.fontSize())
            .fontColor(this.textColor())
            .textAlign(TextAlign.Center)
        }
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height('100%')
      .borderRadius(7)
      .backgroundColor(this.keyBackground())
      .shadow({ radius: this.theme.dark ? 0 : 0.5, color: '#33000000', offsetX: 0, offsetY: this.theme.dark ? 0 : 1 })
      if (this.keyDef.hint.length > 0) {
        Text(this.keyDef.hint)
          .fontSize(10)
          .fontColor(this.theme.hint)
          .margin({ top: 2, right: 5 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .layoutWeight(this.keyDef.width)
    .height('100%')
    .padding({ left: KEY_GAP_VP / 2, right: KEY_GAP_VP / 2, top: KEY_GAP_VP, bottom: KEY_GAP_VP })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.rect.x = Number(newValue.globalPosition.x ?? 0);
      this.rect.y = Number(newValue.globalPosition.y ?? 0);
      this.rect.width = Number(newValue.width);
      this.rect.height = Number(newValue.height);
    })
    .onTouch((event: TouchEvent) => {
      this.onTouchEvent(event);
    })
  }

  /** Function keys use HarmonyOS system symbols (monochrome, like Gboard's icons). */
  private symbol(): Resource | null {
    switch (this.keyDef.kind) {
      case KeyKind.SHIFT:
        return this.capsLock ? $r('sys.symbol.arrow_up_to_line') : $r('sys.symbol.arrow_up');
      case KeyKind.BACKSPACE:
        return $r('sys.symbol.delete_left');
      case KeyKind.EMOJI:
        return $r('sys.symbol.face_smiling');
      case KeyKind.LANGUAGE:
        return $r('sys.symbol.globe_and_keyboard');
      case KeyKind.ENTER:
        switch (this.enterLabel) {
          case 'search':
            return $r('sys.symbol.magnifyingglass');
          case 'send':
            return $r('sys.symbol.paperplane');
          case 'next':
            return $r('sys.symbol.arrow_right');
          case 'done':
            return $r('sys.symbol.checkmark');
          default:
            return $r('sys.symbol.return_down_left');
        }
      default:
        return null;
    }
  }

  private label(): string {
    switch (this.keyDef.kind) {
      case KeyKind.ENTER:
        return this.enterLabel;
      case KeyKind.SPACE:
        return this.spaceLabel;
      case KeyKind.SHIFT:
        return this.capsLock ? '⇪' : '⇧';
      case KeyKind.CHAR:
        return this.shift || this.capsLock ? this.keyDef.label.toUpperCase() : this.keyDef.label;
      default:
        return this.keyDef.label;
    }
  }

  private fontSize(): number {
    if (this.keyDef.kind === KeyKind.CHAR) {
      return 22;
    }
    if (this.keyDef.kind === KeyKind.SPACE) {
      return 14;
    }
    if (this.keyDef.kind === KeyKind.EMOJI || this.keyDef.kind === KeyKind.LANGUAGE) {
      return 20;
    }
    return 16;
  }

  private textColor(): string {
    if (this.keyDef.kind === KeyKind.ENTER) {
      return this.theme.accentText;
    }
    if (this.keyDef.kind === KeyKind.SHIFT && (this.shift || this.capsLock)) {
      return this.theme.accent;
    }
    if (this.keyDef.kind === KeyKind.SPACE) {
      return this.theme.hint;
    }
    return this.theme.text;
  }

  private keyBackground(): string {
    if (this.pressed) {
      return this.theme.pressedKey;
    }
    if (this.keyDef.kind === KeyKind.ENTER) {
      return this.theme.accentKey;
    }
    if (this.keyDef.kind === KeyKind.CHAR || this.keyDef.kind === KeyKind.SPACE) {
      return this.theme.key;
    }
    return this.theme.functionKey;
  }

  private onTouchEvent(event: TouchEvent): void {
    // Fast two-finger typing: a key only follows the finger that went down on it. Reading
    // touches[0] would hand it the other finger's position and turn the tap into a swipe.
    if (event.type === TouchType.Down) {
      const down = event.changedTouches.length > 0 ? event.changedTouches[0] : event.touches[0];
      if (!down) {
        return;
      }
      this.pointerId = down.id;
      this.downY = down.windowY;
      this.onDown(down.windowX);
      return;
    }
    // Up/Cancel count only when our finger is the one that changed; moves use its current position.
    const changed = event.changedTouches.find((t: TouchObject) => t.id === this.pointerId);
    const touch = event.type === TouchType.Move ?
      (changed ?? event.touches.find((t: TouchObject) => t.id === this.pointerId)) : changed;
    if (!touch) {
      return;
    }
    switch (event.type) {
      case TouchType.Move:
        this.onMove(touch.windowX, touch.windowY, event.touches.length > 1);
        break;
      case TouchType.Up:
        this.onUp(false);
        break;
      case TouchType.Cancel:
        this.onUp(true);
        break;
    }
  }

  private onDown(x: number): void {
    this.pressed = true;
    this.longPressFired = false;
    this.popupOpen = false;
    this.cursorMode = false;
    this.swipeDelete = false;
    this.gliding = false;
    this.downX = x;
    this.cursorAnchorX = x;
    this.controller?.haptic();
    if (this.keyDef.kind === KeyKind.CHAR && this.settings.keyPopup) {
      this.host.showPreview(this.rect, this.label());
    }
    this.clearTimers();
    this.longPressTimer = setTimeout(() => {
      this.onLongPress();
    }, this.settings.longPressMs);
  }

  private onLongPress(): void {
    this.longPressTimer = -1;
    if (this.cursorMode || this.swipeDelete) {
      return;
    }
    const controller = this.controller;
    if (!controller) {
      return;
    }
    switch (this.keyDef.kind) {
      case KeyKind.CHAR:
        if (this.keyDef.popup.length > 0) {
          this.longPressFired = true;
          this.popupChars = this.keyDef.popup.map((c: string) => this.shift || this.capsLock ? c.toUpperCase() : c);
          this.popupX = this.host.showPopup(this.rect, this.popupChars);
          this.popupIndex = 0;
          this.popupOpen = true;
          controller.haptic();
        }
        break;
      case KeyKind.BACKSPACE:
        this.longPressFired = true;
        controller.onBackspace();
        this.repeatTimer = setInterval(() => {
          controller.onBackspace();
        }, BACKSPACE_REPEAT_MS);
        break;
      case KeyKind.SHIFT:
        this.longPressFired = true;
        controller.onCapsLock();
        controller.haptic();
        break;
      case KeyKind.SPACE:
        if (controller.currentSettings().languages.length > 1) {
          this.longPressFired = true;
          controller.nextLanguage();
          controller.haptic();
        }
        break;
      default:
        break;
    }
  }

  /** Window point (vp) in engine units, through this key's frame (all letter keys share one scale). */
  private engineX(x: number): number {
    return Math.round(this.keyDef.engineX + (x - this.rect.x) * this.keyDef.engineWidth / this.rect.width);
  }

  private engineY(y: number): number {
    return Math.round(this.keyDef.engineY + (y - this.rect.y) * this.keyDef.engineHeight / this.rect.height);
  }

  private onMove(x: number, y: number, multiTouch: boolean = false): void {
    if (this.gliding) {
      this.gestureXs.push(this.engineX(x));
      this.gestureYs.push(this.engineY(y));
      if (this.settings.gestureTrail) {
        this.host.trailMove(x, y);
      }
      return;
    }
    if (this.keyDef.kind === KeyKind.CHAR && this.keyDef.engineX >= 0 && this.rect.width > 0 && !this.popupOpen &&
      !this.longPressFired && !multiTouch && this.controller?.gestureAllowed() &&
      Math.hypot(x - this.downX, y - this.downY) > this.rect.width * GESTURE_START_KEY_WIDTHS) {
      // Glide typing: the finger left the key; from here on the trace is collected.
      this.gliding = true;
      this.pressed = false;
      this.clearTimers();
      this.host.hideOverlay();
      this.gestureXs = [this.engineX(this.downX), this.engineX(x)];
      this.gestureYs = [this.engineY(this.downY), this.engineY(y)];
      if (this.settings.gestureTrail) {
        this.host.trailStart(this.downX, this.downY);
        this.host.trailMove(x, y);
      }
      return;
    }
    if (this.popupOpen) {
      const cell = this.host.popupCellWidth();
      const index = Math.max(0, Math.min(this.popupChars.length - 1, Math.floor((x - this.popupX) / cell)));
      if (index !== this.popupIndex) {
        this.popupIndex = index;
        this.host.selectPopup(index);
      }
      return;
    }
    if (this.keyDef.kind === KeyKind.SPACE && this.settings.spaceCursorControl) {
      if (!this.cursorMode && Math.abs(x - this.downX) > SPACE_CURSOR_START_VP) {
        this.cursorMode = true;
        this.cursorAnchorX = this.downX;
        this.clearTimers();
      }
      if (this.cursorMode) {
        while (Math.abs(x - this.cursorAnchorX) >= SPACE_CURSOR_STEP_VP) {
          const right = x > this.cursorAnchorX;
          this.controller?.onMoveCursor(right);
          this.cursorAnchorX += right ? SPACE_CURSOR_STEP_VP : -SPACE_CURSOR_STEP_VP;
        }
      }
      return;
    }
    if (this.keyDef.kind === KeyKind.BACKSPACE && !this.longPressFired && this.downX - x > BACKSPACE_SWIPE_VP) {
      this.swipeDelete = true;
      this.clearTimers();
    }
  }

  private onUp(cancelled: boolean): void {
    this.pressed = false;
    this.clearTimers();
    this.host.hideOverlay();
    const controller = this.controller;
    if (this.gliding) {
      this.gliding = false;
      this.host.trailEnd();
      if (controller && !cancelled) {
        controller.onGesture(this.gestureXs, this.gestureYs);
      }
      this.gestureXs = [];
      this.gestureYs = [];
      return;
    }
    if (!controller || cancelled) {
      this.popupOpen = false;
      return;
    }
    if (this.popupOpen) {
      this.popupOpen = false;
      controller.onText(this.popupChars[this.popupIndex]);
      return;
    }
    if (this.cursorMode) {
      controller.onCursorMoveFinished();
      return;
    }
    if (this.swipeDelete) {
      controller.onDeleteWord();
      return;
    }
    if (!this.longPressFired) {
      this.onTap(controller);
    }
  }

  private onTap(controller: KeyboardController): void {
    switch (this.keyDef.kind) {
      case KeyKind.CHAR: {
        // Touch point inside the key, mapped into the engine's key frame (spatial model).
        const key = this.keyDef;
        let x = -1;
        let y = -1;
        if (key.engineX >= 0 && this.rect.width > 0 && this.rect.height > 0) {
          const fx = Math.max(0, Math.min(1, (this.downX - this.rect.x) / this.rect.width));
          const fy = Math.max(0, Math.min(1, (this.downY - this.rect.y) / this.rect.height));
          x = Math.round(key.engineX + fx * key.engineWidth);
          y = Math.round(key.engineY + fy * key.engineHeight);
        }
        controller.onText(key.label, x, y);
        break;
      }
      case KeyKind.SHIFT: {
        const now = Date.now();
        if (now - lastShiftTap < DOUBLE_TAP_MS) {
          controller.onCapsLock();
          lastShiftTap = 0;
        } else {
          controller.onShift();
          lastShiftTap = now;
        }
        break;
      }
      case KeyKind.BACKSPACE:
        controller.onBackspace();
        break;
      case KeyKind.SYMBOLS:
        controller.showLayout(LayoutKind.SYMBOLS);
        break;
      case KeyKind.SYMBOLS_MORE:
        controller.showLayout(LayoutKind.SYMBOLS_MORE);
        break;
      case KeyKind.LETTERS:
        controller.showLayout(LayoutKind.LETTERS);
        break;
      case KeyKind.LANGUAGE:
        controller.nextLanguage();
        break;
      case KeyKind.EMOJI:
        controller.showEmoji(true);
        break;
      case KeyKind.SPACE:
        controller.onSpace();
        break;
      case KeyKind.ENTER:
        controller.onEnter();
        break;
    }
  }

  private clearTimers(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
    if (this.repeatTimer !== -1) {
      clearInterval(this.repeatTimer);
      this.repeatTimer = -1;
    }
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }
}

/** One suggestion in the strip. A component (not a @Builder) so its text updates while typing. */
@Component
struct StripSlotView {
  @Prop text: string = '';
  @Prop slot: StripSlot = StripSlot.CENTER;
  @Prop highlighted: boolean = false;
  @Prop theme: KeyboardTheme = DARK_THEME;
  controller: KeyboardController | undefined = undefined;

  build() {
    Text(this.text)
      .fontSize(17)
      .fontColor(this.highlighted ? this.theme.accent : this.theme.text)
      .fontWeight(this.highlighted || this.slot === StripSlot.CENTER ? FontWeight.Medium : FontWeight.Normal)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      .width('100%')
      .height('100%')
      .onClick(() => {
        this.controller?.haptic();
        this.controller?.onSuggestion(this.slot);
      })
  }
}

// The LocalStorage passed to Panel.setUiContent() by KeyboardExtAbility is the shared storage.
@Entry({ useSharedStorage: true })
@Component
struct KeyboardPanel {
  @LocalStorageLink(StorageKeys.LAYOUT) layout: KeyboardLayout = buildLetters('de', new KeyboardSettings());
  @LocalStorageLink(StorageKeys.STRIP) strip: StripState = new StripState();
  @LocalStorageLink(StorageKeys.SHIFT) shift: boolean = false;
  @LocalStorageLink(StorageKeys.CAPS_LOCK) capsLock: boolean = false;
  @LocalStorageLink(StorageKeys.ENTER_LABEL) enterLabel: string = 'return';
  @LocalStorageLink(StorageKeys.SPACE_LABEL) spaceLabel: string = '';
  @LocalStorageLink(StorageKeys.MODE) mode: PanelMode = PanelMode.KEYS;
  @LocalStorageLink(StorageKeys.SETTINGS) settings: KeyboardSettings = new KeyboardSettings();
  @LocalStorageLink(StorageKeys.RECENT_EMOJIS) recentEmojis: string[] = [];
  @LocalStorageLink(THEME_KEY) theme: KeyboardTheme = DARK_THEME;
  @LocalStorageLink(KEY_HEIGHT_KEY) keyHeight: number = 54;
  @LocalStorageLink(EMOJI_CATEGORIES_KEY) emojiCategories: EmojiCategory[] = [];

  @State overlayKind: OverlayKind = OverlayKind.NONE;
  @State overlayX: number = 0;
  @State overlayY: number = 0;
  @State overlayW: number = 0;
  @State overlayH: number = 0;
  @State overlayChars: string[] = [];
  @State overlaySelected: number = 0;
  @State previewLabel: string = '';
  @State emojiCategoryId: string = RECENT_CATEGORY_ID;
  @State emojiVariants: string[] = [];
  @State trail: Array<[number, number]> = [];
  private panelWidth: number = 0;
  private controller: KeyboardController | undefined = undefined;
  private host: KeyHost = new KeyHost();

  aboutToAppear(): void {
    this.controller = this.getUIContext().getSharedLocalStorage()?.get<KeyboardController>(CONTROLLER_KEY);
    this.host.showPreview = (rect: KeyRect, label: string) => {
      const w = rect.width + 8;
      const h = rect.height + 14;
      this.overlayW = w;
      this.overlayH = h;
      this.overlayX = Math.max(0, Math.min(this.panelWidth - w, rect.x - 4));
      this.overlayY = Math.max(0, rect.y - h + 6);
      this.previewLabel = label;
      this.overlayKind = OverlayKind.PREVIEW;
    };
    this.host.popupCellWidth = () => this.popupCell();
    this.host.showPopup = (rect: KeyRect, chars: string[]) => {
      const cell = this.popupCell();
      const w = cell * chars.length + 8;
      const h = rect.height + 4;
      this.overlayW = w;
      this.overlayH = h;
      this.overlayX = Math.max(0, Math.min(this.panelWidth - w, rect.x));
      this.overlayY = Math.max(0, rect.y - h + 4);
      this.overlayChars = chars;
      this.overlaySelected = 0;
      this.overlayKind = OverlayKind.POPUP;
      return this.overlayX + 4;
    };
    this.host.selectPopup = (index: number) => {
      this.overlaySelected = index;
    };
    this.host.hideOverlay = () => {
      this.overlayKind = OverlayKind.NONE;
    };
    this.host.trailStart = (x: number, y: number) => {
      this.trail = [[x, y]];
    };
    this.host.trailMove = (x: number, y: number) => {
      const points = this.trail.length >= TRAIL_POINTS ? this.trail.slice(this.trail.length - TRAIL_POINTS + 1) :
        this.trail.slice();
      points.push([x, y]);
      this.trail = points;
    };
    this.host.trailEnd = () => {
      this.trail = [];
    };
  }

  private popupCell(): number {
    return Math.max(34, this.panelWidth / 12);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.mode === PanelMode.EMOJI) {
          this.emojiPanel()
        } else {
          this.stripOrToolbar()
          ForEach(this.layout.rows, (row: KeyDef[], index: number) => {
            this.keyRow(row, index === 0 && this.layout.hasNumberRow)
          }, (row: KeyDef[], index: number) => `${this.layout.id}-${index}`)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: SIDE_PADDING_VP, right: SIDE_PADDING_VP })

      if (this.trail.length > 1) {
        Polyline()
          .points(this.trail)
          .width('100%')
          .height('100%')
          .fillOpacity(0)
          .stroke(this.theme.accent)
          .strokeWidth(6)
          .strokeOpacity(0.8)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.overlayKind === OverlayKind.PREVIEW) {
        Text(this.previewLabel)
          .fontSize(30)
          .fontColor(this.theme.text)
          .textAlign(TextAlign.Center)
          .width(this.overlayW)
          .height(this.overlayH)
          .borderRadius(10)
          .backgroundColor(this.theme.popup)
          .shadow({ radius: 6, color: '#55000000', offsetY: 2 })
          .position({ x: this.overlayX, y: this.overlayY })
          .hitTestBehavior(HitTestMode.None)
      } else if (this.overlayKind === OverlayKind.POPUP) {
        Row() {
          ForEach(this.overlayChars, (c: string, index: number) => {
            Text(c)
              .fontSize(22)
              .fontColor(index === this.overlaySelected ? this.theme.accentText : this.theme.text)
              .textAlign(TextAlign.Center)
              .width(this.popupCell())
              .height('100%')
              .borderRadius(8)
              .backgroundColor(index === this.overlaySelected ? this.theme.popupSelected : Color.Transparent)
          }, (c: string, index: number) => `${index}-${c}`)
        }
        .padding(4)
        .width(this.overlayW)
        .height(this.overlayH)
        .borderRadius(10)
        .backgroundColor(this.theme.popup)
        .shadow({ radius: 6, color: '#55000000', offsetY: 2 })
        .position({ x: this.overlayX, y: this.overlayY })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.background)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.panelWidth = Number(newValue.width);
    })
  }

  // --- suggestion strip / toolbar ------------------------------------------------------------

  @Builder
  stripOrToolbar() {
    if (this.strip.isEmpty()) {
      this.toolbarRow()
    } else {
      Row() {
        StripSlotView({ text: this.strip.left, slot: StripSlot.LEFT, highlighted: false, theme: this.theme,
          controller: this.controller }).layoutWeight(1)
        Divider().vertical(true).height(20).color(this.theme.divider)
        StripSlotView({ text: this.strip.center, slot: StripSlot.CENTER,
          highlighted: this.strip.centerIsAutocorrect, theme: this.theme, controller: this.controller }).layoutWeight(1)
        Divider().vertical(true).height(20).color(this.theme.divider)
        StripSlotView({ text: this.strip.right, slot: StripSlot.RIGHT, highlighted: false, theme: this.theme,
          controller: this.controller }).layoutWeight(1)
      }
      .width('100%')
      .height(STRIP_HEIGHT_VP)
    }
  }

  @Builder
  toolbarIcon(icon: Resource, action: () => void) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.theme.hint])
    }
    .justifyContent(FlexAlign.Center)
    .width(52)
    .height('100%')
    .onClick(() => {
        this.controller?.haptic();
        action();
      })
  }

  @Builder
  toolbarRow() {
    Row() {
      this.toolbarIcon($r('sys.symbol.gearshape'), () => {
        this.controller?.openSettings();
      })
      this.toolbarIcon($r('sys.symbol.face_smiling'), () => {
        this.controller?.showEmoji(true);
      })
      if (this.settings.languages.length > 1) {
        this.toolbarIcon($r('sys.symbol.globe_and_keyboard'), () => {
          this.controller?.nextLanguage();
        })
      }
      Blank()
      this.toolbarIcon($r('sys.symbol.chevron_down'), () => {
        this.controller?.hideKeyboard();
      })
    }
    .width('100%')
    .height(STRIP_HEIGHT_VP)
  }

  // --- keys ----------------------------------------------------------------------------------

  @Builder
  keyRow(row: KeyDef[], numberRow: boolean) {
    Row() {
      if (KeyboardLayout.rowUnits(row) < this.layout.unitsWide()) {
        Blank().layoutWeight((this.layout.unitsWide() - KeyboardLayout.rowUnits(row)) / 2)
      }
      ForEach(row, (key: KeyDef) => {
        KeyView({
          keyDef: key,
          controller: this.controller,
          host: this.host,
          shift: this.shift,
          capsLock: this.capsLock,
          enterLabel: this.enterLabel,
          spaceLabel: this.spaceLabel,
          theme: this.theme,
          settings: this.settings
        })
      }, (key: KeyDef, index: number) => `${this.layout.id}-${index}-${key.label}`)
      if (KeyboardLayout.rowUnits(row) < this.layout.unitsWide()) {
        Blank().layoutWeight((this.layout.unitsWide() - KeyboardLayout.rowUnits(row)) / 2)
      }
    }
    .width('100%')
    .height(numberRow ? this.keyHeight * NUMBER_ROW_HEIGHT : this.keyHeight)
  }

  // --- emoji ---------------------------------------------------------------------------------

  private currentEmojiCategory(): EmojiCategory {
    if (this.emojiCategoryId === RECENT_CATEGORY_ID) {
      return recentCategory(this.recentEmojis);
    }
    return this.emojiCategories.find((c: EmojiCategory) => c.id === this.emojiCategoryId) ?? recentCategory([]);
  }

  @Builder
  emojiPanel() {
    Column() {
      // Header: category name, or the variants of a long-pressed emoji.
      Row() {
        if (this.emojiVariants.length > 0) {
          ForEach(this.emojiVariants, (e: string) => {
            Text(e)
              .fontSize(26)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .height('100%')
              .onClick(() => {
                this.controller?.haptic();
                this.controller?.onEmoji(e);
                this.emojiVariants = [];
              })
          }, (e: string) => e)
        } else {
          Text(this.currentEmojiCategory().label)
            .fontSize(14)
            .fontColor(this.theme.hint)
            .margin({ left: 12 })
        }
      }
      .width('100%')
      .height(STRIP_HEIGHT_VP)

      Grid() {
        ForEach(this.currentEmojiCategory().items, (item: EmojiItem) => {
          GridItem() {
            Text(item.base)
              .fontSize(28)
              .textAlign(TextAlign.Center)
              .width('100%')
              .height(46)
          }
          .onClick(() => {
            this.controller?.haptic();
            this.emojiVariants = [];
            this.controller?.onEmoji(item.base);
          })
          .gesture(LongPressGesture({ duration: 350 }).onAction(() => {
            if (item.variants.length > 0) {
              this.controller?.haptic();
              this.emojiVariants = [item.base].concat(item.variants);
            }
          }))
        }, (item: EmojiItem, index: number) => `${this.emojiCategoryId}-${index}-${item.base}`)
      }
      .columnsTemplate('1fr '.repeat(EMOJI_COLUMNS).trim())
      .cachedCount(4)
      .layoutWeight(1)
      .width('100%')

      if (this.recentEmojis.length === 0 && this.emojiCategoryId === RECENT_CATEGORY_ID) {
        Text($r('app.string.emoji_recent_empty'))
          .fontSize(13)
          .fontColor(this.theme.hint)
          .margin({ bottom: 8 })
      }

      Row() {
        Text('ABC')
          .fontSize(15)
          .fontColor(this.theme.text)
          .textAlign(TextAlign.Center)
          .width(56)
          .height('100%')
          .borderRadius(7)
          .backgroundColor(this.theme.functionKey)
          .onClick(() => {
            this.controller?.haptic();
            this.emojiVariants = [];
            this.controller?.showEmoji(false);
          })
        Scroll() {
          Row() {
            this.emojiTab('🕘', RECENT_CATEGORY_ID)
            ForEach(this.emojiCategories, (c: EmojiCategory) => {
              this.emojiTab(c.icon, c.id)
            }, (c: EmojiCategory) => c.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .height('100%')
        Column() {
          SymbolGlyph($r('sys.symbol.delete_left'))
            .fontSize(22)
            .fontColor([this.theme.text])
        }
          .justifyContent(FlexAlign.Center)
          .width(56)
          .height('100%')
          .borderRadius(7)
          .backgroundColor(this.theme.functionKey)
          .onClick(() => {
            this.controller?.haptic();
            this.controller?.onBackspace();
          })
      }
      .width('100%')
      .height(this.keyHeight - 6)
      .padding({ top: 3, bottom: 3 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  emojiTab(icon: string, id: string) {
    Text(icon)
      .fontSize(22)
      .textAlign(TextAlign.Center)
      .width(42)
      .height('100%')
      .borderRadius(8)
      .opacity(this.emojiCategoryId === id ? 1 : 0.55)
      .backgroundColor(this.emojiCategoryId === id ? this.theme.key : Color.Transparent)
      .onClick(() => {
        this.emojiVariants = [];
        this.emojiCategoryId = id;
      })
  }
}
