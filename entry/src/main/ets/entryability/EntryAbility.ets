/**
 * 主应用入口
 * 目标路径：entry/src/main/ets/entryability/EntryAbility.ets
 *
 * 职责：
 *   1. 接收卡片 postCardAction 的 router 事件（want.parameters.targetPage）
 *   2. 进入前台时把最新快照推给桌面卡片，保证"打开 App 后卡片一定是最新的"
 */
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ScheduleStore } from '../model/ScheduleStore';
import { CardPusher } from '../model/CardPusher';
import { ScheduleSnapshot } from '../model/Schedule';

const TAG: string = 'EntryAbility';
const DOMAIN: number = 0xFF00;

/** 卡片跳转目标页，页面侧可读 AppStorage 决定路由 */
export const KEY_TARGET_PAGE: string = 'targetPage';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    CardPusher.init(this.context);
    this.consumeTargetPage(want);
  }

  /** 应用已在运行时用户又点了卡片，走这里（不会重新 onCreate） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.consumeTargetPage(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
      // 窗口背景与页面同为米白，避免安全区外露出默认白底
      try {
        windowStage.getMainWindowSync().setWindowBackgroundColor('#F6F1E9');
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'setWindowBackgroundColor failed');
      }
    });
  }

  onForeground(): void {
    this.refreshForms();
  }

  /** 把卡片带过来的 targetPage 存进 AppStorage，供页面消费 */
  private consumeTargetPage(want: Want): void {
    const target: string = want.parameters?.[KEY_TARGET_PAGE] as string ?? '';
    if (target.length > 0) {
      AppStorage.setOrCreate<string>(KEY_TARGET_PAGE, target);
      hilog.info(DOMAIN, TAG, 'targetPage=%{public}s', target);
    }
  }

  /** 前台时刷新桌面卡片；桌面上没有卡片时静默跳过 */
  private async refreshForms(): Promise<void> {
    const store: ScheduleStore = new ScheduleStore(this.context);
    const snap: ScheduleSnapshot = await store.loadSnapshot(Date.now());
    const count: number = await CardPusher.pushToAll(snap);
    hilog.info(DOMAIN, TAG, 'onForeground pushed to %{public}d forms', count);
  }
}
