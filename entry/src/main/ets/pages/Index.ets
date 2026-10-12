/**
 * 主应用首页：今日概览（下一节课 + 今日课程）+ 日程倒计时管理
 *
 * 关键时序（决定了卡片会不会"看起来没反应"）：
 *   改日程 → saveSchedules() → await flush → 重新算快照 → CardPusher.pushToAll()
 *   ⚠️ 必须 await 写入完成后再推送，否则卡片进程可能读到旧值。
 *
 * ⚠️ 弹层显示条件都绑 @State；颜色一律 #AARRGGBB。
 */
import { Todo, dayOf, pendingTodos, starsText, ruleLabel } from '../features/planner/Planner';
import { PlannerStore } from '../features/planner/PlannerStore';
import { syncWindowColor } from '../common/WindowColor';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { Schedule, ScheduleSnapshot, buildSnapshot, calcDaysLeft, startOfDay } from '../model/Schedule';
import { ScheduleStore } from '../model/ScheduleStore';
import { CardPusher } from '../model/CardPusher';
import { CourseStore } from '../model/CourseStore';
import {
  CourseItem, CourseTable, NextClass, calcNextClass, todayClasses, weekOfTerm,
  sectionStartTime, sectionEndTime
} from '../model/Course';
import {
  C_BG, C_SURFACE, C_INK, C_SUB, C_MUTE, C_LINE, C_PRIMARY, C_PRIMARY_SOFT, C_ACCENT, C_DANGER,
  C_WARN_BG, C_WARN_INK, C_SCRIM, C_DISABLED, W100, W85, W65, W25,
  courseColor, urgencyColor, pad2
} from '../common/Theme';

const TAG: string = 'Index';
const DOMAIN: number = 0xFF00;
const WEEK_NAMES: string[] = ['日', '一', '二', '三', '四', '五', '六'];

@Entry
@Component
struct Index {
  @State schedules: Schedule[] = [];
  @State activeId: string = '';
  @State snapshot: ScheduleSnapshot = new ScheduleSnapshot();
  @State formOnDesktop: boolean = false;
  @State showEditor: boolean = false;
  @State editingId: string = '';
  @State draftTitle: string = '';
  @State draftNote: string = '';
  @State draftDate: Date = new Date();
  @State confirmDeleteId: string = '';
  // ---- 课程概览 ----
  @State next: NextClass = new NextClass();
  @State today: CourseItem[] = [];
  @State week: number = 1;
  @State weekNames: string[] = ['', '', '', '', '', '', ''];
  @State homeTodos: Todo[] = [];
  @State homeTodoError: string = '';
  private plannerStore: PlannerStore | null = null;
  private store: ScheduleStore | null = null;
  private courseStore: CourseStore | null = null;

  aboutToAppear(): void {
    // API 12+ 推荐写法；旧写法为 getContext(this) as common.UIAbilityContext
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.plannerStore = new PlannerStore(ctx);
    this.reloadHomeTodos();
    this.store = new ScheduleStore(ctx);
    this.courseStore = new CourseStore(ctx);
    CardPusher.init(ctx);
    this.reload();
    this.reloadCourses();
    this.checkFormOnDesktop();
  }

  /** 从课表子页返回时刷新概览 */
  onPageShow(): void {
    syncWindowColor(this.getUIContext());
    this.reloadHomeTodos();
    if (this.store !== null) {
      this.reload();
    }
    if (this.courseStore !== null) {
      this.reloadCourses();
    }
  }

  private async reloadHomeTodos(): Promise<void> {
    if (this.plannerStore === null) { return; }
    try {
      const data = await this.plannerStore.load();
      this.homeTodos = pendingTodos(data, dayOf(new Date()), false);
      this.homeTodoError = '';
    } catch (e) {
      this.homeTodoError = '待办读取失败';
    }
  }

  private remainingSchedules(): Schedule[] {
    const selected: Schedule | undefined = this.schedules.find((item: Schedule): boolean => item.id === this.activeId);
    const heroId: string = selected !== undefined ? selected.id : (this.schedules.length > 0 ? this.schedules[0].id : '');
    return this.schedules.filter((item: Schedule): boolean => item.id !== heroId);
  }

  private homeTodoRule(todo: Todo): string {
    const overdue: number = dayOf(new Date()) - todo.nextDay;
    if (overdue > 0) { return `${overdue} 天未完成`; }
    if (todo.repeat === 'once') { return '今天'; }
    return todo.repeat === 'interval' ? `每 ${todo.interval} 天` : ruleLabel(todo);
  }

  /** 从持久化重载列表 + 重算快照（不推送） */
  private async reload(): Promise<void> {
    const store: ScheduleStore = this.store!;
    this.schedules = await store.loadSchedules();
    this.activeId = await store.loadActiveId();
    this.recomputeSnapshot();
  }

  private async reloadCourses(): Promise<void> {
    const table: CourseTable = await this.courseStore!.load();
    const now: number = Date.now();
    this.next = calcNextClass(table, now);
    this.today = todayClasses(table, now);
    this.week = weekOfTerm(table, now);
    // 本周每天的课程名（周一~周日），给右栏「本周概览」用
    const names: string[][] = [[], [], [], [], [], [], []];
    for (let i = 0; i < table.items.length; i++) {
      const it: CourseItem = table.items[i];
      if (it.weekList !== null && it.weekList !== undefined &&
        it.weekList.indexOf(this.week) >= 0 && it.dayOfWeek >= 1 && it.dayOfWeek <= 7) {
        names[it.dayOfWeek - 1].push(it.name);
      }
    }
    this.weekNames = names.map((arr: string[]): string => arr.join('、'));
  }

  private recomputeSnapshot(): void {
    let active: Schedule | null = null;
    for (let i = 0; i < this.schedules.length; i++) {
      if (this.schedules[i].id === this.activeId) {
        active = this.schedules[i];
        break;
      }
    }
    if (active === null && this.schedules.length > 0) {
      active = this.schedules[0];
    }
    this.snapshot = buildSnapshot(active, Date.now());
  }

  /** 保存 + 立即推送到卡片（核心时序） */
  private async persistAndPush(): Promise<void> {
    const store: ScheduleStore = this.store!;
    await store.saveSchedules(this.schedules);   // 先落盘
    await store.saveActiveId(this.activeId);
    this.recomputeSnapshot();
    const count: number = await CardPusher.pushToAll(this.snapshot);  // 再推送
    hilog.info(DOMAIN, TAG, 'pushed to %{public}d forms', count);
  }

  private async checkFormOnDesktop(): Promise<void> {
    this.formOnDesktop = await CardPusher.hasFormOnDesktop();
  }

  // ---------------------------- 交互 ----------------------------

  private openEditor(item: Schedule | null): void {
    if (item === null) {
      this.editingId = '';
      this.draftTitle = '';
      this.draftNote = '';
      // 默认选一周后
      this.draftDate = new Date(startOfDay(Date.now()) + 7 * 86400000);
    } else {
      this.editingId = item.id;
      this.draftTitle = item.title;
      this.draftNote = item.note;
      this.draftDate = new Date(item.targetDate);
    }
    this.showEditor = true;
  }

  private async saveEditor(): Promise<void> {
    const title: string = this.draftTitle.trim();
    if (title.length === 0) {
      return;
    }
    const target: number = startOfDay(this.draftDate.getTime());
    const list: Schedule[] = this.schedules.slice();
    if (this.editingId.length > 0) {
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === this.editingId) {
          list[i] = new Schedule(list[i].id, title, target, list[i].createdDate, this.draftNote);
          break;
        }
      }
    } else {
      const id: string = `${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
      list.push(new Schedule(id, title, target, startOfDay(Date.now()), this.draftNote));
      this.activeId = id;   // 新增后自动选中
    }
    list.sort((a: Schedule, b: Schedule): number => a.targetDate - b.targetDate);
    this.schedules = list;
    this.showEditor = false;
    await this.persistAndPush();
  }

  private async selectItem(id: string): Promise<void> {
    if (this.activeId === id) {
      return;
    }
    this.activeId = id;
    await this.persistAndPush();
  }

  private async deleteItem(id: string): Promise<void> {
    const list: Schedule[] = this.schedules.filter((s: Schedule): boolean => s.id !== id);
    this.schedules = list;
    if (this.activeId === id) {
      this.activeId = list.length > 0 ? list[0].id : '';
    }
    this.confirmDeleteId = '';
    await this.persistAndPush();
  }

  // ---------------------------- 展示辅助 ----------------------------

  private dateTitle(): string {
    const d: Date = new Date();
    return `${d.getMonth() + 1}月${d.getDate()}日 周${WEEK_NAMES[d.getDay()]}`;
  }

  private dotColor(daysLeft: number): string {
    if (daysLeft < 0) {
      return C_MUTE;
    }
    return daysLeft <= 7 ? C_ACCENT : C_PRIMARY;
  }

  private shortDays(daysLeft: number): string {
    if (daysLeft > 0) {
      return `${daysLeft} 天`;
    }
    return daysLeft === 0 ? '今天' : `已过 ${-daysLeft} 天`;
  }

  private dateOf(ts: number): string {
    const d: Date = new Date(ts);
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  }

  /** idx: 0=周一 … 6=周日 */
  private isTodayIdx(idx: number): boolean {
    return (new Date().getDay() + 6) % 7 === idx;
  }

  private hm(minutes: number): string {
    return `${pad2(Math.floor(minutes / 60))}:${pad2(minutes % 60)}`;
  }

  /** 今日课程是否已结束（用于淡化） */
  private isPast(it: CourseItem): boolean {
    const d: Date = new Date();
    const nowMin: number = d.getHours() * 60 + d.getMinutes();
    return sectionEndTime(it.endSection) <= nowMin;
  }

  // ---------------------------- 组件 ----------------------------

  @Builder
  progressBar(label: string, percent: number) {
    Column() {
      Row() {
        Text(label).fontSize(12).fontColor(W65)
        Blank()
        Text(`${percent}%`).fontSize(12).fontColor(W100)
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(6).borderRadius(3).backgroundColor(W25)
        Row().width(`${percent}%`).height(6).borderRadius(3).backgroundColor(W100)
      }
      .width('100%')
      .height(6)
      .margin({ top: 6 })
    }
    .width('100%')
  }

  /** 左上：下一节课大卡 */
  @Builder
  nextClassCard() {
    Column() {
      if (this.next.hasClass) {
        Row() {
          Text(this.next.ongoing ? '正在上课' : '下一节课')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(W100)
            .backgroundColor(W25)
            .borderRadius(12)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          Blank()
          Text(this.next.sectionText).fontSize(13).fontColor(W65)
        }
        .width('100%')

        Text(this.next.name)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(W100)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 14 })

        Text(this.next.countdownText)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(W100)
          .margin({ top: 10 })
          .width('100%')

        Text(`${this.next.whenText}　${this.next.roomText}`)
          .fontSize(14)
          .fontColor(W85)
          .margin({ top: 6 })
          .width('100%')
        if (this.next.teacher.length > 0) {
          Text(this.next.teacher).fontSize(13).fontColor(W65).margin({ top: 2 }).width('100%')
        }
      } else {
        SymbolGlyph($r('sys.symbol.doc')).fontColor([C_PRIMARY]).fontSize(36)
        Text('暂无即将开始的课')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(W100)
          .margin({ top: 8 })
        Text('点右上角「课表」导入或查看')
          .fontSize(13)
          .fontColor(W65)
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(22)
    .alignItems(this.next.hasClass ? HorizontalAlign.Start : HorizontalAlign.Center)
    .borderRadius(24)
    .backgroundColor(this.next.ongoing ? C_ACCENT : C_PRIMARY)
  }

  /** 左下：今日课程时间线 */
  @Builder
  todayList() {
    Column() {
      Row() {
        Text('今日课程').fontSize(16).fontWeight(FontWeight.Bold).fontColor(C_INK)
        Text(`第 ${this.week} 周`).fontSize(12).fontColor(C_SUB).margin({ left: 8 })
        Blank()
        Text(`${this.today.length} 门`).fontSize(12).fontColor(C_MUTE)
      }
      .width('100%')

      if (this.today.length === 0) {
        Text('今天无课')
          .fontSize(14)
          .fontColor(C_MUTE)
          .margin({ top: 18, bottom: 8 })
      } else {
        ForEach(this.today, (it: CourseItem) => {
          Row() {
            Column()
              .width(4)
              .height(40)
              .borderRadius(2)
              .backgroundColor(courseColor(it.name))
              .opacity(this.isPast(it) ? 0.35 : 1)
            Column() {
              Text(it.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isPast(it) ? C_MUTE : C_INK)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${it.room.length > 0 ? it.room : '待定'} · 第 ${it.startSection}-${it.endSection} 节`)
                .fontSize(12)
                .fontColor(C_SUB)
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })
            Text(this.hm(sectionStartTime(it.startSection)))
              .fontSize(13)
              .fontColor(this.isPast(it) ? C_MUTE : C_SUB)
          }
          .width('100%')
          .margin({ top: 12 })
        }, (it: CourseItem): string => `t${it.id}`)
      }
    }
    .width('100%')
    .padding(20)
    .borderRadius(24)
    .backgroundColor(C_SURFACE)
    .alignItems(HorizontalAlign.Start)
  }

  /** 右上：当前选中日程（与桌面卡片同款渐变） */
  @Builder
  scheduleHero() {
    Column() {
      if (this.snapshot.hasData) {
        Row() {
          SymbolGlyph($r('sys.symbol.calendar')).fontColor([C_PRIMARY]).fontSize(14)
          Text(this.snapshot.title)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(W100)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 6 })
            .layoutWeight(1)
        }
        .width('100%')

        Row() {
          Text(this.snapshot.daysLeft > 0 ? '还剩' : (this.snapshot.daysLeft === 0 ? '就是' : ''))
            .fontSize(14)
            .fontColor(W65)
            .margin({ right: 6, bottom: 12 })
          Text(this.snapshot.daysText)
            .fontSize(this.snapshot.daysLeft > 0 ? 64 : 40)
            .fontWeight(FontWeight.Bold)
            .fontColor(W100)
            .maxLines(1)
          if (this.snapshot.daysLeft > 0) {
            Text('天').fontSize(18).fontColor(W85).margin({ left: 4, bottom: 12 })
          }
          Blank()
          Text(this.snapshot.dateText).fontSize(13).fontColor(W65).margin({ bottom: 12 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 6 })

        this.progressBar('本周已过', this.snapshot.weekPercent)
        Column().height(10)
        this.progressBar('整体进度', this.snapshot.progressPercent)
      } else {
        SymbolGlyph($r('sys.symbol.calendar')).fontColor([C_PRIMARY]).fontSize(36)
        Text('还没有日程').fontSize(18).fontWeight(FontWeight.Medium).fontColor(W100).margin({ top: 8 })
        Text('点右上「＋ 日程」创建第一个倒计时').fontSize(13).fontColor(W65).margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(22)
    .borderRadius(24)
    .alignItems(this.snapshot.hasData ? HorizontalAlign.Start : HorizontalAlign.Center)
    .backgroundColor(urgencyColor(this.snapshot.daysLeft, this.snapshot.hasData))
    .accessibilityText('打开日程手账，查看全部日程、待办和日记')
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/Planner' });
    })
  }

  @Builder
  scheduleRow(item: Schedule) {
    Row() {
      Column()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(this.dotColor(calcDaysLeft(item.targetDate, Date.now())))

      Column() {
        Text(item.title)
          .fontSize(16)
          .fontWeight(item.id === this.activeId ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(C_INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.dateOf(item.targetDate)} · ${this.shortDays(calcDaysLeft(item.targetDate, Date.now()))}`)
          .fontSize(12)
          .fontColor(C_SUB)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14 })
      .onClick(() => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/Planner' });
      })

      if (item.id === this.activeId) {
        Text('卡片显示中')
          .fontSize(11)
          .fontColor(C_PRIMARY)
          .backgroundColor(C_PRIMARY_SOFT)
          .borderRadius(10)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .margin({ right: 4 })
      }

      Image($r('sys.media.ohos_ic_public_edit'))
        .fillColor(C_SUB)
        .width(40)
        .height(40)
        .onClick(() => {
          this.openEditor(item);
        })
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(20).fontColor([C_SUB])
        .width(40)
        .height(40)
        .onClick(() => {
          this.confirmDeleteId = item.id;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 6, top: 8, bottom: 8 })
    .borderRadius(16)
    .backgroundColor(item.id === this.activeId ? C_PRIMARY_SOFT : C_SURFACE)
  }

  @Builder
  topBar() {
    Row() {
      Column({ space: 4 }) {
        Text(this.dateTitle()).fontSize(42).fontWeight(FontWeight.Bold).fontColor(C_INK)
        Text(`第 ${this.week} 周`).fontSize(20).fontColor(C_SUB)
      }.alignItems(HorizontalAlign.Start)
      Blank()
      Button() {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.calendar')).fontSize(24).fontColor([C_PRIMARY])
          Text('课表').fontSize(23).fontWeight(FontWeight.Medium).fontColor(C_PRIMARY)
        }
      }.id('home-courses').height(60).padding({ left: 24, right: 24 })
        .backgroundColor(C_PRIMARY_SOFT).borderRadius(30).margin({ right: 14 })
        .accessibilityText('打开课表')
        .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/CourseTable' }); })
      Button() {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.book_pages')).fontSize(24).fontColor([C_PRIMARY])
          Text('背单词').fontSize(23).fontWeight(FontWeight.Medium).fontColor(C_PRIMARY)
        }
      }.id('home-wordbook').height(60).padding({ left: 24, right: 24 })
        .backgroundColor(C_PRIMARY_SOFT).borderRadius(30).margin({ right: 14 })
        .accessibilityText('打开背单词')
        .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Wordbook' }); })
      Button() {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(24).fontColor([W100])
          Text('日程').fontSize(23).fontWeight(FontWeight.Medium).fontColor(W100)
        }
      }.id('home-add-schedule').height(60).padding({ left: 24, right: 24 })
        .backgroundColor(C_PRIMARY).borderRadius(30).accessibilityText('新增日程')
        .onClick(() => { this.openEditor(null); })
    }.width('100%')
  }

  @Builder
  homeSchedule() {
    Column() {
      Row() {
        Text(this.snapshot.hasData ? this.snapshot.title : '日程')
          .fontSize(38).fontWeight(FontWeight.Bold).fontColor(C_INK)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(24).fontColor([C_SUB])
      }.width('100%')
      if (this.snapshot.hasData) {
        Text(this.snapshot.daysLeft > 0 ? '还剩' : (this.snapshot.daysLeft === 0 ? '就是' : ''))
          .fontSize(23).fontColor(C_SUB).margin({ top: 22 }).width('100%')
        Row({ space: 8 }) {
          Text(this.snapshot.daysText).fontSize(this.snapshot.daysLeft > 0 ? 144 : 54)
            .fontWeight(FontWeight.Bold).fontColor(C_PRIMARY)
            .maxLines(1).minFontSize(38).maxFontSize(this.snapshot.daysLeft > 0 ? 144 : 54)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.snapshot.daysLeft > 0) {
            Text('天').fontSize(38).fontWeight(FontWeight.Medium).fontColor(C_PRIMARY).margin({ bottom: 20 })
          }
        }.width('100%').alignItems(VerticalAlign.Bottom)
        Text(this.snapshot.dateText).fontSize(23).fontColor(C_SUB).width('100%').margin({ top: 4 })
      } else {
        Text('暂无日程').fontSize(30).fontColor(C_SUB).margin({ top: 28 }).width('100%')
      }
    }.id('home-schedule').width('100%').alignItems(HorizontalAlign.Start)
      .accessibilityText('打开全部日程、待办与记录')
      .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Planner' }); })
  }

  private homeCourseWhen(): string {
    const date: Date = new Date(this.next.startAt);
    const relative: string = this.next.whenText.startsWith('今天') ? '今天 ' :
      (this.next.whenText.startsWith('明天') ? '明天 ' : (this.next.whenText.startsWith('后天') ? '后天 ' : ''));
    return `${relative}${date.getMonth() + 1}月${date.getDate()}日 周${WEEK_NAMES[date.getDay()]} ${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  }

  @Builder
  homeNextCourse() {
    Column() {
      Text(this.next.ongoing ? '正在上课' : '下一节课').fontSize(22).fontColor(C_SUB).width('100%')
      if (this.next.hasClass) {
        Row({ space: 12 }) {
          Text(this.next.name).fontSize(42).fontWeight(FontWeight.Bold).fontColor(C_INK)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(24).fontColor([C_SUB])
        }.width('100%').margin({ top: 20 })
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.calendar')).fontSize(24).fontColor([C_SUB])
            Text(this.homeCourseWhen()).fontSize(22).fontColor(C_SUB)
          }.margin({ right: 20, bottom: 8 })
          Row({ space: 10 }) {
            Image($r('sys.media.ohos_ic_public_location')).width(24).height(24).fillColor(C_ACCENT)
            Text(this.next.roomText.length > 0 ? this.next.roomText : '地点待定')
              .fontSize(22).fontColor(C_SUB).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.margin({ right: 20, bottom: 8 })
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.doc')).fontSize(24).fontColor([C_SUB])
            Text(this.next.sectionText).fontSize(22).fontColor(C_SUB)
          }.margin({ bottom: 8 })
        }.width('100%').margin({ top: 24 })
      } else {
        Text('暂无课程').fontSize(32).fontColor(C_SUB).margin({ top: 20 }).width('100%')
      }
    }.id('home-next-course').width('100%').alignItems(HorizontalAlign.Start)
      .accessibilityText('打开课程表')
      .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/CourseTable' }); })
  }

  @Builder
  homeOtherSchedules() {
    Column() {
      Text('其他日程').fontSize(22).fontColor(C_SUB).width('100%')
      if (this.remainingSchedules().length === 0) {
        Text('暂无其他日程').fontSize(21).fontColor(C_SUB).margin({ top: 16 }).width('100%')
      } else {
        ForEach(this.remainingSchedules(), (item: Schedule) => {
          Column({ space: 6 }) {
            Row({ space: 10 }) {
              Text(item.title).fontSize(24).fontWeight(FontWeight.Medium).fontColor(C_INK)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(20).fontColor([C_SUB])
            }.width('100%')
            Text(`${this.dateOf(item.targetDate)} · ${this.shortDays(calcDaysLeft(item.targetDate, Date.now()))}`)
              .fontSize(20).fontColor(C_SUB).width('100%')
          }.width('100%').padding({ top: 16, bottom: 14 }).alignItems(HorizontalAlign.Start)
            .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Planner' }); })
          Divider().color(C_LINE)
        }, (item: Schedule): string => `home-other-${item.id}`)
      }
    }.id('home-other-schedules').width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  homeTodoPreview() {
    Column() {
      Row() {
        Text('待办').fontSize(22).fontColor(C_SUB).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(20).fontColor([C_SUB])
      }.width('100%').constraintSize({ minHeight: 40 })
        .accessibilityText('打开全部待办')
        .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Planner' }); })
      if (this.homeTodoError.length > 0) {
        Button('重试读取待办').fontSize(20).fontColor(C_DANGER).backgroundColor(C_BG)
          .onClick(() => { this.reloadHomeTodos(); })
      } else if (this.homeTodos.length === 0) {
        Text('暂无待办').fontSize(24).fontColor(C_SUB).margin({ top: 12 }).width('100%')
      } else {
        ForEach(this.homeTodos, (todo: Todo) => {
          Column({ space: 6 }) {
            Row({ space: 12 }) {
              Text(todo.title).fontSize(24).fontWeight(FontWeight.Medium).fontColor(C_INK)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Text(starsText(todo.stars)).fontSize(22).fontColor('#A87518').letterSpacing(-1)
                .accessibilityText(`重要程度 ${todo.stars} 星`)
            }.width('100%')
            Text(this.homeTodoRule(todo)).fontSize(20).fontColor(todo.nextDay < dayOf(new Date()) ? C_DANGER : C_SUB)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.width('100%').padding({ top: 12, bottom: 14 }).alignItems(HorizontalAlign.Start)
            .accessibilityText(`打开待办：${todo.title}`)
            .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Planner' }); })
          Divider().color(C_LINE)
        }, (todo: Todo): string => `home-todo-${todo.id}`)
      }
    }.id('home-todo-preview').width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 右栏：本周概览，每天一行，今天高亮 */
  @Builder
  weekOverview() {
    Column() {
      Row() {
        Text('本周概览').fontSize(16).fontWeight(FontWeight.Bold).fontColor(C_INK)
        Text(`第 ${this.week} 周`).fontSize(12).fontColor(C_SUB).margin({ left: 8 })
      }
      .width('100%')

      ForEach(['一', '二', '三', '四', '五', '六', '日'], (n: string, idx: number) => {
        Row() {
          Text(`周${n}`)
            .fontSize(13)
            .fontWeight(this.isTodayIdx(idx) ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.isTodayIdx(idx) ? C_PRIMARY : C_SUB)
            .width(34)
          Text(this.weekNames[idx].length > 0 ? this.weekNames[idx] : '—')
            .fontSize(13)
            .fontColor(this.weekNames[idx].length > 0 ? C_INK : C_MUTE)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 9, bottom: 9 })
        .margin({ top: 6 })
        .borderRadius(12)
        .backgroundColor(this.isTodayIdx(idx) ? C_PRIMARY_SOFT : '#00000000')
        .alignItems(VerticalAlign.Top)
      }, (n: string): string => `w${n}`)
    }
    .width('100%')
    .padding(20)
    .borderRadius(24)
    .backgroundColor(C_SURFACE)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  leftColumn() {
    Scroll() {
      Column() {
        this.nextClassCard()
        Column().height(16)
        this.todayList()
      }
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  @Builder
  rightColumn() {
    Column() {
      this.scheduleHero()

      Row() {
        Text('日程倒计时').fontSize(16).fontWeight(FontWeight.Bold).fontColor(C_INK)
        Blank()
        Text(`${this.schedules.length} 个`).fontSize(12).fontColor(C_MUTE)
      }
      .width('100%')
      .margin({ top: 18 })

      if (!this.formOnDesktop) {
        Row() {
          SymbolGlyph($r('sys.symbol.lightbulb')).fontColor([C_PRIMARY]).fontSize(15)
          Text('长按桌面上的应用图标，选择「服务卡片」即可添加')
            .fontSize(12)
            .fontColor(C_WARN_INK)
            .layoutWeight(1)
            .margin({ left: 8 })
        }
        .width('100%')
        .padding(12)
        .borderRadius(12)
        .backgroundColor(C_WARN_BG)
        .margin({ top: 10 })
      }

      if (this.schedules.length === 0) {
        Column() {
          Text('暂无日程').fontSize(15).fontColor(C_MUTE)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.schedules, (item: Schedule) => {
            ListItem() {
              this.scheduleRow(item)
            }
          }, (item: Schedule): string => item.id)
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ top: 10 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  editorDialog() {
    Column() {
      Text(this.editingId.length > 0 ? '编辑日程' : '新增日程')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_INK)
        .width('100%')

      TextInput({ placeholder: '日程标题，如：期末考试', text: this.draftTitle })
        .maxLength(30)
        .height(48)
        .margin({ top: 16 })
        .onChange((v: string) => {
          this.draftTitle = v;
        })

      Text('目标日期').fontSize(14).fontColor(C_SUB).width('100%').margin({ top: 16 })
      DatePicker({
        start: new Date('2020-01-01'),
        end: new Date('2100-12-31'),
        selected: this.draftDate
      })
        .onDateChange((v: Date) => {
          this.draftDate = v;
        })

      Row() {
        Button('取消')
          .fontColor(C_INK)
          .backgroundColor(C_BG)
          .layoutWeight(1)
          .height(44)
          .onClick(() => {
            this.showEditor = false;
          })
        Button('保存')
          .fontColor(W100)
          .backgroundColor(this.draftTitle.trim().length > 0 ? C_PRIMARY : C_DISABLED)
          .layoutWeight(1)
          .height(44)
          .margin({ left: 12 })
          .onClick(() => {
            this.saveEditor();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width(420)
    .padding(24)
    .borderRadius(24)
    .backgroundColor(C_SURFACE)
  }

  @Builder
  confirmDialog() {
    Column() {
      Text('删除这个日程？').fontSize(18).fontWeight(FontWeight.Bold).fontColor(C_INK)
      Text('删除后桌面卡片会同步更新，无法恢复。')
        .fontSize(14)
        .fontColor(C_SUB)
        .margin({ top: 8 })
      Row() {
        Button('取消')
          .fontColor(C_INK)
          .backgroundColor(C_BG)
          .layoutWeight(1)
          .onClick(() => {
            this.confirmDeleteId = '';
          })
        Button('删除')
          .fontColor(W100)
          .backgroundColor(C_DANGER)
          .layoutWeight(1)
          .margin({ left: 12 })
          .onClick(() => {
            this.deleteItem(this.confirmDeleteId);
          })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .width(340)
    .padding(24)
    .borderRadius(24)
    .backgroundColor(C_SURFACE)
  }

  build() {
    Stack() {
      Column() {
        this.topBar()

        Scroll() {
          Row({ space: 34 }) {
            Column() {
              this.homeSchedule()
              Divider().color(C_LINE).margin({ top: 26, bottom: 24 })
              this.homeOtherSchedules()
            }.width('35%').padding({ right: 34 }).alignItems(HorizontalAlign.Start)
              .border({ width: { right: 1 }, color: C_LINE })
              .constraintSize({ minHeight: 310 })
            Column() {
              this.homeNextCourse()
              Divider().color(C_LINE).margin({ top: 28, bottom: 26 })
              this.homeTodoPreview()
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').alignItems(VerticalAlign.Top)
        }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
          .margin({ top: 60 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: 24, left: 44, right: 36, bottom: 24 })

      if (this.showEditor || this.confirmDeleteId.length > 0) {
        // 遮罩 + 居中弹层
        Column() {
          if (this.showEditor) {
            this.editorDialog()
          } else {
            this.confirmDialog()
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(C_SCRIM)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    // 让米白背景延伸进状态栏 / 导航栏区域，消除上下白边
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
