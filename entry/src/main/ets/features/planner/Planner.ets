/** 日程手账的纯逻辑。day 为本地年月日对应的 UTC 日序，避免夏令时天长差异。 */
export class TodoDraft {
  title: string = '';
  note: string = '';
  stars: number = 3;
  repeat: string = 'once';
  startDay: number = 0;
  weekdays: number[] = [];
  interval: number = 2;
}

export class Todo extends TodoDraft {
  id: string = '';
  nextDay: number = 0;
  checkedThrough: number = 0;
  revision: number = 1;
  finished: boolean = false;
}

export class TodoHistory {
  id: string = '';
  todoId: string = '';
  title: string = '';
  stars: number = 3;
  rule: string = '';
  dueDay: number = 0;
  recordedDay: number = 0;
  status: string = '';
  overdueDays: number = 0;
}

export class DiaryEntry {
  day: number = 0;
  body: string = '';
  updatedAt: number = 0;
}

export class PlannerData {
  version: number = 1;
  todos: Todo[] = [];
  history: TodoHistory[] = [];
  diaries: DiaryEntry[] = [];
}

export function dayOf(date: Date): number {
  return Math.floor(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86400000);
}

export function dateOfDay(day: number): Date {
  const utc: Date = new Date(day * 86400000);
  return new Date(utc.getUTCFullYear(), utc.getUTCMonth(), utc.getUTCDate());
}

export function dayLabel(day: number): string {
  const d: Date = dateOfDay(day);
  return `${d.getFullYear()}-${`${d.getMonth() + 1}`.padStart(2, '0')}-${`${d.getDate()}`.padStart(2, '0')}`;
}

export function parseDay(text: string): number {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) {
    return -1;
  }
  const pieces: string[] = text.split('-');
  const value: number = dayOf(new Date(Number(pieces[0]), Number(pieces[1]) - 1, Number(pieces[2])));
  return dayLabel(value) === text ? value : -1;
}

export function starsText(stars: number): string {
  return '★★★★★'.slice(0, stars) + '☆☆☆☆☆'.slice(0, 5 - stars);
}

export function ruleLabel(todo: TodoDraft): string {
  if (todo.repeat === 'daily') {
    return '每天';
  }
  if (todo.repeat === 'weekly') {
    const names: string[] = ['一', '二', '三', '四', '五', '六', '日'];
    return `每周${todo.weekdays.map((d: number): string => names[d - 1]).join('、')}`;
  }
  if (todo.repeat === 'interval') {
    return `每 ${todo.interval} 天 · 从 ${dayLabel(todo.startDay)} 起`;
  }
  return `${dayLabel(todo.startDay)} · 单次`;
}

export function draftError(draft: TodoDraft): string {
  if (typeof draft.title !== 'string' || draft.title.trim().length === 0 || draft.title.length > 80) {
    return '请输入 1～80 字的待办名称';
  }
  if (typeof draft.note !== 'string' || draft.note.length > 2000) {
    return '说明最多 2000 字';
  }
  if (!Number.isInteger(draft.stars) || draft.stars < 1 || draft.stars > 5) {
    return '重要程度请选择 1～5 星';
  }
  if (!Number.isInteger(draft.startDay) || draft.startDay < parseDay('2020-01-01') ||
    draft.startDay > parseDay('2100-12-31')) {
    return '日期范围为 2020-01-01 至 2100-12-31';
  }
  if (['once', 'daily', 'weekly', 'interval'].indexOf(draft.repeat) < 0) {
    return '请选择执行方式';
  }
  if (!Array.isArray(draft.weekdays) || draft.weekdays.some((d: number): boolean => !Number.isInteger(d) || d < 1 || d > 7)) {
    return '星期选择无效';
  }
  if (draft.repeat === 'weekly' && draft.weekdays.length === 0) {
    return '请至少选择一个星期';
  }
  if (!Number.isInteger(draft.interval) || draft.interval < 1 || draft.interval > 365) {
    return '间隔请输入 1～365 天';
  }
  return '';
}

/** 取规则中不早于 from 的执行日。单次已过返回 -1。 */
export function nextOccurrence(todo: TodoDraft, from: number): number {
  const first: number = Math.max(todo.startDay, from);
  if (todo.repeat === 'once') {
    return from <= todo.startDay ? todo.startDay : -1;
  }
  if (todo.repeat === 'daily') {
    return first;
  }
  if (todo.repeat === 'interval') {
    return todo.startDay + Math.ceil((first - todo.startDay) / todo.interval) * todo.interval;
  }
  for (let offset: number = 0; offset < 7; offset++) {
    const candidate: number = first + offset;
    const weekday: number = ((candidate + 3) % 7 + 7) % 7 + 1;
    if (todo.weekdays.indexOf(weekday) >= 0) {
      return candidate;
    }
  }
  return -1;
}

function copyDraft(target: Todo, draft: TodoDraft): void {
  target.title = draft.title.trim();
  target.note = draft.note;
  target.stars = draft.stars;
  target.repeat = draft.repeat;
  target.startDay = draft.startDay;
  target.weekdays = draft.weekdays.slice().sort((a: number, b: number): number => a - b);
  target.interval = draft.interval;
}

export function createTodo(draft: TodoDraft, id: string): Todo {
  const error: string = draftError(draft);
  if (error.length > 0) {
    throw new Error(error);
  }
  const todo: Todo = new Todo();
  copyDraft(todo, draft);
  todo.id = id;
  todo.nextDay = nextOccurrence(todo, todo.startDay);
  todo.checkedThrough = todo.nextDay - 1;
  return todo;
}

function historyRecord(todo: Todo, due: number, day: number, status: string): TodoHistory {
  const record: TodoHistory = new TodoHistory();
  record.id = `${todo.id}:${todo.revision}:${status}:${due}:${day}`;
  record.todoId = todo.id;
  record.title = todo.title;
  record.stars = todo.stars;
  record.rule = ruleLabel(todo);
  record.dueDay = due;
  record.recordedDay = day;
  record.status = status;
  record.overdueDays = Math.max(0, day - due);
  return record;
}

/** 惰性补记应做但当日未完成的日期，重复调用不会重复记录。 */
export function reconcile(data: PlannerData, today: number): boolean {
  let changed: boolean = false;
  for (let index: number = 0; index < data.todos.length; index++) {
    const todo: Todo = data.todos[index];
    if (todo.finished || todo.nextDay > today || todo.checkedThrough >= today - 1) {
      continue;
    }
    let due: number = nextOccurrence(todo, Math.max(todo.nextDay, todo.checkedThrough + 1));
    while (due >= 0 && due < today) {
      data.history.push(historyRecord(todo, due, due, 'missed'));
      due = nextOccurrence(todo, due + 1);
    }
    todo.checkedThrough = today - 1;
    changed = true;
  }
  return changed;
}

export function completeTodo(data: PlannerData, id: string, today: number): boolean {
  reconcile(data, today);
  const todo: Todo | undefined = data.todos.find((item: Todo): boolean => item.id === id);
  if (todo === undefined || todo.finished || todo.nextDay > today) {
    return false;
  }
  data.history.push(historyRecord(todo, todo.nextDay, today, 'completed'));
  const next: number = nextOccurrence(todo, today + 1);
  todo.finished = next < 0;
  if (next >= 0) {
    todo.nextDay = next;
  }
  todo.checkedThrough = today;
  return true;
}

export function editTodo(data: PlannerData, id: string, draft: TodoDraft, today: number): void {
  const error: string = draftError(draft);
  if (error.length > 0) {
    throw new Error(error);
  }
  reconcile(data, today);
  const todo: Todo | undefined = data.todos.find((item: Todo): boolean => item.id === id);
  if (todo === undefined) {
    throw new Error('待办已不存在');
  }
  const changed: boolean = todo.repeat !== draft.repeat || todo.startDay !== draft.startDay ||
    (draft.repeat === 'weekly' && todo.weekdays.join(',') !== draft.weekdays.slice().sort((a: number, b: number): number => a - b).join(',')) ||
    (draft.repeat === 'interval' && todo.interval !== draft.interval);
  copyDraft(todo, draft);
  if (changed) {
    // 单次选过去日期依然保留为逾期；重复规则从今天起生效。
    todo.nextDay = todo.repeat === 'once' ? todo.startDay : nextOccurrence(todo, today);
    todo.finished = false;
    todo.checkedThrough = today - 1;
    todo.revision += 1;
  }
}

export function pendingTodos(data: PlannerData, today: number, future: boolean): Todo[] {
  return data.todos.filter((item: Todo): boolean => !item.finished && (future ? item.nextDay > today : item.nextDay <= today))
    .sort((a: Todo, b: Todo): number => future ? a.nextDay - b.nextDay || b.stars - a.stars : b.stars - a.stars || a.nextDay - b.nextDay);
}

export function saveDiary(data: PlannerData, day: number, body: string, now: number): void {
  const existing: DiaryEntry | undefined = data.diaries.find((entry: DiaryEntry): boolean => entry.day === day);
  if (existing !== undefined) {
    existing.body = body;
    existing.updatedAt = now;
  } else {
    const entry: DiaryEntry = new DiaryEntry();
    entry.day = day;
    entry.body = body;
    entry.updatedAt = now;
    data.diaries.push(entry);
  }
}

export function clonePlanner(data: PlannerData): PlannerData {
  return JSON.parse(JSON.stringify(data)) as PlannerData;
}

/** 不把损坏或新版本的数据误当空数据覆盖。 */
export function decodePlanner(raw: string): PlannerData {
  const data: PlannerData = JSON.parse(raw) as PlannerData;
  if (data === null || data.version !== 1 || !Array.isArray(data.todos) || !Array.isArray(data.history) || !Array.isArray(data.diaries)) {
    throw new Error('手账数据格式无法读取，原数据已保留');
  }
  const ids: string[] = [];
  for (let i: number = 0; i < data.todos.length; i++) {
    const item: Todo = data.todos[i];
    if (item === null || typeof item.id !== 'string' || item.id.length === 0 || ids.indexOf(item.id) >= 0 ||
      draftError(item).length > 0 || !Number.isInteger(item.nextDay) || !Number.isInteger(item.checkedThrough) ||
      !Number.isInteger(item.revision) || item.revision < 1 || typeof item.finished !== 'boolean') {
      throw new Error('待办数据无法读取，原数据已保留');
    }
    ids.push(item.id);
  }
  for (let i: number = 0; i < data.history.length; i++) {
    const h: TodoHistory = data.history[i];
    if (h === null || typeof h.id !== 'string' || typeof h.todoId !== 'string' || typeof h.title !== 'string' ||
      typeof h.rule !== 'string' || !Number.isInteger(h.stars) || h.stars < 1 || h.stars > 5 ||
      !Number.isInteger(h.dueDay) || !Number.isInteger(h.recordedDay) || !Number.isInteger(h.overdueDays) ||
      (h.status !== 'missed' && h.status !== 'completed')) {
      throw new Error('历史记录无法读取，原数据已保留');
    }
  }
  for (let i: number = 0; i < data.diaries.length; i++) {
    const diary: DiaryEntry = data.diaries[i];
    if (diary === null || !Number.isInteger(diary.day) || typeof diary.body !== 'string' || !Number.isFinite(diary.updatedAt)) {
      throw new Error('日记无法读取，原数据已保留');
    }
  }
  return data;
}
