// 背单词：纯逻辑（解析 / 合并 / 轮次 / 统计）与存储层（模拟系统 Preferences）的离线测试。
// 直接加载真实的 ArkTS 源码（Node 的 TypeScript 类型擦除），不需要设备。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temp = path.join(root, 'test/.tmp');
const modelDir = path.join(root, 'entry/src/main/ets/model');
fs.mkdirSync(temp, { recursive: true });
fs.copyFileSync(path.join(modelDir, 'Wordbook.ets'), path.join(temp, 'Wordbook.ts'));
fs.writeFileSync(path.join(temp, 'wb-preferences-mock.mjs'), `
export const state = { cache: {}, disk: {}, openFail: false, readFail: false, flushFail: 0, puts: 0 };
export const preferences = {
  async getPreferences(context, name) {
    if (state.openFail) throw Error('open failure');
    if (name !== 'wordbook_store_v1') throw Error('wrong namespace');
    return {
      async get(key, fallback) { if (state.readFail) throw Error('read failure'); return key in state.cache ? state.cache[key] : fallback; },
      async put(key, value) { state.puts++; state.cache[key] = value; },
      async flush() { if (state.flushFail > 0) { state.flushFail--; throw Error('flush failure'); } state.disk = { ...state.cache }; }
    };
  }
};
`);
fs.writeFileSync(path.join(temp, 'WordbookStore.ts'), fs.readFileSync(path.join(modelDir, 'WordbookStore.ets'), 'utf8')
  .replace("import { preferences } from '@kit.ArkData';", "import { preferences } from './wb-preferences-mock.mjs';")
  .replace("import { common } from '@kit.AbilityKit';", '')
  .replace("from './Wordbook';", "from './Wordbook.ts';"));

const w = await import(pathToFileURL(path.join(temp, 'Wordbook.ts')));
const { WordbookStore } = await import(pathToFileURL(path.join(temp, 'WordbookStore.ts')));
const { state } = await import(pathToFileURL(path.join(temp, 'wb-preferences-mock.mjs')));

let count = 0;
async function test(name, run) {
  state.cache = {}; state.disk = {}; state.openFail = false; state.readFail = false; state.flushFail = 0; state.puts = 0;
  await run();
  count++;
  console.log(`ok ${name}`);
}
const sample = (name = 'L1', n = 4) => ({
  name,
  words: Array.from({ length: n }, (_, i) => ({ en: `w${i}`, ph: `[w${i}]`, cn: `释义${i}` }))
});
const parse = (v) => w.parseWordbookText(typeof v === 'string' ? v : JSON.stringify(v));
const listOf = (name = 'L1', n = 4) => parse([sample(name, n)]).lists[0];
const noShuffle = () => 0.999999; // Fisher–Yates 里 j===i：保持原顺序

// ---------------------------------------------------------------- 解析
await test('real wordbook.json parses: 3 lists / 24 words', () => {
  const text = fs.readFileSync(path.join(root, 'wordbook/wordbook.json'), 'utf8');
  const r = w.parseWordbookText(text);
  assert.equal(r.error, '');
  assert.equal(r.lists.length, 3);
  assert.equal(r.wordCount, 24);
  assert.deepEqual(r.lists.map((l) => l.words.length), [8, 8, 8]);
  assert.equal(r.lists[0].name, '示例词表 A · 学术写作');
  assert.equal(r.lists[0].words[0].en, 'hypothesis');
});
await test('three accepted top-level shapes', () => {
  assert.equal(parse({ lists: [sample('A'), sample('B')] }).lists.length, 2);
  assert.equal(parse(sample('Solo')).lists[0].name, 'Solo');
  assert.equal(parse([sample('A'), sample('B'), sample('C')]).lists.length, 3);
});
await test('BOM is tolerated; ph is optional; source is kept', () => {
  const r = parse('﻿' + JSON.stringify({ name: 'B', source: ' 来源 ', words: [{ en: 'a', cn: '甲' }, { en: 'b', ph: '', cn: '乙' }] }));
  assert.equal(r.error, '');
  assert.equal(r.lists[0].source, '来源');
  assert.equal(r.lists[0].words[0].ph, '');
});
await test('syntax errors report line, column and reason', () => {
  const text = '{\n  "lists": [\n    { "name": "A", "words": [\n      { "en": "a" "cn": "甲" }\n    ] }\n  ]\n}';
  const r = parse(text);
  assert.match(r.error, /^第 4 行第 19 列：/);
  assert.match(r.error, /逗号/);
  assert.equal(r.lists.length, 0);
});
await test('trailing comma, curly quotes, single quotes, unterminated string', () => {
  assert.match(parse('{"name":"A","words":[{"en":"a","cn":"甲"},]}').error, /多余的逗号/);
  assert.match(parse('{“name”:"A"}').error, /中文引号/);
  assert.match(parse("{'name':'A'}").error, /单引号/);
  assert.match(parse('{"name":"A').error, /没有结束引号/);
  assert.match(parse('{"name":"A\nB"}').error, /不能直接换行/);
  assert.match(parse('[{"name":"A"}] 多余').error, /多余内容/);
  assert.match(parse('{"name":"A","words":[').error, /意外结束/);
  assert.match(parse('{"a":1,，}').error, /中文标点/);
  assert.match(parse('   ').error, /内容为空/);
});
await test('semantic errors point at the offending line', () => {
  const text = '{\n"lists":[\n{"name":"A","words":[\n{"en":"a","cn":"甲"},\n{"en":"b"}\n]}\n]}';
  const r = parse(text);
  assert.match(r.error, /^第 5 行第 1 列：缺少必填字段 cn/);
  assert.match(parse([{ name: '', words: [{ en: 'a', cn: 'b' }] }]).error, /name.*不能为空/);
  assert.match(parse([{ words: [{ en: 'a', cn: 'b' }] }]).error, /缺少必填字段 name/);
  assert.match(parse([{ name: 'A' }]).error, /缺少 words/);
  assert.match(parse([{ name: 'A', words: [] }]).error, /没有任何单词/);
  assert.match(parse([{ name: 'A', words: [{ en: 'a', cn: 'x' }, { en: 'a', cn: 'y' }] }]).error, /重复/);
  assert.match(parse([sample('A'), sample('A')]).error, /词表名「A」重复/);
  assert.match(parse([{ name: 'A', words: [{ en: 'a', cn: 3 }] }]).error, /cn.*字符串/);
  assert.match(parse({ foo: 1 }).error, /顶层应为/);
  assert.match(parse('42').error, /顶层应为/);
});
await test('escapes and unicode survive parsing', () => {
  const r = parse('[{"name":"A","words":[{"en":"a","cn":"带\\"引号\\"\\n换行\\u4e2d"}]}]');
  assert.equal(r.error, '');
  assert.equal(r.lists[0].words[0].cn, '带"引号"\n换行中');
});

// ---------------------------------------------------------------- 合并
await test('same name updates in place, new name appends', () => {
  const existing = [listOf('A', 2), listOf('B', 2)];
  const incoming = [listOf('B', 5), listOf('C', 1)];
  const m = w.mergeLists(existing, incoming);
  assert.deepEqual(m.lists.map((l) => l.name), ['A', 'B', 'C']);
  assert.equal(m.lists[1].words.length, 5);
  assert.deepEqual(m.updated, ['B']);
  assert.deepEqual(m.added, ['C']);
  assert.equal(existing[1].words.length, 2); // 不改动入参
});

// ---------------------------------------------------------------- 轮次
await test('nextQueue keeps only wrong (and unmarked) words in order', () => {
  assert.deepEqual(w.nextQueue(['a', 'b', 'c', 'd'], [1, 2, 1, 2]), ['b', 'd']);
  assert.deepEqual(w.nextQueue(['a', 'b'], [1, 1]), []);
  assert.deepEqual(w.nextQueue(['a', 'b', 'c'], [1, 0, 2]), ['b', 'c']);
  assert.deepEqual(w.nextQueue(['a', 'b'], [1]), ['b']);
});
await test('startSession queues the whole list; shuffle is injectable', () => {
  const list = listOf('L1', 5);
  const plain = w.startSession(list, 1000, noShuffle);
  assert.deepEqual(plain.entries.map((e) => e.en), ['w0', 'w1', 'w2', 'w3', 'w4']);
  assert.equal(plain.total, 5);
  assert.equal(plain.phase, 'write');
  const rev = w.startSession(list, 1000, () => 0);
  assert.deepEqual([...rev.entries.map((e) => e.en)].sort(), ['w0', 'w1', 'w2', 'w3', 'w4']);
  assert.notDeepEqual(rev.entries.map((e) => e.en), plain.entries.map((e) => e.en));
});
await test('phase guards: cannot mark before reveal, cannot settle with unmarked', () => {
  const s = w.startSession(listOf('L1', 3), 1, noShuffle);
  const rec = new w.WordbookRecords();
  assert.equal(w.setMark(s, 0, 1), false);
  assert.equal(w.revealAnswers(s), true);
  assert.equal(w.revealAnswers(s), false);
  w.setMark(s, 0, 1);
  assert.match(w.settleRound(s, rec, 5), /还有 2 条/);
  assert.equal(s.phase, 'check');
  assert.equal(rec.words.length, 0); // 拒绝结算时不改记录
  assert.equal(w.setMark(s, 0, 1), true); // 再点同一个标记：取消
  assert.equal(s.entries[0].mark, 0);
  assert.equal(w.setMark(s, 0, 9), false);
});
await test('full flow: wrong words loop until all right; right words never return', () => {
  const list = listOf('L1', 6);
  const rec = new w.WordbookRecords();
  const s = w.startSession(list, 100, noShuffle);
  const seen = []; // 每轮出现的词
  // 第 1 轮：w1、w4 答错
  seen.push(s.entries.map((e) => e.en));
  w.revealAnswers(s);
  s.entries.forEach((e, i) => w.setMark(s, i, e.en === 'w1' || e.en === 'w4' ? 2 : 1));
  assert.equal(w.settleRound(s, rec, 200), '');
  assert.equal(s.phase, 'result');
  assert.equal(s.finished, false);
  assert.deepEqual({ ...s.rounds[0] }, { round: 1, total: 6, right: 4, wrong: 2 });
  assert.equal(w.advanceRound(s), true);
  assert.equal(s.round, 2);
  assert.equal(s.phase, 'write');
  seen.push(s.entries.map((e) => e.en));
  assert.deepEqual(seen[1], ['w1', 'w4']);
  assert.ok(s.entries.every((e) => e.answer === '' && e.mark === 0));
  // 第 2 轮：w4 仍错
  w.revealAnswers(s);
  w.setMark(s, 0, 1); w.setMark(s, 1, 2);
  w.settleRound(s, rec, 300);
  assert.equal(w.advanceRound(s), true);
  assert.deepEqual(s.entries.map((e) => e.en), ['w4']);
  // 第 3 轮：全对 → 本遍完成
  w.revealAnswers(s); w.setMark(s, 0, 1);
  assert.equal(w.settleRound(s, rec, 400), '');
  assert.equal(s.finished, true);
  assert.equal(w.advanceRound(s), false);
  assert.equal(w.passCountOf(rec, 'L1'), 1);
  const byKey = w.indexRecords(rec);
  assert.deepEqual([byKey.get('L1|w0').right, byKey.get('L1|w0').wrong], [1, 0]);
  assert.deepEqual([byKey.get('L1|w1').right, byKey.get('L1|w1').wrong], [1, 1]);
  assert.deepEqual([byKey.get('L1|w4').right, byKey.get('L1|w4').wrong], [1, 2]);
  assert.ok([...byKey.values()].every((r) => r.lastOk));
  assert.equal(seen.flat().filter((x) => x === 'w0').length, 1); // 答对的词只出现一次
});
await test('settling twice cannot double count', () => {
  const s = w.startSession(listOf('L1', 2), 1, noShuffle);
  const rec = new w.WordbookRecords();
  w.revealAnswers(s); w.setMark(s, 0, 1); w.setMark(s, 1, 2);
  assert.equal(w.settleRound(s, rec, 2), '');
  assert.match(w.settleRound(s, rec, 3), /不在对答案阶段/);
  assert.equal(rec.words.reduce((n, r) => n + r.right + r.wrong, 0), 2);
});
await test('backToWrite keeps answers, then reveal again', () => {
  const s = w.startSession(listOf('L1', 2), 1, noShuffle);
  s.entries[0].answer = '甲';
  w.revealAnswers(s);
  assert.equal(w.backToWrite(s), true);
  assert.equal(s.entries[0].answer, '甲');
  assert.equal(w.backToWrite(s), false);
  assert.equal(w.filledCount(s), 1);
});
await test('reconcileSession drops words removed from the list', () => {
  const s = w.startSession(listOf('L1', 4), 1, noShuffle);
  const updated = parse([{ name: 'L1', words: [{ en: 'w1', cn: 'a' }, { en: 'w3', cn: 'b' }, { en: 'new', cn: 'c' }] }]).lists;
  assert.equal(w.reconcileSession(s, updated), true);
  assert.deepEqual(s.entries.map((e) => e.en), ['w1', 'w3']);
  assert.equal(w.reconcileSession(s, [listOf('Other')]), false);
  const none = parse([{ name: 'L1', words: [{ en: 'zzz', cn: 'c' }] }]).lists;
  assert.equal(w.reconcileSession(w.startSession(listOf('L1', 2), 1, noShuffle), none), false);
});

// ---------------------------------------------------------------- 统计
await test('progress and wrong book', () => {
  const lists = [listOf('A', 3), listOf('B', 3)];
  const rec = new w.WordbookRecords();
  const run = (list, marks, now) => {
    const s = w.startSession(list, now, noShuffle);
    w.revealAnswers(s);
    marks.forEach((m, i) => w.setMark(s, i, m));
    w.settleRound(s, rec, now);
  };
  run(lists[0], [2, 1, 1], 10); // A: w0 错
  run(lists[0], [2, 1, 2], 20); // A: w0 再错, w2 错
  run(lists[1], [1, 1, 2], 30); // B: w2 错
  const pa = w.listProgress(lists[0], rec);
  assert.deepEqual([pa.total, pa.mastered, pa.remaining, pa.passes, pa.lastAt], [3, 1, 2, 0, 20]);
  const wb = w.wrongBook(lists, rec, '');
  assert.deepEqual(wb.map((x) => `${x.listName}/${x.en}/${x.wrong}`), ['A/w0/2', 'B/w2/1', 'A/w2/1']); // 次数相同时最近作答的在前
});
await test('wrong book tie-break: more recent first; filter by list', () => {
  const lists = [listOf('A', 2), listOf('B', 2)];
  const rec = new w.WordbookRecords();
  for (const [name, t] of [['A', 10], ['B', 30]]) {
    const s = w.startSession(lists.find((l) => l.name === name), t, noShuffle);
    w.revealAnswers(s); w.setMark(s, 0, 2); w.setMark(s, 1, 1); w.settleRound(s, rec, t);
  }
  assert.deepEqual(w.wrongBook(lists, rec, '').map((x) => x.listName), ['B', 'A']);
  assert.deepEqual(w.wrongBook(lists, rec, 'A').map((x) => x.listName), ['A']);
  assert.deepEqual(w.wrongBook(lists, new w.WordbookRecords(), ''), []);
});
await test('re-import keeps records; removeListData wipes only that list', () => {
  const rec = new w.WordbookRecords();
  const s = w.startSession(listOf('A', 2), 1, noShuffle);
  w.revealAnswers(s); w.setMark(s, 0, 1); w.setMark(s, 1, 1); w.settleRound(s, rec, 5);
  const s2 = w.startSession(listOf('B', 2), 1, noShuffle);
  w.revealAnswers(s2); w.setMark(s2, 0, 2); w.setMark(s2, 1, 1); w.settleRound(s2, rec, 6);
  const merged = w.mergeLists([listOf('A', 2)], parse([{ name: 'A', words: [{ en: 'w0', cn: '新释义' }, { en: 'extra', cn: 'x' }] }]).lists);
  const p = w.listProgress(merged.lists[0], rec);
  assert.deepEqual([p.total, p.mastered, p.passes], [2, 1, 1]); // w0 记录保留，extra 未学
  const cleaned = w.removeListData(rec, 'A');
  assert.deepEqual(cleaned.words.map((r) => r.key), ['B|w0', 'B|w1']);
  assert.equal(w.passCountOf(cleaned, 'A'), 0);
  assert.equal(w.passCountOf(cleaned, 'B'), 0);
  assert.equal(rec.words.length, 4); // 原对象未动
});

// ---------------------------------------------------------------- 存储
await test('store: empty storage loads empty without writing', async () => {
  const d = await new WordbookStore({}).load();
  assert.equal(d.lists.length, 0);
  assert.equal(w.hasSession(d.session), false);
  assert.equal(state.puts, 0);
});
await test('store: lists, records and an unfinished session survive reopening', async () => {
  const lists = [listOf('A', 3)];
  const rec = new w.WordbookRecords();
  const s = w.startSession(lists[0], 7, noShuffle);
  s.entries[0].answer = '写到一半的答案';
  w.revealAnswers(s); w.setMark(s, 0, 2);
  await new WordbookStore({}).saveAll(lists, rec, s);
  state.cache = { ...state.disk }; // 模拟重启：只剩落盘内容
  const d = await new WordbookStore({}).load();
  assert.equal(d.lists[0].words.length, 3);
  assert.equal(d.session.phase, 'check');
  assert.equal(d.session.entries[0].answer, '写到一半的答案');
  assert.equal(d.session.entries[0].mark, 2);
  assert.equal(d.session.round, 1);
});
await test('store: saving an empty session clears it', async () => {
  const s = w.startSession(listOf('A', 2), 1, noShuffle);
  const store = new WordbookStore({});
  await store.saveSession(s);
  await store.saveSession(new w.WordSession());
  assert.equal(w.hasSession((await new WordbookStore({}).load()).session), false);
});
await test('store: records and session are written together and roll back on flush failure', async () => {
  const store = new WordbookStore({});
  const s = w.startSession(listOf('A', 2), 1, noShuffle);
  await store.saveSession(s);
  const snap = (o) => JSON.stringify(Object.fromEntries(Object.entries(o).filter(([, v]) => v !== ''))); // 空串等同于没有这个键
  const before = snap(state.disk);
  const rec = new w.WordbookRecords();
  rec.words.push(Object.assign(new w.WordRecord(), { key: 'A|w0', right: 1, lastOk: true, last: 3 }));
  state.flushFail = 1;
  await assert.rejects(store.saveRecordsAndSession(rec, new w.WordSession()), /保存失败/);
  assert.equal(snap(state.disk), before);
  assert.equal(snap(state.cache), before); // 缓存也已还原，重试不会读到半成品
  await store.saveRecordsAndSession(rec, new w.WordSession());
  const d = await new WordbookStore({}).load();
  assert.equal(d.records.words.length, 1);
  assert.equal(w.hasSession(d.session), false);
});
await test('store: read failure never writes; corrupt data is surfaced and kept', async () => {
  state.cache = state.disk = { wordbook_lists: 'not json' };
  await assert.rejects(new WordbookStore({}).load());
  assert.equal(state.puts, 0);
  assert.equal(state.disk.wordbook_lists, 'not json');
  state.readFail = true;
  await assert.rejects(new WordbookStore({}).saveAll([], new w.WordbookRecords(), new w.WordSession()), /已取消保存/);
  assert.equal(state.puts, 0);
  state.readFail = false; state.openFail = true;
  await assert.rejects(new WordbookStore({}).load(), /无法打开/);
});
await test('decode rejects malformed persisted data', () => {
  assert.throws(() => w.decodeLists('{"version":2,"lists":[]}'));
  assert.throws(() => w.decodeLists('{"version":1,"lists":[{"name":"A","source":"","words":[{"en":"a","ph":"","cn":1}]}]}'));
  assert.throws(() => w.decodeRecords('{"version":1,"words":[{"key":"A|a","right":-1,"wrong":0,"last":0,"lastOk":true}],"passes":[]}'));
  assert.throws(() => w.decodeSession('{"version":1,"listName":"A","round":1,"phase":"oops","entries":[],"rounds":[],"total":0,"startedAt":0,"finished":false}'));
});

console.log(`\n${count} wordbook checks passed`);
