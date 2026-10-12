/**
 * 日程数据模型 + 卡片快照计算
 *
 * 纯逻辑，不依赖任何卡片 API —— 可离线验证，工程建好后可直接落盘。
 * 路径规划：entry/src/main/ets/model/Schedule.ets
 */

const MS_PER_DAY: number = 86400000;

/** 把时间戳归零到当天 00:00（本地时区），用于"按自然日"计算天数差 */
export function startOfDay(ts: number): number {
  const d: Date = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 一条日程 */
export class Schedule {
  id: string = '';
  title: string = '';
  /** 目标日期，当天 00:00 的时间戳 */
  targetDate: number = 0;
  /** 创建日期，当天 00:00 的时间戳 */
  createdDate: number = 0;
  note: string = '';

  constructor(id: string, title: string, targetDate: number, createdDate: number, note: string) {
    this.id = id;
    this.title = title;
    this.targetDate = targetDate;
    this.createdDate = createdDate;
    this.note = note;
  }
}

/** 卡片/主应用共用的展示快照 —— 字段名即卡片 @LocalStorageProp 的 key */
export class ScheduleSnapshot {
  hasData: boolean = false;
  title: string = '暂无日程';
  /** 剩余天数，可为负（已过期） */
  daysLeft: number = 0;
  /** 剩余天数的展示文案 */
  daysText: string = '--';
  /** 目标日期展示文案 */
  dateText: string = '';
  /** 本周进度 0~100 */
  weekPercent: number = 0;
  /** 整体进度 0~100 */
  progressPercent: number = 0;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function formatDate(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function clampPercent(v: number): number {
  if (v < 0) {
    return 0;
  }
  if (v > 100) {
    return 100;
  }
  return Math.round(v);
}

/** 剩余天数：按自然日差，避免时分秒误差 */
export function calcDaysLeft(targetDate: number, now: number): number {
  return Math.round((startOfDay(targetDate) - startOfDay(now)) / MS_PER_DAY);
}

/**
 * 本周进度（周一为一周开始）：已过去的比例，0~100。
 * 例：周三中午 → (2 + 0.5) / 7 ≈ 35.7%
 */
export function calcWeekPercent(now: number): number {
  const d: Date = new Date(now);
  const dow: number = (d.getDay() + 6) % 7; // 周一 = 0
  const dayFraction: number = (now - startOfDay(now)) / MS_PER_DAY;
  return clampPercent(((dow + dayFraction) / 7) * 100);
}

/** 整体进度：创建 → 目标 之间已过去的比例，0~100 */
export function calcProgressPercent(createdDate: number, targetDate: number, now: number): number {
  const span: number = targetDate - createdDate;
  if (span <= 0) {
    return 100;
  }
  return clampPercent(((now - createdDate) / span) * 100);
}

/** 由一条日程生成展示快照；schedule 为 null 时返回空态 */
export function buildSnapshot(schedule: Schedule | null, now: number): ScheduleSnapshot {
  const snap: ScheduleSnapshot = new ScheduleSnapshot();
  if (schedule === null || schedule === undefined) {
    return snap;
  }
  snap.hasData = true;
  snap.title = schedule.title;
  snap.daysLeft = calcDaysLeft(schedule.targetDate, now);
  snap.dateText = formatDate(schedule.targetDate);
  snap.weekPercent = calcWeekPercent(now);
  snap.progressPercent = calcProgressPercent(schedule.createdDate, schedule.targetDate, now);

  if (snap.daysLeft > 0) {
    snap.daysText = `${snap.daysLeft}`;
  } else if (snap.daysLeft === 0) {
    snap.daysText = '今天';
  } else {
    snap.daysText = `已过${-snap.daysLeft}天`;
  }
  return snap;
}

/**
 * 快照 → 卡片推送数据（formBindingData）。
 *
 * ⚠️ 官方约束（《ArkTS卡片页面刷新概述》）：
 *   "卡片提供方和卡片为相互独立的进程，两者间的数据共享只能通过 LocalStorageProp 传递，
 *    不能使用 getContext 方法。因此卡片提供方推送数据后，卡片UI需要通过 LocalStorageProp
 *    接收数据，且接收数据时，卡片数据会被转换成 string 类型。"
 *
 * 因此这里**只输出 string**：卡片 UI 侧一律用 string 声明 @LocalStorageProp，
 * 由数据层负责格式化，避免 number / boolean 在序列化后类型漂移。
 */
export function snapshotToFormData(snap: ScheduleSnapshot): Record<string, string> {
  const data: Record<string, string> = {};
  data['hasData'] = snap.hasData ? '1' : '0';
  data['title'] = snap.title;
  data['daysText'] = snap.daysText;
  data['dateText'] = snap.dateText;
  data['weekPercentText'] = `${snap.weekPercent}%`;
  data['progressPercentText'] = `${snap.progressPercent}%`;
  data['daysLeftText'] = `${snap.daysLeft}`;
  return data;
}

/** 进度条宽度用的 0~1 数值（卡片内 Text/Row 计算用，仍以 string 输出） */
export function weekRatioText(snap: ScheduleSnapshot): string {
  return `${snap.weekPercent / 100}`;
}
