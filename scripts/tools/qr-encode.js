/**
 * 自包含 QR 编码器（byte 模式，ECC level M，版本 1–10）+ 极简 PNG 写出。
 *
 * 为什么自己写：临时入口二维码必须在**没有网络**的情况下也能重生成
 * （`npx qrcode` 要联网；本机 %TEMP% 只缓存了 jsqr/pngjs 解码器，没有编码器）。
 * 正确性不靠"我觉得对"——生成后一律用 jsQR 解码回读，payload 必须逐字相等。
 *
 * 用法（作为库）：const {encodeQR, matrixToPng} = require('.../qr-encode.js');
 */
const zlib = require('zlib');

// ---- ECC level M 的 RS 块结构：[每块数据码字数, 组1块数, 组2块数]，总码字数 ----
// 来源：ISO/IEC 18004 表 9（ECC M），版本 1..10。
// ⚠️ 坑（2026-10-06）：这张表**不要凭记忆写**。第一版凭记忆写成 v1=19+10，
// 结果总码字 29 ≠ 符号容量 26，矩阵看起来功能图形全对、扫码器却完全读不出。
// 现在这张表由参考实现（qrcode@1.5.4 + ISO 18004 块分配算法）导出并逐版核对：
//   总码字/数据码字 = 1:16/16、2:28/28、3:44/44、4:64/32×2、5:86/43×2、
//   6:108/27×4、7:124/31×4、8:154/38×2+39×2、9:182/36×3+37×2、10:216/43×4+44×1
const ECC_M = {
  1:  { ec: 10, g1: [16, 1], g2: [0, 0] },
  2:  { ec: 16, g1: [28, 1], g2: [0, 0] },
  3:  { ec: 26, g1: [44, 1], g2: [0, 0] },
  4:  { ec: 18, g1: [32, 2], g2: [0, 0] },
  5:  { ec: 24, g1: [43, 2], g2: [0, 0] },
  6:  { ec: 16, g1: [27, 4], g2: [0, 0] },
  7:  { ec: 18, g1: [31, 4], g2: [0, 0] },
  8:  { ec: 22, g1: [38, 2], g2: [39, 2] },
  9:  { ec: 22, g1: [36, 3], g2: [37, 2] },
  10: { ec: 26, g1: [43, 4], g2: [44, 1] },
};

const ALIGN_COORD = {
  1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
  7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
};

// ---- GF(256) 运算（本原多项式 0x11D） ----
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(function initGF() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11D;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();
const gfMul = (a, b) => (a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]);

/** 生成多项式 ∏(x - α^i)，i=0..degree-1 */
function rsGenPoly(degree) {
  let poly = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(poly.length + 1).fill(0);
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= gfMul(poly[j], 1);
      next[j + 1] ^= gfMul(poly[j], EXP[i]);
    }
    poly = next;
  }
  return poly;
}

function rsEncode(data, ecLen) {
  const gen = rsGenPoly(ecLen);
  const res = new Uint8Array(data.length + ecLen);
  res.set(data, 0);
  for (let i = 0; i < data.length; i++) {
    const coef = res[i];
    if (coef === 0) continue;
    for (let j = 0; j < gen.length; j++) res[i + j] ^= gfMul(gen[j], coef);
  }
  return res.subarray(data.length);
}

// ---- 位缓冲 ----
class BitBuf {
  constructor() { this.bits = []; }
  put(value, len) {
    for (let i = len - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
  }
  get length() { return this.bits.length; }
  toBytes() {
    const out = new Uint8Array(Math.ceil(this.bits.length / 8));
    this.bits.forEach((b, i) => { if (b) out[i >> 3] |= 0x80 >> (i & 7); });
    return out;
  }
}

/** 数据码字：模式 0100 + 字符数 + 数据 + 终止符 + 补齐 + 交替填充字节 */
function buildDataCodewords(bytes, version) {
  const info = ECC_M[version];
  if (!info) throw new Error('unsupported version ' + version);
  const totalData = info.g1[0] * info.g1[1] + info.g2[0] * info.g2[1];
  const bb = new BitBuf();
  bb.put(0b0100, 4);                                   // byte 模式
  bb.put(bytes.length, version <= 9 ? 8 : 16);          // 字符计数指示符
  for (const b of bytes) bb.put(b, 8);
  const capBits = totalData * 8;
  if (bb.length > capBits) throw new Error('data too long for version ' + version);
  bb.put(0, Math.min(4, capBits - bb.length));          // 终止符
  while (bb.length % 8 !== 0) bb.put(0, 1);
  const cw = new Uint8Array(totalData);
  cw.set(bb.toBytes(), 0);
  const pad = [0xEC, 0x11];
  for (let i = bb.length / 8, k = 0; i < totalData; i++, k++) cw[i] = pad[k % 2];
  return cw;
}

/** 按标准把数据码字分块 + 算 EC + 交织 */
function interleave(dataCw, version) {
  const info = ECC_M[version];
  const blocks = [];
  let off = 0;
  for (let i = 0; i < info.g1[1]; i++) {
    const d = dataCw.subarray(off, off + info.g1[0]); off += info.g1[0];
    blocks.push({ d, e: rsEncode(d, info.ec) });
  }
  for (let i = 0; i < info.g2[1]; i++) {
    const d = dataCw.subarray(off, off + info.g2[0]); off += info.g2[0];
    blocks.push({ d, e: rsEncode(d, info.ec) });
  }
  const out = [];
  const maxD = Math.max(...blocks.map((b) => b.d.length));
  for (let i = 0; i < maxD; i++) for (const b of blocks) if (i < b.d.length) out.push(b.d[i]);
  for (let i = 0; i < info.ec; i++) for (const b of blocks) out.push(b.e[i]);
  return Uint8Array.from(out);
}

// ---- 矩阵 ----
function newMatrix(size) {
  return { size, m: Array.from({ length: size }, () => new Int8Array(size).fill(-1)) }; // -1 未定
}

function placeFinder(mx, row, col) {
  for (let r = -1; r <= 7; r++) {
    for (let c = -1; c <= 7; c++) {
      const rr = row + r, cc = col + c;
      if (rr < 0 || cc < 0 || rr >= mx.size || cc >= mx.size) continue;
      const inner = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                    (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
                    (r >= 2 && r <= 4 && c >= 2 && c <= 4);
      mx.m[rr][cc] = inner ? 1 : 0;
    }
  }
}

function placeAlignment(mx, version) {
  const coords = ALIGN_COORD[version] || [];
  for (const r of coords) {
    for (const c of coords) {
      if (mx.m[r][c] !== -1) continue;                 // 与定位图形重叠 → 跳过
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const inner = Math.max(Math.abs(dr), Math.abs(dc)) !== 1;
          mx.m[r + dr][c + dc] = inner ? 1 : 0;
        }
      }
    }
  }
}

function placeTiming(mx) {
  for (let i = 8; i < mx.size - 8; i++) {
    if (mx.m[6][i] === -1) mx.m[6][i] = i % 2 === 0 ? 1 : 0;
    if (mx.m[i][6] === -1) mx.m[i][6] = i % 2 === 0 ? 1 : 0;
  }
}

function reserveFormatAndVersion(mx, version) {
  const s = mx.size;
  // 格式信息区（两处）
  const fmtPos = [];
  for (let i = 0; i <= 8; i++) { if (i !== 6) { fmtPos.push([8, i < 8 ? i : 8]); } }
  // 简化：直接按标准坐标标记（稍后统一写值）
  for (let i = 0; i < 9; i++) {
    if (mx.m[8][i] === -1) mx.m[8][i] = 0;
    if (mx.m[i][8] === -1) mx.m[i][8] = 0;
  }
  for (let i = 0; i < 8; i++) {
    if (mx.m[8][s - 1 - i] === -1) mx.m[8][s - 1 - i] = 0;
    if (mx.m[s - 1 - i][8] === -1) mx.m[s - 1 - i][8] = 0;
  }
  mx.m[s - 8][8] = 1;                                   // 固定暗模块
  // 版本信息（版本 ≥ 7）
  if (version >= 7) {
    const bits = versionBits(version);
    for (let i = 0; i < 18; i++) {
      const r = Math.floor(i / 3), c = s - 11 + (i % 3);
      const b = (bits >> i) & 1;
      mx.m[r][c] = b;
      mx.m[c][r] = b;
    }
  }
}

function versionBits(version) {
  // 版本信息 = 6 位版本号 + 12 位 BCH(18,6)，生成多项式 0x1F25
  let v = version << 12;
  for (let i = 17; i >= 12; i--) if ((v >>> i) & 1) v ^= 0x1F25 << (i - 12);
  return (version << 12) | v;
}

function formatBits(ecLevelBits, mask) {
  // 5 位（2 位 EC + 3 位 mask）+ 10 位 BCH(15,5)，再异或 0x5412
  const data = (ecLevelBits << 3) | mask;
  let v = data << 10;
  for (let i = 14; i >= 10; i--) if ((v >>> i) & 1) v ^= 0x537 << (i - 10);
  return ((data << 10) | v) ^ 0x5412;
}

function placeFormat(mx, ecLevelBits, mask) {
  const s = mx.size;
  const bits = formatBits(ecLevelBits, mask);
  for (let i = 0; i < 15; i++) {
    const b = (bits >> i) & 1;
    // ---- 第 1 份：左上角（竖列 8 自下而上，再横向到 (8,0)）----
    if (i < 6) mx.m[i][8] = b;
    else if (i === 6) mx.m[7][8] = b;
    else if (i === 7) mx.m[8][8] = b;
    else if (i === 8) mx.m[8][7] = b;
    else mx.m[8][14 - i] = b;
    // ---- 第 2 份：右上横排 + 左下竖排 ----
    // ⚠️ 位序方向踩过坑（2026-10-06）：两份拷贝的"走向"不同 ——
    //   左上那份：竖着自下而上（(0,8)→(5,8)→(7,8)→(8,8)），再横向从右往左到 (8,0)；
    //   右上那份：横排**从右往左**依次放 bit0..bit7（(8,s-1)→(8,s-8)），
    //             左下那份：竖排**自上而下**依次放 bit8..bit14（(s-7,8)→(s-1,8)）。
    //   写反了功能图形仍然全对、格式位自己也自洽，但扫码器读到反的格式信息 → 整张读不出。
    if (i < 8) mx.m[8][s - 1 - i] = b;
    else mx.m[s - 7 + (i - 8)][8] = b;
  }
  mx.m[s - 8][8] = 1;                                  // 固定暗模块
}

function maskFn(mask, r, c) {
  switch (mask) {
    case 0: return (r + c) % 2 === 0;
    case 1: return r % 2 === 0;
    case 2: return c % 3 === 0;
    case 3: return (r + c) % 3 === 0;
    case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
    case 5: return ((r * c) % 2) + ((r * c) % 3) === 0;
    case 6: return (((r * c) % 2) + ((r * c) % 3)) % 2 === 0;
    case 7: return (((r + c) % 2) + ((r * c) % 3)) % 2 === 0;
    default: return false;
  }
}

function placeData(mx, codewords, mask) {
  const s = mx.size;
  let bitIdx = 0;
  const total = codewords.length * 8;
  for (let right = s - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;                          // 跳过竖直定时列
    for (let vert = 0; vert < s; vert++) {
      for (let j = 0; j < 2; j++) {
        const c = right - j;
        const upward = ((right + 1) & 2) === 0;
        const r = upward ? s - 1 - vert : vert;
        if (mx.m[r][c] !== -1) continue;                 // 功能图形占位
        let bit = 0;
        if (bitIdx < total) bit = (codewords[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1;
        bitIdx++;
        if (maskFn(mask, r, c)) bit ^= 1;
        mx.m[r][c] = bit;
      }
    }
  }
}

/** 掩码罚分（ISO 18004 表 11 的四条规则） */
function penalty(m) {
  const s = m.length;
  let score = 0;
  // 规则1：同色连续 ≥5
  for (let i = 0; i < s; i++) {
    let runR = 1, runC = 1;
    for (let j = 1; j < s; j++) {
      if (m[i][j] === m[i][j - 1]) runR++; else { if (runR >= 5) score += runR - 2; runR = 1; }
      if (m[j][i] === m[j - 1][i]) runC++; else { if (runC >= 5) score += runC - 2; runC = 1; }
    }
    if (runR >= 5) score += runR - 2;
    if (runC >= 5) score += runC - 2;
  }
  // 规则2：2x2 同色块
  for (let r = 0; r < s - 1; r++) {
    for (let c = 0; c < s - 1; c++) {
      const v = m[r][c];
      if (v === m[r][c + 1] && v === m[r + 1][c] && v === m[r + 1][c + 1]) score += 3;
    }
  }
  // 规则3：1:1:3:1:1 图形（前后带 4 空白）
  const pat = [1, 0, 1, 1, 1, 0, 1];
  const has = (arr, i) => pat.every((p, k) => arr[i + k] === p) &&
    ((i >= 4 && arr.slice(i - 4, i).every((x) => x === 0)) ||
     (i + 11 <= arr.length && arr.slice(i + 7, i + 11).every((x) => x === 0)));
  for (let i = 0; i < s; i++) {
    const row = m[i], col = m.map((r) => r[i]);
    for (let j = 0; j + 7 <= s; j++) {
      if (has(row, j)) score += 40;
      if (has(col, j)) score += 40;
    }
  }
  // 规则4：黑白比例偏离 50%
  let dark = 0;
  for (let r = 0; r < s; r++) for (let c = 0; c < s; c++) if (m[r][c]) dark++;
  const pct = (dark * 100) / (s * s);
  score += Math.floor(Math.abs(pct - 50) / 5) * 10;
  return score;
}

/** 用指定掩码构造完整模块矩阵（返回 boolean[][]）——供 encodeQR 与调试比对复用 */
function buildMatrix(finalCw, version, mask, ecLevelBits = 0b00) {
  const size = version * 4 + 17;
  const mx = newMatrix(size);
  placeFinder(mx, 0, 0);
  placeFinder(mx, 0, size - 7);
  placeFinder(mx, size - 7, 0);
  placeAlignment(mx, version);
  placeTiming(mx);
  reserveFormatAndVersion(mx, version);
  placeData(mx, finalCw, mask);
  placeFormat(mx, ecLevelBits, mask);
  return mx.m.map((row) => Array.from(row, (v) => v === 1));
}

/** 主入口：返回 {size, modules:boolean[][], version, mask} */
function encodeQR(text) {
  const bytes = Buffer.from(text, 'utf8');
  let version = 0;
  for (let v = 1; v <= 10; v++) {
    const info = ECC_M[v];
    const totalData = info.g1[0] * info.g1[1] + info.g2[0] * info.g2[1];
    const need = 4 + (v <= 9 ? 8 : 16) + bytes.length * 8;
    if (need <= totalData * 8) { version = v; break; }
  }
  if (!version) throw new Error('payload too long for version 1-10: ' + bytes.length + ' bytes');

  const dataCw = buildDataCodewords(bytes, version);
  const finalCw = interleave(dataCw, version);

  let best = null;
  for (let mask = 0; mask < 8; mask++) {
    const mods = buildMatrix(finalCw, version, mask);
    const p = penalty(mods.map((row) => row.map((v) => (v ? 1 : 0))));
    if (!best || p < best.p) best = { p, mods, mask };
  }
  return { size: version * 4 + 17, modules: best.mods, version, mask: best.mask, penalty: best.p };
}

/** 极简 PNG 写出：模块 → 像素，含 quiet zone。
 *  **RGBA（color type 6）**：jsQR / 多数扫码库按 RGBA 读像素，
 *  写成 RGB 会让解码器把相邻像素错位读出 → 明明码是对的却 DECODE_FAIL（踩过）。 */
function matrixToPng(mods, { scale = 8, quiet = 4 } = {}) {
  const n = mods.length;
  const dim = (n + quiet * 2) * scale;
  const raw = Buffer.alloc((dim * 4 + 1) * dim);        // RGBA + 每行 filter 字节
  let o = 0;
  for (let y = 0; y < dim; y++) {
    raw[o++] = 0;                                       // filter type 0
    const my = Math.floor(y / scale) - quiet;
    for (let x = 0; x < dim; x++) {
      const mx = Math.floor(x / scale) - quiet;
      const dark = my >= 0 && my < n && mx >= 0 && mx < n && mods[my][mx];
      const v = dark ? 0 : 255;
      raw[o++] = v; raw[o++] = v; raw[o++] = v; raw[o++] = 255;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(dim, 0);
  ihdr.writeUInt32BE(dim, 4);
  ihdr[8] = 8;      // bit depth
  ihdr[9] = 6;      // color type: truecolor + alpha (RGBA)
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const t = Buffer.from(type, 'ascii');
    const crcBuf = Buffer.concat([t, data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(crcBuf) >>> 0, 0);
    return Buffer.concat([len, t, data, crc]);
  };
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

let CRC_TABLE = null;
function crc32(buf) {
  if (!CRC_TABLE) {
    CRC_TABLE = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      CRC_TABLE[n] = c;
    }
  }
  let c = -1;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >>> 8);
  return c ^ -1;
}

module.exports = { encodeQR, matrixToPng, buildMatrix, buildDataCodewords, interleave, ECC_M };
