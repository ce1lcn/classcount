/**
 * 卡片数据契约（单一真源）
 *
 * 卡片与提供方是独立进程，数据只能通过 @LocalStorageProp 传递，
 * 且**接收时会被转成 string**，因此这里统一只输出 string。
 *
 * 字段分两组：
 *   日程组（hasData / title / daysText / ...）—— 原有「日程倒计时」
 *   课程组（hasCourse / courseName / ...）—— 新增「下一节课」
 * 卡片 UI 自行决定优先展示哪组（建议：有课先显示课，无课回落到日程）。
 */
import { ScheduleSnapshot } from './Schedule';
import { NextClass } from './Course';

export function buildCardData(snap: ScheduleSnapshot, next: NextClass): Record<string, string> {
  const data: Record<string, string> = {};

  // ---- 日程组 ----
  data['hasData'] = snap.hasData ? '1' : '0';
  data['title'] = snap.title;
  data['daysText'] = snap.daysText;
  data['daysLeftText'] = `${snap.daysLeft}`;
  data['dateText'] = snap.dateText;
  data['weekPercentText'] = `${snap.weekPercent}%`;
  data['progressPercentText'] = `${snap.progressPercent}%`;

  // ---- 课程组 ----
  data['hasCourse'] = next.hasClass ? '1' : '0';
  data['courseName'] = next.name;
  data['courseRoom'] = next.roomText;
  data['courseTeacher'] = next.teacher;
  data['courseWhen'] = next.whenText;
  data['courseCountdown'] = next.countdownText;
  data['courseSection'] = next.sectionText;
  data['courseOngoing'] = next.ongoing ? '1' : '0';

  return data;
}
