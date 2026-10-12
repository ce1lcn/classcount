// Exercises the actual ArkTS pure-logic source via Node's TypeScript stripping.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dest = path.join(root, 'test/.tmp/Planner.ts');
fs.mkdirSync(path.dirname(dest), { recursive: true });
fs.copyFileSync(path.join(root, 'entry/src/main/ets/features/planner/Planner.ets'), dest);
const p = await import(pathToFileURL(dest));
const day = p.parseDay;
let checks = 0;
function test(name, run) {
  run();
  checks++;
  console.log(`ok ${name}`);
}
function draft(repeat = 'daily', start = '2026-10-01') {
  const d = new p.TodoDraft();
  d.title = '背单词';
  d.startDay = day(start);
  d.repeat = repeat;
  return d;
}
function data(d = draft()) {
  const result = new p.PlannerData();
  result.todos.push(p.createTodo(d, 'one'));
  return result;
}

test('date roundtrip and invalid dates', () => {
  assert.equal(p.dayLabel(day('2028-02-29')), '2028-02-29');
  assert.equal(day('2026-02-29'), -1);
  assert.equal(day('2026-13-01'), -1);
  assert.equal(day('2026-1-1'), -1);
  assert.equal(day('2027-01-01') - day('2026-12-31'), 1);
  assert.equal(p.dayOf(p.dateOfDay(day('2026-10-02'))), day('2026-10-02'));
});
test('local calendar days across DST', () => {
  assert.equal(p.dayOf(new Date(2026, 2, 9)) - p.dayOf(new Date(2026, 2, 8)), 1);
  assert.equal(p.dayOf(new Date(2026, 10, 2)) - p.dayOf(new Date(2026, 10, 1)), 1);
});
test('daily carries only one item and records each missed date', () => {
  const state = data();
  p.reconcile(state, day('2026-10-04'));
  assert.equal(p.pendingTodos(state, day('2026-10-04'), false).length, 1);
  assert.equal(state.todos[0].nextDay, day('2026-10-01'));
  assert.deepEqual(state.history.map(h => h.dueDay), [1, 2, 3].map(n => day(`2026-10-0${n}`)));
  assert.equal(p.reconcile(state, day('2026-10-04')), false);
  assert.equal(state.history.length, 3);
});
test('daily completion resets count, retains misses, next day reappears', () => {
  const state = data();
  assert.equal(p.completeTodo(state, 'one', day('2026-10-04')), true);
  assert.equal(state.history.filter(h => h.status === 'missed').length, 3);
  assert.equal(state.history.at(-1).overdueDays, 3);
  assert.equal(state.todos[0].nextDay, day('2026-10-05'));
  assert.equal(p.pendingTodos(state, day('2026-10-04'), false).length, 0);
  assert.equal(p.pendingTodos(state, day('2026-10-05'), false).length, 1);
  assert.equal(p.completeTodo(state, 'one', day('2026-10-04')), false);
  assert.equal(state.history.length, 4);
});
test('weekly multiple weekdays and non-scheduled days', () => {
  const d = draft('weekly', '2026-09-28');
  d.weekdays = [1, 3, 5];
  const state = data(d);
  p.reconcile(state, day('2026-10-04'));
  assert.deepEqual(state.history.map(h => p.dayLabel(h.dueDay)), ['2026-09-28', '2026-09-30', '2026-10-02']);
  assert.equal(p.pendingTodos(state, day('2026-10-04'), false).length, 1);
  p.completeTodo(state, 'one', day('2026-10-04'));
  assert.equal(p.dayLabel(state.todos[0].nextDay), '2026-10-05');
  assert.equal(state.history.at(-1).overdueDays, 6);
});
test('weekly Sunday wraps correctly', () => {
  const d = draft('weekly', '2026-10-02');
  d.weekdays = [7];
  assert.equal(p.dayLabel(p.nextOccurrence(d, d.startDay)), '2026-10-04');
  assert.equal(p.dayLabel(p.nextOccurrence(d, day('2026-10-05'))), '2026-10-11');
});
test('interval anchored to original start after late completion', () => {
  const d = draft('interval');
  d.interval = 3;
  const state = data(d);
  p.completeTodo(state, 'one', day('2026-10-05'));
  assert.deepEqual(state.history.filter(h => h.status === 'missed').map(h => p.dayLabel(h.dueDay)), ['2026-10-01', '2026-10-04']);
  assert.equal(p.dayLabel(state.todos[0].nextDay), '2026-10-07');
});
test('single occurrence rolls over until done without repeated misses', () => {
  const state = data(draft('once'));
  p.reconcile(state, day('2026-10-10'));
  p.reconcile(state, day('2026-10-12'));
  assert.equal(state.history.length, 1);
  assert.equal(p.pendingTodos(state, day('2026-10-12'), false).length, 1);
  p.completeTodo(state, 'one', day('2026-10-12'));
  assert.equal(state.todos[0].finished, true);
  assert.equal(p.pendingTodos(state, day('2026-10-13'), false).length, 0);
  assert.equal(state.history.at(-1).overdueDays, 11);
});
test('future task cannot be completed', () => {
  const state = data(draft('once', '2026-12-01'));
  assert.equal(p.completeTodo(state, 'one', day('2026-10-02')), false);
  assert.equal(state.history.length, 0);
  assert.equal(p.pendingTodos(state, day('2026-10-02'), true).length, 1);
});
test('stars and text edits preserve outstanding date and historical title', () => {
  const state = data();
  p.reconcile(state, day('2026-10-03'));
  const d = draft();
  d.title = '新的名称';
  d.stars = 5;
  p.editTodo(state, 'one', d, day('2026-10-03'));
  assert.equal(state.todos[0].nextDay, day('2026-10-01'));
  assert.equal(state.todos[0].stars, 5);
  assert.equal(state.history[0].title, '背单词');
  assert.equal(state.history[0].stars, 3);
});
test('rule edits preserve old history and begin new recurrence today', () => {
  const state = data();
  const d = draft('weekly');
  d.weekdays = [1, 5];
  p.editTodo(state, 'one', d, day('2026-10-04'));
  assert.equal(state.history.length, 3);
  assert.equal(p.dayLabel(state.todos[0].nextDay), '2026-10-05');
  p.reconcile(state, day('2026-10-07'));
  assert.equal(state.history.length, 4);
  assert.equal(state.history.at(-1).rule, '每周一、五');
});
test('completion on scheduled day records no missed entry for today', () => {
  const state = data();
  p.completeTodo(state, 'one', day('2026-10-01'));
  p.reconcile(state, day('2026-10-02'));
  assert.equal(state.history.length, 1);
  assert.equal(state.history[0].status, 'completed');
});
test('sorting prioritizes stars then oldest outstanding date', () => {
  const state = data();
  const d = draft('once', '2026-10-02');
  d.stars = 5;
  state.todos.push(p.createTodo(d, 'two'));
  assert.deepEqual(p.pendingTodos(state, day('2026-10-03'), false).map(t => t.id), ['two', 'one']);
  assert.equal(p.starsText(5), '★★★★★');
  assert.equal(p.starsText(1), '★☆☆☆☆');
});
test('delete task retains independent historical snapshots', () => {
  const state = data();
  p.completeTodo(state, 'one', day('2026-10-03'));
  state.todos = [];
  assert.equal(state.history.length, 3);
  assert.equal(p.decodePlanner(JSON.stringify(state)).history[2].title, '背单词');
});
test('diary edits one entry per date and persists Unicode/newlines', () => {
  const state = data();
  p.saveDiary(state, day('2026-10-02'), '今天\n学习了英语 ★', 1);
  p.saveDiary(state, day('2026-10-02'), '修改过的日记\n第二行', 2);
  p.saveDiary(state, day('2026-10-03'), '另一天', 3);
  const restored = p.decodePlanner(JSON.stringify(state));
  assert.equal(restored.diaries.length, 2);
  assert.equal(restored.diaries[0].body, '修改过的日记\n第二行');
  assert.equal(restored.diaries[0].updatedAt, 2);
});
test('clone leaves original untouched until successful write', () => {
  const state = data();
  const copy = p.clonePlanner(state);
  p.completeTodo(copy, 'one', day('2026-10-03'));
  assert.equal(state.history.length, 0);
  assert.equal(state.todos[0].nextDay, day('2026-10-01'));
});
test('invalid input cannot enter recurrence loop', () => {
  const d = draft('interval');
  d.interval = 0;
  assert.throws(() => p.createTodo(d, 'bad'));
  d.interval = 1.5;
  assert.throws(() => p.createTodo(d, 'bad'));
  d.repeat = 'weekly';
  d.interval = 2;
  assert.throws(() => p.createTodo(d, 'bad'));
  d.weekdays = [8];
  assert.throws(() => p.createTodo(d, 'bad'));
});
test('corrupt storage and unsupported schemas fail without resetting data', () => {
  assert.throws(() => p.decodePlanner('{bad'));
  assert.throws(() => p.decodePlanner('null'));
  assert.throws(() => p.decodePlanner('{"version":2,"todos":[],"history":[],"diaries":[]}'));
  const state = data();
  state.todos[0].interval = 0;
  assert.throws(() => p.decodePlanner(JSON.stringify(state)));
  assert.throws(() => p.decodePlanner('{"version":1,"todos":[],"history":[null],"diaries":[]}'));
});
test('reopen storage does not duplicate history', () => {
  let state = data();
  p.reconcile(state, day('2026-10-04'));
  state = p.decodePlanner(JSON.stringify(state));
  p.reconcile(state, day('2026-10-04'));
  assert.equal(state.history.length, 3);
});
test('clock moving back does not duplicate or forget missed dates', () => {
  const state = data();
  p.reconcile(state, day('2026-10-05'));
  p.reconcile(state, day('2026-10-03'));
  p.reconcile(state, day('2026-10-06'));
  assert.equal(state.history.length, 5);
  assert.equal(new Set(state.history.map(h => h.id)).size, 5);
});

console.log(`\n${checks} planner scenarios passed (TZ=${Intl.DateTimeFormat().resolvedOptions().timeZone})`);
