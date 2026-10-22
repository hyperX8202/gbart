import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardSettings } from './Settings';
import { buildTheme, KeyboardTheme, themeDef, ThemeGroup } from './Theme';

const DOMAIN = 0x4b42;
const TAG = 'ThemeAssets';
/** Own picture, in the directory shared by the settings app and the keyboard. */
const CUSTOM_IMAGE = 'custom_theme.jpg';

export function customImagePath(context: common.Context): string {
  return `${context.distributedFilesDir}/${CUSTOM_IMAGE}`;
}

/**
 * file:// URI of a landscape picture. Pictures ship as rawfiles; Image needs a file for a picture
 * chosen at run time, so each one is copied once into this process's files directory.
 */
export function landscapeUri(context: common.Context, picture: string): string {
  const dir = `${context.filesDir}/themes`;
  const target = `${dir}/${picture}`;
  try {
    if (!fs.accessSync(target)) {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const bytes = context.resourceManager.getRawFileContentSync(`themes/${picture}`);
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
      } finally {
        fs.closeSync(file);
      }
    }
    return `file://${target}`;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'theme picture %{public}s: %{public}s', picture, JSON.stringify(e));
    return '';
  }
}

/**
 * Local copy of the own picture named after its version, so Image never shows a cached older
 * picture; older copies are removed.
 */
function customImageUri(context: common.Context, version: number): string {
  const source = customImagePath(context);
  const dir = `${context.filesDir}/themes`;
  const target = `${dir}/custom_${version}.jpg`;
  try {
    if (!fs.accessSync(source)) {
      return '';
    }
    if (!fs.accessSync(target)) {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      for (const name of fs.listFileSync(dir)) {
        if (name.startsWith('custom_')) {
          fs.unlinkSync(`${dir}/${name}`);
        }
      }
      fs.copyFileSync(source, target);
    }
    return `file://${target}`;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'own picture: %{public}s', JSON.stringify(e));
    return '';
  }
}

/** Background picture URI for a theme id ('' for themes without a picture). */
export function themeImageUri(context: common.Context, id: string, settings: KeyboardSettings): string {
  const def = themeDef(id);
  if (def.group === ThemeGroup.LANDSCAPE) {
    return landscapeUri(context, def.picture);
  }
  if (def.group === ThemeGroup.CUSTOM) {
    return customImageUri(context, settings.customImageAt);
  }
  return '';
}

/** The theme the keyboard shows for these settings. */
export function resolveTheme(context: common.Context, settings: KeyboardSettings, systemDark: boolean): KeyboardTheme {
  return buildTheme(settings.theme, systemDark, settings.keyBorders,
    themeImageUri(context, settings.theme, settings), settings.customDim);
}
