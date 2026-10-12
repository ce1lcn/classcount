/**
 * 课表时间算法离线验证：直接跑工程里的真实 Course.ets（逐字节复制）。
 * 运行：node test/course.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, 'entry/src/main/ets/model/Course.ets');
const TMP_DIR = path.join(ROOT, 'test/.tmp');
const TMP = path.join(TMP_DIR, 'Course.ts');

fs.mkdirSync(TMP_DIR, { recursive: true });
fs.copyFileSync(SRC, TMP);

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

console.log('[parseWeeks]');
eq('1-16周', m.parseWeeks('1-16周'), [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]);
eq('1-16周(单)', m.parseWeeks('1-16周(单)'), [1,3,5,7,9,11,13,15]);
eq('1-16周(双)', m.parseWeeks('1-16周(双)'), [2,4,6,8,10,12,14,16]);
eq('3,5,7周', m.parseWeeks('3,5,7周'), [3,5,7]);
eq('第1-4周', m.parseWeeks('第1-4周'), [1,2,3,4]);
eq('空串', m.parseWeeks(''), []);

console.log('[parseKbJson]');
const rawJson = JSON.stringify({
  kbList: [
    { kcmc: '高等数学', jsxm: '张三', cdmc: '教3-201', xqj: '1', jcs: '1-2', zcd: '1-16周' },
    { kcmc: '大学英语', jsxm: '李四', cdmc: '教1-105', xqj: '3', jcs: '3-4', zcd: '1-16周(单)' }
  ]
});
const table = m.parseKbJson(rawJson, '2026', '3');
eq('课程数', table.items.length, 2);
eq('第一门课名', table.items[0].name, '高等数学');
eq('第一门教师', table.items[0].teacher, '张三');
eq('第一门教室', table.items[0].room, '教3-201');
eq('第一门星期', table.items[0].dayOfWeek, 1);
eq('第一门起节', table.items[0].startSection, 1);
eq('第一门止节', table.items[0].endSection, 2);
eq('第二门单周', table.items[1].weekList, [1,3,5,7,9,11,13,15]);

// 学期第一周周一 = 2026-09-07
table.termStart = D(2026, 9, 7);

console.log('[weekOfTerm]');
eq('开学当天 = 第1周', m.weekOfTerm(table, D(2026, 9, 7, 10)), 1);
eq('9/14 = 第2周', m.weekOfTerm(table, D(2026, 9, 14, 10)), 2);
eq('9/20(周日) 仍是第2周', m.weekOfTerm(table, D(2026, 9, 20, 23)), 2);
eq('9/21 = 第3周', m.weekOfTerm(table, D(2026, 9, 21, 0)), 3);

console.log('[calcNextClass]');
// 2026-09-07 是周一，高数 1-2 节（08:00 开始）
const t1 = m.calcNextClass(table, D(2026, 9, 7, 7, 30));
eq('周一 7:30 → 找到高数', t1.name, '高等数学');
eq('  → 还有 30 分钟', t1.countdownText, '还有 30 分钟');
eq('  → 今天 08:00', t1.whenText, '今天 08:00');
eq('  → 第 1-2 节', t1.sectionText, '第 1-2 节');
eq('  → 未开始', t1.ongoing, false);

const t2 = m.calcNextClass(table, D(2026, 9, 7, 8, 30));
eq('周一 8:30 → 正在进行', t2.ongoing, true);
eq('  → 文案', t2.countdownText, '正在进行');

// 周一 10:00 高数已下课（1-2节 08:00-09:40），下一节是周三单周英语
const t3 = m.calcNextClass(table, D(2026, 9, 7, 10, 0));
eq('周一 10:00 → 下一节是英语', t3.name, '大学英语');
eq('  → 后天', t3.whenText, '后天 09:50');

// 第2周周一 00:00：高数是 1-16 周（不分单双周），当天 08:00 就有课
const t4 = m.calcNextClass(table, D(2026, 9, 14, 0, 0));
eq('第2周周一 0:00 → 当天高数', t4.name, '高等数学');
eq('  → 今天 08:00', t4.whenText, '今天 08:00');

// 第2周周一 10:00（高数已下课）→ 英语是单周、本周不上 → 跳到第3周周一
const t5 = m.calcNextClass(table, D(2026, 9, 14, 10, 0));
eq('第2周周一 10:00 → 跳过本周英语，指向第3周高数', t5.name, '高等数学');
eq('  → 9/21 08:00', t5.whenText, '9/21 08:00');

// 只留一门单周英语，直接验证单双周跳过
const onlyEn = m.parseKbJson(JSON.stringify({
  kbList: [{ kcmc: '大学英语', jsxm: '李四', cdmc: '教1-105', xqj: '3', jcs: '3-4', zcd: '1-16周(单)' }]
}), '2026', '3');
onlyEn.termStart = D(2026, 9, 7);
const t6 = m.calcNextClass(onlyEn, D(2026, 9, 15, 0, 0));
eq('第2周周二 → 单周英语跳到第3周周三', t6.whenText, '9/23 09:50');

console.log('[todayClasses]');
// 2026-09-07 周一第1周，应有高数
const day1 = m.todayClasses(table, D(2026, 9, 7, 9));
eq('周一课程数', day1.length, 1);
eq('周一第一门', day1[0].name, '高等数学');
// 周三第2周（双周），英语是单周 → 无课
const day2 = m.todayClasses(table, D(2026, 9, 16, 9));
eq('第2周周三无课（英语单周）', day2.length, 0);
// 周三第3周 → 有英语
const day3 = m.todayClasses(table, D(2026, 9, 23, 9));
eq('第3周周三有英语', day3.length, 1);

console.log('[toDateKey]');
eq('日期 key', m.toDateKey(D(2026, 10, 8, 15)), '2026-10-08');

console.log('[空课表容错]');
const empty = new m.CourseTable();
eq('空表 hasClass', m.calcNextClass(empty, Date.now()).hasClass, false);
eq('空表今日课数', m.todayClasses(empty, Date.now()).length, 0);
eq('空表周次', m.weekOfTerm(empty, Date.now()), 1);

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
