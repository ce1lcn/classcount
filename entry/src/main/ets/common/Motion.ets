/**
 * 统一动效参数 —— 时长/曲线集中在这里，各页面手感一致。
 *
 * 约定：
 *   - 列表/页面内容只做「出现」动画（enter-only），消失要么瞬间、要么先原地淡出再移除；
 *     否则退场节点会继续占着布局位置，把兄弟节点挤开；
 *   - 弹层（遮罩 + 面板）是独立图层，进出都做动画；
 *   - 动画只挂在展示属性上，不改任何数据/落盘逻辑；
 *   - TransitionEffect 里每个子效果各自带 animation 参数，避免 combine 后只有一部分有动画。
 */
import { curves } from '@kit.ArkUI';

const EASE: Curve = Curve.FastOutSlowIn;

/** 按压反馈：配合 .scale(...).animation(pressAnim()) */
export function pressAnim(): AnimateParam {
  return { duration: 150, curve: Curve.EaseOut };
}

/** 弹性回弹（星星、判定按钮等小弹跳） */
export function popAnim(): AnimateParam {
  return { curve: curves.springMotion(0.32, 0.62) };
}

/** 普通属性渐变（颜色、宽度） */
export function softAnim(duration: number = 260): AnimateParam {
  return { duration: duration, curve: EASE };
}

/** 页面内元素错峰入场用的 animateTo 参数 */
export function enterParam(delay: number): AnimateParam {
  return { duration: 460, delay: delay, curve: EASE };
}

/** 页面切换：新页面从右侧滑入并淡入，旧页面轻微左移淡出；返回时反向 */
export const PAGE_MS: number = 300;

/** 仅出现：向上浮起 + 淡入。delay 用来做列表的错峰 */
export function riseIn(dy: number = 14, delay: number = 0): TransitionEffect {
  const p: AnimateParam = { duration: 340, delay: delay, curve: EASE };
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation(p)
      .combine(TransitionEffect.translate({ y: dy }).animation(p)),
    TransitionEffect.IDENTITY);
}

/** 仅出现：水平滑入 + 淡入。dx 为正表示从右侧来 */
export function slideIn(dx: number = 24, delay: number = 0): TransitionEffect {
  const p: AnimateParam = { duration: 320, delay: delay, curve: EASE };
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation(p)
      .combine(TransitionEffect.translate({ x: dx }).animation(p)),
    TransitionEffect.IDENTITY);
}

/** 仅出现：淡入（页内视图切换） */
export function fadeIn(delay: number = 0): TransitionEffect {
  const p: AnimateParam = { duration: 260, delay: delay, curve: EASE };
  return TransitionEffect.asymmetric(TransitionEffect.OPACITY.animation(p), TransitionEffect.IDENTITY);
}

/** 遮罩：进出都淡 */
export function scrimFade(): TransitionEffect {
  const p: AnimateParam = { duration: 220, curve: Curve.EaseOut };
  return TransitionEffect.OPACITY.animation(p);
}

/** 居中弹窗：进入时从 92% 放大并淡入，退出时淡出并略缩小 */
export function dialogPop(): TransitionEffect {
  const enter: AnimateParam = { curve: curves.springMotion(0.36, 0.82) };
  const exit: AnimateParam = { duration: 160, curve: Curve.EaseIn };
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }).animation(enter)),
    TransitionEffect.OPACITY.animation(exit)
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation(exit)));
}

/** 底部面板：从下方滑入，退出时滑回去 */
export function sheetUp(): TransitionEffect {
  const enter: AnimateParam = { curve: curves.springMotion(0.4, 0.88) };
  const exit: AnimateParam = { duration: 200, curve: Curve.EaseIn };
  return TransitionEffect.asymmetric(
    TransitionEffect.translate({ y: '100%' }).animation(enter),
    TransitionEffect.translate({ y: '100%' }).animation(exit));
}

/**
 * 数字滚动：把 from 平滑推到 to，每帧回调当前整数值。
 * 页面销毁时务必 cancel()，否则定时器会继续写已销毁页面的状态。
 */
export class Tween {
  private timer: number = -1;

  start(from: number, to: number, ms: number, onTick: (value: number) => void): void {
    this.cancel();
    if (from === to || ms <= 0) {
      onTick(to);
      return;
    }
    const t0: number = Date.now();
    this.timer = setInterval(() => {
      const p: number = Math.min(1, (Date.now() - t0) / ms);
      const eased: number = 1 - Math.pow(1 - p, 3);
      onTick(p >= 1 ? to : Math.round(from + (to - from) * eased));
      if (p >= 1) {
        this.cancel();
      }
    }, 16);
  }

  cancel(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }
}
