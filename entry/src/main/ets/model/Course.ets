/**
 * 课表数据模型 + 正方教务系统返回数据解析
 *
 * 数据来源：学校正方教务系统
 *   POST <教务系统课表接口>，地址与路径配置见 common/Campus.ets
 *   参数：xnm(学年) xqm(学期) kzlx=ck
 *   正方学期编码：3 = 第一学期，12 = 第二学期，16 = 第三学期
 *
 * ⚠️ 字段名依据正方教务系统通行结构推断，**首次抓取真实数据后需按实际返回校正**。
 *    解析器已写成宽松模式：字段取不到就留空，不抛异常。
 */

/** 课表上的一个格子（一门课的一次课） */
export class CourseItem {
  /** 唯一 id：课程名|星期|节次|周次 */
  id: string = '';
  name: string = '';
  teacher: string = '';
  room: string = '';
  /** 星期几：1=周一 ... 7=周日 */
  dayOfWeek: number = 1;
  startSection: number = 1;
  endSection: number = 1;
  /** 周次原文，如 "1-16周" / "1-16周(单)" */
  weeksText: string = '';
  /** 解析后的周次列表，如 [1,2,...,16] */
  weekList: number[] = [];
  /** 用户备注（挂在课程格上，如"要带实验报告"） */
  memo: string = '';
  /** 单次课备忘：key = "yyyy-MM-dd"（该次课的实际日期），value = 备忘内容 */
  dayMemos: Record<string, string> = {};
  /** 课程性质：必修 / 限选 / 任选（正方字段 kcxz） */
  nature: string = '';
  /** 学分（正方字段 xf） */
  credit: string = '';
}

/** 整张课表 */
export class CourseTable {
  xnm: string = '';
  xqm: string = '';
  /** 学期第 1 周的周一 00:00（毫秒时间戳），用于算"当前第几周" */
  termStart: number = 0;
  /** 抓取时间 */
  fetchedAt: number = 0;
  /** 教务系统返回的当前周次（有则用于反推 termStart） */
  currentWeek: number = 0;
  /** 开学日是否为用户手动设置（false 时允许用随包内置值覆盖） */
  termStartUserSet: boolean = false;
  items: CourseItem[] = [];
}

const MS_PER_DAY: number = 86400000;

function toInt(v: ESObject, def: number): number {
  const n: number = Number(v);
  return isNaN(n) ? def : Math.trunc(n);
}

function toStr(v: ESObject, def: string): string {
  if (v === null || v === undefined) {
    return def;
  }
  const s: string = `${v}`;
  return s.length > 0 ? s : def;
}

/**
 * 解析周次描述。
 * 支持："1-16周" / "1-16周(单)" / "1-16周(双)" / "3,5,7周" / "1-16" / "第1-16周"
 */
export function parseWeeks(text: string): number[] {
  const out: number[] = [];
  if (text.length === 0) {
    return out;
  }
  const isOdd: boolean = text.indexOf('单') >= 0;
  const isEven: boolean = text.indexOf('双') >= 0;
  // 去掉中文与括号，只留数字、逗号和连字符
  const cleaned: string = text.replace(/[^0-9,\-]/g, '');
  const parts: string[] = cleaned.split(',');
  for (let i = 0; i < parts.length; i++) {
    const seg: string = parts[i];
    if (seg.length === 0) {
      continue;
    }
    const dash: number = seg.indexOf('-');
    if (dash > 0) {
      const a: number = toInt(seg.substring(0, dash), -1);
      const b: number = toInt(seg.substring(dash + 1), -1);
      if (a > 0 && b >= a) {
        for (let w = a; w <= b; w++) {
          out.push(w);
        }
      }
    } else {
      const w: number = toInt(seg, -1);
      if (w > 0) {
        out.push(w);
      }
    }
  }
  let filtered: number[] = out;
  if (isOdd) {
    filtered = filtered.filter((w: number) => w % 2 === 1);
  } else if (isEven) {
    filtered = filtered.filter((w: number) => w % 2 === 0);
  }
  // 去重 + 升序
  const seen: number[] = [];
  for (let i = 0; i < filtered.length; i++) {
    if (seen.indexOf(filtered[i]) < 0) {
      seen.push(filtered[i]);
    }
  }
  seen.sort((a: number, b: number) => a - b);
  return seen;
}

/** 从 "1-2" / "3" / "1-2节" 解析出 [起, 止] 节次 */
function parseSections(text: string): number[] {
  const cleaned: string = text.replace(/[^0-9\-]/g, '');
  if (cleaned.length === 0) {
    return [1, 1];
  }
  const dash: number = cleaned.indexOf('-');
  if (dash > 0) {
    const a: number = toInt(cleaned.substring(0, dash), 1);
    const b: number = toInt(cleaned.substring(dash + 1), a);
    return [a, b >= a ? b : a];
  }
  const n: number = toInt(cleaned, 1);
  return [n, n];
}

/**
 * 解析正方课表接口返回的 JSON。
 * 主要取 kbList 数组；字段名做了多种兼容。
 */
export function parseKbJson(raw: string, xnm: string, xqm: string): CourseTable {
  const table: CourseTable = new CourseTable();
  table.xnm = xnm;
  table.xqm = xqm;
  table.fetchedAt = Date.now();

  let root: Record<string, ESObject> | null = null;
  try {
    root = JSON.parse(raw) as Record<string, ESObject>;
  } catch (e) {
    return table;
  }
  if (root === null || root === undefined) {
    return table;
  }

  // 尝试提取当前周次，用于反推学期起始日（各版本字段名不一，宽松匹配）

  const zcA: ESObject = root['dqzc'];

  const zcB: ESObject = root['zc'];

  const zcC: ESObject = root['zcxq'];

  if (zcA !== null && zcA !== undefined) {

    table.currentWeek = toInt(zcA, 0);

  } else if (zcB !== null && zcB !== undefined) {

    table.currentWeek = toInt(zcB, 0);

  } else if (zcC !== null && zcC !== undefined) {

    table.currentWeek = toInt(zcC, 0);

  }


  const list: ESObject = root['kbList'];
  if (list === null || list === undefined) {
    return table;
  }
  const arr: ESObject[] = list as ESObject[];
  if (arr === null || arr === undefined) {
    return table;
  }

  for (let i = 0; i < arr.length; i++) {
    const o: Record<string, ESObject> = arr[i] as Record<string, ESObject>;
    if (o === null || o === undefined) {
      continue;
    }
    const item: CourseItem = new CourseItem();
    item.name = toStr(o['kcmc'], '未知课程');
    // ⚠️ 实测该校正方返回：xm 是「学生姓名」，教师姓名在 jsxm
    item.teacher = toStr(o['jsxm'], '');
    item.room = toStr(o['cdmc'], '');
    item.dayOfWeek = toInt(o['xqj'], 1);
    const jc: string = toStr(o['jcs'], toStr(o['jc'], '1-1'));
    const sec: number[] = parseSections(jc);
    item.startSection = sec[0];
    item.endSection = sec[1];
    // ⚠️ zcmc 实测值是「无」，不能当兜底，否则会把正确周次覆盖掉
    item.weeksText = toStr(o['zcd'], '');
    item.weekList = parseWeeks(item.weeksText);
    item.nature = toStr(o['kcxz'], '');
    item.credit = toStr(o['xf'], '');
    item.id = `${item.name}|${item.dayOfWeek}|${item.startSection}|${item.weeksText}`;
    table.items.push(item);
  }
  return table;
}

/**
 * 每节课的开始时间（单位：分钟，从 0:00 起算）
 * 依据学校实际作息时间表（1–12 节）：
 *   1  08:00-08:45     2  08:50-09:35     3  09:50-10:35    4  10:40-11:25
 *   5  11:30-12:15     6  13:45-14:30     7  14:35-15:20    8  15:35-16:20
 *   9  16:25-17:10    10  18:30-19:15    11  19:25-20:10   12  20:20-21:05
 */
export function sectionStartTime(section: number): number {
  const table: number[] = [480, 530, 590, 640, 690, 825, 875, 935, 985, 1110, 1165, 1220];
  const idx: number = section - 1;
  if (idx < 0 || idx >= table.length) {
    return 480;
  }
  return table[idx];
}

/** 每节课的结束时间（分钟） */
export function sectionEndTime(section: number): number {
  const table: number[] = [525, 575, 635, 685, 735, 870, 920, 980, 1030, 1155, 1210, 1265];
  const idx: number = section - 1;
  if (idx < 0 || idx >= table.length) {
    return 525;
  }
  return table[idx];
}

/** 今天 00:00 的时间戳 */
export function startOfToday(now: number): number {
  const d: Date = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 学期第几周（第 1 周为 1）；未设 termStart 时返回 1 */
export function weekOfTerm(table: CourseTable, now: number): number {
  if (table.termStart <= 0) {
    return 1;
  }
  const diff: number = startOfToday(now) - startOfToday(table.termStart);
  return Math.floor(diff / MS_PER_DAY / 7) + 1;
}

// ==================== 下一节课 ====================

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** "下一节课"信息：卡片和课表页共用 */
export class NextClass {
  hasClass: boolean = false;
  /** 已经开始但还没下课 */
  ongoing: boolean = false;
  name: string = '';
  room: string = '';
  teacher: string = '';
  startAt: number = 0;
  endAt: number = 0;
  /** 距上课还有几分钟（进行中为 0） */
  minutesLeft: number = 0;
  /** "第 3-4 节" */
  sectionText: string = '';
  /** "今天 14:00" / "明天 08:00" */
  whenText: string = '';
  /** "还有 25 分钟" / "正在进行" */
  countdownText: string = '';
  roomText: string = '';
}

/** 单小节按 45 分钟估算 */
const SLOT_MINUTES: number = 45;

/**
 * 计算"下一节课"：在所有课程格里，找结束时间晚于 now 且开始最早的那一节。
 * 已经开始但未结束 → ongoing。
 */
export function calcNextClass(table: CourseTable, now: number): NextClass {
  const out: NextClass = new NextClass();
  if (table.items === null || table.items === undefined || table.items.length === 0) {
    return out;
  }
  if (table.termStart <= 0) {
    return out;
  }
  const base: number = startOfToday(table.termStart);
  let bestItem: CourseItem = new CourseItem();
  let bestStart: number = 0;
  let bestEnd: number = 0;
  let hasBest: boolean = false;

  for (let i = 0; i < table.items.length; i++) {
    const it: CourseItem = table.items[i];
    const weeks: number[] = it.weekList;
    if (weeks === null || weeks === undefined || weeks.length === 0) {
      continue;
    }
    for (let w = 0; w < weeks.length; w++) {
      const dayOffset: number = (weeks[w] - 1) * 7 + (it.dayOfWeek - 1);
      const dayStart: number = base + dayOffset * MS_PER_DAY;
      const startMs: number = dayStart + sectionStartTime(it.startSection) * 60000;
      const endMs: number = dayStart + sectionEndTime(it.endSection) * 60000;
      if (endMs <= now) {
        continue;
      }
      if (!hasBest || startMs < bestStart) {
        bestItem = it;
        bestStart = startMs;
        bestEnd = endMs;
        hasBest = true;
      }
    }
  }

  if (!hasBest) {
    return out;
  }
  out.hasClass = true;
  out.name = bestItem.name;
  out.room = bestItem.room;
  out.teacher = bestItem.teacher;
  out.startAt = bestStart;
  out.endAt = bestEnd;
  out.ongoing = bestStart <= now;
  out.minutesLeft = out.ongoing ? 0 : Math.ceil((bestStart - now) / 60000);
  out.sectionText = bestItem.startSection === bestItem.endSection
    ? `第 ${bestItem.startSection} 节`
    : `第 ${bestItem.startSection}-${bestItem.endSection} 节`;
  out.roomText = bestItem.room.length > 0 ? bestItem.room : '待定';

  const sd: Date = new Date(bestStart);
  const dayDiff: number = Math.round((startOfToday(bestStart) - startOfToday(now)) / MS_PER_DAY);
  const hm: string = `${pad2(sd.getHours())}:${pad2(sd.getMinutes())}`;
  if (dayDiff === 0) {
    out.whenText = `今天 ${hm}`;
  } else if (dayDiff === 1) {
    out.whenText = `明天 ${hm}`;
  } else if (dayDiff === 2) {
    out.whenText = `后天 ${hm}`;
  } else {
    out.whenText = `${sd.getMonth() + 1}/${sd.getDate()} ${hm}`;
  }

  if (out.ongoing) {
    out.countdownText = '正在进行';
  } else if (out.minutesLeft < 60) {
    out.countdownText = `还有 ${out.minutesLeft} 分钟`;
  } else if (out.minutesLeft < 60 * 24) {
    out.countdownText = `还有 ${Math.floor(out.minutesLeft / 60)} 小时`;
  } else {
    out.countdownText = `还有 ${dayDiff} 天`;
  }
  return out;
}

/** 今天的课（按节次排序） */
export function todayClasses(table: CourseTable, now: number): CourseItem[] {
  const out: CourseItem[] = [];
  if (table.items === null || table.items === undefined || table.termStart <= 0) {
    return out;
  }
  const week: number = weekOfTerm(table, now);
  const dow: number = ((new Date(now).getDay() + 6) % 7) + 1; // 周一 = 1
  for (let i = 0; i < table.items.length; i++) {
    const it: CourseItem = table.items[i];
    if (it.dayOfWeek !== dow) {
      continue;
    }
    const weeks: number[] = it.weekList;
    if (weeks !== null && weeks !== undefined && weeks.indexOf(week) >= 0) {
      out.push(it);
    }
  }
  out.sort((a: CourseItem, b: CourseItem) => a.startSection - b.startSection);
  return out;
}

/** 毫秒时间戳 → "yyyy-MM-dd"，用作 dayMemos 的 key */
export function toDateKey(ms: number): string {
  const d: Date = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** 某周周一的 00:00（用于反推学期起始日） */
export function startOfWeek(ms: number): number {
  const d: Date = new Date(ms);
  const dow: number = (d.getDay() + 6) % 7;
  return startOfToday(ms) - dow * MS_PER_DAY;
}
