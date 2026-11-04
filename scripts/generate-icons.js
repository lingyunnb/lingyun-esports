/**
 * FISH电竞 Launcher 图标生成器（docs/15 品牌规范，2026-09-22 高端化重设计）
 * 设计：深色渐变底（#171A24→#242A3A）+ 中央光晕 + 渐变几何 "F"（中间一横为鱼鳍式斜切）；
 *       老板端=黑金（金色渐变 F + 顶部金色皇冠，呼应会员黑金体系）；
 *       工作端=深蓝专业（蓝色渐变 F + 右下角蓝底白心方形徽章，内部版识别）；
 *       圆角 20%（未做自适应掩码的老设备也保持高端圆角外观）。
 * 输出：mipmap-mdpi..xxxhdpi 的 ic_launcher.png（4x 超采样抗锯齿）
 * 运行：node scripts/generate-icons.js <boss|worker>
 */
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

// ---------- 极简 PNG 编码器（RGBA, filter0） ----------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function encodePng(w, h, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const scanlines = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    scanlines[y * (w * 4 + 1)] = 0;
    rgba.copy(scanlines, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(scanlines, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function inPoly(x, y, pts) {
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

function downsample(src, S, W100) {
  const W = W100 * S;
  const out = Buffer.alloc(W100 * W100 * 4);
  for (let y = 0; y < W100; y++)
    for (let x = 0; x < W100; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < S; sy++)
        for (let sx = 0; sx < S; sx++) {
          const i = ((y * S + sy) * W + x * S + sx) * 4;
          r += src[i];
          g += src[i + 1];
          b += src[i + 2];
          a += src[i + 3];
        }
      const n = S * S;
      const o = (y * W100 + x) * 4;
      out[o] = Math.round(r / n);
      out[o + 1] = Math.round(g / n);
      out[o + 2] = Math.round(b / n);
      out[o + 3] = Math.round(a / n);
    }
  return out;
}

// ---------- 生成 ----------
const kind = process.argv[2] === 'worker' ? 'worker' : 'boss';
const appDir = path.join(__dirname, '..', 'apps', kind === 'boss' ? 'boss-app' : 'worker-app');

// 主题色
const GOLD_TOP = [245, 220, 160]; // #F5DCA0
const GOLD_BOTTOM = [201, 155, 74]; // #C99B4A
const BLUE_TOP = [111, 164, 245]; // #6FA4F5
const BLUE_BOTTOM = [45, 91, 214]; // #2D5BD6
const DARK_TOP = [23, 26, 36]; // #171A24
const DARK_BOTTOM = [36, 42, 58]; // #242A3A
const top = kind === 'boss' ? GOLD_TOP : BLUE_TOP;
const bottom = kind === 'boss' ? GOLD_BOTTOM : BLUE_BOTTOM;
const glow = kind === 'boss' ? GOLD_TOP : BLUE_TOP;
const glowPeak = kind === 'boss' ? 0.55 : 0.45;
const CORNER_R = 20; // 圆角半径（100 设计空间）

const sizes = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
const S = 4; // 超采样倍率

const lerp = (a, b, t) => a + (b - a) * t;
const mix = (c1, c2, t) => [lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t)];

/** F 标记的渐变取色（按 y 在 26-78 区间插值） */
function fColor(x, y) {
  return mix(top, bottom, Math.max(0, Math.min(1, (y - 26) / 52)));
}

for (const [dpi, size] of Object.entries(sizes)) {
  const W100 = size;
  const buf = Buffer.alloc(W100 * S * W100 * S * 4);
  const scale = size / 100;
  const W = W100 * S;

  // 1. 深色渐变底
  for (let y = 0; y < W; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const t = (x / W + y / W) / 2;
      const c = mix(DARK_TOP, DARK_BOTTOM, t);
      buf[i] = c[0];
      buf[i + 1] = c[1];
      buf[i + 2] = c[2];
      buf[i + 3] = 255;
    }
  }
  // 2. 中央光晕（设计坐标 50,44，半径 36）
  for (let y = 0; y < W; y++) {
    for (let x = 0; x < W; x++) {
      const dx = x / S - 50 * scale;
      const dy = y / S - 44 * scale;
      const d = Math.sqrt(dx * dx + dy * dy) / (36 * scale);
      if (d < 1) {
        const f = Math.pow(1 - d, 2) * glowPeak;
        const i = (y * W + x) * 4;
        buf[i] = Math.round(lerp(buf[i], glow[0], f));
        buf[i + 1] = Math.round(lerp(buf[i + 1], glow[1], f));
        buf[i + 2] = Math.round(lerp(buf[i + 2], glow[2], f));
      }
    }
  }

  // 3. 几何 F（带渐变与 4 采样抗锯齿）
  const fillPolyGrad = (pts, colorFn) => {
    const sp = pts.map(([x, y]) => [x * scale, y * scale]);
    const minX = Math.floor(Math.min(...sp.map((p) => p[0])) * S);
    const maxX = Math.ceil(Math.max(...sp.map((p) => p[0])) * S);
    const minY = Math.floor(Math.min(...sp.map((p) => p[1])) * S);
    const maxY = Math.ceil(Math.max(...sp.map((p) => p[1])) * S);
    for (let y = minY; y < maxY; y++)
      for (let x = minX; x < maxX; x++) {
        let hit = 0;
        for (const [ox, oy] of [[0.25, 0.25], [0.25, 0.75], [0.75, 0.25], [0.75, 0.75]])
          if (inPoly((x + ox) / S, (y + oy) / S, sp)) hit++;
        if (hit > 0) {
          const i = (y * W + x) * 4;
          const a = hit / 4;
          const c = colorFn((x + 0.5) / S / scale, (y + 0.5) / S / scale);
          buf[i] = Math.round(c[0] * a + buf[i] * (1 - a));
          buf[i + 1] = Math.round(c[1] * a + buf[i + 1] * (1 - a));
          buf[i + 2] = Math.round(c[2] * a + buf[i + 2] * (1 - a));
        }
      }
  };

  // F：竖笔 + 顶横 + 鱼鳍斜切中横
  fillPolyGrad([[36, 26], [44, 26], [44, 78], [36, 78]], fColor);
  fillPolyGrad([[36, 26], [66, 26], [66, 34], [36, 34]], fColor);
  fillPolyGrad([[36, 52], [64, 52], [56, 60], [36, 60]], fColor);
  if (kind === 'boss') {
    // 金色皇冠（顶部）
    fillPolyGrad([[44.5, 21], [57.5, 21], [57.5, 25], [44.5, 25]], fColor);
    fillPolyGrad([[44.5, 21], [48, 13], [51.5, 21]], fColor);
    fillPolyGrad([[48.5, 21], [52, 13], [55.5, 21]], fColor);
    fillPolyGrad([[52.5, 21], [56, 13], [59.5, 21]], fColor);
  } else {
    // 工作端徽章：蓝底白心方形
    fillPolyGrad([[63, 63], [90, 63], [90, 90], [63, 90]], () => mix(BLUE_TOP, BLUE_BOTTOM, 0.4));
    fillPolyGrad([[68, 68], [85, 68], [85, 85], [68, 85]], () => [255, 255, 255]);
  }

  // 4. 圆角掩码（角外透明，老设备也高端）
  for (let y = 0; y < W; y++) {
    for (let x = 0; x < W; x++) {
      const px = x / S / scale;
      const py = y / S / scale;
      const r = CORNER_R;
      const cx = Math.max(r, Math.min(px, 100 - r));
      const cy = Math.max(r, Math.min(py, 100 - r));
      const dx = px - cx;
      const dy = py - cy;
      if (dx * dx + dy * dy > r * r && (px < r || px > 100 - r) && (py < r || py > 100 - r)) {
        const i = (y * W + x) * 4;
        buf[i + 3] = 0;
      }
    }
  }

  const png = encodePng(W100, W100, downsample(buf, S, W100));
  const outDir = path.join(appDir, 'android', 'app', 'src', 'main', 'res', `mipmap-${dpi}`);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'ic_launcher.png'), png);
  console.log(`已生成 ${kind} mipmap-${dpi}/ic_launcher.png (${W100}x${W100})`);
}
console.log('完成');
