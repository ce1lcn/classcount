/**
 * 持久化层：Preferences 封装
 *   - UIAbility 进程：异步读写日程列表
 *   - FormExtensionAbility 进程：同步只读（见 CardDataReader）
 *
 * 注意：本文件位于工程内，是**唯一真实来源**。
 *      早期草案已废弃，请以本文件为准。
 *
 * 设计依据：formProvider.getPublishedRunningFormInfos()（@since 20 / @since 23 static，
 * 无 @permission、无 @systemapi）让主应用可直接查到桌面卡片的 formId，
 * 因此不再需要把 formId 写进 Preferences 让主应用读。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { buildSnapshot, Schedule, ScheduleSnapshot } from './Schedule';

const STORE_NAME: string = 'schedule_store';
const K_ITEMS: string = 'items';
const K_ACTIVE: string = 'active_id';

/** 反序列化日程列表，任何异常都退化为空数组 */
function parseSchedules(raw: string): Schedule[] {
  try {
    const parsed: Schedule[] = JSON.parse(raw) as Schedule[];
    if (parsed !== null && parsed !== undefined) {
      return parsed;
    }
  } catch (err) {
    return [];
  }
  return [];
}

/** 取当前选中日程；activeId 为空或找不到时退化为列表第一条 */
function pickActive(list: Schedule[], activeId: string): Schedule | null {
  if (list.length === 0) {
    return null;
  }
  if (activeId.length > 0) {
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === activeId) {
        return list[i];
      }
    }
  }
  return list[0];
}

/** 主应用使用：异步读写 */
export class ScheduleStore {
  private ctx: common.Context;
  private pref: preferences.Preferences | null = null;

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  /** 取 Preferences 实例；失败返回 null（调用方走空态，不抛异常） */
  private async ensure(): Promise<preferences.Preferences | null> {
    if (this.pref === null) {
      try {
        this.pref = await preferences.getPreferences(this.ctx, STORE_NAME);
      } catch (err) {
        return null;
      }
    }
    return this.pref;
  }

  async loadSchedules(): Promise<Schedule[]> {
    const pref: preferences.Preferences | null = await this.ensure();
    if (pref === null) {
      return [];
    }
    try {
      const raw: string = await pref.get(K_ITEMS, '[]') as string;
      return parseSchedules(raw);
    } catch (err) {
      return [];
    }
  }

  async saveSchedules(list: Schedule[]): Promise<void> {
    const pref: preferences.Preferences | null = await this.ensure();
    if (pref === null) {
      return;
    }
    try {
      await pref.put(K_ITEMS, JSON.stringify(list));
      await pref.flush();
    } catch (err) {
      return;
    }
  }

  async loadActiveId(): Promise<string> {
    const pref: preferences.Preferences | null = await this.ensure();
    if (pref === null) {
      return '';
    }
    try {
      return await pref.get(K_ACTIVE, '') as string;
    } catch (err) {
      return '';
    }
  }

  async saveActiveId(id: string): Promise<void> {
    const pref: preferences.Preferences | null = await this.ensure();
    if (pref === null) {
      return;
    }
    try {
      await pref.put(K_ACTIVE, id);
      await pref.flush();
    } catch (err) {
      return;
    }
  }

  /** 主应用侧算快照（用于主界面 + 推送到卡片） */
  async loadSnapshot(now: number): Promise<ScheduleSnapshot> {
    const list: Schedule[] = await this.loadSchedules();
    const activeId: string = await this.loadActiveId();
    return buildSnapshot(pickActive(list, activeId), now);
  }
}

/**
 * 卡片进程专用：**全同步**读取。
 * onAddForm 是同步返回 formBindingData 的，不能 await，故必须走同步接口
 * （已确认 API 23 存在 getPreferencesSync / getSync）。
 */
export class CardDataReader {
  static readSnapshot(ctx: common.Context, now: number): ScheduleSnapshot {
    try {
      const pref: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: STORE_NAME });
      const raw: string = pref.getSync(K_ITEMS, '[]') as string;
      const activeId: string = pref.getSync(K_ACTIVE, '') as string;
      const list: Schedule[] = parseSchedules(raw);
      return buildSnapshot(pickActive(list, activeId), now);
    } catch (err) {
      return buildSnapshot(null, now);
    }
  }
}
