import { window, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { C_BG, C_INK } from './Theme';

/** Both system bars follow the page, including the dimmed editor backdrop. */
export async function syncWindowColor(ui: UIContext, dimmed: boolean = false): Promise<void> {
  try {
    const main: window.Window = await window.getLastWindow(ui.getHostContext() as common.UIAbilityContext);
    const color: string = dimmed ? '#A5A099' : C_BG;
    main.setWindowBackgroundColor(color);
    await main.setWindowSystemBarProperties({
      statusBarColor: color, navigationBarColor: color,
      statusBarContentColor: C_INK, navigationBarContentColor: C_INK
    });
  } catch (e) {
    hilog.warn(0xFF00, 'WindowColor', 'Unable to synchronize system bar colors');
  }
}
