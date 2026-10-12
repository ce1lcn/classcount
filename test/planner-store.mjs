// Actual PlannerStore source; only the platform imports are replaced by a fault-injecting adapter.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temp = path.join(root, 'test/.tmp');
fs.mkdirSync(temp, { recursive: true });
fs.copyFileSync(path.join(root, 'entry/src/main/ets/features/planner/Planner.ets'), path.join(temp, 'Planner.ts'));
fs.writeFileSync(path.join(temp, 'preferences-mock.mjs'), `
export const state = { cache: '', disk: '', openFail: false, readFail: false, flushFail: 0, puts: 0 };
export const preferences = {
  async getPreferences(context, name) {
    if (state.openFail) throw Error('open failure');
    if (name !== 'planner_store_v1') throw Error('wrong namespace');
    return {
      async get(key, fallback) { if (state.readFail) throw Error('read failure'); return state.cache || fallback; },
      async put(key, value) { state.puts++; state.cache = value; },
      async flush() { if (state.flushFail > 0) { state.flushFail--; throw Error('flush failure'); } state.disk = state.cache; }
    };
  }
};
`);
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/features/planner/PlannerStore.ets'), 'utf8')
  .replace("import { preferences } from '@kit.ArkData';", "import { preferences } from './preferences-mock.mjs';")
  .replace("import { common } from '@kit.AbilityKit';", '')
  .replace("from './Planner';", "from './Planner.ts';");
fs.writeFileSync(path.join(temp, 'PlannerStore.ts'), source);
const { PlannerStore } = await import(pathToFileURL(path.join(temp, 'PlannerStore.ts')));
const { PlannerData, saveDiary } = await import(pathToFileURL(path.join(temp, 'Planner.ts')));
const { state } = await import(pathToFileURL(path.join(temp, 'preferences-mock.mjs')));
let count = 0;
async function test(name, run) {
  state.cache = ''; state.disk = ''; state.openFail = false; state.readFail = false; state.flushFail = 0; state.puts = 0;
  await run(); count++; console.log(`ok ${name}`);
}
await test('empty storage initializes without write', async () => {
  const loaded = await new PlannerStore({}).load();
  assert.deepEqual(loaded, new PlannerData());
  assert.equal(state.puts, 0);
});
await test('save and reopen keep diary data', async () => {
  const data = new PlannerData(); saveDiary(data, 20000, '中文\n记录', 123);
  await new PlannerStore({}).save(data);
  state.cache = state.disk;
  const result = await new PlannerStore({}).load();
  assert.equal(result.diaries[0].body, '中文\n记录');
});
await test('opening failure propagates to caller', async () => {
  state.openFail = true;
  await assert.rejects(new PlannerStore({}).load());
  assert.equal(state.puts, 0);
});
await test('read failure never writes an empty replacement', async () => {
  state.cache = state.disk = 'valuable original bytes'; state.readFail = true;
  await assert.rejects(new PlannerStore({}).save(new PlannerData()));
  assert.equal(state.puts, 0);
  assert.equal(state.disk, 'valuable original bytes');
});
await test('corrupt data is surfaced and left unchanged', async () => {
  state.cache = state.disk = '{broken';
  await assert.rejects(new PlannerStore({}).load());
  assert.equal(state.disk, '{broken');
  assert.equal(state.puts, 0);
});
await test('failed flush restores original cached and persisted data', async () => {
  const old = JSON.stringify(new PlannerData()); state.cache = state.disk = old;
  const data = new PlannerData(); saveDiary(data, 20000, 'unsaved', 123);
  state.flushFail = 1;
  await assert.rejects(new PlannerStore({}).save(data));
  assert.equal(state.cache, old);
  assert.equal(state.disk, old);
});
await test('persistent storage failure remains visible', async () => {
  state.cache = state.disk = JSON.stringify(new PlannerData()); state.flushFail = 2;
  await assert.rejects(new PlannerStore({}).save(new PlannerData()));
});
console.log(`\n${count} persistence scenarios passed (mock platform, not device verification)`);
