/**
 * 教务系统地址配置
 *
 * ⚠️ 这里的默认值是**占位符**，必须替换成自己学校教务系统的实际地址后再使用。
 *
 * 抓取课表的原理：Web 组件加载教务系统并让用户手动登录，登录后的 cookie 留在
 * WebView 里，再用**同源 fetch** 调课表接口取回 JSON。因此：
 *   - PORTAL_HOME 要指向统一身份认证（CAS）登录页，直接进这里，不要先开官网首页
 *     —— 官网多为 HTTPS 而 CAS 可能是 HTTP，协议降级会让 WebView 卡住不跳转
 *   - JW_HOME 与 JW_HOST_KEY 必须指向同一个教务系统站点，否则同源校验不过
 */
export const PORTAL_HOME: string = 'http://cas.example.edu.cn/cas/login?service=';
/** 信息门户（登录后从这里找教务系统入口） */
export const PORTAL_INDEX: string = 'http://portal.example.edu.cn/';
/** 教务系统首页：抓取必须在这个域名下执行（同源才能带 cookie） */
export const JW_HOME: string = 'http://jw.example.edu.cn/';
/** 教务系统域名的特征片段，用于判断 WebView 是否已进入教务系统 */
export const JW_HOST_KEY: string = 'jw';
/**
 * 课表接口路径候选。正方教务系统部署时 context path 不一致：
 * 接口可能挂在站点根目录，也可能挂在 /jwglxt 下，两种都要试一遍。
 */
export const KB_API_PATHS: string[] = [
  '/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151',
  '/jwglxt/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151'
];
