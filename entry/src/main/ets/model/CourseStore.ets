/**
 * 课表持久化层
 *
 * 双接口模式（同 ScheduleStore）：
 *   - 主应用/课表页：异步读写
 *   - FormExtensionAbility 卡片进程：同步只读（onAddForm 必须同步返回）
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { CourseItem, CourseTable, parseKbJson, parseWeeks, startOfWeek } from './Course';

const STORE_NAME: string = 'course_store';
const K_TABLE: string = 'course_table';
/** 内置课表（由教务系统导出 PDF 解析而来），首次使用时自动导入 */
const BUNDLED_TABLE: string = 'kebiao_init.json';

function emptyTable(): CourseTable {
  return new CourseTable();
}

function parseTable(raw: string): CourseTable {
  try {
    const t: CourseTable = JSON.parse(raw) as CourseTable;
    if (t !== null && t !== undefined && t.items !== null && t.items !== undefined) {
      // 补全派生字段：内置 JSON 只写基本信息，weekList / id / 备注容器在这里补齐
      for (let i = 0; i < t.items.length; i++) {
        const it: CourseItem = t.items[i];
        const wl: number[] = it.weekList;
        if (wl === null || wl === undefined || wl.length === 0) {
          it.weekList = parseWeeks(it.weeksText);
        }
        if (it.id === null || it.id === undefined || it.id.length === 0) {
          it.id = `${it.name}|${it.dayOfWeek}|${it.startSection}|${it.weeksText}`;
        }
        if (it.memo === null || it.memo === undefined) {
          it.memo = '';
        }
        if (it.dayMemos === null || it.dayMemos === undefined) {
          it.dayMemos = {};
        }
      }
      // 「课程备注」按课程名共享：同一门课不论排在周几、第几节，用的都是同一条备注。
      // 取同名项里第一个非空值回填给全部同名项（兼容历史数据：备注曾散落在某一个时段上）。
      const sharedMemo: Record<string, string> = {};
      for (let i = 0; i < t.items.length; i++) {
        const it: CourseItem = t.items[i];
        if (it.memo !== null && it.memo !== undefined && it.memo.length > 0
            && sharedMemo[it.name] === undefined) {
          sharedMemo[it.name] = it.memo;
        }
      }
      for (let i = 0; i < t.items.length; i++) {
        const it: CourseItem = t.items[i];
        const m: string = sharedMemo[it.name];
        if (m !== undefined && m !== it.memo) {
          it.memo = m;
        }
      }
      return t;
    }
  } catch (e) {
    return emptyTable();
  }
  return emptyTable();
}

export class CourseStore {
  private ctx: common.Context;
  private pref: preferences.Preferences | null = null;

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  private async ensure(): Promise<preferences.Preferences | null> {
    if (this.pref === null) {
      try {
        this.pref = await preferences.getPreferences(this.ctx, STORE_NAME);
      } catch (e) {
        return null;
      }
    }
    return this.pref;
  }

  async load(): Promise<CourseTable> {
    const pref: preferences.Preferences | null = await this.ensure();
    if (pref === null) {
      return emptyTable();
    }
    try {
      const raw: string = await pref.get(K_TABLE, '') as string;
      if (raw.length === 0) {
        return emptyTable();
      }
      return parseTable(raw);
    } catch (e) {
      return emptyTable();
    }
  }

  async save(t: CourseTable): Promise<void> {
    const pref: preferences.Preferences | null = await this.ensure();
    if (pref === null) {
      return;
    }
    try {
      await pref.put(K_TABLE, JSON.stringify(t));
      await pref.flush();
    } catch (e) {
      return;
    }
  }

  /** 首次使用：从内置 rawfile 导入课表 */
  async importBundled(): Promise<CourseTable> {
    try {
      const bytes: Uint8Array = await this.ctx.resourceManager.getRawFileContent(BUNDLED_TABLE);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const raw: string = decoder.decodeToString(bytes);
      const t: CourseTable = parseTable(raw);
      if (t.items.length > 0) {
        await this.save(t);
      }
      return t;
    } catch (e) {
      return emptyTable();
    }
  }

  /** 落盘教务系统抓到的原始 JSON，保留用户已写的备注/备忘 */
  async saveFromRaw(raw: string, xnm: string, xqm: string): Promise<CourseTable> {
    const t: CourseTable = parseKbJson(raw, xnm, xqm);
    const old: CourseTable = await this.load();
    for (let i = 0; i < t.items.length; i++) {
      const it: CourseItem = t.items[i];
      for (let j = 0; j < old.items.length; j++) {
        if (old.items[j].id === it.id) {
          it.memo = old.items[j].memo;
          it.dayMemos = old.items[j].dayMemos;
          break;
        }
      }
    }
    // 学期起始：优先沿用旧值，否则用系统返回的当前周次反推
    if (t.termStart <= 0) {
      t.termStart = old.termStart;
    }
    if (t.termStart <= 0 && t.currentWeek > 0) {
      t.termStart = startOfWeek(Date.now()) - (t.currentWeek - 1) * 7 * 86400000;
    }
    await this.save(t);
    return t;
  }

  /**
   * 写入「课程备注」。
   * 备注以**课程名**为单位共享：同一门课的每个时段都写同一条，
   * 避免「周一写过的备注，周三那节看不到」。
   * （「本次课备忘」不受影响，仍按具体时段存储。）
   */
  async updateMemo(itemId: string, memo: string): Promise<void> {
    const t: CourseTable = await this.load();
    let name: string = '';
    for (let i = 0; i < t.items.length; i++) {
      if (t.items[i].id === itemId) {
        name = t.items[i].name;
        break;
      }
    }
    if (name.length === 0) {
      return;
    }
    for (let i = 0; i < t.items.length; i++) {
      if (t.items[i].name === name) {
        t.items[i].memo = memo;
      }
    }
    await this.save(t);
  }

  async updateDayMemo(itemId: string, date: string, memo: string): Promise<void> {
    const t: CourseTable = await this.load();
    for (let i = 0; i < t.items.length; i++) {
      if (t.items[i].id === itemId) {
        if (t.items[i].dayMemos === null || t.items[i].dayMemos === undefined) {
          t.items[i].dayMemos = {};
        }
        t.items[i].dayMemos[date] = memo;
        break;
      }
    }
    await this.save(t);
  }

  async setTermStart(ts: number): Promise<void> {
    const t: CourseTable = await this.load();
    t.termStart = ts;
    t.termStartUserSet = true;   // 用户手动设过，之后不再被内置值覆盖
    await this.save(t);
  }

  /**
   * 用随包内置课表的开学日纠正本地值。
   * 仅在用户从未手动设置过时生效 —— 这样升级应用能修正基准周次，
   * 又不会把用户自己设的日期冲掉。
   */
  async syncBundledTermStart(): Promise<boolean> {
    try {
      const bytes: Uint8Array = await this.ctx.resourceManager.getRawFileContent(BUNDLED_TABLE);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const bundled: CourseTable = parseTable(decoder.decodeToString(bytes));
      if (bundled.termStart <= 0) {
        return false;
      }
      const local: CourseTable = await this.load();
      if (local.termStartUserSet) {
        return false;
      }
      if (local.termStart === bundled.termStart) {
        return false;
      }
      local.termStart = bundled.termStart;
      await this.save(local);
      return true;
    } catch (e) {
      return false;
    }
  }
}

/** 卡片进程专用：同步读 */
export class CourseReader {
  static readSync(ctx: common.Context): CourseTable {
    try {
      const pref: preferences.Preferences =
        preferences.getPreferencesSync(ctx, { name: STORE_NAME });
      const raw: string = pref.getSync(K_TABLE, '') as string;
      if (raw.length === 0) {
        return emptyTable();
      }
      return parseTable(raw);
    } catch (e) {
      return emptyTable();
    }
  }
}