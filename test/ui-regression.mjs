// Run actual page methods with platform mocks; this does not compile or render ArkUI.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

const root = new URL('../', import.meta.url);
const plannerSource = fs.readFileSync(new URL('entry/src/main/ets/features/planner/Planner.ets', root), 'utf8');
const p = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(plannerSource)).toString('base64')}`);

function harness(file, methods, dependencies) {
  const lines = fs.readFileSync(new URL(file, root), 'utf8').split(/\r?\n/);
  const body = methods.map(name => {
    const start = lines.findIndex(line => new RegExp(`^  private (async )?${name}\\(`).test(line));
    const end = lines.findIndex((line, i) => i > start && line === '  }');
    assert.ok(start >= 0 && end > start, `missing method ${name}`);
    return lines.slice(start, end + 1).join('\n');
  }).join('\n');
  const js = stripTypeScriptTypes(`class Harness {\n${body}\n}`);
  return new Function(...Object.keys(dependencies), `${js}; return new Harness();`)(...Object.values(dependencies));
}

function planner(save) {
  const h = harness('entry/src/main/ets/pages/Planner.ets', ['finish', 'persist'], {
    clonePlanner: p.clonePlanner, completeTodo: p.completeTodo, dayOf: p.dayOf,
    softAnim: () => ({})
  });
  const draft = new p.TodoDraft();
  draft.title = 'example'; draft.startDay = p.dayOf(new Date()); draft.repeat = 'once';
  h.data = new p.PlannerData();
  h.data.todos.push(p.createTodo(draft, 'example'));
  h.busy = false; h.completingId = ''; h.error = '';
  h.plannerStore = { save };
  h.getUIContext = () => ({ animateTo: (_, update) => update() });
  return h;
}

let release;
let writes = 0;
const first = planner(async () => { writes++; await new Promise(resolve => { release = resolve; }); });
const saving = first.finish(first.data.todos[0]);
assert.equal(first.busy, true, 'save lock must be acquired before finish returns');
await first.finish(first.data.todos[0]);
assert.equal(writes, 1, 'repeated click must not save twice');
release(); await saving;
assert.equal(first.data.todos[0].finished, true);
assert.equal(first.data.history.at(-1).status, 'completed');
assert.equal(first.completingId, '');
console.log('ok completion saves immediately and blocks repeated clicks');

const failed = planner(async () => { throw Error('mock write failure'); });
await failed.finish(failed.data.todos[0]);
assert.equal(failed.data.todos.length, 1);
assert.equal(failed.data.todos[0].finished, false);
assert.ok(failed.error.includes('保存失败'));
assert.equal(failed.busy, false);
assert.equal(failed.completingId, '');
console.log('ok failed completion retains data and reports failure');

function reader(bytes, options = {}) {
  let position = 0;
  const stats = { reads: 0, closes: 0 };
  const fileIo = {
    OpenMode: { READ_ONLY: 0 },
    open: async () => ({ fd: 1 }),
    stat: async () => ({ size: options.size ?? bytes.length }),
    read: async (_, buffer) => {
      stats.reads++;
      if (options.fail) throw Error('mock read failure');
      const count = Math.min(buffer.byteLength, bytes.length - position, options.chunk ?? 3);
      new Uint8Array(buffer).set(bytes.subarray(position, position + count));
      position += count;
      return count;
    },
    close: async () => { stats.closes++; }
  };
  const h = harness('entry/src/main/ets/pages/Wordbook.ets', ['readFileText'], {
    fileIo, util: { TextDecoder: { create: () => ({ decodeToString: value => new TextDecoder().decode(value) }) } }
  });
  return { read: () => h.readFileText('mock://example'), stats };
}

const unicode = reader(Buffer.from('\ufeff{"示例":"词表"}'));
assert.equal(await unicode.read(), '{"示例":"词表"}');
assert.ok(unicode.stats.reads > 1); assert.equal(unicode.stats.closes, 1);
console.log('ok partial reads preserve UTF-8 and remove BOM');

const large = reader(Buffer.alloc(0), { size: 4 * 1024 * 1024 + 1 });
await assert.rejects(large.read(), /4 MiB/);
assert.equal(large.stats.reads, 0); assert.equal(large.stats.closes, 1);
console.log('ok oversized file rejected before reading');

const empty = reader(Buffer.alloc(0));
assert.equal(await empty.read(), ''); assert.equal(empty.stats.closes, 1);
console.log('ok empty file closes normally');

const truncated = reader(Buffer.from('abc'), { size: 10 });
await assert.rejects(truncated.read(), /未读取完整/);
assert.equal(truncated.stats.closes, 1);
console.log('ok truncated file reports failure and closes');

const broken = reader(Buffer.from('abc'), { fail: true });
await assert.rejects(broken.read(), /mock read failure/);
assert.equal(broken.stats.closes, 1);
console.log('ok read failure closes the file');
console.log('7 page-method regression scenarios passed (mock platform, not device verification)');
