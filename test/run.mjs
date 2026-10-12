/**
 * 数据层离线验证：直接跑 draft 里的真实源文件副本（逐字节复制，保证测的是源文件）。
 * 运行：node test/run.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, 'entry/src/main/ets/model/Schedule.ets');
const TMP_DIR = path.join(ROOT, 'test/.tmp');
const TMP = path.join(TMP_DIR, 'Schedule.ts');

fs.mkdirSync(TMP_DIR, { recursive: true });
fs.copyFileSync(SRC, TMP); // 逐字节复制

const m = await import(pathToFileURL(TMP).href);

let pass = 0;
let fail = 0;
function eq(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    pass++;
    console.log(`  ok   ${name} = ${JSON.stringify(actual)}`);
  } else {
    fail++;
    console.log(`  FAIL ${name}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
  }
}

const D = (y, mo, d, h = 0, mi = 0) => new Date(y, mo - 1, d, h, mi, 0, 0).getTime();

console.log('[calcDaysLeft]');
eq('01-01 -> 01-11 (10天)', m.calcDaysLeft(D(2026, 1, 11), D(2026, 1, 1)), 10);
eq('同一天 = 0', m.calcDaysLeft(D(2026, 1, 11, 23), D(2026, 1, 11, 1)), 0);
eq('跨月 01-31 -> 02-01 = 1', m.calcDaysLeft(D(2026, 2, 1), D(2026, 1, 31)), 1);
eq('跨年 12-31 -> 01-01 = 1', m.calcDaysLeft(D(2027, 1, 1), D(2026, 12, 31)), 1);
eq('已过期 = -3', m.calcDaysLeft(D(2026, 1, 8), D(2026, 1, 11)), -3);
eq('时刻不影响天数(20:00 vs 01:00)', m.calcDaysLeft(D(2026, 3, 5, 1), D(2026, 3, 4, 20)), 1);

console.log('[calcWeekPercent]');
// 2026-01-05 是周一
eq('周一 00:00 = 0', m.calcWeekPercent(D(2026, 1, 5)), 0);
eq('周三 12:00 = 36', m.calcWeekPercent(D(2026, 1, 7, 12)), 36);
eq('周日 23:00 = 99', m.calcWeekPercent(D(2026, 1, 11, 23)), 99);
eq('周日 23:59 = 100', m.calcWeekPercent(D(2026, 1, 11, 23, 59)), 100);
eq('周一 12:00 = 7', m.calcWeekPercent(D(2026, 1, 5, 12)), 7);

console.log('[calcProgressPercent]');
eq('起点 = 0', m.calcProgressPercent(D(2026, 1, 1), D(2026, 1, 11), D(2026, 1, 1)), 0);
eq('中点 = 50', m.calcProgressPercent(D(2026, 1, 1), D(2026, 1, 11), D(2026, 1, 6)), 50);
eq('超过终点 = 100（clamp）', m.calcProgressPercent(D(2026, 1, 1), D(2026, 1, 11), D(2026, 2, 1)), 100);
eq('span<=0 = 100', m.calcProgressPercent(D(2026, 1, 11), D(2026, 1, 11), D(2026, 1, 5)), 100);

console.log('[buildSnapshot]');
const none = m.buildSnapshot(null, D(2026, 1, 7, 12));
eq('空态 hasData', none.hasData, false);
eq('空态 title', none.title, '暂无日程');
eq('空态 daysText', none.daysText, '--');

const s = new m.Schedule('id1', '期末考试', D(2026, 1, 21), D(2026, 1, 1), '');
const snap = m.buildSnapshot(s, D(2026, 1, 7, 12));
eq('有数据 hasData', snap.hasData, true);
eq('title', snap.title, '期末考试');
eq('daysLeft', snap.daysLeft, 14);
eq('daysText', snap.daysText, '14');
eq('dateText', snap.dateText, '2026-01-21');
eq('progressPercent (6.5/20 天 = 33%)', snap.progressPercent, 33);

const today = m.buildSnapshot(new m.Schedule('i', 't', D(2026, 1, 7), D(2026, 1, 1), ''), D(2026, 1, 7, 9));
eq('当天到期 daysText', today.daysText, '今天');

const past = m.buildSnapshot(new m.Schedule('i', 't', D(2026, 1, 4), D(2026, 1, 1), ''), D(2026, 1, 7, 9));
eq('过期 daysText', past.daysText, '已过3天');

console.log('[snapshotToFormData]');
const fd = m.snapshotToFormData(snap);
eq('key 集合', Object.keys(fd).sort(), ['dateText', 'daysLeftText', 'daysText', 'hasData', 'progressPercentText', 'title', 'weekPercentText']);
eq('daysText 透传', fd['daysText'], '14');
eq('daysLeftText 透传', fd['daysLeftText'], '14');
eq('weekPercentText 透传', fd['weekPercentText'], '36%');
eq('progressPercentText 透传', fd['progressPercentText'], '33%');
eq('hasData 用 1/0', fd['hasData'], '1');
eq('全部值为 string（卡片序列化约束）', Object.values(fd).every((v) => typeof v === 'string'), true);
eq('weekRatioText', m.weekRatioText(snap), '0.36');

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
