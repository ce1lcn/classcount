# ClassCount 架构说明

> 鸿蒙（HarmonyOS NEXT / ArkTS）课表 + 日程手账 + 桌面服务卡片，API 23，已在华为平板真机验证。

## 一、分层与职责

单 HAP，业务跨两个进程：主应用与卡片（FormExtensionAbility）。

| 目录 | 职责 |
|---|---|
| `entryability/` | 主应用入口：加载首页、同步窗口与系统栏配色、接收卡片跳转参数、回前台推卡片 |
| `entryformability/` | 卡片生命周期；只做同步读 + 纯计算，`onAddForm` 同步返回 |
| `widget/pages/WidgetCard.ets` | 卡片 UI，自包含，用 `@LocalStorageProp` 收数据 |
| `model/` | 数据层唯一真源：`Schedule`/`ScheduleStore`（日程与快照、持久化、卡片进程同步读）、`Course`/`CourseStore`（课表解析、周次、下一节课）、`Wordbook`、`CardData`（卡片契约）、`CardPusher`（推送） |
| `features/planner/` | 手账纯逻辑与独立存储，不依赖 UI 与卡片 API，可离线测试 |
| `pages/` | 首页、周视图课表、课表导入、手账、背单词 |
| `common/` | 视觉令牌与课程名取色、系统栏配色同步 |
| `resources/` | 卡片配置、页面注册、内置课表兜底 |

`model/` 与 `features/` 不引用 ArkUI 组件，页面只做展示与调用。

## 二、数据契约与进程边界

卡片与提供方是两个独立进程。平台约束：跨进程只能经 `@LocalStorageProp` 传值，卡片内不能用 `getContext()`，且接收时数据会被转成 string。

契约因此是扁平字符串字典，由 `buildCardData()` 统一产出：日程组 7 个（`hasData`/`title`/`daysText`/`daysLeftText`/`dateText`/`weekPercentText`/`progressPercentText`，布尔用 `'1'`/`'0'`），课程组 8 个（`hasCourse`/`courseName`/`courseRoom`/`courseTeacher`/`courseWhen`/`courseCountdown`/`courseSection`/`courseOngoing`）。格式化（天数文案、倒计时、百分比）全在数据层完成，卡片只渲染字符串。

流向单向：主应用 → 卡片。主应用用 `getPublishedRunningFormInfos()` 直接查到桌面卡片，无需持久化 formId；卡片不回写数据，点击只发 `postCardAction` 拉起应用，故卡片进程无状态、可随时回收。

## 三、关键机制

**课表解析与周次**：`parseKbJson()` 取返回 JSON 的 `kbList`，宽松取值；周次文本经 `parseWeeks()` 支持区间、枚举与"单/双"过滤，再去重升序。课程格 `id = 课程名|星期|起始节|周次`。当前周次 = 自然日差 ÷ 7 + 1，基准 `termStart`（第 1 周周一 00:00），优先级：用户手动设置 → 内置值纠正（仅当用户没设过）→ 由接口返回的当前周次反推。`calcNextClass()` 展开 `weekList × dayOfWeek`，用节次作息表算出每节课的绝对起止时间，取"结束晚于现在且开始最早"的一节，已开始未结束标 `ongoing`。

**重复与顺延**：手账以"日序号"为基准，回避时区与夏令时。`nextOccurrence()` 支持单次、每天、每周多选星期、每隔 N 天，间隔用 `ceil` 对齐原始起点，晚完成不重设周期。`reconcile()` 惰性补记"应做未做"的历史，靠 `checkedThrough` 水位防重复；`completeTodo()` 记完成历史后从"今天 + 1"排下一次。改标题或星级不清零逾期，改日期或规则从当天重排，`revision` 自增。

**快照与推送**：`buildSnapshot()` 为纯函数。刷新有三条路径：系统定时（`updateDuration: 1`，粒度 30 分钟）、主应用改动后立即强推（先 await 落盘再推，否则卡片可能读到旧值）、回前台补推。`pushToAll()` 枚举桌面卡片逐个 `updateForm`，单张失败只记日志。

**持久化**：全部为 Preferences 分库，日程、课表、手账、单词本各存一份 JSON 字符串。主应用走异步 `get`/`put`/`flush`，卡片进程走同步 `getPreferencesSync`/`getSync`。容错有意区分：日程与课表读失败退化为空态，手账读损坏则显式报错、不自动重置。

## 四、硬约束

| 不能改 | 原因 |
|---|---|
| `model/*.ets` | 契约与算法唯一真源，两侧共用；字段名即卡片 `@LocalStorageProp` 的 key |
| `entryformability/` | 生命周期已真机验证；`onAddForm` 必须同步 |
| `entryability/` | 入口与推送时序；窗口底色须与页面背景一致，否则安全区露白边 |
| `form_config.json` | 五元组变更会让系统删除桌面已有卡片；ArkTS 卡片必须显式写 `uiSyntax: "arkts"` |
| `main_pages.json` | 未注册的页面无法路由 |
| `kebiao_init.json` | 内置学期基准，被 `syncBundledTermStart()` 引用 |

页面与卡片 UI、`common/Theme` 配色可改，但卡片 UI 自包含、主题改动需分别处理；新增页面必须注册进 `main_pages.json`。

## 五、已知的坑

1. **编码**：配置 JSON 必须是不带 BOM 的 UTF-8，否则编译报 `file format is invalid`。
2. **卡片进程**：不能用 `getContext()` 或 `SymbolGlyph`（有崩溃风险）；`onAddForm` 同步返回，故只能用同步 Preferences 接口；调度完成后最多存活约 10 秒，禁引多媒体与后台任务模块。
3. **空卡片错误码**：桌面无卡片时查询接口返回 `{"code":16500100}` 而非空数组，要当"暂无卡片"处理。
4. **契约比 UI 用量大**：数据层输出 15 个字段，卡片 UI 目前只用 7 个，删字段前先确认消费方。
5. **颜色格式**：8 位十六进制是 `#AARRGGBB`（透明度在前），不是 `#RRGGBBAA`。
6. **状态管理**：普通字段不加 `@State` 不触发重渲染，弹层会弹不出来且不报错；`@ObjectLink` 变量名须与父组件属性名逐字一致。
7. **ForEach key**：key 必须覆盖所有影响渲染的字段，否则数据换了仍复用旧组件、静默不刷新；课程格 id 不含备注，切换周次同理。
8. **ArkWeb**：三个本地存储开关缺一不可，否则统一认证卡在登录转圈；抓取路径前缀因部署而异，两种都要试。
9. **字段名**：教师姓名字段与学生信息字段容易混；周次名称字段实测值是"无"，不能当周次正文兜底。
10. **备注作用域**：课程备注按课程名共享，单次课备忘按日期分开，二者都不参与 `id`。
11. **取色**：课程色须按课程名稳定哈希，不能按数组下标，否则刷新后会换色。

## 六、验证

`test/` 下为纯逻辑离线测试（课表、周次、手账、单词本）；构建走 `assembleHap`，UI 观感须真机确认。
