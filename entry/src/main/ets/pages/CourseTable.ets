/**
 * 周视图课表页
 *
 * 网格：每天一列（Stack），课程按「起始节次 × 行高」绝对定位，连堂课天然是一整块；
 * 同一时段有多门课时按「车道」并排显示，每门都能点开。
 * 颜色按课程名稳定哈希（见 common/Theme.ets），颜色一律 #AARRGGBB。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  CourseItem, CourseTable, NextClass, calcNextClass,
  sectionEndTime, sectionStartTime, startOfToday, startOfWeek, toDateKey, weekOfTerm
} from '../model/Course';
import { CourseStore } from '../model/CourseStore';
import {
  C_BG, C_SURFACE, C_INK, C_SUB, C_MUTE, C_LINE, C_PRIMARY, C_PRIMARY_SOFT,
  C_WARN_BG, C_WARN_INK, C_SCRIM, W100, courseColor, courseTint
} from '../common/Theme';

const TAG: string = 'CourseTable';
const DOMAIN: number = 0xFF00;
const MS_PER_DAY: number = 86400000;
const SECTIONS: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
const DAYS: number[] = [1, 2, 3, 4, 5, 6, 7];
const DAY_NAMES: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const ROW_H: number = 64;
const TIME_W: number = 56;
const MAX_WEEK: number = 25;

/** 一块已排好位置的课程：lane/lanes 表示同一时段并排时的第几列/共几列 */
class Placed {
  item: CourseItem = new CourseItem();
  lane: number = 0;
  lanes: number = 1;
}

@Entry
@Component
struct CourseTablePage {
  @State table: CourseTable = new CourseTable();
  @State week: number = 1;
  @State loaded: boolean = false;
  @State next: NextClass = new NextClass();
  @State selId: string = '';
  @State selName: string = '';
  @State selInfo: string = '';
  @State selDate: string = '';
  @State selNature: string = '';
  @State memoDraft: string = '';
  @State dayMemoDraft: string = '';
  @State showTermPicker: boolean = false;
  @State termDate: Date = new Date();
  /**
   * 数据版本号：每次 reload 自增。
   * ForEach 的 key 只由 item.id（课名|星期|起始节|周次）构成，备注变化不会改 key，
   * 于是 ArkUI 会复用旧组件、onClick 闭包仍指向旧的 item —— 表现为「备注保存后不生效，退出重进才好」。
   */
  @State dataVersion: number = 0;
  private store: CourseStore | null = null;
  private selItem: CourseItem | null = null;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new CourseStore(ctx);
    this.reload();
  }

  private async reload(): Promise<void> {
    const store: CourseStore = this.store!;
    let t: CourseTable = await store.load();
    if (t.items.length === 0) {
      // 首次使用：导入随包内置的课表（由教务系统导出 PDF 解析而来）
      t = await store.importBundled();
    } else {
      // 已有数据：用内置课表的开学日纠正基准周次（用户手动设过则跳过）
      const fixed: boolean = await store.syncBundledTermStart();
      if (fixed) {
        t = await store.load();
      }
    }
    this.table = t;
    this.dataVersion = this.dataVersion + 1;
    const now: number = Date.now();
    this.week = weekOfTerm(this.table, now);
    this.next = calcNextClass(this.table, now);
    this.loaded = true;
    hilog.info(DOMAIN, TAG, 'loaded=%{public}d week=%{public}d',
      this.table.items.length, this.week);
  }

  /**
   * 某天、当前周要显示的课程，并算好并排车道。
   * 每次渲染现算（二十来门课，开销可忽略），避免切周后缓存过期。
   */
  private blocksOf(day: number): Placed[] {
    const list: CourseItem[] = [];
    for (let i = 0; i < this.table.items.length; i++) {
      const it: CourseItem = this.table.items[i];
      if (it.dayOfWeek !== day || it.weekList === null || it.weekList === undefined) {
        continue;
      }
      if (it.weekList.indexOf(this.week) >= 0) {
        list.push(it);
      }
    }
    list.sort((a: CourseItem, b: CourseItem): number =>
      a.startSection !== b.startSection ? a.startSection - b.startSection : a.endSection - b.endSection);

    const out: Placed[] = [];
    let clusterStart: number = 0;       // 当前簇在 out 里的起点
    let clusterEnd: number = 0;         // 当前簇已覆盖到的最大节次
    let laneEnds: number[] = [];        // 每条车道当前占用到第几节
    for (let i = 0; i < list.length; i++) {
      const it: CourseItem = list[i];
      if (out.length > clusterStart && it.startSection > clusterEnd) {
        // 与上一簇不重叠：结算上一簇的车道数
        for (let k = clusterStart; k < out.length; k++) {
          out[k].lanes = laneEnds.length;
        }
        clusterStart = out.length;
        laneEnds = [];
      }
      let lane: number = -1;
      for (let l = 0; l < laneEnds.length; l++) {
        if (laneEnds[l] < it.startSection) {
          lane = l;
          break;
        }
      }
      if (lane < 0) {
        laneEnds.push(it.endSection);
        lane = laneEnds.length - 1;
      } else {
        laneEnds[lane] = it.endSection;
      }
      if (out.length === clusterStart) {
        clusterEnd = it.endSection;
      } else if (it.endSection > clusterEnd) {
        clusterEnd = it.endSection;
      }
      const p: Placed = new Placed();
      p.item = it;
      p.lane = lane;
      out.push(p);
    }
    for (let k = clusterStart; k < out.length; k++) {
      out[k].lanes = laneEnds.length;
    }
    return out;
  }

  /** 第 week 周星期 day 对应的日期（毫秒） */
  private dateOf(week: number, day: number): number {
    const base: number = startOfToday(this.table.termStart);
    return base + ((week - 1) * 7 + (day - 1)) * MS_PER_DAY;
  }

  private weekHasClass(): boolean {
    for (let i = 0; i < this.table.items.length; i++) {
      const it: CourseItem = this.table.items[i];
      if (it.weekList !== null && it.weekList.indexOf(this.week) >= 0) {
        return true;
      }
    }
    return false;
  }

  private hm(minutes: number): string {
    const h: number = Math.floor(minutes / 60);
    const m: number = minutes % 60;
    return `${h < 10 ? `0${h}` : `${h}`}:${m < 10 ? `0${m}` : `${m}`}`;
  }

  private sectionTime(sec: number): string {
    return `${this.hm(sectionStartTime(sec))}-${this.hm(sectionEndTime(sec))}`;
  }

  /** 该周某天的日期标签，如 "9-28" */
  private dateLabel(day: number): string {
    if (this.table.termStart <= 0) {
      return '';
    }
    const d: Date = new Date(this.dateOf(this.week, day));
    return `${d.getMonth() + 1}-${d.getDate()}`;
  }

  private isToday(day: number): boolean {
    if (this.table.termStart <= 0) {
      return false;
    }
    return startOfToday(this.dateOf(this.week, day)) === startOfToday(Date.now());
  }

  private openDetail(it: CourseItem): void {
    this.selItem = it;
    this.selId = it.id;
    this.selName = it.name;
    const parts: string[] = [];
    if (it.teacher.length > 0) {
      parts.push(it.teacher);
    }
    if (it.room.length > 0) {
      parts.push(it.room);
    }
    parts.push(`周${DAY_NAMES[it.dayOfWeek - 1]} 第${it.startSection}-${it.endSection}节`);
    parts.push(it.weeksText);
    this.selInfo = parts.join(' · ');
    const tags: string[] = [];
    if (it.nature.length > 0) {
      tags.push(it.nature);
    }
    if (it.credit.length > 0) {
      tags.push(`${it.credit} 学分`);
    }
    this.selNature = tags.join(' · ');

    const dk: string = toDateKey(this.dateOf(this.week, it.dayOfWeek));
    this.selDate = dk;
    this.memoDraft = it.memo ?? '';
    const dm: Record<string, string> = it.dayMemos ?? {};
    this.dayMemoDraft = dm[dk] ?? '';
  }

  private closeDetail(): void {
    this.selId = '';
    this.selItem = null;
  }

  private async saveMemos(): Promise<void> {
    if (this.selItem === null) {
      return;
    }
    const store: CourseStore = this.store!;
    await store.updateMemo(this.selId, this.memoDraft);
    if (this.selDate.length > 0) {
      await store.updateDayMemo(this.selId, this.selDate, this.dayMemoDraft);
    }
    const keepWeek: number = this.week;
    await this.reload();
    this.week = keepWeek;      // 保存备注不应把用户正在看的周翻回本周
    this.closeDetail();
  }

  /** 保存学期第 1 周周一（自动对齐到当周周一） */
  private async saveTermStart(): Promise<void> {
    const store: CourseStore = this.store!;
    await store.setTermStart(startOfWeek(this.termDate.getTime()));
    this.showTermPicker = false;
    await this.reload();
  }

  private termLabel(): string {
    if (this.table.termStart <= 0) {
      return '';
    }
    return toDateKey(this.table.termStart).substring(5);
  }

  // ---------------------------- UI ----------------------------

  @Builder
  headerBar() {
    Row() {
      Text('‹')
        .fontSize(28)
        .fontColor(C_INK)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })

      Button() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.week > 1 ? C_PRIMARY : C_MUTE])
          .rotate({ angle: 180 })
      }
        .id('course-prev-week')
        .accessibilityText('上一周')
        .padding(0)
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(C_PRIMARY_SOFT)
        .margin({ left: 8 })
        .onClick(() => {
          if (this.week > 1) {
            this.week = this.week - 1;
          }
        })
      Text(`第 ${this.week} 周`)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_INK)
        .margin({ left: 12, right: 12 })
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([this.week < MAX_WEEK ? C_PRIMARY : C_MUTE])
      }
        .id('course-next-week')
        .accessibilityText('下一周')
        .padding(0)
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(C_PRIMARY_SOFT)
        .onClick(() => {
          if (this.week < MAX_WEEK) {
            this.week = this.week + 1;
          }
        })
      Text('回到本周')
        .fontSize(13)
        .fontColor(C_PRIMARY)
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .borderRadius(16)
        .backgroundColor(C_PRIMARY_SOFT)
        .margin({ left: 12 })
        .onClick(() => {
          this.week = weekOfTerm(this.table, Date.now());
        })

      Blank()

      Text(this.table.termStart > 0 ? `开学 ${this.termLabel()}` : '设置开学日')
        .fontSize(13)
        .fontColor(C_SUB)
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .borderRadius(16)
        .backgroundColor(C_SURFACE)
        .margin({ right: 8 })
        .onClick(() => {
          if (this.table.termStart > 0) {
            this.termDate = new Date(this.table.termStart);
          }
          this.showTermPicker = true;
        })
      Button('导入 / 刷新')
        .fontSize(14)
        .height(36)
        .borderRadius(18)
        .backgroundColor(C_PRIMARY)
        .fontColor(W100)
        .onClick(() => {
          router.pushUrl({ url: 'pages/CourseImport' });
        })
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 10, bottom: 6 })
  }

  @Builder
  nextBanner() {
    Row() {
      Text(this.next.ongoing ? '正在上课' : '下一节')
        .fontSize(12)
        .fontColor(C_PRIMARY)
        .backgroundColor(C_PRIMARY_SOFT)
        .borderRadius(10)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      if (this.next.hasClass) {
        Text(this.next.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 10 })
          .flexShrink(1)
        Text(`${this.next.countdownText} · ${this.next.whenText} · ${this.next.roomText}`)
          .fontSize(12)
          .fontColor(C_SUB)
          .maxLines(1)
          .margin({ left: 10 })
      } else {
        Text('暂无课程数据 —— 点右上角「导入 / 刷新」')
          .fontSize(12)
          .fontColor(C_WARN_INK)
          .margin({ left: 10 })
      }
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  gridHead() {
    Row() {
      Text('').width(TIME_W)
      ForEach(DAYS, (d: number) => {
        Column() {
          Text(`周${DAY_NAMES[d - 1]}`)
            .fontSize(13)
            .fontWeight(this.isToday(d) ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.isToday(d) ? W100 : C_INK)
          Text(this.dateLabel(d))
            .fontSize(11)
            .fontColor(this.isToday(d) ? '#D9FFFFFF' : C_MUTE)
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .padding({ top: 6, bottom: 6 })
        .margin({ left: 2, right: 2 })
        .backgroundColor(this.isToday(d) ? C_PRIMARY : '#00000000')
        .borderRadius(10)
      }, (d: number) => `h${d}`)
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }

  /** 左侧节次列：节号 + 起止时间 */
  @Builder
  timeColumn() {
    Column() {
      ForEach(SECTIONS, (sec: number) => {
        Column() {
          Text(`${sec}`).fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_SUB)
          Text(this.hm(sectionStartTime(sec))).fontSize(9).fontColor(C_MUTE).margin({ top: 2 })
          Text(this.hm(sectionEndTime(sec))).fontSize(9).fontColor(C_MUTE)
        }
        .width(TIME_W)
        .height(ROW_H)
        .justifyContent(FlexAlign.Center)
      }, (sec: number) => `tc${sec}`)
    }
  }

  /** 一天的一列：背景分隔线 + 绝对定位的课程块 */
  @Builder
  dayColumn(d: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        ForEach(SECTIONS, (sec: number) => {
          Row()
            .width('100%')
            .height(ROW_H)
            .border({ width: { bottom: sec === 5 || sec === 9 ? 1 : 0.5 }, color: C_LINE })
        }, (sec: number) => `g${d}-${sec}`)
      }
      .width('100%')

      ForEach(this.blocksOf(d), (p: Placed) => {
        Column() {
          Row() {
            Column()
              .width(3)
              .height('100%')
              .borderRadius(2)
              .backgroundColor(courseColor(p.item.name))
            Column() {
              Text(p.item.name)
                .fontSize(p.lanes > 1 ? 10 : 12)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_INK)
                .maxLines(p.lanes > 1 ? 4 : 3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (p.item.room.length > 0) {
                Text(p.item.room)
                  .fontSize(p.lanes > 1 ? 9 : 10)
                  .fontColor(C_SUB)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 5, right: 2 })
          }
          .width('100%')
          .height('100%')
          .padding({ left: 2, top: 4, bottom: 4, right: 2 })
          .borderRadius(8)
          .backgroundColor(courseTint(p.item.name))
          .border({
            width: p.item.id === this.selId ? 2 : 0,
            color: courseColor(p.item.name)
          })
          .onClick(() => {
            this.openDetail(p.item);
          })
        }
        .width(`${100 / p.lanes}%`)
        .height((p.item.endSection - p.item.startSection + 1) * ROW_H)
        .padding(1.5)
        .position({
          x: `${p.lane * 100 / p.lanes}%`,
          y: (p.item.startSection - 1) * ROW_H
        })
      }, (p: Placed): string => `b${this.dataVersion}-${this.week}-${p.item.id}`)
    }
    .layoutWeight(1)
    .height(ROW_H * SECTIONS.length)
    .margin({ left: 2, right: 2 })
    .backgroundColor(this.isToday(d) ? '#142F6F5E' : '#00000000')
    .borderRadius(8)
  }

  @Builder
  detailPanel() {
    Column() {
      Row() {
        Column()
          .width(6)
          .height(22)
          .borderRadius(3)
          .backgroundColor(courseColor(this.selName))
        Text(this.selName)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_INK)
          .margin({ left: 10 })
          .layoutWeight(1)
          .maxLines(2)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([C_SUB])
          .width(36)
          .height(36)
          .accessibilityText('关闭课程详情')
          .onClick(() => {
            this.closeDetail();
          })
      }
      .width('100%')

      Text(this.selInfo).fontSize(13).fontColor(C_SUB).margin({ top: 6 }).width('100%')
      if (this.selNature.length > 0) {
        Text(this.selNature)
          .fontSize(12)
          .fontColor(courseColor(this.selName))
          .backgroundColor(courseTint(this.selName))
          .borderRadius(10)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .margin({ top: 8 })
      }

      Text('课程备注（每次上课都显示）').fontSize(12).fontColor(C_SUB)
        .margin({ top: 14 }).width('100%')
      TextArea({ text: this.memoDraft, placeholder: '如：要带实验报告' })
        .height(92).fontSize(16).placeholderFont({ size: 16 }).width('100%')
        .onChange((v: string) => {
          this.memoDraft = v;
        })

      Text(`本次课备忘（${this.selDate}）`).fontSize(12).fontColor(C_SUB)
        .margin({ top: 10 }).width('100%')
      TextArea({ text: this.dayMemoDraft, placeholder: '如：下节课小测' })
        .height(76).fontSize(16).placeholderFont({ size: 16 }).width('100%')
        .onChange((v: string) => {
          this.dayMemoDraft = v;
        })

      Button('保存')
        .width('100%').height(44).borderRadius(22).margin({ top: 16 })
        .backgroundColor(C_PRIMARY).fontColor(W100)
        .onClick(() => {
          this.saveMemos();
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(C_SURFACE)
    .borderRadius(24)
  }

  /** 右侧常驻详情栏的空态 */
  @Builder
  detailEmpty() {
    Column() {
      SymbolGlyph($r('sys.symbol.hand_tap')).fontSize(32).fontColor([C_PRIMARY])
      Text('点选一门课').fontSize(16).fontWeight(FontWeight.Medium).fontColor(C_INK).margin({ top: 8 })
      Text('在这里查看详情，写课程备注和本次备忘')
        .fontSize(12)
        .fontColor(C_SUB)
        .margin({ top: 4 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(C_SURFACE)
    .borderRadius(24)
    .justifyContent(FlexAlign.Center)
    .height(220)
  }

  @Builder
  termPicker() {
    Column() {
      Text('设置学期第 1 周周一').fontSize(17).fontWeight(FontWeight.Bold).fontColor(C_INK)
      Text('课表按周次排课，需要知道开学日才能算出今天是第几周')
        .fontSize(12).fontColor(C_SUB).margin({ top: 4 })
      DatePicker({
        start: new Date('2020-01-01'),
        end: new Date('2030-12-31'),
        selected: this.termDate
      })
        .onDateChange((v: Date) => {
          this.termDate = v;
        })
      Row() {
        Button('取消')
          .layoutWeight(1).height(44).borderRadius(22)
          .backgroundColor(C_BG).fontColor(C_INK)
          .onClick(() => {
            this.showTermPicker = false;
          })
        Button('保存')
          .layoutWeight(1).height(44).borderRadius(22).margin({ left: 10 })
          .backgroundColor(C_PRIMARY).fontColor(W100)
          .onClick(() => {
            this.saveTermStart();
          })
      }
      .width('100%').margin({ top: 10 })
    }
    .width('100%').padding(20).backgroundColor(C_SURFACE)
    .borderRadius({ topLeft: 24, topRight: 24 })
    .onClick(() => {
      // 吞掉点击，避免冒泡到遮罩把面板关掉
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Row() {
      Column() {
        this.headerBar()
        this.nextBanner()

        if (!this.loaded) {
          Text('加载中…').fontSize(14).fontColor(C_SUB).margin({ top: 40 })
        } else if (this.table.items.length === 0) {
          Column() {
            SymbolGlyph($r('sys.symbol.doc')).fontSize(40).fontColor([C_SUB])
            Text('还没有课表数据').fontSize(18).fontWeight(FontWeight.Medium).fontColor(C_INK)
              .margin({ top: 8 })
            Text('点右上角「导入 / 刷新」，在应用内登录教务系统后抓取')
              .fontSize(13).fontColor(C_SUB).margin({ top: 6 })
          }
          .width('100%').margin({ top: 60 })
        } else {
          this.gridHead()
          if (!this.weekHasClass()) {
            Text(`第 ${this.week} 周没有课`)
              .fontSize(12)
              .fontColor(C_WARN_INK)
              .backgroundColor(C_WARN_BG)
              .borderRadius(10)
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .margin({ top: 6, bottom: 2 })
          }
          Scroll() {
            Row() {
              this.timeColumn()
              ForEach(DAYS, (d: number) => {
                this.dayColumn(d)
              }, (d: number) => `dc${d}`)
            }
            .width('100%')
            .padding({ left: 8, right: 8, bottom: 16 })
            .alignItems(VerticalAlign.Top)
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
        }
      }
      .layoutWeight(1)
      .height('100%')

      // 横屏常驻详情栏：点课程块在右边显示，不再弹层
      Scroll() {
        Column() {
          if (this.selId.length > 0) {
            this.detailPanel()
          } else {
            this.detailEmpty()
          }
        }
        .width('100%')
      }
      .width(320)
      .height('100%')
      .padding({ top: 12, right: 16, bottom: 16 })
      .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')

      // 注意：弹层条件必须用 @State（selId / showTermPicker），不能用普通字段 selItem
      if (this.showTermPicker) {
        Column() {
          Blank()
          this.termPicker()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(C_SCRIM)
        .onClick(() => {
          this.showTermPicker = false;
        })
      }
    }
    .width('100%')
    .height('100%')
    // 背景延伸进状态栏/导航栏，避免上下白边
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(C_BG)
  }
}
