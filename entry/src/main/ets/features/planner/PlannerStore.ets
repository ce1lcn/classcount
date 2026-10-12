import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { PlannerData, decodePlanner } from './Planner';

/** 独立存储，不接触旧日程和卡片数据。错误交由页面显示，不静默吞掉。 */
export class PlannerStore {
  private context: common.Context;
  private pref: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async open(): Promise<preferences.Preferences> {
    try {
      if (this.pref === null) {
        this.pref = await preferences.getPreferences(this.context, 'planner_store_v1');
      }
      return this.pref;
    } catch (err) {
      throw new Error('无法打开手账存储');
    }
  }

  async load(): Promise<PlannerData> {
    const pref: preferences.Preferences = await this.open();
    try {
      const raw: string = await pref.get('data', '') as string;
      return raw.length === 0 ? new PlannerData() : decodePlanner(raw);
    } catch (err) {
      throw new Error('无法读取手账，原数据已保留');
    }
  }

  async save(data: PlannerData): Promise<void> {
    const pref: preferences.Preferences = await this.open();
    const raw: string = JSON.stringify(data);
    decodePlanner(raw);
    let previous: string = '';
    try {
      previous = await pref.get('data', '') as string;
    } catch (err) {
      throw new Error('无法读取原数据，已取消保存');
    }
    try {
      await pref.put('data', raw);
      await pref.flush();
    } catch (err) {
      // flush 失败时尽量还原缓存，避免重试读取到尚未可靠落盘的新值。
      try {
        await pref.put('data', previous);
        await pref.flush();
      } catch (restoreError) {
        throw new Error('存储不可用，请重试');
      }
      throw new Error('手账保存失败，请重试');
    }
  }
}
