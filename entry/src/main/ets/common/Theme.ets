/**
 * 全局视觉令牌 —— 暖纸手账风（米白底 + 深墨字 + 墨绿主色 + 陶土橘点缀，无渐变）
 * 仅主应用页面使用；卡片进程保持自包含，不引用本文件。
 *
 * ⚠️ ArkTS 的 8 位十六进制颜色是 #AARRGGBB（透明度在最前），不是 CSS 的 #RRGGBBAA。
 */
export const C_BG: string = '#F6F1E9';
export const C_SURFACE: string = '#FFFDF9';
export const C_INK: string = '#2B2622';
export const C_SUB: string = '#7A7066';
export const C_MUTE: string = '#B5ABA0';
export const C_LINE: string = '#E7DFD3';
export const C_PRIMARY: string = '#2F6F5E';
export const C_PRIMARY_SOFT: string = '#E3EEE9';
export const C_ACCENT: string = '#D9622B';
export const C_DANGER: string = '#C8402F';
export const C_WARN_BG: string = '#FBEBD0';
export const C_WARN_INK: string = '#7A4A10';
export const C_SCRIM: string = '#662B2622';
export const C_DISABLED: string = '#A9C4BB';

/** 纯色卡片上的文字/底槽：白色的不同透明度 */
export const W100: string = '#FFFFFF';
export const W85: string = '#D9FFFFFF';
export const W65: string = '#A6FFFFFF';
export const W25: string = '#40FFFFFF';

const PALETTE: string[] = [
  '#2F6F5E', '#D9622B', '#C9962B', '#8A5A44', '#5C7FA3', '#B5527A', '#6B8E3A', '#7B6AA8'
];

/** 按课程名做稳定哈希取色：课表顺序变化也不会让颜色乱跳 */
export function courseColor(name: string): string {
  let h: number = 0;
  for (let i = 0; i < name.length; i++) {
    h = (h * 31 + name.charCodeAt(i)) % 100000;
  }
  return PALETTE[h % PALETTE.length];
}

/** 课程色的浅底（约 14% 不透明度）：把 #RRGGBB 变成 #24RRGGBB */
export function courseTint(name: string): string {
  return `#24${courseColor(name).substring(1)}`;
}

/** 日程卡底色：已过期灰、7 天内陶土橘、其余深褐灰、空态暖灰 */
export function urgencyColor(daysLeft: number, has: boolean): string {
  if (!has) {
    return '#8A8174';
  }
  if (daysLeft < 0) {
    return '#9A948B';
  }
  return daysLeft <= 7 ? '#D9622B' : '#3D3A36';
}

export function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}
