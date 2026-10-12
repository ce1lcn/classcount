/**
 * 背单词的纯逻辑：词表 JSON 解析（带行列号报错）、轮次推进、累计记录、统计。
 * 不依赖 UI 与平台 API，可由 test/wordbook.mjs 在 Node 下直接测试（不要在这里引入 @kit.*）。
 *
 * 规则（见 docs/WORDBOOK-DESIGN.md）：
 *   - 不自动判分，对错由用户逐条标记；
 *   - 答对的词在同一遍内不再出现，答错的词构成下一轮队列，队列为空即本遍完成；
 *   - 词表以 name 为唯一标识，同名导入视为更新（累计记录以 `词表名|英文单词` 为键，不受影响）。
 */

export const MARK_NONE: number = 0;
export const MARK_RIGHT: number = 1;
export const MARK_WRONG: number = 2;

export const PHASE_WRITE: string = 'write';
export const PHASE_CHECK: string = 'check';
export const PHASE_RESULT: string = 'result';

const MAX_TOTAL_WORDS: number = 20000;

// ------------------------------------------------------------------ 数据模型

export class WordItem {
  en: string = '';
  ph: string = '';
  cn: string = '';
}

export class WordList {
  name: string = '';
  source: string = '';
  words: WordItem[] = [];
}

export class WordbookLists {
  version: number = 1;
  lists: WordList[] = [];
}

/** 单词的累计记录：key = `词表名|英文单词` */
export class WordRecord {
  key: string = '';
  right: number = 0;
  wrong: number = 0;
  last: number = 0;
  lastOk: boolean = false;
}

/** 词表被完整刷完（某一遍全对）的次数 */
export class PassRecord {
  list: string = '';
  count: number = 0;
  last: number = 0;
}

export class WordbookRecords {
  version: number = 1;
  words: WordRecord[] = [];
  passes: PassRecord[] = [];
}

export class SessionEntry {
  en: string = '';
  answer: string = '';
  mark: number = MARK_NONE;
}

export class RoundSummary {
  round: number = 0;
  total: number = 0;
  right: number = 0;
  wrong: number = 0;
}

/** 未完成的一次刷词。listName 为空串表示「没有会话」。 */
export class WordSession {
  version: number = 1;
  listName: string = '';
  round: number = 1;
  phase: string = PHASE_WRITE;
  entries: SessionEntry[] = [];
  rounds: RoundSummary[] = [];
  total: number = 0;
  startedAt: number = 0;
  finished: boolean = false;
}

export class SessionCounts {
  right: number = 0;
  wrong: number = 0;
  none: number = 0;
}

export class ImportParse {
  lists: WordList[] = [];
  wordCount: number = 0;
  error: string = '';
}

export class MergeResult {
  lists: WordList[] = [];
  added: string[] = [];
  updated: string[] = [];
}

export class ListProgress {
  total: number = 0;
  mastered: number = 0;
  remaining: number = 0;
  passes: number = 0;
  lastAt: number = 0;
}

export class WrongItem {
  listName: string = '';
  en: string = '';
  ph: string = '';
  cn: string = '';
  wrong: number = 0;
  right: number = 0;
  last: number = 0;
  lastOk: boolean = false;
}

// ------------------------------------------------------------------ JSON 解析（带位置）

class JNode {
  kind: string = 'null';
  pos: number = 0;
  str: string = '';
  keys: string[] = [];
  vals: JNode[] = [];

  get(key: string): JNode | null {
    for (let i: number = 0; i < this.keys.length; i++) {
      if (this.keys[i] === key) {
        return this.vals[i];
      }
    }
    return null;
  }
}

/** 常见的手写 JSON 错误给出针对性提示；普通字符返回空串 */
function describeBadChar(ch: string): string {
  if (ch === '“' || ch === '”' || ch === '‘' || ch === '’') {
    return `出现了中文引号 ${ch}，JSON 只接受英文双引号 "`;
  }
  if ('，：；（）【】｛｝［］'.indexOf(ch) >= 0) {
    return `出现了中文标点 ${ch}，请改成英文半角符号`;
  }
  if (ch === '　' || ch === ' ') {
    return '出现了全角或不间断空格，请改成普通空格';
  }
  if (ch === '\'') {
    return 'JSON 不支持单引号，请改用英文双引号 "';
  }
  return '';
}

function locate(text: string, pos: number): string {
  let line: number = 1;
  let lastBreak: number = -1;
  const end: number = Math.min(pos, text.length);
  for (let k: number = 0; k < end; k++) {
    if (text.charCodeAt(k) === 10) {
      line++;
      lastBreak = k;
    }
  }
  return `第 ${line} 行第 ${pos - lastBreak} 列`;
}

class WordbookImporter {
  private text: string = '';
  private i: number = 0;

  constructor(raw: string) {
    this.text = raw.charCodeAt(0) === 0xFEFF ? raw.substring(1) : raw;
  }

  private fail(pos: number, reason: string): Error {
    return new Error(`${locate(this.text, pos)}：${reason}`);
  }

  private unexpected(pos: number, expected: string): Error {
    if (pos >= this.text.length) {
      return this.fail(this.text.length, `内容在此意外结束，这里应为${expected}（括号或引号没有配对？）`);
    }
    const ch: string = this.text.charAt(pos);
    const hint: string = describeBadChar(ch);
    return this.fail(pos, hint.length > 0 ? hint : `这里应为${expected}，实际是「${ch}」`);
  }

  private peek(): string {
    return this.i < this.text.length ? this.text.charAt(this.i) : '';
  }

  private skipSpace(): void {
    while (this.i < this.text.length) {
      const c: number = this.text.charCodeAt(this.i);
      if (c === 32 || c === 9 || c === 10 || c === 13) {
        this.i++;
      } else {
        break;
      }
    }
  }

  private parseValue(depth: number): JNode {
    if (depth > 40) {
      throw this.fail(this.i, '嵌套层数过多');
    }
    this.skipSpace();
    const ch: string = this.peek();
    if (ch === '{') {
      return this.parseObject(depth);
    }
    if (ch === '[') {
      return this.parseArray(depth);
    }
    if (ch === '"') {
      return this.parseString();
    }
    if (ch === '-' || (ch >= '0' && ch <= '9')) {
      return this.parseNumber();
    }
    const rest: string = this.text.substring(this.i, this.i + 5);
    if (rest.startsWith('true')) {
      return this.literal('bool', 4);
    }
    if (rest.startsWith('false')) {
      return this.literal('bool', 5);
    }
    if (rest.startsWith('null')) {
      return this.literal('null', 4);
    }
    throw this.unexpected(this.i, '一个值（对象、数组、字符串、数字）');
  }

  private literal(kind: string, length: number): JNode {
    const node: JNode = new JNode();
    node.kind = kind;
    node.pos = this.i;
    this.i += length;
    return node;
  }

  private parseNumber(): JNode {
    const node: JNode = new JNode();
    node.kind = 'number';
    node.pos = this.i;
    let end: number = this.i;
    while (end < this.text.length && '+-.eE0123456789'.indexOf(this.text.charAt(end)) >= 0) {
      end++;
    }
    const token: string = this.text.substring(this.i, end);
    if (!/^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$/.test(token)) {
      throw this.fail(this.i, `数字格式不正确：${token}`);
    }
    node.str = token;
    this.i = end;
    return node;
  }

  private parseString(): JNode {
    const node: JNode = new JNode();
    node.kind = 'string';
    node.pos = this.i;
    this.i++;
    let out: string = '';
    while (true) {
      if (this.i >= this.text.length) {
        throw this.fail(node.pos, '字符串没有结束引号 "');
      }
      const ch: string = this.text.charAt(this.i);
      const code: number = this.text.charCodeAt(this.i);
      if (ch === '"') {
        this.i++;
        node.str = out;
        return node;
      }
      if (code < 32) {
        throw this.fail(node.pos, '字符串中不能直接换行（是否漏了结束引号 "？）');
      }
      if (ch !== '\\') {
        out += ch;
        this.i++;
        continue;
      }
      const esc: string = this.i + 1 < this.text.length ? this.text.charAt(this.i + 1) : '';
      if (esc === 'u') {
        const hex: string = this.text.substring(this.i + 2, this.i + 6);
        if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
          throw this.fail(this.i, '\\u 后面应跟 4 位十六进制数');
        }
        out += String.fromCharCode(parseInt(hex, 16));
        this.i += 6;
        continue;
      }
      const table: string = '"\\/bfnrt';
      const decoded: string = '"\\/\b\f\n\r\t';
      const at: number = esc.length > 0 ? table.indexOf(esc) : -1;
      if (at < 0) {
        throw this.fail(this.i, `无效的转义 \\${esc}（反斜杠请写成 \\\\）`);
      }
      out += decoded.charAt(at);
      this.i += 2;
    }
  }

  private parseArray(depth: number): JNode {
    const node: JNode = new JNode();
    node.kind = 'array';
    node.pos = this.i;
    this.i++;
    this.skipSpace();
    if (this.peek() === ']') {
      this.i++;
      return node;
    }
    while (true) {
      this.skipSpace();
      if (this.peek() === ']') {
        throw this.fail(this.i, '多余的逗号（] 之前不能有逗号）');
      }
      node.vals.push(this.parseValue(depth + 1));
      this.skipSpace();
      const c: string = this.peek();
      if (c === ',') {
        this.i++;
        continue;
      }
      if (c === ']') {
        this.i++;
        return node;
      }
      throw this.unexpected(this.i, '逗号或 ]（上一项末尾是否漏了逗号？）');
    }
  }

  private parseObject(depth: number): JNode {
    const node: JNode = new JNode();
    node.kind = 'object';
    node.pos = this.i;
    this.i++;
    this.skipSpace();
    if (this.peek() === '}') {
      this.i++;
      return node;
    }
    while (true) {
      this.skipSpace();
      if (this.peek() === '}') {
        throw this.fail(this.i, '多余的逗号（} 之前不能有逗号）');
      }
      if (this.peek() !== '"') {
        throw this.unexpected(this.i, '属性名（用英文双引号括起来）');
      }
      const key: JNode = this.parseString();
      this.skipSpace();
      if (this.peek() !== ':') {
        throw this.unexpected(this.i, '冒号 :');
      }
      this.i++;
      const value: JNode = this.parseValue(depth + 1);
      node.keys.push(key.str);
      node.vals.push(value);
      this.skipSpace();
      const c: string = this.peek();
      if (c === ',') {
        this.i++;
        continue;
      }
      if (c === '}') {
        this.i++;
        return node;
      }
      throw this.unexpected(this.i, '逗号或 }（上一项末尾是否漏了逗号？）');
    }
  }

  // ---------------------------------------------------------------- 语义检查

  private listNodes(root: JNode): JNode[] {
    if (root.kind === 'array') {
      return root.vals;
    }
    if (root.kind === 'object') {
      const lists: JNode | null = root.get('lists');
      if (lists !== null) {
        if (lists.kind !== 'array') {
          throw this.fail(lists.pos, 'lists 应为数组 [ … ]');
        }
        return lists.vals;
      }
      if (root.get('words') !== null) {
        return [root];
      }
    }
    throw this.fail(root.pos,
      '顶层应为 {"lists":[…]}、单个词表 {"name":…,"words":[…]}，或词表数组 [ … ]');
  }

  private readText(node: JNode | null, label: string, at: JNode, required: boolean): string {
    if (node === null || node.kind === 'null') {
      if (required) {
        throw this.fail(at.pos, `缺少必填字段 ${label}`);
      }
      return '';
    }
    if (node.kind !== 'string') {
      throw this.fail(node.pos, `${label} 必须是字符串`);
    }
    const value: string = node.str.trim();
    if (required && value.length === 0) {
      throw this.fail(node.pos, `${label} 不能为空`);
    }
    return value;
  }

  private buildList(node: JNode, index: number, counter: number[]): WordList {
    if (node.kind !== 'object') {
      throw this.fail(node.pos, `第 ${index + 1} 个词表应为对象 { "name": …, "words": […] }`);
    }
    const list: WordList = new WordList();
    list.name = this.readText(node.get('name'), 'name（词表名）', node, true);
    list.source = this.readText(node.get('source'), 'source', node, false);
    const words: JNode | null = node.get('words');
    if (words === null) {
      throw this.fail(node.pos, `词表「${list.name}」缺少 words 数组`);
    }
    if (words.kind !== 'array') {
      throw this.fail(words.pos, `词表「${list.name}」的 words 应为数组 [ … ]`);
    }
    if (words.vals.length === 0) {
      throw this.fail(words.pos, `词表「${list.name}」没有任何单词`);
    }
    const seen: Set<string> = new Set<string>();
    for (let w: number = 0; w < words.vals.length; w++) {
      const item: JNode = words.vals[w];
      if (item.kind !== 'object') {
        throw this.fail(item.pos, `词表「${list.name}」第 ${w + 1} 个词应为对象 { "en": …, "cn": … }`);
      }
      const word: WordItem = new WordItem();
      word.en = this.readText(item.get('en'), `en（第 ${w + 1} 个词的英文）`, item, true);
      word.ph = this.readText(item.get('ph'), 'ph', item, false);
      word.cn = this.readText(item.get('cn'), `cn（「${word.en}」的中文释义）`, item, true);
      if (seen.has(word.en)) {
        throw this.fail(item.pos, `单词「${word.en}」在词表「${list.name}」中重复，同一词表内 en 不能重复`);
      }
      seen.add(word.en);
      list.words.push(word);
      counter[0]++;
      if (counter[0] > MAX_TOTAL_WORDS) {
        throw this.fail(item.pos, `一次最多导入 ${MAX_TOTAL_WORDS} 个词`);
      }
    }
    return list;
  }

  run(): WordList[] {
    if (this.text.trim().length === 0) {
      throw new Error('内容为空，请先粘贴词表 JSON 文本');
    }
    const root: JNode = this.parseValue(0);
    this.skipSpace();
    if (this.i < this.text.length) {
      throw this.fail(this.i, 'JSON 在这之前已经结束，后面还有多余内容（多个词表请放进 lists 数组）');
    }
    const nodes: JNode[] = this.listNodes(root);
    if (nodes.length === 0) {
      throw this.fail(root.pos, '没有找到任何词表');
    }
    const counter: number[] = [0];
    const lists: WordList[] = [];
    const names: Set<string> = new Set<string>();
    for (let n: number = 0; n < nodes.length; n++) {
      const list: WordList = this.buildList(nodes[n], n, counter);
      if (names.has(list.name)) {
        throw this.fail(nodes[n].pos, `词表名「${list.name}」重复，name 必须唯一`);
      }
      names.add(list.name);
      lists.push(list);
    }
    return lists;
  }
}

/** 解析粘贴的词表文本。永不抛异常：失败时 error 为「第 x 行第 y 列：原因」。 */
export function parseWordbookText(raw: string): ImportParse {
  const result: ImportParse = new ImportParse();
  try {
    result.lists = new WordbookImporter(raw).run();
    for (let i: number = 0; i < result.lists.length; i++) {
      result.wordCount += result.lists[i].words.length;
    }
  } catch (err) {
    result.lists = [];
    result.wordCount = 0;
    const message: string = (err as Error).message;
    result.error = message !== undefined && message.length > 0 ? message : '词表解析失败';
  }
  return result;
}

// ------------------------------------------------------------------ 词表合并

function copyList(list: WordList): WordList {
  const out: WordList = new WordList();
  out.name = list.name;
  out.source = list.source;
  for (let i: number = 0; i < list.words.length; i++) {
    const w: WordItem = new WordItem();
    w.en = list.words[i].en;
    w.ph = list.words[i].ph;
    w.cn = list.words[i].cn;
    out.words.push(w);
  }
  return out;
}

/** 同名更新、新名新增；已有词表保持原顺序。累计记录按 key 保留，不在此处改动。 */
export function mergeLists(existing: WordList[], incoming: WordList[]): MergeResult {
  const result: MergeResult = new MergeResult();
  for (let i: number = 0; i < existing.length; i++) {
    result.lists.push(copyList(existing[i]));
  }
  for (let i: number = 0; i < incoming.length; i++) {
    let at: number = -1;
    for (let j: number = 0; j < result.lists.length; j++) {
      if (result.lists[j].name === incoming[i].name) {
        at = j;
        break;
      }
    }
    if (at >= 0) {
      result.lists[at] = copyList(incoming[i]);
      result.updated.push(incoming[i].name);
    } else {
      result.lists.push(copyList(incoming[i]));
      result.added.push(incoming[i].name);
    }
  }
  return result;
}

// ------------------------------------------------------------------ 累计记录

export function recordKey(listName: string, en: string): string {
  return `${listName}|${en}`;
}

export function indexRecords(records: WordbookRecords): Map<string, WordRecord> {
  const map: Map<string, WordRecord> = new Map<string, WordRecord>();
  for (let i: number = 0; i < records.words.length; i++) {
    map.set(records.words[i].key, records.words[i]);
  }
  return map;
}

export function passCountOf(records: WordbookRecords, listName: string): number {
  for (let i: number = 0; i < records.passes.length; i++) {
    if (records.passes[i].list === listName) {
      return records.passes[i].count;
    }
  }
  return 0;
}

function bumpPass(records: WordbookRecords, listName: string, now: number): void {
  for (let i: number = 0; i < records.passes.length; i++) {
    if (records.passes[i].list === listName) {
      records.passes[i].count++;
      records.passes[i].last = now;
      return;
    }
  }
  const p: PassRecord = new PassRecord();
  p.list = listName;
  p.count = 1;
  p.last = now;
  records.passes.push(p);
}

/** 删除词表时一并清掉它的累计记录与遍数 */
export function removeListData(records: WordbookRecords, listName: string): WordbookRecords {
  const out: WordbookRecords = new WordbookRecords();
  const prefix: string = `${listName}|`;
  for (let i: number = 0; i < records.words.length; i++) {
    if (!records.words[i].key.startsWith(prefix)) {
      out.words.push(cloneRecord(records.words[i]));
    }
  }
  for (let i: number = 0; i < records.passes.length; i++) {
    if (records.passes[i].list !== listName) {
      const p: PassRecord = new PassRecord();
      p.list = records.passes[i].list;
      p.count = records.passes[i].count;
      p.last = records.passes[i].last;
      out.passes.push(p);
    }
  }
  return out;
}

function cloneRecord(r: WordRecord): WordRecord {
  const out: WordRecord = new WordRecord();
  out.key = r.key;
  out.right = r.right;
  out.wrong = r.wrong;
  out.last = r.last;
  out.lastOk = r.lastOk;
  return out;
}

export function cloneRecords(records: WordbookRecords): WordbookRecords {
  const out: WordbookRecords = new WordbookRecords();
  for (let i: number = 0; i < records.words.length; i++) {
    out.words.push(cloneRecord(records.words[i]));
  }
  for (let i: number = 0; i < records.passes.length; i++) {
    const p: PassRecord = new PassRecord();
    p.list = records.passes[i].list;
    p.count = records.passes[i].count;
    p.last = records.passes[i].last;
    out.passes.push(p);
  }
  return out;
}

// ------------------------------------------------------------------ 轮次推进

/**
 * 下一轮队列：只含答错的词，保持原相对顺序。
 * 未判定（MARK_NONE）一律按「未过关」处理——没有明确的 ✅ 就不放行。
 */
export function nextQueue(queue: string[], marks: number[]): string[] {
  const out: string[] = [];
  for (let i: number = 0; i < queue.length; i++) {
    if (i >= marks.length || marks[i] !== MARK_RIGHT) {
      out.push(queue[i]);
    }
  }
  return out;
}

export function hasSession(session: WordSession): boolean {
  return session.listName.length > 0;
}

export function cloneSession(session: WordSession): WordSession {
  const out: WordSession = new WordSession();
  out.version = session.version;
  out.listName = session.listName;
  out.round = session.round;
  out.phase = session.phase;
  out.total = session.total;
  out.startedAt = session.startedAt;
  out.finished = session.finished;
  for (let i: number = 0; i < session.entries.length; i++) {
    const e: SessionEntry = new SessionEntry();
    e.en = session.entries[i].en;
    e.answer = session.entries[i].answer;
    e.mark = session.entries[i].mark;
    out.entries.push(e);
  }
  for (let i: number = 0; i < session.rounds.length; i++) {
    const r: RoundSummary = new RoundSummary();
    r.round = session.rounds[i].round;
    r.total = session.rounds[i].total;
    r.right = session.rounds[i].right;
    r.wrong = session.rounds[i].wrong;
    out.rounds.push(r);
  }
  return out;
}

/** 开始一遍：整张词表乱序入队。rand 由调用方注入，便于测试。 */
export function startSession(list: WordList, now: number, rand: () => number): WordSession {
  const session: WordSession = new WordSession();
  session.listName = list.name;
  session.startedAt = now;
  const order: string[] = [];
  for (let i: number = 0; i < list.words.length; i++) {
    order.push(list.words[i].en);
  }
  for (let i: number = order.length - 1; i > 0; i--) {
    const j: number = Math.floor(rand() * (i + 1));
    const tmp: string = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
  for (let i: number = 0; i < order.length; i++) {
    const e: SessionEntry = new SessionEntry();
    e.en = order[i];
    session.entries.push(e);
  }
  session.total = session.entries.length;
  return session;
}

export function sessionCounts(session: WordSession): SessionCounts {
  const c: SessionCounts = new SessionCounts();
  for (let i: number = 0; i < session.entries.length; i++) {
    const m: number = session.entries[i].mark;
    if (m === MARK_RIGHT) {
      c.right++;
    } else if (m === MARK_WRONG) {
      c.wrong++;
    } else {
      c.none++;
    }
  }
  return c;
}

export function filledCount(session: WordSession): number {
  let n: number = 0;
  for (let i: number = 0; i < session.entries.length; i++) {
    if (session.entries[i].answer.trim().length > 0) {
      n++;
    }
  }
  return n;
}

/** 填写 → 对答案 */
export function revealAnswers(session: WordSession): boolean {
  if (session.phase !== PHASE_WRITE || session.entries.length === 0) {
    return false;
  }
  session.phase = PHASE_CHECK;
  return true;
}

/** 对答案 → 回到填写（已打的标记保留，但重新对答案时可以再改） */
export function backToWrite(session: WordSession): boolean {
  if (session.phase !== PHASE_CHECK) {
    return false;
  }
  session.phase = PHASE_WRITE;
  return true;
}

/** 再点一次同样的标记会取消标记 */
export function setMark(session: WordSession, index: number, mark: number): boolean {
  if (session.phase !== PHASE_CHECK || index < 0 || index >= session.entries.length ||
    (mark !== MARK_RIGHT && mark !== MARK_WRONG)) {
    return false;
  }
  const entry: SessionEntry = session.entries[index];
  entry.mark = entry.mark === mark ? MARK_NONE : mark;
  return true;
}

/**
 * 结算本轮：把每条判定计入累计记录，写入本轮小结。
 * 返回空串表示成功；否则是不能结算的原因（会话与记录均未改动）。
 * 全对时同时标记本遍完成并给该词表遍数 +1。
 */
export function settleRound(session: WordSession, records: WordbookRecords, now: number): string {
  if (session.phase !== PHASE_CHECK) {
    return '当前不在对答案阶段';
  }
  const counts: SessionCounts = sessionCounts(session);
  if (counts.none > 0) {
    return `还有 ${counts.none} 条没有判定对错`;
  }
  const map: Map<string, WordRecord> = indexRecords(records);
  for (let i: number = 0; i < session.entries.length; i++) {
    const key: string = recordKey(session.listName, session.entries[i].en);
    let rec: WordRecord | undefined = map.get(key);
    if (rec === undefined) {
      rec = new WordRecord();
      rec.key = key;
      records.words.push(rec);
      map.set(key, rec);
    }
    const ok: boolean = session.entries[i].mark === MARK_RIGHT;
    if (ok) {
      rec.right++;
    } else {
      rec.wrong++;
    }
    rec.lastOk = ok;
    rec.last = now;
  }
  const summary: RoundSummary = new RoundSummary();
  summary.round = session.round;
  summary.total = session.entries.length;
  summary.right = counts.right;
  summary.wrong = counts.wrong;
  session.rounds.push(summary);
  session.phase = PHASE_RESULT;
  if (counts.wrong === 0) {
    session.finished = true;
    bumpPass(records, session.listName, now);
  }
  return '';
}

/** 结算页 → 下一轮：仅答错的词，答案清空 */
export function advanceRound(session: WordSession): boolean {
  if (session.phase !== PHASE_RESULT || session.finished) {
    return false;
  }
  const queue: string[] = [];
  const marks: number[] = [];
  for (let i: number = 0; i < session.entries.length; i++) {
    queue.push(session.entries[i].en);
    marks.push(session.entries[i].mark);
  }
  const next: string[] = nextQueue(queue, marks);
  if (next.length === 0) {
    return false;
  }
  session.entries = [];
  for (let i: number = 0; i < next.length; i++) {
    const e: SessionEntry = new SessionEntry();
    e.en = next[i];
    session.entries.push(e);
  }
  session.round++;
  session.phase = PHASE_WRITE;
  return true;
}

/**
 * 词表被重新导入后，让未完成会话与新词表对齐：词已不在词表里的条目被丢弃。
 * 返回 false 表示会话已无意义（词表不存在，或本轮词全被移除）应当丢弃。
 */
export function reconcileSession(session: WordSession, lists: WordList[]): boolean {
  let list: WordList | null = null;
  for (let i: number = 0; i < lists.length; i++) {
    if (lists[i].name === session.listName) {
      list = lists[i];
      break;
    }
  }
  if (list === null) {
    return false;
  }
  const alive: Set<string> = new Set<string>();
  for (let i: number = 0; i < list.words.length; i++) {
    alive.add(list.words[i].en);
  }
  const kept: SessionEntry[] = [];
  for (let i: number = 0; i < session.entries.length; i++) {
    if (alive.has(session.entries[i].en)) {
      kept.push(session.entries[i]);
    }
  }
  if (kept.length !== session.entries.length) {
    session.entries = kept;
  }
  return session.entries.length > 0;
}

// ------------------------------------------------------------------ 统计

export function findList(lists: WordList[], name: string): WordList | null {
  for (let i: number = 0; i < lists.length; i++) {
    if (lists[i].name === name) {
      return lists[i];
    }
  }
  return null;
}

export function listProgress(list: WordList, records: WordbookRecords): ListProgress {
  const progress: ListProgress = new ListProgress();
  const map: Map<string, WordRecord> = indexRecords(records);
  progress.total = list.words.length;
  for (let i: number = 0; i < list.words.length; i++) {
    const rec: WordRecord | undefined = map.get(recordKey(list.name, list.words[i].en));
    if (rec !== undefined) {
      if (rec.lastOk) {
        progress.mastered++;
      }
      progress.lastAt = Math.max(progress.lastAt, rec.last);
    }
  }
  progress.remaining = progress.total - progress.mastered;
  progress.passes = passCountOf(records, list.name);
  return progress;
}

/** 错词本：累计答错过的词，按错误次数从多到少。listName 为空串表示全部词表。 */
export function wrongBook(lists: WordList[], records: WordbookRecords, listName: string): WrongItem[] {
  const map: Map<string, WordRecord> = indexRecords(records);
  const out: WrongItem[] = [];
  for (let i: number = 0; i < lists.length; i++) {
    if (listName.length > 0 && lists[i].name !== listName) {
      continue;
    }
    for (let j: number = 0; j < lists[i].words.length; j++) {
      const w: WordItem = lists[i].words[j];
      const rec: WordRecord | undefined = map.get(recordKey(lists[i].name, w.en));
      if (rec === undefined || rec.wrong <= 0) {
        continue;
      }
      const item: WrongItem = new WrongItem();
      item.listName = lists[i].name;
      item.en = w.en;
      item.ph = w.ph;
      item.cn = w.cn;
      item.wrong = rec.wrong;
      item.right = rec.right;
      item.last = rec.last;
      item.lastOk = rec.lastOk;
      out.push(item);
    }
  }
  out.sort((a: WrongItem, b: WrongItem): number => {
    if (a.wrong !== b.wrong) {
      return b.wrong - a.wrong;
    }
    if (a.last !== b.last) {
      return b.last - a.last;
    }
    return a.en < b.en ? -1 : (a.en > b.en ? 1 : 0);
  });
  return out;
}

// ------------------------------------------------------------------ 反序列化与校验

function isCount(n: number): boolean {
  return Number.isInteger(n) && n >= 0;
}

export function decodeLists(raw: string): WordbookLists {
  const data: WordbookLists = JSON.parse(raw) as WordbookLists;
  if (data === null || data.version !== 1 || !Array.isArray(data.lists)) {
    throw new Error('词表数据格式无法读取，原数据已保留');
  }
  const names: Set<string> = new Set<string>();
  for (let i: number = 0; i < data.lists.length; i++) {
    const list: WordList = data.lists[i];
    if (list === null || typeof list.name !== 'string' || list.name.length === 0 || names.has(list.name) ||
      typeof list.source !== 'string' || !Array.isArray(list.words)) {
      throw new Error('词表数据无法读取，原数据已保留');
    }
    names.add(list.name);
    for (let j: number = 0; j < list.words.length; j++) {
      const w: WordItem = list.words[j];
      if (w === null || typeof w.en !== 'string' || w.en.length === 0 || typeof w.ph !== 'string' ||
        typeof w.cn !== 'string') {
        throw new Error('单词数据无法读取，原数据已保留');
      }
    }
  }
  return data;
}

export function decodeRecords(raw: string): WordbookRecords {
  const data: WordbookRecords = JSON.parse(raw) as WordbookRecords;
  if (data === null || data.version !== 1 || !Array.isArray(data.words) || !Array.isArray(data.passes)) {
    throw new Error('答题记录格式无法读取，原数据已保留');
  }
  const keys: Set<string> = new Set<string>();
  for (let i: number = 0; i < data.words.length; i++) {
    const r: WordRecord = data.words[i];
    if (r === null || typeof r.key !== 'string' || keys.has(r.key) || !isCount(r.right) || !isCount(r.wrong) ||
      !Number.isFinite(r.last) || typeof r.lastOk !== 'boolean') {
      throw new Error('答题记录无法读取，原数据已保留');
    }
    keys.add(r.key);
  }
  for (let i: number = 0; i < data.passes.length; i++) {
    const p: PassRecord = data.passes[i];
    if (p === null || typeof p.list !== 'string' || !isCount(p.count) || !Number.isFinite(p.last)) {
      throw new Error('遍数记录无法读取，原数据已保留');
    }
  }
  return data;
}

export function decodeSession(raw: string): WordSession {
  const data: WordSession = JSON.parse(raw) as WordSession;
  if (data === null || data.version !== 1 || typeof data.listName !== 'string' || data.listName.length === 0 ||
    !Number.isInteger(data.round) || data.round < 1 ||
    (data.phase !== PHASE_WRITE && data.phase !== PHASE_CHECK && data.phase !== PHASE_RESULT) ||
    !Array.isArray(data.entries) || !Array.isArray(data.rounds) || !isCount(data.total) ||
    !Number.isFinite(data.startedAt) || typeof data.finished !== 'boolean') {
    throw new Error('刷词进度无法读取，原数据已保留');
  }
  for (let i: number = 0; i < data.entries.length; i++) {
    const e: SessionEntry = data.entries[i];
    if (e === null || typeof e.en !== 'string' || typeof e.answer !== 'string' ||
      (e.mark !== MARK_NONE && e.mark !== MARK_RIGHT && e.mark !== MARK_WRONG)) {
      throw new Error('刷词进度无法读取，原数据已保留');
    }
  }
  for (let i: number = 0; i < data.rounds.length; i++) {
    const r: RoundSummary = data.rounds[i];
    if (r === null || !isCount(r.round) || !isCount(r.total) || !isCount(r.right) || !isCount(r.wrong)) {
      throw new Error('刷词进度无法读取，原数据已保留');
    }
  }
  return data;
}
