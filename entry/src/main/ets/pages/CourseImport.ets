/**
 * 课表导入页 —— 内嵌正方教务系统登录 + 抓取课表
 *
 * 🔒 安全设计：账号密码在 Web 组件里**直接提交给学校服务器**，
 *    本应用既不读取也不存储密码；只复用 WebView 登录后的 session cookie。
 *    抓取用的是同源 fetch，因此不用处理正方的 RSA 密码加密、验证码和 CSRF token。
 *
 * 抓取链路：
 *   Web 加载教务系统 → 用户手动登录 → 点「抓取课表」
 *   → runJavaScript 注入 fetch 调 xskbcx_cxXsKb.html
 *   → 轮询 window.__kb.state → 取回 JSON → 打日志 + 存沙箱 + 解析
 */
import { webview } from '@kit.ArkWeb';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { CourseTable } from '../model/Course';
import { CourseStore } from '../model/CourseStore';
import { PORTAL_HOME, PORTAL_INDEX, JW_HOME, JW_HOST_KEY, KB_API_PATHS } from '../common/Campus';

const TAG: string = 'CourseImport';
const DOMAIN: number = 0xFF00;
/* 教务系统地址常量集中配置在 common/Campus.ets */
/** 日志分段长度：hilog 单条有长度上限，中文按 UTF-8 占 3 字节，280 字符较安全 */
const CHUNK: number = 280;
/** 最多打印多少段（避免刷爆日志） */
const MAX_CHUNKS: number = 130;
/**
 * 调试开关，**默认关闭**。
 * 打开后会把教务系统返回的原始 JSON 打进 hilog 并落盘到 filesDir/kb_raw.json，
 * 便于按真实字段结构校正解析器。原始返回可能包含学生个人信息，
 * 只在本机调试时临时打开，不要随发布版本开启。
 */
const DEBUG_DUMP_RAW: boolean = false;

@Entry
@Component
struct CourseImport {
  controller: webview.WebviewController = new webview.WebviewController();
  @State status: string = '① 在下方登录教务系统　② 登录成功后点「抓取课表」';
  @State xnm: string = '2026';
  @State xqm: string = '3';
  @State busy: boolean = false;
  @State parsedNames: string = '';

  private buildScript(): string {
    const body: string = `xnm=${this.xnm}&xqm=${this.xqm}&kzlx=ck`;
    const apiPaths: string = JSON.stringify(KB_API_PATHS);
    return `(function(){
      if (location.host.indexOf('${JW_HOST_KEY}') < 0) {
        return 'NOT_ON_JWGLXT';
      }
      // 接口路径来自 common/Campus.ets 的 KB_API_PATHS：
      // 教务系统的 context path 可能是根目录，也可能带 /jwglxt 前缀，逐个试。
      var paths = ${apiPaths};
      window.__kb = { state: 'PENDING', data: '', path: '', tried: [] };
      function tryNext(i) {
        if (i >= paths.length) {
          window.__kb.state = 'ERROR';
          window.__kb.data = 'ALL_FAILED ' + window.__kb.tried.join(' ');
          return;
        }
        var p = paths[i];
        window.__kb.tried.push(p);
        fetch(p, {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
          credentials: 'include',
          body: '${body}'
        }).then(function(r){ return r.text(); })
          .then(function(t){
            if (t.indexOf('页面不存在') >= 0 || t.indexOf('404.png') >= 0) {
              tryNext(i + 1);
            } else {
              window.__kb.data = t;
              window.__kb.path = p;
              window.__kb.state = 'DONE';
            }
          })
          .catch(function(e){ tryNext(i + 1); });
      }
      tryNext(0);
      return 'STARTED';
    })()`;
  }

  private grab(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.parsedNames = '';
    this.status = '正在抓取…';
    this.controller.runJavaScript(this.buildScript(), (err: BusinessError, res: string) => {
      if (err) {
        this.busy = false;
        this.status = `注入脚本失败：${err.message}`;
        return;
      }
      hilog.info(DOMAIN, TAG, 'inject=%{public}s', res);
      if ((res ?? '').indexOf('NOT_ON_JWGLXT') >= 0) {
        this.busy = false;
        this.status = '当前网页不在教务系统域名下 —— 请先点「去教务系统」进到课表页再抓取';
        return;
      }
      this.poll(0);
    });
  }

  private poll(attempt: number): void {
    if (attempt > 24) {
      this.busy = false;
      this.status = '抓取超时 —— 请确认已在下方页面登录成功，再点一次';
      return;
    }
    this.controller.runJavaScript('window.__kb ? window.__kb.state : "NONE"',
      (err: BusinessError, state: string) => {
        const s: string = (state ?? '').split('"').join('');
        if (s === 'DONE' || s === 'ERROR') {
          this.collect();
        } else {
          setTimeout(() => {
            this.poll(attempt + 1);
          }, 400);
        }
      });
  }

  private collect(): void {
    this.controller.runJavaScript('window.__kb.data', (err: BusinessError, data: string) => {
      this.controller.runJavaScript('window.__kb.path', (e2: BusinessError, path: string) => {
        this.busy = false;
        hilog.info(DOMAIN, TAG, 'usedPath=%{public}s', path ?? '');
        let raw: string = data ?? '';
      // runJavaScript 回传的是 JSON 序列化结果，去掉最外层引号并反转义
      if (raw.length > 1 && raw.charAt(0) === '"') {
        try {
          raw = JSON.parse(raw) as string;
        } catch (e) {
          raw = raw.substring(1, raw.length - 1);
        }
      }
      if (raw.startsWith('ERR:')) {
        this.status = `抓取失败：${raw.substring(0, 120)}`;
        return;
      }
      if (raw.length < 20) {
        this.status = `返回内容过短（${raw.length} 字符）—— 多半没登录，或学年/学期填错`;
        this.dumpChunks(raw);
        return;
      }
        if (DEBUG_DUMP_RAW) {
          this.dumpChunks(raw);
          this.saveRaw(raw);
        }
        this.parse(raw);
      });
    });
  }

  /** 把原始 JSON 分段打进 hilog，便于按真实字段结构校正解析器 */
  private dumpChunks(raw: string): void {
    if (!DEBUG_DUMP_RAW) {
      return;
    }
    // hilog 遇到真实换行会截断日志条目，先把内容压成单行
    // （JSON 字符串值里的 \n 是转义字符，不受影响）
    const flat: string = raw.replace(/[\r\n]+/g, '⏎');
    hilog.info(DOMAIN, TAG, 'RAW len=%{public}d', flat.length);
    let i: number = 0;
    let idx: number = 0;
    while (i < flat.length && idx < MAX_CHUNKS) {
      const end: number = Math.min(i + CHUNK, flat.length);
      hilog.info(DOMAIN, TAG, 'R%{public}d|%{public}s', idx, flat.substring(i, end));
      i = end;
      idx++;
    }
    if (i < flat.length) {
      hilog.info(DOMAIN, TAG, 'TRUNCATED rest=%{public}d', flat.length - i);
    }
  }

  private saveRaw(raw: string): void {
    if (!DEBUG_DUMP_RAW) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path: string = `${ctx.filesDir}/kb_raw.json`;
      const f: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, raw);
      fileIo.closeSync(f);
      hilog.info(DOMAIN, TAG, 'saved=%{public}s', path);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveRaw failed: %{public}s', err.message);
    }
  }

  private async parse(raw: string): Promise<void> {
    // 落盘（saveFromRaw 会保留用户已写的备注/备忘）
    let table: CourseTable = new CourseTable();
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store: CourseStore = new CourseStore(ctx);
      table = await store.saveFromRaw(raw, this.xnm, this.xqm);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', err.message);
    }
    if (table.items.length === 0) {
      this.status = '抓到数据但没解析出课程 —— 字段名与预期不同（开启 DEBUG_DUMP_RAW 可落盘原文核对）';
      return;
    }
    const names: string[] = [];
    for (let i = 0; i < table.items.length && i < 6; i++) {
      const it = table.items[i];
      names.push(`${it.name}(周${it.dayOfWeek} ${it.startSection}节)`);
    }
    this.parsedNames = names.join('、');
    this.status = `解析成功：${table.items.length} 个课程格`;
  }

  build() {
    Column() {
      // 顶栏：返回 + 标题 + 主操作
      Row() {
        Text('‹')
          .fontSize(28).fontColor('#2B2622').width(40).height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text('课表导入').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2B2622')
        Blank()
        Text('学年').fontSize(13).fontColor('#7A7066')
        TextInput({ text: this.xnm })
          .width(80).height(36).fontSize(14).margin({ left: 4 })
          .onChange((v: string) => {
            this.xnm = v;
          })
        Text('学期').fontSize(13).fontColor('#7A7066').margin({ left: 10 })
        TextInput({ text: this.xqm })
          .width(56).height(36).fontSize(14).margin({ left: 4 })
          .onChange((v: string) => {
            this.xqm = v;
          })
        Button(this.busy ? '抓取中…' : '抓取课表')
          .fontSize(15).height(40).borderRadius(20).margin({ left: 14 })
          .backgroundColor(this.busy ? '#A9C4BB' : '#2F6F5E').fontColor('#FFFFFF')
          .enabled(!this.busy)
          .onClick(() => {
            this.grab();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: 10, bottom: 6 })

      // 步骤导航：登录页面快捷入口
      Row() {
        Text('① 登录').fontSize(12).fontColor('#7A7066')
        Text('信息门户')
          .fontSize(13).fontColor('#2F6F5E').backgroundColor('#E3EEE9')
          .borderRadius(14).padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ left: 8 })
          .onClick(() => {
            this.controller.loadUrl(PORTAL_INDEX);
          })
        Text('重新登录')
          .fontSize(13).fontColor('#2F6F5E').backgroundColor('#E3EEE9')
          .borderRadius(14).padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ left: 8 })
          .onClick(() => {
            this.controller.loadUrl(PORTAL_HOME);
          })
        Text('② 进入')
          .fontSize(12).fontColor('#7A7066').margin({ left: 14 })
        Text('教务系统')
          .fontSize(13).fontColor('#2F6F5E').backgroundColor('#E3EEE9')
          .borderRadius(14).padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ left: 8 })
          .onClick(() => {
            this.controller.loadUrl(JW_HOME);
          })
        Text('③ 点右上「抓取课表」')
          .fontSize(12).fontColor('#7A7066').margin({ left: 14 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 状态条
      Column() {
        Text(this.status).fontSize(13).fontColor('#2B2622').width('100%')
        if (this.parsedNames.length > 0) {
          Text(`例：${this.parsedNames}`)
            .fontSize(12).fontColor('#7A7066').width('100%').margin({ top: 4 })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .margin({ left: 12, right: 12, bottom: 8 })
      .borderRadius(12)
      .backgroundColor('#FFFFFF')
      .alignItems(HorizontalAlign.Start)

      Web({ src: PORTAL_HOME, controller: this.controller })
        .layoutWeight(1)
        .mixedMode(MixedMode.All)
        // 统一身份认证靠本地存储维持登录态，ArkWeb 这几个开关默认是关的
        .domStorageAccess(true)
        .databaseAccess(true)
        .fileAccess(true)
        .onPageBegin((e: OnPageBeginEvent) => {
          // 认证跳转 URL 可能带临时票据，不作为明文日志输出
          hilog.info(DOMAIN, TAG, 'pageBegin %{private}s', e.url);
        })
        .onPageEnd(() => {
          hilog.info(DOMAIN, TAG, 'pageEnd');
        })
        .onConsole((e: OnConsoleEvent) => {
          // 网页控制台消息可能回显页面内容，不作为明文日志输出
          hilog.info(DOMAIN, TAG, 'js: %{private}s', e.message.getMessage());
          return false;
        })
        .onErrorReceive((e: OnErrorReceiveEvent) => {
          hilog.error(DOMAIN, TAG, 'resErr: %{public}s', e.error.getErrorInfo());
        })
    }
    .width('100%')
    .height('100%')
    // 背景延伸进状态栏/导航栏，避免上下白边
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor('#F6F1E9')
  }
}
