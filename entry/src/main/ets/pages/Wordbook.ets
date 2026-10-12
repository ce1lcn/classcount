/**
 * 背单词：看英文写中文 → 整页对答案 → 用户逐条点对错 → 答错的词进入下一轮，直到全对。
 *
 * 页面三个视图：home（词表 + 详情）、session（刷词）、wrong（错词本）。
 * 刷词会话每一步都落盘，退出应用再回来仍停在原处（含已填内容、轮次、队列）。
 *
 * 实现要点（踩坑备忘）：
 *   - 答案输入框打字时只改数据、不触发重渲染（不替换 @State 对象），否则中文输入法的组词会被打断；
 *     落盘用 400ms 防抖，并在页面隐藏/销毁时立即写入。
 *   - ForEach 的 key 必须包含会变的字段（判定行带上 mark），否则 ArkUI 复用旧组件、界面不更新。
 *   - 弹层显示条件都绑 @State；颜色一律 #AARRGGBB。
 */
import { KeyboardAvoidMode as UIKeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { common } from '@kit.AbilityKit';
import { syncWindowColor } from '../common/WindowColor';
import {
  C_BG, C_SURFACE, C_INK, C_SUB, C_MUTE, C_LINE, C_PRIMARY, C_PRIMARY_SOFT, C_ACCENT,
  C_DANGER, C_SCRIM, C_DISABLED, W100, pad2
} from '../common/Theme';
import {
  MARK_RIGHT, MARK_WRONG, PHASE_WRITE, PHASE_CHECK, PHASE_RESULT,
  WordItem, WordList, WordRecord, WordbookRecords, WordSession, SessionEntry, RoundSummary,
  SessionCounts, ListProgress, WrongItem, ImportParse, MergeResult,
  parseWordbookText, mergeLists, startSession, cloneSession, cloneRecords, removeListData,
  setMark, revealAnswers, backToWrite, settleRound, advanceRound, reconcileSession,
  sessionCounts, filledCount, hasSession, findList, listProgress, wrongBook, indexRecords, recordKey
} from '../model/Wordbook';
import { WordbookStore, WordbookData } from '../model/WordbookStore';

const TINT_RIGHT: string = '#1F2F6F5E';
const TINT_WRONG: string = '#1FC8402F';
const SAVE_DELAY: number = 400;

/** 词表预览行：单词 + 它的累计答错次数 */
class PreviewItem {
  word: WordItem = new WordItem();
  wrong: number = 0;
}

function fmtTime(ts: number): string {
  if (ts <= 0) {
    return '—';
  }
  const d: Date = new Date(ts);
  return `${d.getMonth() + 1}月${d.getDate()}日 ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

@Entry
@Component
struct Wordbook {
  @State ready: boolean = false;
  @State error: string = '';
  @State notice: string = '';
  @State view: string = 'home';
  @State lists: WordList[] = [];
  @State records: WordbookRecords = new WordbookRecords();
  @State session: WordSession = new WordSession();
  @State selected: string = '';
  @State wrongFilter: string = '';
  @State filled: number = 0;
  @State busy: boolean = false;
  @State @Watch('refreshWindowColor') showImport: boolean = false;
  @State importError: string = '';
  @State importHasText: boolean = false;
  @State @Watch('refreshWindowColor') confirm: string = '';
  @State confirmTarget: string = '';
  private store: WordbookStore | null = null;
  private importText: string = '';
  private chain: Promise<void> = Promise.resolve();
  private saveTimer: number = -1;
  private dirty: boolean = false;
  private scroller: Scroller = new Scroller();
  private previousKeyboardMode: UIKeyboardAvoidMode = UIKeyboardAvoidMode.OFFSET;

  private refreshWindowColor(): void {
    syncWindowColor(this.getUIContext(), this.showImport || this.confirm.length > 0);
  }

  aboutToAppear(): void {
    this.refreshWindowColor();
    this.previousKeyboardMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new WordbookStore(context);
    this.load();
  }

  onPageShow(): void {
    this.refreshWindowColor();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
  }

  onPageHide(): void {
    this.flushNow();
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
  }

  aboutToDisappear(): void {
    this.flushNow();
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
  }

  onBackPress(): boolean {
    this.goBack();
    return true;
  }

  // ---------------------------------------------------------------- 读写

  /** 所有写盘排成一条队列，避免防抖保存与结算保存交错落盘 */
  private queue(task: () => Promise<void>): Promise<boolean> {
    const run: Promise<boolean> = this.chain.then(async (): Promise<boolean> => {
      try {
        await task();
        return true;
      } catch (err) {
        this.error = (err as Error).message;
        return false;
      }
    });
    this.chain = run.then((): void => {});
    return run;
  }

  private async load(): Promise<void> {
    if (this.store === null || this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    try {
      const data: WordbookData = await this.store.load();
      let session: WordSession = data.session;
      if (hasSession(session) && !reconcileSession(session, data.lists)) {
        session = new WordSession();
        const store: WordbookStore = this.store;
        await store.saveSession(session);
      }
      this.lists = data.lists;
      this.records = data.records;
      this.session = session;
      this.filled = filledCount(session);
      this.selected = hasSession(session) ? session.listName : (data.lists.length > 0 ? data.lists[0].name : '');
      this.ready = true;
    } catch (err) {
      this.error = `${(err as Error).message}。可重试，原数据不会被改动。`;
    } finally {
      this.busy = false;
    }
  }

  private markDirty(): void {
    this.dirty = true;
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => { this.flushNow(); }, SAVE_DELAY);
  }

  private flushNow(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (!this.dirty || this.store === null) {
      return;
    }
    this.dirty = false;
    const store: WordbookStore = this.store;
    // 任务在轮到它时才读取 this.session，保证写入的是最新内容
    this.queue((): Promise<void> => store.saveSession(this.session));
  }

  private async commitSession(next: WordSession): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const store: WordbookStore = this.store;
    this.dirty = false;
    const ok: boolean = await this.queue((): Promise<void> => store.saveSession(next));
    if (ok) {
      this.session = next;
      this.error = '';
    }
    return ok;
  }

  // ---------------------------------------------------------------- 动作

  private goBack(): void {
    if (this.confirm.length > 0) {
      this.confirm = '';
      return;
    }
    if (this.showImport) {
      this.showImport = false;
      return;
    }
    if (this.view !== 'home') {
      this.flushNow();
      this.view = 'home';
      return;
    }
    this.flushNow();
    this.getUIContext().getRouter().back();
  }

  private async startPass(name: string): Promise<void> {
    const list: WordList | null = findList(this.lists, name);
    if (list === null || this.busy) {
      return;
    }
    this.busy = true;
    const next: WordSession = startSession(list, Date.now(), (): number => Math.random());
    if (await this.commitSession(next)) {
      this.filled = 0;
      this.selected = name;
      this.view = 'session';
    }
    this.busy = false;
  }

  private async abandon(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    if (await this.commitSession(new WordSession())) {
      this.filled = 0;
    }
    this.busy = false;
  }

  private async reveal(): Promise<void> {
    const next: WordSession = cloneSession(this.session);
    if (this.busy || !revealAnswers(next)) {
      return;
    }
    this.busy = true;
    await this.commitSession(next);
    this.busy = false;
  }

  private async backToWriting(): Promise<void> {
    const next: WordSession = cloneSession(this.session);
    if (this.busy || !backToWrite(next)) {
      return;
    }
    this.busy = true;
    await this.commitSession(next);
    this.busy = false;
  }

  private mark(index: number, mark: number): void {
    const next: WordSession = cloneSession(this.session);
    if (setMark(next, index, mark)) {
      this.session = next;
      this.markDirty();
    }
  }

  /** 结算：记录与会话在同一次落盘里写入；失败则界面保持原状，可重试 */
  private async settle(): Promise<void> {
    if (this.busy || this.store === null) {
      return;
    }
    const nextSession: WordSession = cloneSession(this.session);
    const nextRecords: WordbookRecords = cloneRecords(this.records);
    const problem: string = settleRound(nextSession, nextRecords, Date.now());
    if (problem.length > 0) {
      this.error = problem;
      return;
    }
    this.busy = true;
    this.dirty = false;
    const store: WordbookStore = this.store;
    const ok: boolean = await this.queue((): Promise<void> => store.saveRecordsAndSession(nextRecords, nextSession));
    if (ok) {
      this.records = nextRecords;
      this.session = nextSession;
      this.error = '';
    }
    this.busy = false;
  }

  private async nextRound(): Promise<void> {
    const next: WordSession = cloneSession(this.session);
    if (this.busy || !advanceRound(next)) {
      return;
    }
    this.busy = true;
    if (await this.commitSession(next)) {
      this.filled = 0;
    }
    this.busy = false;
  }

  private async finishPass(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    if (await this.commitSession(new WordSession())) {
      this.filled = 0;
      this.view = 'home';
    }
    this.busy = false;
  }

  private openImport(): void {
    this.importText = '';
    this.importError = '';
    this.importHasText = false;
    this.showImport = true;
  }

  private async doImport(): Promise<void> {
    if (this.busy || this.store === null) {
      return;
    }
    const parsed: ImportParse = parseWordbookText(this.importText);
    if (parsed.error.length > 0) {
      this.importError = parsed.error;
      return;
    }
    const merged: MergeResult = mergeLists(this.lists, parsed.lists);
    let session: WordSession = cloneSession(this.session);
    if (hasSession(session) && !reconcileSession(session, merged.lists)) {
      session = new WordSession();
    }
    this.busy = true;
    const store: WordbookStore = this.store;
    const records: WordbookRecords = this.records;
    const ok: boolean = await this.queue((): Promise<void> => store.saveAll(merged.lists, records, session));
    if (ok) {
      this.lists = merged.lists;
      this.session = session;
      this.filled = filledCount(session);
      this.selected = parsed.lists[0].name;
      this.showImport = false;
      this.importError = '';
      this.error = '';
      const parts: string[] = [];
      if (merged.added.length > 0) {
        parts.push(`新增 ${merged.added.length} 个词表`);
      }
      if (merged.updated.length > 0) {
        parts.push(`更新 ${merged.updated.length} 个词表（答题记录已保留）`);
      }
      this.notice = `导入完成：${parts.join('，')}，共 ${parsed.wordCount} 词`;
    } else {
      this.importError = this.error;
    }
    this.busy = false;
  }

  private async deleteList(name: string): Promise<void> {
    if (this.busy || this.store === null) {
      return;
    }
    const lists: WordList[] = this.lists.filter((l: WordList): boolean => l.name !== name);
    const records: WordbookRecords = removeListData(this.records, name);
    const session: WordSession = this.session.listName === name ? new WordSession() : cloneSession(this.session);
    this.busy = true;
    const store: WordbookStore = this.store;
    const ok: boolean = await this.queue((): Promise<void> => store.saveAll(lists, records, session));
    if (ok) {
      this.lists = lists;
      this.records = records;
      this.session = session;
      this.filled = filledCount(session);
      if (this.selected === name) {
        this.selected = lists.length > 0 ? lists[0].name : '';
      }
      if (this.wrongFilter === name) {
        this.wrongFilter = '';
      }
      this.notice = `已删除词表「${name}」`;
    }
    this.busy = false;
  }

  private onAnswer(index: number, value: string): void {
    const entry: SessionEntry | undefined = this.session.entries[index];
    if (entry === undefined || entry.answer === value) {
      return;
    }
    const wasBlank: boolean = entry.answer.trim().length === 0;
    const isBlank: boolean = value.trim().length === 0;
    entry.answer = value;
    if (wasBlank !== isBlank) {
      this.filled += isBlank ? -1 : 1;
    }
    this.markDirty();
  }

  private focusNext(index: number): void {
    const next: number = index + 1;
    if (next >= this.session.entries.length) {
      return;
    }
    this.scroller.scrollToIndex(next);
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus(`wb-in-${next}`);
      } catch (err) {
        // 目标输入框尚未创建时忽略，用户可手动点选
      }
    }, 120);
  }

  private confirmAction(): void {
    const kind: string = this.confirm;
    const name: string = this.confirmTarget;
    this.confirm = '';
    if (kind === 'start') {
      this.startPass(name);
    } else if (kind === 'abandon') {
      this.abandon();
    } else if (kind === 'delete') {
      this.deleteList(name);
    }
  }

  // ---------------------------------------------------------------- 展示辅助

  /** 记录与会话的指纹：任何会改变词表卡片/详情显示的数据变化，都会让它变化 */
  private dataSig(): string {
    let sum: number = 0;
    for (let i: number = 0; i < this.records.words.length; i++) {
      sum += this.records.words[i].right * 7 + this.records.words[i].wrong * 13 + (this.records.words[i].lastOk ? 1 : 0);
    }
    let passes: number = 0;
    for (let i: number = 0; i < this.records.passes.length; i++) {
      passes += this.records.passes[i].count;
    }
    const s: WordSession = this.session;
    return `${this.lists.length}|${sum}|${passes}|${s.listName}|${s.round}|${s.phase}|${s.finished}|${s.entries.length}`;
  }

  private selectedArray(): WordList[] {
    const list: WordList | null = this.selectedList();
    return list === null ? [] : [list];
  }

  private selectedList(): WordList | null {
    const found: WordList | null = findList(this.lists, this.selected);
    if (found !== null) {
      return found;
    }
    return this.lists.length > 0 ? this.lists[0] : null;
  }

  private sessionWrong(): number {
    return sessionCounts(this.session).wrong;
  }

  /** 本遍已过关的词数：总数减去仍需重写的词 */
  private passedCount(): number {
    const remaining: number = this.session.phase === PHASE_RESULT ? this.sessionWrong() : this.session.entries.length;
    return Math.max(0, this.session.total - remaining);
  }

  private titleText(): string {
    if (this.view === 'wrong') {
      return '错词本';
    }
    if (this.view === 'session') {
      return this.session.listName;
    }
    return '背单词';
  }

  private confirmTitle(): string {
    if (this.confirm === 'start') {
      return '开始新的一遍？';
    }
    return this.confirm === 'delete' ? '删除这个词表？' : '放弃当前进度？';
  }

  private confirmBody(): string {
    if (this.confirm === 'start') {
      return `将放弃「${this.session.listName}」未完成的刷词进度（第 ${this.session.round} 轮）。已结算的对错记录会保留。`;
    }
    if (this.confirm === 'delete') {
      return `「${this.confirmTarget}」的单词、累计对错记录和已刷遍数都会一起删除，无法恢复。`;
    }
    return `「${this.session.listName}」当前这一遍将作废，需要重新开始。已结算的对错记录会保留。`;
  }

  private startLabel(list: WordList): string {
    if (this.session.listName === list.name) {
      if (this.session.phase === PHASE_RESULT && this.session.finished) {
        return '查看本遍结果';
      }
      return `继续刷词 · 第 ${this.session.round} 轮`;
    }
    return '开始刷词';
  }

  private tapStart(list: WordList): void {
    if (this.session.listName === list.name) {
      this.view = 'session';
    } else if (hasSession(this.session)) {
      this.confirmTarget = list.name;
      this.confirm = 'start';
    } else {
      this.startPass(list.name);
    }
  }

  // ---------------------------------------------------------------- 通用组件

  @Builder
  header() {
    Row({ space: 14 }) {
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([C_INK])
          Text(this.view === 'home' ? '首页' : '词表').fontSize(15).fontColor(C_INK)
        }
      }.id('wb-back').height(42).padding({ left: 14, right: 20 }).backgroundColor(C_SURFACE).borderRadius(24)
        .accessibilityText('返回').onClick(() => { this.goBack(); })
      Text(this.titleText()).fontSize(26).fontWeight(FontWeight.Bold).fontColor(C_INK)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      if (this.view === 'home' && this.ready) {
        Button() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.flag')).fontSize(18).fontColor([C_ACCENT])
            Text('错词本').fontSize(16).fontWeight(FontWeight.Medium).fontColor(C_ACCENT)
          }
        }.id('wb-wrong').height(44).padding({ left: 22, right: 22 }).backgroundColor(C_SURFACE).borderRadius(26)
          .accessibilityText('打开错词本').onClick(() => { this.view = 'wrong'; })
        Button() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([W100])
            Text('导入词表').fontSize(16).fontWeight(FontWeight.Medium).fontColor(W100)
          }
        }.id('wb-import').height(44).padding({ left: 22, right: 24 }).backgroundColor(C_PRIMARY).borderRadius(26)
          .accessibilityText('导入词表').onClick(() => { this.openImport(); })
      }
    }.width('100%').height(50)
  }

  @Builder
  banner() {
    if (this.error.length > 0) {
      Row({ space: 12 }) {
        Text(this.error).fontSize(14).fontColor(C_DANGER).layoutWeight(1)
        if (!this.ready) {
          Button('重试').fontSize(14).height(36).fontColor(W100).backgroundColor(C_DANGER)
            .onClick(() => { this.load(); })
        } else {
          Button('知道了').fontSize(14).height(36).fontColor(C_DANGER).backgroundColor(C_SURFACE)
            .onClick(() => { this.error = ''; })
        }
      }.width('100%').padding({ left: 18, right: 12, top: 10, bottom: 10 }).borderRadius(14)
        .backgroundColor(TINT_WRONG).margin({ top: 12 })
    } else if (this.notice.length > 0) {
      Row({ space: 12 }) {
        Text(this.notice).fontSize(14).fontColor(C_PRIMARY).layoutWeight(1)
        Button('好').fontSize(14).height(36).fontColor(C_PRIMARY).backgroundColor(C_SURFACE)
          .onClick(() => { this.notice = ''; })
      }.width('100%').padding({ left: 18, right: 12, top: 10, bottom: 10 }).borderRadius(14)
        .backgroundColor(C_PRIMARY_SOFT).margin({ top: 12 })
    }
  }

  @Builder
  progressBar(done: number, total: number, color: string) {
    Stack({ alignContent: Alignment.Start }) {
      Row().width('100%').height(8).borderRadius(4).backgroundColor(C_LINE)
      Row().width(total > 0 ? `${Math.round(done * 100 / total)}%` : '0%').height(8).borderRadius(4)
        .backgroundColor(color)
    }.width('100%').height(8)
  }

  @Builder
  statTile(value: string, label: string, color: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(42).fontWeight(FontWeight.Bold).fontColor(color).maxLines(1)
      Text(label).fontSize(15).fontColor(C_SUB)
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  // ---------------------------------------------------------------- home

  @Builder
  emptyHome() {
    Column({ space: 16 }) {
      SymbolGlyph($r('sys.symbol.book_pages')).fontSize(58).fontColor([C_MUTE])
      Text('还没有词表').fontSize(26).fontWeight(FontWeight.Bold).fontColor(C_INK)
      Text('点右上角「导入词表」，把词表 JSON 文本粘贴进来即可。\n一次可导入多个词表，导入后无需重复导入。')
        .fontSize(16).fontColor(C_SUB).textAlign(TextAlign.Center).lineHeight(32)
      Button('导入词表').fontSize(18).height(50).padding({ left: 40, right: 40 }).fontColor(W100)
        .backgroundColor(C_PRIMARY).borderRadius(30).margin({ top: 12 })
        .onClick(() => { this.openImport(); })
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  @Builder
  listCard(list: WordList) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(list.name).fontSize(20).fontWeight(FontWeight.Bold).fontColor(C_INK)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.session.listName === list.name) {
          Text(this.session.finished ? '本遍完成' : `进行中 · 第 ${this.session.round} 轮`)
            .fontSize(13).fontColor(C_ACCENT).backgroundColor('#1FD9622B').borderRadius(12)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        }
      }.width('100%')
      if (list.source.length > 0) {
        Text(list.source).fontSize(13).fontColor(C_SUB).maxLines(1).width('100%')
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      this.progressBar(this.progressOf(list).mastered, list.words.length, C_PRIMARY)
      Row() {
        Text(`已掌握 ${this.progressOf(list).mastered} / ${list.words.length}`).fontSize(14).fontColor(C_SUB)
        Blank()
        Text(`已刷 ${this.progressOf(list).passes} 遍`).fontSize(14).fontColor(C_SUB)
      }.width('100%')
    }.width('100%').padding(20).borderRadius(20).alignItems(HorizontalAlign.Start)
      .backgroundColor(this.selected === list.name ? C_PRIMARY_SOFT : C_SURFACE)
      .accessibilityText(`词表 ${list.name}，共 ${list.words.length} 词`)
      .onClick(() => { this.selected = list.name; })
  }

  private progressOf(list: WordList): ListProgress {
    return listProgress(list, this.records);
  }

  @Builder
  wordRow(word: WordItem, wrongCount: number) {
    Row({ space: 16 }) {
      Column({ space: 2 }) {
        Text(word.en).fontSize(19).fontWeight(FontWeight.Medium).fontColor(C_INK).maxLines(1)
        Text(word.ph).fontSize(14).fontColor(C_MUTE).maxLines(1)
      }.width(160).alignItems(HorizontalAlign.Start)
      Text(word.cn).fontSize(16).fontColor(C_SUB).layoutWeight(1).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (wrongCount > 0) {
        Text(`错 ${wrongCount}`).fontSize(13).fontColor(C_DANGER).backgroundColor(TINT_WRONG).borderRadius(10)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
      }
    }.width('100%').padding({ top: 12, bottom: 12 })
  }

  private previewItems(list: WordList): PreviewItem[] {
    const map: Map<string, WordRecord> = indexRecords(this.records);
    const out: PreviewItem[] = [];
    for (let i: number = 0; i < list.words.length; i++) {
      const item: PreviewItem = new PreviewItem();
      const rec: WordRecord | undefined = map.get(recordKey(list.name, list.words[i].en));
      item.word = list.words[i];
      item.wrong = rec === undefined ? 0 : rec.wrong;
      out.push(item);
    }
    return out;
  }

  @Builder
  detailPane(list: WordList) {
    Column() {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text(list.name).fontSize(30).fontWeight(FontWeight.Bold).fontColor(C_INK)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (list.source.length > 0) {
              Text(list.source).fontSize(14).fontColor(C_SUB).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.trash')).fontSize(21).fontColor([C_SUB]).width(44).height(44)
            .accessibilityText('删除词表')
            .onClick(() => { this.confirmTarget = list.name; this.confirm = 'delete'; })
        }.width('100%').alignItems(VerticalAlign.Top)

        Row({ space: 20 }) {
          this.statTile(`${list.words.length}`, '词数', C_INK)
          this.statTile(`${this.progressOf(list).mastered}`, '已掌握', C_PRIMARY)
          this.statTile(`${this.progressOf(list).remaining}`, '未掌握',
            this.progressOf(list).remaining > 0 ? C_ACCENT : C_MUTE)
          this.statTile(`${this.progressOf(list).passes}`, '已刷遍数', C_INK)
        }.width('100%').margin({ top: 24 })

        Row({ space: 14 }) {
          Button(this.startLabel(list)).id('wb-start').fontSize(19).fontWeight(FontWeight.Medium).height(54)
            .padding({ left: 36, right: 36 }).fontColor(W100).backgroundColor(this.busy ? C_DISABLED : C_PRIMARY)
            .borderRadius(27).enabled(!this.busy).onClick(() => { this.tapStart(list); })
          if (this.session.listName === list.name) {
            Button('放弃本遍').fontSize(16).height(54).padding({ left: 28, right: 28 }).fontColor(C_SUB)
              .backgroundColor(C_SURFACE).borderRadius(27)
              .onClick(() => { this.confirmTarget = list.name; this.confirm = 'abandon'; })
          }
          if (this.session.listName === list.name) {
            Text(`本轮 ${this.session.entries.length} 词 · 已过关 ${this.passedCount()} / ${this.session.total}`)
              .fontSize(14).fontColor(C_SUB).layoutWeight(1).maxLines(2)
          }
        }.width('100%').margin({ top: 24 })

        Text('词表预览').fontSize(16).fontColor(C_SUB).margin({ top: 28 }).width('100%')
        Divider().color(C_LINE).margin({ top: 8 })
        List() {
          ForEach(this.previewItems(list), (item: PreviewItem) => {
            ListItem() {
              this.wordRow(item.word, item.wrong)
            }
          }, (item: PreviewItem): string => `${list.name}|${item.word.en}|${item.wrong}`)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).divider({ strokeWidth: 1, color: C_LINE })
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  homeView() {
    if (this.lists.length === 0) {
      this.emptyHome()
    } else {
      Row({ space: 34 }) {
        Scroll() {
          Column({ space: 14 }) {
            ForEach(this.lists, (list: WordList) => {
              this.listCard(list)
            }, (list: WordList): string =>
              `${list.name}|${this.selected === list.name}|${this.dataSig()}`)
          }.width('100%')
        }.width('36%').height('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
        // 用 ForEach 单元素绑定：@Builder 的按值参数不会随状态刷新，换词表时必须靠 key 重建详情
        Column() {
          ForEach(this.selectedArray(), (list: WordList) => {
            this.detailPane(list)
          }, (list: WordList): string => `${list.name}|${this.dataSig()}|${this.busy}`)
        }.layoutWeight(1).height('100%')
      }.width('100%').layoutWeight(1).alignItems(VerticalAlign.Top).margin({ top: 18 })
    }
  }

  // ---------------------------------------------------------------- wrong

  @Builder
  filterChip(label: string, value: string) {
    Text(label).fontSize(15).fontColor(this.wrongFilter === value ? W100 : C_INK)
      .backgroundColor(this.wrongFilter === value ? C_PRIMARY : C_SURFACE).borderRadius(22)
      .padding({ left: 20, right: 20, top: 9, bottom: 9 }).maxLines(1)
      .onClick(() => { this.wrongFilter = value; })
  }

  @Builder
  wrongRow(item: WrongItem, rank: number) {
    Row({ space: 20 }) {
      Column({ space: 2 }) {
        Text(`${item.wrong}`).fontSize(35).fontWeight(FontWeight.Bold).fontColor(C_DANGER)
        Text('次答错').fontSize(13).fontColor(C_SUB)
      }.width(78)
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          Text(item.en).fontSize(22).fontWeight(FontWeight.Bold).fontColor(C_INK)
          Text(item.ph).fontSize(15).fontColor(C_MUTE)
        }
        Text(item.cn).fontSize(16).fontColor(C_SUB).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Column({ space: 6 }) {
        Text(item.lastOk ? '最近一次答对' : '最近一次答错').fontSize(13)
          .fontColor(item.lastOk ? C_PRIMARY : C_DANGER)
          .backgroundColor(item.lastOk ? TINT_RIGHT : TINT_WRONG).borderRadius(10)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        Text(`答对 ${item.right} 次 · ${fmtTime(item.last)}`).fontSize(13).fontColor(C_SUB)
        Text(item.listName).fontSize(13).fontColor(C_MUTE).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width(210).alignItems(HorizontalAlign.End)
    }.width('100%').padding({ left: 22, right: 22, top: 16, bottom: 16 }).borderRadius(18)
      .backgroundColor(C_SURFACE).alignItems(VerticalAlign.Center)
      .accessibilityText(`第 ${rank} 位，${item.en}，累计答错 ${item.wrong} 次，${item.cn}`)
  }

  @Builder
  wrongView() {
    Column() {
      Scroll() {
        Row({ space: 10 }) {
          this.filterChip('全部词表', '')
          ForEach(this.lists, (list: WordList) => {
            this.filterChip(list.name, list.name)
          }, (list: WordList): string => `${list.name}|${this.wrongFilter === list.name}`)
        }
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').margin({ top: 18 })
      if (this.wrongItems().length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(51).fontColor([C_PRIMARY])
          Text('还没有答错过的词').fontSize(22).fontWeight(FontWeight.Bold).fontColor(C_INK)
          Text('刷词时被你判为答错的词会出现在这里，按累计错误次数排序。').fontSize(15).fontColor(C_SUB)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Text(`共 ${this.wrongItems().length} 个词 · 按累计错误次数排序`).fontSize(14).fontColor(C_SUB)
          .width('100%').margin({ top: 14, bottom: 10 })
        List({ space: 12 }) {
          ForEach(this.wrongItems(), (item: WrongItem, idx: number) => {
            ListItem() {
              this.wrongRow(item, idx + 1)
            }
          }, (item: WrongItem): string => `${item.listName}|${item.en}|${item.wrong}|${item.lastOk}`)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }
    }.width('100%').layoutWeight(1)
  }

  private wrongItems(): WrongItem[] {
    return wrongBook(this.lists, this.records, this.wrongFilter);
  }

  // ---------------------------------------------------------------- session

  private wordOf(en: string): WordItem {
    const list: WordList | null = findList(this.lists, this.session.listName);
    if (list !== null) {
      for (let i: number = 0; i < list.words.length; i++) {
        if (list.words[i].en === en) {
          return list.words[i];
        }
      }
    }
    const missing: WordItem = new WordItem();
    missing.en = en;
    return missing;
  }

  @Builder
  sessionInfo() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Text(`第 ${this.session.round} 轮`).fontSize(16).fontWeight(FontWeight.Medium).fontColor(C_PRIMARY)
          .backgroundColor(C_PRIMARY_SOFT).borderRadius(16).padding({ left: 14, right: 14, top: 5, bottom: 5 })
        Text(this.session.phase === PHASE_WRITE ? '看英文，写出中文释义' :
          (this.session.phase === PHASE_CHECK ? '对照答案，逐条点 ✓ 或 ✕' : '本轮结算'))
          .fontSize(16).fontColor(C_SUB).layoutWeight(1)
        Text(`本遍已过关 ${this.passedCount()} / ${this.session.total}`).fontSize(15).fontColor(C_SUB)
      }.width('100%')
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(8).borderRadius(4).backgroundColor(C_LINE)
        Row().width(this.session.total > 0 ? `${Math.round(this.passedCount() * 100 / this.session.total)}%` : '0%')
          .height(8).borderRadius(4).backgroundColor(C_PRIMARY)
      }.width('100%').height(8)
    }.width('100%').margin({ top: 16, bottom: 14 })
  }

  @Builder
  writeCell(entry: SessionEntry, index: number) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Text(`${index + 1}`).fontSize(14).fontColor(C_MUTE).width(22)
        Text(entry.en).fontSize(26).fontWeight(FontWeight.Bold).fontColor(C_INK).maxLines(1)
        Text(this.wordOf(entry.en).ph).fontSize(16).fontColor(C_MUTE).maxLines(1).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      TextInput({ placeholder: '写出中文释义', text: entry.answer })
        .id(`wb-in-${index}`)
        .height(50).fontSize(18).fontColor(C_INK).backgroundColor(C_BG).borderRadius(14)
        .maxLength(200).enterKeyType(index + 1 < this.session.entries.length ? EnterKeyType.Next : EnterKeyType.Done)
        .onChange((value: string) => { this.onAnswer(index, value); })
        .onSubmit(() => { this.focusNext(index); })
    }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 18 }).borderRadius(18)
      .backgroundColor(C_SURFACE).alignItems(HorizontalAlign.Start)
  }

  @Builder
  writePhase() {
    Column() {
      Grid(this.scroller) {
        ForEach(this.session.entries, (entry: SessionEntry, index: number) => {
          GridItem() {
            this.writeCell(entry, index)
          }
        }, (entry: SessionEntry): string => `w-${this.session.round}-${entry.en}`)
      }.columnsTemplate('1fr 1fr').columnsGap(16).rowsGap(16).layoutWeight(1).width('100%')
        .scrollBar(BarState.Auto)

      Row({ space: 16 }) {
        Text(`已填 ${this.filled} / ${this.session.entries.length}`).fontSize(17).fontColor(C_SUB).layoutWeight(1)
        Button('对答案').id('wb-reveal').fontSize(19).fontWeight(FontWeight.Medium).height(50)
          .padding({ left: 48, right: 48 }).fontColor(W100).backgroundColor(this.busy ? C_DISABLED : C_PRIMARY)
          .borderRadius(30).enabled(!this.busy).onClick(() => { this.reveal(); })
      }.width('100%').padding({ left: 8, right: 4, top: 14 })
    }.width('100%').layoutWeight(1)
  }

  @Builder
  judgeButton(entry: SessionEntry, index: number, mark: number) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(mark === MARK_RIGHT ? $r('sys.symbol.checkmark') : $r('sys.symbol.xmark'))
        .fontSize(24)
        .fontColor([entry.mark === mark ? W100 : (mark === MARK_RIGHT ? C_PRIMARY : C_DANGER)])
    }.width(54).height(54)
      .backgroundColor(entry.mark === mark ? (mark === MARK_RIGHT ? C_PRIMARY : C_DANGER) : C_SURFACE)
      .borderWidth(2).borderColor(mark === MARK_RIGHT ? C_PRIMARY : C_DANGER)
      .accessibilityText(`${entry.en} 标记为${mark === MARK_RIGHT ? '答对' : '答错'}`)
      .onClick(() => { this.mark(index, mark); })
  }

  @Builder
  checkRow(entry: SessionEntry, index: number) {
    Row({ space: 20 }) {
      Column({ space: 4 }) {
        Text(entry.en).fontSize(24).fontWeight(FontWeight.Bold).fontColor(C_INK).maxLines(1)
        Text(this.wordOf(entry.en).ph).fontSize(15).fontColor(C_MUTE).maxLines(1)
      }.width('24%').alignItems(HorizontalAlign.Start)
      Column({ space: 4 }) {
        Text('你写的').fontSize(13).fontColor(C_MUTE)
        Text(entry.answer.trim().length > 0 ? entry.answer : '（未作答）').fontSize(18)
          .fontColor(entry.answer.trim().length > 0 ? C_INK : C_MUTE)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Column({ space: 4 }) {
        Text('正确答案').fontSize(13).fontColor(C_PRIMARY)
        Text(this.wordOf(entry.en).cn).fontSize(18).fontColor(C_PRIMARY)
      }.layoutWeight(1.3).alignItems(HorizontalAlign.Start)
      Row({ space: 14 }) {
        this.judgeButton(entry, index, MARK_WRONG)
        this.judgeButton(entry, index, MARK_RIGHT)
      }
    }.width('100%').padding({ left: 22, right: 22, top: 16, bottom: 16 }).borderRadius(18)
      .backgroundColor(entry.mark === MARK_RIGHT ? '#E3EEE9' : (entry.mark === MARK_WRONG ? '#F7E4DF' : C_SURFACE))
      .alignItems(VerticalAlign.Center)
  }

  @Builder
  checkPhase() {
    Column() {
      List({ space: 12 }) {
        ForEach(this.session.entries, (entry: SessionEntry, index: number) => {
          ListItem() {
            this.checkRow(entry, index)
          }
        }, (entry: SessionEntry): string => `c-${this.session.round}-${entry.en}-${entry.mark}`)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)

      Row({ space: 16 }) {
        Text(this.checkSummary()).fontSize(17).fontColor(C_SUB).layoutWeight(1)
        Button('返回修改').fontSize(17).height(50).padding({ left: 32, right: 32 }).fontColor(C_SUB)
          .backgroundColor(C_SURFACE).borderRadius(30).enabled(!this.busy).onClick(() => { this.backToWriting(); })
        Button('结算本轮').id('wb-settle').fontSize(19).fontWeight(FontWeight.Medium).height(50)
          .padding({ left: 44, right: 44 }).fontColor(W100)
          .backgroundColor(this.checkReady() && !this.busy ? C_PRIMARY : C_DISABLED).borderRadius(30)
          .enabled(this.checkReady() && !this.busy).onClick(() => { this.settle(); })
      }.width('100%').padding({ left: 8, right: 4, top: 14 })
    }.width('100%').layoutWeight(1)
  }

  private checkReady(): boolean {
    return sessionCounts(this.session).none === 0;
  }

  private checkSummary(): string {
    const c: SessionCounts = sessionCounts(this.session);
    if (c.none > 0) {
      return `还有 ${c.none} 条没判定 · 已 ${c.right} 对 ${c.wrong} 错`;
    }
    return `全部判定完毕 · ${c.right} 对 ${c.wrong} 错`;
  }

  @Builder
  roundChip(summary: RoundSummary) {
    Text(`第 ${summary.round} 轮 · ${summary.total} 词 → ${summary.right} 对 ${summary.wrong} 错`)
      .fontSize(14).fontColor(C_SUB).backgroundColor(C_SURFACE).borderRadius(16)
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
  }

  @Builder
  resultPhase() {
    Scroll() {
      Column({ space: 18 }) {
        if (this.session.finished) {
          Text('本遍完成').fontSize(22).fontColor(C_PRIMARY).fontWeight(FontWeight.Medium)
          Text('全部答对').fontSize(67).fontWeight(FontWeight.Bold).fontColor(C_PRIMARY)
          Text(`「${this.session.listName}」这一遍共 ${this.session.rounds.length} 轮刷完 · 累计已刷 ${this.passesOfSession()} 遍`)
            .fontSize(17).fontColor(C_SUB)
        } else {
          Text(`第 ${this.session.round} 轮结算`).fontSize(21).fontColor(C_SUB)
          Row({ space: 28 }) {
            Text(`${sessionCounts(this.session).right} 对`).fontSize(67).fontWeight(FontWeight.Bold).fontColor(C_PRIMARY)
            Text(`${sessionCounts(this.session).wrong} 错`).fontSize(67).fontWeight(FontWeight.Bold).fontColor(C_DANGER)
          }
        }
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          ForEach(this.session.rounds, (summary: RoundSummary) => {
            Row() { this.roundChip(summary) }.margin({ left: 6, right: 6, bottom: 8 })
          }, (summary: RoundSummary): string => `r-${summary.round}`)
        }.width('100%')

        if (!this.session.finished) {
          Column({ space: 10 }) {
            Text('这些词进入下一轮').fontSize(16).fontColor(C_SUB).width('100%')
            ForEach(this.wrongEntries(), (entry: SessionEntry) => {
              Row({ space: 18 }) {
                Text(entry.en).fontSize(21).fontWeight(FontWeight.Bold).fontColor(C_INK).width(180).maxLines(1)
                Text(this.wordOf(entry.en).cn).fontSize(16).fontColor(C_SUB).layoutWeight(1).maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 }).borderRadius(14)
                .backgroundColor('#F7E4DF')
            }, (entry: SessionEntry): string => `x-${entry.en}`)
          }.width('100%').constraintSize({ maxWidth: 900 }).margin({ top: 8 })
        }

        Row({ space: 16 }) {
          if (this.session.finished) {
            Button('返回词表').fontSize(19).height(54).padding({ left: 44, right: 44 }).fontColor(C_INK)
              .backgroundColor(C_SURFACE).borderRadius(27).enabled(!this.busy).onClick(() => { this.finishPass(); })
            Button('再刷一遍').id('wb-again').fontSize(19).fontWeight(FontWeight.Medium).height(54)
              .padding({ left: 44, right: 44 }).fontColor(W100).backgroundColor(C_PRIMARY).borderRadius(27)
              .enabled(!this.busy).onClick(() => { this.restartPass(); })
          } else {
            Button(`进入第 ${this.session.round + 1} 轮 · ${sessionCounts(this.session).wrong} 个词`)
              .id('wb-next').fontSize(19).fontWeight(FontWeight.Medium).height(54).padding({ left: 48, right: 48 })
              .fontColor(W100).backgroundColor(this.busy ? C_DISABLED : C_PRIMARY).borderRadius(27)
              .enabled(!this.busy).onClick(() => { this.nextRound(); })
          }
        }.margin({ top: 14 })
      }.width('100%').padding({ top: 24, bottom: 30 }).alignItems(HorizontalAlign.Center)
    }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
  }

  private wrongEntries(): SessionEntry[] {
    return this.session.entries.filter((e: SessionEntry): boolean => e.mark !== MARK_RIGHT);
  }

  private passesOfSession(): number {
    return listProgress(this.selectedListFor(this.session.listName), this.records).passes;
  }

  private selectedListFor(name: string): WordList {
    const found: WordList | null = findList(this.lists, name);
    return found !== null ? found : new WordList();
  }

  private restartPass(): void {
    this.startPass(this.session.listName);
  }

  @Builder
  sessionView() {
    Column() {
      this.sessionInfo()
      if (this.session.phase === PHASE_WRITE) {
        this.writePhase()
      } else if (this.session.phase === PHASE_CHECK) {
        this.checkPhase()
      } else {
        this.resultPhase()
      }
    }.width('100%').layoutWeight(1)
  }

  // ---------------------------------------------------------------- 弹层

  @Builder
  importDialog() {
    Column() {
      Text('导入词表').fontSize(21).fontWeight(FontWeight.Bold).fontColor(C_INK).width('100%')
      Text('粘贴词表 JSON 文本。同名词表会被更新（答题记录保留），新名字则新增。')
        .fontSize(14).fontColor(C_SUB).width('100%').margin({ top: 8 })
      TextArea({ placeholder: '{ "lists": [ { "name": "词表名", "words": [ { "en": "word", "ph": "[wɜːd]", "cn": "n. 单词" } ] } ] }',
        text: this.importText })
        .id('wb-import-text')
        .height(360).fontSize(14).fontColor(C_INK).backgroundColor(C_BG).borderRadius(14)
        .margin({ top: 14 })
        .onChange((value: string) => {
          this.importText = value;
          const has: boolean = value.trim().length > 0;
          if (has !== this.importHasText) {
            this.importHasText = has;
          }
          if (this.importError.length > 0) {
            this.importError = '';
          }
        })
      if (this.importError.length > 0) {
        Text(this.importError).fontSize(14).fontColor(C_DANGER).width('100%').margin({ top: 12 })
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(12).backgroundColor(TINT_WRONG)
      }
      Row({ space: 14 }) {
        Button('取消').fontSize(17).height(46).layoutWeight(1).fontColor(C_INK).backgroundColor(C_BG)
          .borderRadius(27).onClick(() => { this.showImport = false; })
        Button('导入').id('wb-import-confirm').fontSize(17).height(46).layoutWeight(1).fontColor(W100)
          .backgroundColor(this.importHasText && !this.busy ? C_PRIMARY : C_DISABLED).borderRadius(27)
          .enabled(this.importHasText && !this.busy).onClick(() => { this.doImport(); })
      }.width('100%').margin({ top: 16 })
    }.width(860).padding(28).borderRadius(26).backgroundColor(C_SURFACE)
  }

  @Builder
  confirmDialog() {
    Column() {
      Text(this.confirmTitle()).fontSize(19).fontWeight(FontWeight.Bold).fontColor(C_INK).width('100%')
      Text(this.confirmBody()).fontSize(15).fontColor(C_SUB).width('100%').margin({ top: 12 }).lineHeight(30)
      Row({ space: 14 }) {
        Button('取消').fontSize(17).height(44).layoutWeight(1).fontColor(C_INK).backgroundColor(C_BG)
          .borderRadius(26).onClick(() => { this.confirm = ''; })
        Button(this.confirm === 'start' ? '放弃并开始' : (this.confirm === 'delete' ? '删除' : '放弃'))
          .fontSize(17).height(44).layoutWeight(1).fontColor(W100).backgroundColor(C_DANGER).borderRadius(26)
          .onClick(() => { this.confirmAction(); })
      }.width('100%').margin({ top: 22 })
    }.width(480).padding(28).borderRadius(26).backgroundColor(C_SURFACE)
  }

  build() {
    Stack() {
      Column() {
        this.header()
        this.banner()
        if (!this.ready) {
          Column() {
            Text(this.error.length > 0 ? '' : '正在读取词表…').fontSize(16).fontColor(C_SUB)
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.view === 'home') {
          this.homeView()
        } else if (this.view === 'wrong') {
          this.wrongView()
        } else {
          this.sessionView()
        }
      }.width('100%').height('100%').padding({ top: 24, left: 44, right: 36, bottom: 24 })

      if (this.showImport || this.confirm.length > 0) {
        Column() {
          if (this.confirm.length > 0) {
            this.confirmDialog()
          } else {
            this.importDialog()
          }
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(C_SCRIM)
      }
    }.width('100%').height('100%').backgroundColor(C_BG)
      // 让米白背景延伸进状态栏 / 导航栏区域，消除上下白边
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
