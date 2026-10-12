/**
 * 主应用 → 卡片 数据推送
 *
 * formProvider.getPublishedRunningFormInfos()（@since 20 / @since 23 static，
 * 无 @permission、无 @systemapi）让主应用无需持久化 formId 即可直接查到桌面卡片。
 *
 * ⚠️ 实测：桌面上没有本应用卡片时该接口返回 {"code":16500100}，需按"暂无卡片"处理。
 */
import { formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ScheduleSnapshot } from './Schedule';
import { CourseStore } from './CourseStore';
import { CourseTable, NextClass, calcNextClass } from './Course';
import { buildCardData } from './CardData';

const TAG: string = 'CardPusher';
const DOMAIN: number = 0xFF00;

export class CardPusher {
  /** 由 EntryAbility / Index 启动时注入，推送时用它顺带读课表 */
  private static ctx: common.Context | null = null;

  static init(ctx: common.Context): void {
    CardPusher.ctx = ctx;
  }

  /** 组装当前应推给卡片的完整数据（日程 + 下一节课） */
  static async currentData(snap: ScheduleSnapshot, now: number): Promise<Record<string, string>> {
    let next: NextClass = new NextClass();
    const ctx: common.Context | null = CardPusher.ctx;
    if (ctx !== null) {
      try {
        const store: CourseStore = new CourseStore(ctx);
        const table: CourseTable = await store.load();
        next = calcNextClass(table, now);
      } catch (e) {
        // 课表读取失败不影响日程推送
      }
    }
    return buildCardData(snap, next);
  }

  /** 推送给桌面上所有本应用卡片；返回成功条数 */
  static async pushToAll(snap: ScheduleSnapshot): Promise<number> {
    const now: number = Date.now();
    const payload: Record<string, string> = await CardPusher.currentData(snap, now);
    const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(payload);

    let infos: formInfo.RunningFormInfo[] = [];
    try {
      infos = await formProvider.getPublishedRunningFormInfos();
    } catch (err) {
      // 16500100 = 桌面上没有本应用卡片，属正常情况
      return 0;
    }

    let ok: number = 0;
    for (let i = 0; i < infos.length; i++) {
      const formId: string = infos[i].formId;
      try {
        await formProvider.updateForm(formId, data);
        ok++;
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'updateForm %{public}s failed: %{public}s', formId, e.message);
      }
    }
    hilog.info(DOMAIN, TAG, 'pushed to %{public}d / %{public}d forms', ok, infos.length);
    return ok;
  }

  /** 桌面上是否有本应用的卡片 */
  static async hasFormOnDesktop(): Promise<boolean> {
    try {
      const infos: formInfo.RunningFormInfo[] = await formProvider.getPublishedRunningFormInfos();
      return infos.length > 0;
    } catch (err) {
      return false;
    }
  }
}