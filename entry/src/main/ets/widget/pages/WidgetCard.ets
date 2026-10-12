/**
 * 服务卡片：日程倒计时
 *
 * 数据由 EntryFormAbility 经 formBindingData 推送，**全部为 string**
 * （卡片与提供方是独立进程，只能用 @LocalStorageProp 接收；不得使用 getContext / SymbolGlyph）。
 *
 * 展示：hasData === '1' 时整卡显示「日程倒计时」，否则空态引导。
 *   hasData   === '1' → 整卡显示「日程倒计时」
 * 注：早期版本有「下一节课」模式，按用户要求已改为只显示日程；课程字段与 placeLine() 已移除。
 *
 * ⚠️ 颜色一律 #AARRGGBB（透明度在前）。本文件自包含，不 import 主应用的 Theme。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct ScheduleCard {
  // ---- 日程组 ----
  @LocalStorageProp('hasData') hasData: string = '0';
  @LocalStorageProp('title') title: string = '暂无日程';
  @LocalStorageProp('daysText') daysText: string = '--';
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('weekPercentText') weekPercentText: string = '0%';
  @LocalStorageProp('progressPercentText') progressPercentText: string = '0%';
  @LocalStorageProp('daysLeftText') daysLeftText: string = '0';
  private daysLeft(): number {
    const n: number = Number(this.daysLeftText);
    return isNaN(n) ? 0 : n;
  }

  private percentOf(text: string): number {
    const n: number = Number(text.replace('%', ''));
    if (isNaN(n) || n < 0) {
      return 0;
    }
    return n > 100 ? 100 : n;
  }

  /** 天数前的说明语 */
  private caption(): string {
    const d: number = this.daysLeft();
    if (d > 0) {
      return '还剩';
    }
    return d === 0 ? '就是' : '';
  }

  /** 纯色底（暖纸手账风）：日程按紧迫度 */
  private bgColor(): string {
    if (this.hasData !== '1') {
      return '#8A8174';
    }
    const d: number = this.daysLeft();
    if (d < 0) {
      return '#9A948B';
    }
    return d <= 7 ? '#D9622B' : '#3D3A36';
  }

  build() {
    Column() {
      if (this.hasData === '1') {
        // ==================== 日程模式 ====================
        Row() {
          Image($r('sys.media.ohos_ic_normal_white_grid_calendar')).width(16).height(16)
          Text(this.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 6 })
            .layoutWeight(1)
        }
        .width('100%')

        Column() {
          Text(this.caption()).fontSize(12).fontColor('#A6FFFFFF')
          Row() {
            Text(this.daysText)
              .fontSize(this.daysLeft() > 0 ? 52 : 34)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .minFontSize(20)
              .maxFontSize(this.daysLeft() > 0 ? 52 : 34)
            if (this.daysLeft() > 0) {
              Text('天').fontSize(15).fontColor('#D9FFFFFF').margin({ left: 4, bottom: 8 })
            }
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .layoutWeight(1)
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)

        Row() {
          Text(this.dateText).fontSize(12).fontColor('#A6FFFFFF')
          Blank()
          Text(`本周 ${this.weekPercentText}`).fontSize(12).fontColor('#A6FFFFFF')
        }
        .width('100%')

        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(5).borderRadius(3).backgroundColor('#40FFFFFF')
          Row()
            .width(`${this.percentOf(this.weekPercentText)}%`)
            .height(5)
            .borderRadius(3)
            .backgroundColor('#FFFFFF')
        }
        .width('100%')
        .height(5)
        .margin({ top: 6 })
      } else {
        // ==================== 空态 ====================
        Column() {
          Image($r('sys.media.ohos_ic_normal_white_grid_calendar')).width(34).height(34)
          Text('还没有日程')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .margin({ top: 8 })
          Text('点击打开应用，添加日程')
            .fontSize(12)
            .fontColor('#A6FFFFFF')
            .margin({ top: 4 })
            .maxLines(2)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.bgColor())
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { targetPage: 'Index' }
      });
    })
  }
}
