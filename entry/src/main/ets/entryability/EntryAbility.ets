import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { applyUiLanguage, SettingsStore } from '../inputmethod/Settings';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyLanguage(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyLanguage(want);
  }

  /** Hidden UI language override (--ps uiLanguage en | system), see KeyboardSettings.uiLanguage. */
  private applyLanguage(want: Want): void {
    const store = new SettingsStore(this.context);
    const settings = store.load();
    const requested = want.parameters?.['uiLanguage'];
    if (typeof requested === 'string') {
      settings.uiLanguage = requested === 'system' ? '' : requested;
      store.save(settings);
    }
    applyUiLanguage(this.context, settings.uiLanguage);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x4b42, 'EntryAbility', 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
