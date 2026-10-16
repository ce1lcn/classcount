import { KeyboardAvoidMode as UIKeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { syncWindowColor } from '../common/WindowColor';
import { common } from '@kit.AbilityKit';
import { Schedule, buildSnapshot, calcDaysLeft, startOfDay } from '../model/Schedule';
import { ScheduleStore } from '../model/ScheduleStore';
import { CardPusher } from '../model/CardPusher';
import { PlannerStore } from '../features/planner/PlannerStore';
import {
  PlannerData, Todo, TodoDraft, TodoHistory, DiaryEntry, dayOf, dateOfDay, dayLabel,
  starsText, ruleLabel, draftError, createTodo, editTodo, completeTodo, reconcile,
  pendingTodos, saveDiary, clonePlanner
} from '../features/planner/Planner';
import {
  C_BG, C_SURFACE, C_INK, C_SUB, C_MUTE, C_LINE, C_PRIMARY, C_PRIMARY_SOFT,
  C_ACCENT, C_DANGER, C_SCRIM, C_WARN_BG, C_WARN_INK
} from '../common/Theme';
import {
  PAGE_MS, softAnim, popAnim, riseIn, scrimFade, dialogPop
} from '../common/Motion';

@Entry
@Component
struct Planner {
  @State data: PlannerData = new PlannerData();
  @State schedules: Schedule[] = [];
  @State activeId: string = '';
  @State today: number = dayOf(new Date());
  @State @Watch('refreshWindowColor') showHistory: boolean = false;
  @State historyTab: string = '待办记录';
  @State contentHeight: number = 600;
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State error: string = '';
  @State notice: string = '';
  @State cardPushFailed: boolean = false;
  @State showFuture: boolean = false;
  @State historyLimit: number = 50;
  @State @Watch('refreshWindowColor') editor: string = '';
  @State editingId: string = '';
  @State draftTitle: string = '';
  @State draftNote: string = '';
  @State draftStars: number = 3;
  @State draftRepeat: string = 'once';
  @State draftWeekdays: number[] = [];
  @State draftInterval: string = '2';
  @State draftDate: Date = new Date();
  @State editorError: string = '';
  @State diaryDay: number = dayOf(new Date());
  @State diaryBody: string = '';
  @State diarySaved: string = '';
  @State tab: string = '待办';
  /** 正在播放「完成」动画的待办 id；空串表示没有 */
  @State completingId: string = '';
  /** 打开编辑器时的草稿快照，用来判断用户是否真的改过东西（没改就直接关闭，不弹「放弃编辑」） */
  private editorBaseline: string = '';
  private plannerStore: PlannerStore | null = null;
  private scheduleStore: ScheduleStore | null = null;
  private clockId: number = -1;
  private previousKeyboardMode: UIKeyboardAvoidMode = UIKeyboardAvoidMode.OFFSET;

  private refreshWindowColor(): void {
    syncWindowColor(this.getUIContext(), this.editor.length > 0 || this.showHistory);
  }

  /** 页面切换：新页滑入淡入、旧页轻微左移淡出；返回时反向 */
  pageTransition(): void {
    PageTransitionEnter({ type: RouteType.Push, duration: PAGE_MS, curve: Curve.FastOutSlowIn })
      .translate({ x: 72 }).opacity(0)
    PageTransitionEnter({ type: RouteType.Pop, duration: PAGE_MS, curve: Curve.FastOutSlowIn })
      .translate({ x: -48 }).opacity(0)
    PageTransitionExit({ type: RouteType.Push, duration: PAGE_MS, curve: Curve.FastOutSlowIn })
      .translate({ x: -48 }).opacity(0)
    PageTransitionExit({ type: RouteType.Pop, duration: PAGE_MS, curve: Curve.FastOutSlowIn })
      .translate({ x: 72 }).opacity(0)
  }

  aboutToAppear(): void {
    this.refreshWindowColor();
    this.previousKeyboardMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.plannerStore = new PlannerStore(context);
    this.scheduleStore = new ScheduleStore(context);
    CardPusher.init(context);
    this.load();
    this.startClock();
  }

  onPageShow(): void {
    this.refreshWindowColor();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
    this.startClock();
    if (this.ready) {
      this.refreshDay();
    }
  }

  onPageHide(): void {
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
    this.stopClock();
  }

  aboutToDisappear(): void {
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
    this.stopClock();
  }

  onBackPress(): boolean {
    this.goBack();
    return true;
  }

  private startClock(): void {
    if (this.clockId < 0) {
      this.clockId = setInterval(() => { this.refreshDay(); }, 30000);
    }
  }

  private stopClock(): void {
    if (this.clockId >= 0) {
      clearInterval(this.clockId);
      this.clockId = -1;
    }
  }

  private async load(): Promise<void> {
    if (this.busy || this.plannerStore === null || this.scheduleStore === null) {
      return;
    }
    this.busy = true;
    this.error = '';
    try {
      const loaded: PlannerData = await this.plannerStore.load();
      const today: number = dayOf(new Date());
      if (reconcile(loaded, today)) {
        await this.plannerStore.save(loaded);
      }
      this.schedules = await this.scheduleStore.loadSchedules();
      this.activeId = await this.scheduleStore.loadActiveId();
      this.data = loaded;
      this.today = today;
      this.loadDiary(this.diaryDay);
      this.ready = true;
    } catch (err) {
      this.error = '手账读取失败，原数据已保留。请重试。';
    } finally {
      this.busy = false;
    }
  }

  private async refreshDay(): Promise<void> {
    if (!this.ready || this.busy) {
      return;
    }
    const today: number = dayOf(new Date());
    if (today === this.today) {
      return;
    }
    const next: PlannerData = clonePlanner(this.data);
    reconcile(next, today);
    if (await this.persist(next, '')) {
      this.today = today;
      if (this.diaryBody === this.diarySaved) {
        this.loadDiary(today);
      }
    }
  }

  private async persist(next: PlannerData, message: string): Promise<boolean> {
    if (this.busy || this.plannerStore === null) {
      return false;
    }
    this.busy = true;
    this.error = '';
    try {
      await this.plannerStore.save(next);
      // 落盘成功后再改界面数据；放在动画闭包里，增删待办时下面的行会平滑补位而不是跳一下
      this.getUIContext().animateTo(softAnim(280), () => { this.data = next; });
      this.notice = message;
      return true;
    } catch (err) {
      this.error = '保存失败，请重试。当前编辑内容仍然保留。';
      return false;
    } finally {
      this.busy = false;
    }
  }

  private async confirm(title: string, message: string): Promise<boolean> {
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [{ text: '取消', color: C_SUB }, { text: '确定', color: C_PRIMARY }]
      });
      return result.index === 1;
    } catch (err) {
      return false;
    }
  }

  private async closeEditor(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.editor.length === 0) {
      return;
    }
    if (this.editor === 'diary-date' || this.draftSignature() === this.editorBaseline
      || await this.confirm('放弃本次编辑？', '尚未保存的修改将被放弃。')) {
      this.editor = '';
    }
  }

  /** 当前草稿的签名：和打开编辑器时的快照一致 = 用户什么都没动 */
  private draftSignature(): string {
    if (this.editor === 'schedule' || this.editor === 'diary-date') {
      return `${this.draftTitle}\u0001${this.draftNote}\u0001${dayOf(this.draftDate)}`;
    }
    const days: number[] = this.draftWeekdays.slice().sort((a: number, b: number): number => a - b);
    return `${this.draftTitle}\u0001${this.draftNote}\u0001${this.draftStars}\u0001${this.draftRepeat}`
      + `\u0001${days.join(',')}\u0001${this.draftInterval}\u0001${dayOf(this.draftDate)}`;
  }

  private async goBack(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.editor.length > 0) {
      await this.closeEditor();
      return;
    }
    if (this.showHistory) {
      this.showHistory = false;
      return;
    }
    if (this.diaryBody !== this.diarySaved && !await this.confirm('日记尚未保存', '确定放弃本次修改并返回首页？')) {
      return;
    }
    this.getUIContext().getRouter().back();
  }

  private openTodo(todo: Todo | null): void {
    this.editingId = todo === null ? '' : todo.id;
    this.draftTitle = todo === null ? '' : todo.title;
    this.draftNote = todo === null ? '' : todo.note;
    this.draftStars = todo === null ? 3 : todo.stars;
    this.draftRepeat = todo === null ? 'once' : todo.repeat;
    this.draftWeekdays = todo === null ? [] : todo.weekdays.slice();
    this.draftInterval = todo === null ? '2' : `${todo.interval}`;
    this.draftDate = todo === null ? new Date() : dateOfDay(todo.startDay);
    this.editorError = '';
    this.editor = 'todo';
    this.editorBaseline = this.draftSignature();
  }

  private toggleWeekday(day: number): void {
    if (this.draftWeekdays.indexOf(day) >= 0) {
      this.draftWeekdays = this.draftWeekdays.filter((d: number): boolean => d !== day);
    } else {
      this.draftWeekdays = this.draftWeekdays.concat([day]).sort((a: number, b: number): number => a - b);
    }
  }

  private async saveTodo(): Promise<void> {
    const draft: TodoDraft = new TodoDraft();
    draft.title = this.draftTitle;
    draft.note = this.draftNote;
    draft.stars = this.draftStars;
    draft.repeat = this.draftRepeat;
    draft.startDay = dayOf(this.draftDate);
    draft.weekdays = this.draftWeekdays.slice();
    draft.interval = this.draftRepeat === 'interval' ? Number(this.draftInterval) : 2;
    this.editorError = draftError(draft);
    if (this.editorError.length > 0) {
      return;
    }
    const next: PlannerData = clonePlanner(this.data);
    const today: number = dayOf(new Date());
    if (this.editingId.length === 0) {
      next.todos.push(createTodo(draft, `${Date.now()}_${Math.floor(Math.random() * 1000000)}`));
    } else {
      editTodo(next, this.editingId, draft, today);
    }
    reconcile(next, today);
    if (await this.persist(next, '待办已保存')) {
      this.today = today;
      if (pendingTodos(next, today, true).length > 0) {
        this.showFuture = true;
      }
      this.editor = '';
    }
  }

  /** 点击后立即进入保存流程，避免动画延迟期间其他保存抢占；失败时恢复原样。 */
  private async finish(todo: Todo): Promise<void> {
    if (this.completingId.length > 0 || this.busy) {
      return;
    }
    const next: PlannerData = clonePlanner(this.data);
    const today: number = dayOf(new Date());
    if (!completeTodo(next, todo.id, today)) {
      return;
    }
    this.completingId = todo.id;
    try {
      if (await this.persist(next, '已完成，记录已保存在历史中')) {
        this.today = today;
      }
    } finally {
      this.completingId = '';
    }
  }

  private async removeTodo(todo: Todo): Promise<void> {
    if (!await this.confirm('删除待办？', `删除「${todo.title}」后不再出现，已有历史记录仍会保留。`)) {
      return;
    }
    const next: PlannerData = clonePlanner(this.data);
    reconcile(next, dayOf(new Date()));
    next.todos = next.todos.filter((item: Todo): boolean => item.id !== todo.id);
    await this.persist(next, '待办已删除，历史已保留');
  }

  private openSchedule(item: Schedule | null): void {
    this.editingId = item === null ? '' : item.id;
    this.draftTitle = item === null ? '' : item.title;
    this.draftNote = item === null ? '' : item.note;
    this.draftDate = item === null ? dateOfDay(this.today + 7) : new Date(item.targetDate);
    this.editorError = '';
    this.editor = 'schedule';
    this.editorBaseline = this.draftSignature();
  }

  private async writeSchedules(list: Schedule[], activeId: string): Promise<boolean> {
    if (this.busy || this.scheduleStore === null) {
      return false;
    }
    this.busy = true;
    this.error = '';
    try {
      await this.scheduleStore.saveSchedules(list);
      await this.scheduleStore.saveActiveId(activeId);
      const saved: Schedule[] = await this.scheduleStore.loadSchedules();
      const savedActive: string = await this.scheduleStore.loadActiveId();
      if (JSON.stringify(saved) !== JSON.stringify(list) || savedActive !== activeId) {
        throw new Error('Schedule persistence failed');
      }
      this.schedules = saved;
      this.activeId = savedActive;
      const active: Schedule | undefined = saved.find((item: Schedule): boolean => item.id === activeId);
      this.notice = '日程已保存';
      try {
        await CardPusher.pushToAll(buildSnapshot(active === undefined ? (saved.length > 0 ? saved[0] : null) : active, Date.now()));
        this.cardPushFailed = false;
      } catch (pushError) {
        // 保存已成功，不能让用户重试「新增」而创建第二份日程。
        this.error = '日程已保存，桌面卡片更新失败。可稍后点击「重试卡片更新」。';
        this.cardPushFailed = true;
      }
      return true;
    } catch (err) {
      this.error = '日程保存失败，请重试。';
      return false;
    } finally {
      this.busy = false;
    }
  }

  private async saveSchedule(): Promise<void> {
    if (this.draftTitle.trim().length === 0) {
      this.editorError = '请输入日程名称';
      return;
    }
    const list: Schedule[] = this.schedules.slice();
    let active: string = this.activeId;
    const existing: Schedule | undefined = list.find((s: Schedule): boolean => s.id === this.editingId);
    if (existing !== undefined) {
      const index: number = list.findIndex((s: Schedule): boolean => s.id === existing.id);
      list[index] = new Schedule(existing.id, this.draftTitle.trim(), startOfDay(this.draftDate.getTime()), existing.createdDate, this.draftNote);
    } else {
      active = `${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
      list.push(new Schedule(active, this.draftTitle.trim(), startOfDay(this.draftDate.getTime()), startOfDay(Date.now()), this.draftNote));
    }
    list.sort((a: Schedule, b: Schedule): number => a.targetDate - b.targetDate);
    if (await this.writeSchedules(list, active)) {
      this.editor = '';
    }
  }

  private async removeSchedule(item: Schedule): Promise<void> {
    if (!await this.confirm('删除日程？', `确定删除「${item.title}」？待办与日记会继续保留。`)) {
      return;
    }
    const list: Schedule[] = this.schedules.filter((s: Schedule): boolean => s.id !== item.id);
    const active: string = this.activeId === item.id ? (list.length > 0 ? list[0].id : '') : this.activeId;
    await this.writeSchedules(list, active);
  }

  private loadDiary(day: number): void {
    const entry: DiaryEntry | undefined = this.data.diaries.find((d: DiaryEntry): boolean => d.day === day);
    this.diaryDay = day;
    this.diaryBody = entry === undefined ? '' : entry.body;
    this.diarySaved = this.diaryBody;
  }

  private async selectDiary(day: number): Promise<void> {
    if (day === this.diaryDay) {
      this.editor = '';
      this.showHistory = false;
      return;
    }
    if (this.diaryBody !== this.diarySaved && !await this.confirm('日记尚未保存', '切换日期会放弃当前修改，是否继续？')) {
      return;
    }
    this.loadDiary(day);
    this.editor = '';
    this.showHistory = false;
  }

  private async persistDiary(): Promise<void> {
    const next: PlannerData = clonePlanner(this.data);
    const text: string = this.diaryBody;
    saveDiary(next, this.diaryDay, text, Date.now());
    if (await this.persist(next, '日记已保存')) {
      this.diarySaved = text;
    }
  }

  private historyItems(): TodoHistory[] {
    return this.data.history.slice().sort((a: TodoHistory, b: TodoHistory): number =>
      b.recordedDay - a.recordedDay || b.id.localeCompare(a.id)).slice(0, this.historyLimit);
  }

  private diaryItems(): DiaryEntry[] {
    return this.data.diaries.filter((d: DiaryEntry): boolean => d.body.trim().length > 0)
      .sort((a: DiaryEntry, b: DiaryEntry): number => b.day - a.day);
  }

  private dueLabel(todo: Todo): string {
    const days: number = this.today - todo.nextDay;
    if (days > 0) {
      return `${todo.repeat === 'once' ? '已逾期' : '已连续'} ${days} 天${todo.repeat === 'once' ? '' : '未完成'} · 原定 ${dayLabel(todo.nextDay)}`;
    }
    return days === 0 ? '今天要做' : `${dayLabel(todo.nextDay)} 开始`;
  }

  private countdown(item: Schedule): string {
    const days: number = calcDaysLeft(item.targetDate, dateOfDay(this.today).getTime());
    return days > 0 ? `还有 ${days} 天` : (days === 0 ? '就是今天' : `已过 ${-days} 天`);
  }

  private todoHeight(): number {
    const count: number = pendingTodos(this.data, this.today, false).length +
      (this.showFuture ? pendingTodos(this.data, this.today, true).length : 0);
    return Math.min(Math.max(52 + count * 68, 80), this.contentHeight * 0.42);
  }

  private compactRule(todo: Todo): string {
    const overdue: number = this.today - todo.nextDay;
    const date: string = overdue > 0 ? `${overdue} 天未完成` : (overdue < 0 ? dayLabel(todo.nextDay) : '');
    let repeat: string = '';
    if (todo.repeat === 'daily') {
      repeat = '每天';
    } else if (todo.repeat === 'weekly') {
      repeat = ruleLabel(todo);
    } else if (todo.repeat === 'interval') {
      repeat = `每 ${todo.interval} 天`;
    }
    return date.length > 0 && repeat.length > 0 ? `${date} · ${repeat}` : date + repeat;
  }

  private async deleteEditing(): Promise<void> {
    if (this.editor === 'todo') {
      const todo: Todo | undefined = this.data.todos.find((item: Todo): boolean => item.id === this.editingId);
      if (todo !== undefined) {
        await this.removeTodo(todo);
        if (!this.data.todos.some((item: Todo): boolean => item.id === this.editingId)) {
          this.editor = '';
        }
      }
    } else if (this.editor === 'schedule') {
      const item: Schedule | undefined = this.schedules.find((s: Schedule): boolean => s.id === this.editingId);
      if (item !== undefined) {
        await this.removeSchedule(item);
        if (!this.schedules.some((s: Schedule): boolean => s.id === this.editingId)) {
          this.editor = '';
        }
      }
    }
  }

  @Builder
  header() {
    Row({ space: 12 }) {
      Button('‹ 首页').height(38).fontSize(16).backgroundColor(C_BG).fontColor(C_INK)
        .onClick(() => { this.goBack(); })
      Text('日程').fontSize(23).fontWeight(FontWeight.Bold).fontColor(C_INK).layoutWeight(1)
      Button('历史').height(38).fontSize(16).backgroundColor(C_SURFACE).fontColor(C_PRIMARY)
        .onClick(() => { this.showHistory = true; })
    }.width('100%').height(44).margin({ bottom: 10 })
  }

  @Builder
  scheduleCard(item: Schedule) {
    Column({ space: 6 }) {
      Row() {
        Text(item.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(C_INK)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button('···').width(38).height(36).padding(0).fontSize(20).backgroundColor(C_SURFACE).fontColor(C_SUB)
          .accessibilityText('编辑日程').onClick(() => { this.openSchedule(item); })
      }.width('100%')
      Text(this.countdown(item)).fontSize(26).fontWeight(FontWeight.Bold).fontColor(C_PRIMARY)
      Text(dayLabel(dayOf(new Date(item.targetDate)))).fontSize(16).fontColor(C_SUB)
      if (item.note.length > 0) {
        Text(item.note).fontSize(16).fontColor(C_SUB).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Button(item.id === this.activeId ? (this.cardPushFailed ? '重试更新' : '桌面显示中') : '设为桌面显示')
        .height(34).fontSize(15).backgroundColor(C_PRIMARY_SOFT).fontColor(C_PRIMARY)
        .enabled(!this.busy && (item.id !== this.activeId || this.cardPushFailed))
        .onClick(() => { this.writeSchedules(this.schedules.slice(), item.id); })
      Divider().color(C_LINE).margin({ top: 10 })
    }.width('100%').padding({ top: 8, bottom: 8 }).alignItems(HorizontalAlign.Start)
      .transition(riseIn(10))
  }

  @Builder
  schedulesSection() {
    Column({ space: 8 }) {
      Row() {
        Text('日程').fontSize(18).fontWeight(FontWeight.Bold).fontColor(C_INK).layoutWeight(1)
        Button('＋').width(38).height(36).padding(0).fontSize(22).backgroundColor(C_SURFACE).fontColor(C_PRIMARY)
          .accessibilityText('新增日程').onClick(() => { this.openSchedule(null); })
      }.width('100%')
      Scroll() {
        Column() {
          ForEach(this.schedules, (item: Schedule) => { this.scheduleCard(item) }, (item: Schedule): string => item.id)
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
    }.width('100%').height('100%').padding(14).backgroundColor(C_SURFACE).borderRadius(12)
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  todoRow(todo: Todo, future: boolean) {
    Column() {
      Row({ space: 8 }) {
        Button(this.completingId === todo.id ? '●' : '○').width(36).height(40).fontSize(25).padding(0)
          .backgroundColor(C_SURFACE).fontColor(C_PRIMARY).accessibilityText('完成待办：' + todo.title)
          .scale({ x: this.completingId === todo.id ? 1.3 : 1, y: this.completingId === todo.id ? 1.3 : 1 })
          .animation(popAnim())
          .enabled(!future && !this.busy).onClick(() => { this.finish(todo); })
        Column({ space: 3 }) {
          Row({ space: 8 }) {
            Text(todo.title).fontSize(19).fontColor(C_INK).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text(starsText(todo.stars)).fontSize(17).fontColor('#A87518').letterSpacing(-1)
              .accessibilityText('重要程度 ' + todo.stars + ' 星')
          }.width('100%')
          if (this.compactRule(todo).length > 0) {
            Text(this.compactRule(todo)).fontSize(15).fontColor(todo.nextDay < this.today ? C_DANGER : C_SUB)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          .onClick(() => { this.openTodo(todo); })
        Button('···').width(36).height(40).padding(0).fontSize(20).backgroundColor(C_SURFACE).fontColor(C_SUB)
          .accessibilityText('编辑待办').onClick(() => { this.openTodo(todo); })
      }.width('100%').constraintSize({ minHeight: 58 }).padding({ top: 4, bottom: 4 })
      Divider().color(C_LINE)
    }.width('100%')
      // 保存期间反馈完成状态；保存成功后移除，失败则恢复原样。
      .opacity(this.completingId === todo.id ? 0 : 1)
      .translate({ x: this.completingId === todo.id ? 56 : 0 })
      .animation({ duration: 280, delay: this.completingId === todo.id ? 130 : 0, curve: Curve.EaseIn })
      .transition(riseIn(10))
  }

  @Builder
  todosSection() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text('待办').fontSize(19).fontWeight(FontWeight.Bold).fontColor(C_INK).layoutWeight(1)
        if (pendingTodos(this.data, this.today, true).length > 0) {
          Button((this.showFuture ? '收起' : '待安排') + ' ' + pendingTodos(this.data, this.today, true).length)
            .height(34).fontSize(15).backgroundColor(C_SURFACE).fontColor(C_SUB)
            .onClick(() => { this.showFuture = !this.showFuture; })
        }
        Button('＋').width(38).height(36).padding(0).fontSize(23).backgroundColor(C_SURFACE).fontColor(C_PRIMARY)
          .accessibilityText('新增待办').onClick(() => { this.openTodo(null); })
      }.width('100%')
      Scroll() {
        Column() {
          ForEach(pendingTodos(this.data, this.today, false), (todo: Todo) => { this.todoRow(todo, false) },
            (todo: Todo): string => todo.id)
          if (this.showFuture) {
            ForEach(pendingTodos(this.data, this.today, true), (todo: Todo) => { this.todoRow(todo, true) },
              (todo: Todo): string => todo.id)
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
    }.width('100%').height(this.todoHeight()).animation(softAnim(280))
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor(C_SURFACE).borderRadius(10)
  }

  @Builder
  diarySection() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Button('‹').width(34).height(36).padding(0).fontSize(22).backgroundColor(C_BG).fontColor(C_INK)
          .enabled(this.diaryDay > dayOf(new Date(2020, 0, 1)))
          .onClick(() => { this.selectDiary(this.diaryDay - 1); })
        Button(dayLabel(this.diaryDay)).height(36).fontSize(16).backgroundColor(C_BG).fontColor(C_INK)
          .onClick(() => { this.draftDate = dateOfDay(this.diaryDay); this.editorError = ''; this.editor = 'diary-date'; })
        Button('›').width(34).height(36).padding(0).fontSize(22).backgroundColor(C_BG).fontColor(C_INK)
          .enabled(this.diaryDay < dayOf(new Date(2100, 11, 31)))
          .onClick(() => { this.selectDiary(this.diaryDay + 1); })
        if (this.diaryDay !== this.today) {
          Button('今天').height(36).fontSize(16).backgroundColor(C_BG).fontColor(C_PRIMARY)
            .onClick(() => { this.selectDiary(this.today); })
        }
        Blank()
        Button(this.diaryBody === this.diarySaved ? '已保存' : '保存').height(36).fontSize(16)
          .backgroundColor(this.diaryBody === this.diarySaved ? C_BG : C_PRIMARY)
          .fontColor(this.diaryBody === this.diarySaved ? C_SUB : Color.White)
          .animation(softAnim(200))
          .enabled(this.diaryBody !== this.diarySaved && !this.busy).onClick(() => { this.persistDiary(); })
      }.width('100%')
      TextArea({ text: this.diaryBody, placeholder: '' }).id('planner-record-input')
        .layoutWeight(1).width('100%').fontSize(20).backgroundColor(C_SURFACE).fontColor(C_INK)
        .borderRadius(10).padding(16).maxLength(10000).accessibilityText('记录')
        .onChange((value: string) => { this.diaryBody = value; })
    }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder
  historySection() {
    Column({ space: 8 }) {
      if (this.data.history.length === 0) {
        Text('暂无记录').fontSize(17).fontColor(C_SUB).padding(12)
      }
      ForEach(this.historyItems(), (entry: TodoHistory) => {
        Column({ space: 5 }) {
          Row({ space: 8 }) {
            Text(entry.title).fontSize(18).fontColor(C_INK).layoutWeight(1)
            Text(starsText(entry.stars)).fontSize(16).letterSpacing(-1).fontColor('#A87518')
          }.width('100%')
          Text(dayLabel(entry.recordedDay) + ' · ' + (entry.status === 'completed' ? '已完成' : '未完成'))
            .fontSize(16).fontColor(entry.status === 'completed' ? C_PRIMARY : C_SUB)
          if (entry.status === 'completed' && entry.overdueDays > 0) {
            Text('顺延 ' + entry.overdueDays + ' 天').fontSize(16).fontColor(C_SUB)
          }
          Divider().color(C_LINE).margin({ top: 8 })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (entry: TodoHistory): string => entry.id)
      if (this.data.history.length > this.historyLimit) {
        Button('更多').fontSize(16).backgroundColor(C_PRIMARY_SOFT).fontColor(C_PRIMARY)
          .onClick(() => { this.historyLimit += 50; })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  historyPanel() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button('待办记录').fontSize(16).backgroundColor(this.historyTab === '待办记录' ? C_PRIMARY_SOFT : C_SURFACE)
          .fontColor(C_PRIMARY).onClick(() => { this.historyTab = '待办记录'; })
        Button('文字记录').fontSize(16).backgroundColor(this.historyTab === '文字记录' ? C_PRIMARY_SOFT : C_SURFACE)
          .fontColor(C_PRIMARY).onClick(() => { this.historyTab = '文字记录'; })
        Blank()
        Button('关闭').fontSize(16).backgroundColor(C_BG).fontColor(C_INK)
          .onClick(() => { this.showHistory = false; })
      }.width('100%')
      Scroll() {
        Column({ space: 12 }) {
          if (this.historyTab === '待办记录') {
            this.historySection()
          } else {
            if (this.diaryItems().length === 0) {
              Text('暂无记录').fontSize(17).fontColor(C_SUB).padding(12)
            }
            ForEach(this.diaryItems(), (entry: DiaryEntry) => {
              Column({ space: 6 }) {
                Text(dayLabel(entry.day)).fontSize(17).fontWeight(FontWeight.Medium).fontColor(C_PRIMARY)
                Text(entry.body).fontSize(18).fontColor(C_INK).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                Divider().color(C_LINE).margin({ top: 8 })
              }.width('100%').alignItems(HorizontalAlign.Start).onClick(() => { this.selectDiary(entry.day); })
            }, (entry: DiaryEntry): string => '' + entry.day)
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
    }.width('90%').constraintSize({ maxWidth: 800 }).height('85%').padding(20)
      .backgroundColor(C_SURFACE).borderRadius(14).transition(dialogPop())
  }


  @Builder
  repeatChoice(value: string, title: string) {
    Button(title).fontSize(14).height(36).layoutWeight(1)
      .backgroundColor(this.draftRepeat === value ? C_PRIMARY : C_BG)
      .fontColor(this.draftRepeat === value ? Color.White : C_INK)
      .animation(softAnim(180))
      .onClick(() => { this.draftRepeat = value; })
  }

  @Builder
  todoFields() {
    Row({ space: 0 }) {
      Text('重要程度').fontSize(16).fontColor(C_SUB).margin({ right: 14 })
      ForEach([1, 2, 3, 4, 5], (n: number) => {
        Text(n <= this.draftStars ? '★' : '☆').fontSize(30).fontColor('#A87518')
          .width(32).height(44).textAlign(TextAlign.Center).accessibilityText(`${n} 星`)
          // 刚点中的那颗星弹一下，其余回原位
          .scale({ x: n === this.draftStars ? 1.25 : 1, y: n === this.draftStars ? 1.25 : 1 })
          .animation(popAnim())
          .onClick(() => { this.draftStars = n; })
      }, (n: number): string => `${n}`)
    }
    Text('执行方式').fontSize(16).fontColor(C_SUB)
    Row({ space: 6 }) {
      this.repeatChoice('once', '单次')
      this.repeatChoice('daily', '每天')
      this.repeatChoice('weekly', '每周')
      this.repeatChoice('interval', '每隔 N 天')
    }.width('100%')
    if (this.draftRepeat === 'weekly') {
      Row({ space: 4 }) {
        ForEach([1, 2, 3, 4, 5, 6, 7], (day: number) => {
          Button(['一', '二', '三', '四', '五', '六', '日'][day - 1]).fontSize(14).height(40).layoutWeight(1)
            .padding(0).backgroundColor(this.draftWeekdays.indexOf(day) >= 0 ? C_PRIMARY : C_BG)
            .fontColor(this.draftWeekdays.indexOf(day) >= 0 ? Color.White : C_INK)
            .animation(softAnim(180))
            .accessibilityText(`星期${['一', '二', '三', '四', '五', '六', '日'][day - 1]}`)
            .onClick(() => { this.toggleWeekday(day); })
        }, (day: number): string => `${day}`)
      }.width('100%')
    }
    if (this.draftRepeat === 'interval') {
      Row({ space: 10 }) {
        Text('每隔').fontSize(15).fontColor(C_INK)
        TextInput({ text: this.draftInterval, placeholder: '1～365' }).type(InputType.Number).width(100)
          .maxLength(3).onChange((value: string) => { this.draftInterval = value; })
        Text('天出现一次').fontSize(15).fontColor(C_INK)
      }
    }
  }

  @Builder
  editorPanel() {
    Column({ space: 12 }) {
        Text(this.editor === 'diary-date' ? '选择日期' : `${this.editingId.length > 0 ? '编辑' : '新增'}${this.editor === 'todo' ? '待办' : '日程'}`)
          .fontSize(23).fontWeight(FontWeight.Bold).fontColor(C_INK)
        Scroll() {
          Column({ space: 10 }) {
        if (this.editor !== 'diary-date') {
          TextInput({ text: this.draftTitle, placeholder: this.editor === 'todo' ? '准备做些什么？' : '日程名称，如：六级考试' })
            .id('planner-edit-title').fontSize(18).maxLength(this.editor === 'todo' ? 80 : 30).height(44)
            .onChange((value: string) => { this.draftTitle = value; })
          TextArea({ text: this.draftNote, placeholder: '补充说明（选填）' }).fontSize(17).height(60).maxLength(2000)
            .onChange((value: string) => { this.draftNote = value; })
        }
        if (this.editor === 'todo') {
          this.todoFields()
        }
        Text(this.editor === 'todo' && this.draftRepeat !== 'once' ? '开始日期' : '日期').fontSize(16).fontColor(C_SUB)
        DatePicker({ start: new Date(2020, 0, 1), end: new Date(2100, 11, 31), selected: this.draftDate })
          .height(150).textStyle({ color: C_SUB, font: { size: 16 } })
          .selectedTextStyle({ color: C_PRIMARY, font: { size: 20, weight: FontWeight.Medium } })
          .onDateChange((date: Date) => { this.draftDate = date; })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
        if (this.editorError.length > 0) {
          Text(this.editorError).fontSize(16).fontColor(C_DANGER)
        }
        if (this.error.length > 0) {
          Text(this.error).fontSize(16).fontColor(C_DANGER)
        }
        Row({ space: 12 }) {
          if (this.editingId.length > 0 && this.editor !== 'diary-date') {
            Button('删除').id('planner-edit-delete').height(44).width(72).padding(0)
              .fontSize(17).backgroundColor(C_SURFACE).fontColor(C_DANGER)
              .enabled(!this.busy).onClick(() => { this.deleteEditing(); })
          }
          Button('取消').id('planner-edit-cancel').height(44).fontSize(17).layoutWeight(1).backgroundColor(C_BG).fontColor(C_INK)
            .onClick(() => { this.closeEditor(); })
          Button(this.busy ? '保存中…' : '保存').id('planner-edit-save').height(44).fontSize(17).layoutWeight(1).backgroundColor(C_PRIMARY).fontColor(Color.White)
            .enabled(!this.busy).onClick(() => {
              if (this.editor === 'todo') {
                this.saveTodo();
              } else if (this.editor === 'schedule') {
                this.saveSchedule();
              } else {
                this.selectDiary(dayOf(this.draftDate));
              }
            })
        }.width('100%')
    }.id('planner-editor-panel').width('92%').constraintSize({ maxWidth: 560, maxHeight: 600 })
      .height('90%').padding(20).alignItems(HorizontalAlign.Start)
      .backgroundColor(C_SURFACE).borderRadius(18).enabled(!this.busy).transition(dialogPop())
  }

  build() {
    Stack() {
      Column() {
        this.header()
        if (!this.ready) {
          Column({ space: 16 }) {
            Text(this.busy ? '加载中…' : this.error).fontSize(17).fontColor(C_SUB)
            if (!this.busy) {
              Button('重试').backgroundColor(C_PRIMARY).onClick(() => { this.load(); })
            }
          }.layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Row({ space: 14 }) {
            Column() {
              this.schedulesSection()
            }.width('27%').constraintSize({ maxWidth: 300 }).height('100%')
            Column({ space: 10 }) {
                this.todosSection()
                this.diarySection()
            }.layoutWeight(1).height('100%')
              .onAreaChange((oldArea: Area, newArea: Area) => { this.contentHeight = Number(newArea.height); })
          }.layoutWeight(1).width('100%').alignItems(VerticalAlign.Top).enabled(!this.busy)
          if (this.error.length > 0) {
            Text(this.error).fontSize(16).fontColor(C_DANGER).width('100%').margin({ top: 6 })
          }
        }
      }.width('100%').height('100%').padding({ top: 16, left: 18, right: 18, bottom: 16 })
      if (this.showHistory) {
        Column() {
          this.historyPanel()
        }.width('100%').height('100%').backgroundColor(C_SCRIM).justifyContent(FlexAlign.Center)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .transition(scrimFade())
      }
      if (this.editor.length > 0) {
        Column() {
          this.editorPanel()
        }.width('100%').height('100%').backgroundColor(C_SCRIM).justifyContent(FlexAlign.Center)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .transition(scrimFade())
      }
    }.width('100%').height('100%').backgroundColor(C_BG)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
