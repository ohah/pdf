// JBIG2 부호기 — 시험 붙임감을 짓는 데 쓴다.
//
// 규격(ITU-T T.88)의 시험 흐름에 없는 갈래를 시험하려면 그런 파일을 직접
// 지어야 한다. 산술 부호(MQ)와 허프만 표, 세그먼트 틀, PDF 껍데기를 여기
// 모아 두었다. 복호기와 짝을 맞춰 보는 데만 쓰고 제품에는 안 들어간다.
//
// 쓰는 곳: mkjbig2h.mjs(허프만 판의 빈 자리) · mkjbig2big.mjs(스캔 한 장)
import fs from 'fs';



// ===== MQ 부호기 (T.88 부록 E) =====
const QE = [
  [0x5601, 1, 1, 1], [0x3401, 2, 6, 0], [0x1801, 3, 9, 0], [0x0AC1, 4, 12, 0],
  [0x0521, 5, 29, 0], [0x0221, 38, 33, 0], [0x5601, 7, 6, 1], [0x5401, 8, 14, 0],
  [0x4801, 9, 14, 0], [0x3801, 10, 14, 0], [0x3001, 11, 17, 0], [0x2401, 12, 18, 0],
  [0x1C01, 13, 20, 0], [0x1601, 29, 21, 0], [0x5601, 15, 14, 1], [0x5401, 16, 14, 0],
  [0x5101, 17, 15, 0], [0x4801, 18, 16, 0], [0x3801, 19, 17, 0], [0x3401, 20, 18, 0],
  [0x3001, 21, 19, 0], [0x2801, 22, 19, 0], [0x2401, 23, 20, 0], [0x2201, 24, 21, 0],
  [0x1C01, 25, 22, 0], [0x1801, 26, 23, 0], [0x1601, 27, 24, 0], [0x1401, 28, 25, 0],
  [0x1201, 29, 26, 0], [0x1101, 30, 27, 0], [0x0AC1, 31, 28, 0], [0x09C1, 32, 29, 0],
  [0x08A1, 33, 30, 0], [0x0521, 34, 31, 0], [0x0441, 35, 32, 0], [0x02A1, 36, 33, 0],
  [0x0221, 37, 34, 0], [0x0141, 38, 35, 0], [0x0111, 39, 36, 0], [0x0085, 40, 37, 0],
  [0x0049, 41, 38, 0], [0x0025, 42, 39, 0], [0x0015, 43, 40, 0], [0x0009, 44, 41, 0],
  [0x0005, 45, 42, 0], [0x0001, 45, 43, 0], [0x5601, 46, 46, 0],
];

export class MQEnc {
  constructor() {
    // 첫 바이트 앞에 한 칸을 비워 둔다 — BYTEOUT 이 직전 바이트를 본다.
    this.buf = [0];
    this.bp = 0;
    this.A = 0x8000;
    this.C = 0;
    this.ct = 12;
    this.cx = new Map();   // 문맥마다 {i, mps}
  }
  byteout() {
    if (this.buf[this.bp] === 0xff) {
      this.bp++; this.buf[this.bp] = (this.C >>> 20) & 0xff; this.C &= 0xfffff; this.ct = 7;
    } else if ((this.C & 0x8000000) === 0) {
      this.bp++; this.buf[this.bp] = (this.C >>> 19) & 0xff; this.C &= 0x7ffff; this.ct = 8;
    } else {
      this.buf[this.bp]++;
      if (this.buf[this.bp] === 0xff) {
        this.C &= 0x7ffffff;
        this.bp++; this.buf[this.bp] = (this.C >>> 20) & 0xff; this.C &= 0xfffff; this.ct = 7;
      } else {
        this.bp++; this.buf[this.bp] = (this.C >>> 19) & 0xff; this.C &= 0x7ffff; this.ct = 8;
      }
    }
  }
  renorm() {
    do {
      this.A = (this.A << 1) & 0xffff;
      this.C = (this.C << 1) >>> 0;
      this.ct--;
      if (this.ct === 0) this.byteout();
    } while ((this.A & 0x8000) === 0);
  }
  encode(ctx, d) {
    let st = this.cx.get(ctx);
    if (!st) { st = { i: 0, mps: 0 }; this.cx.set(ctx, st); }
    const [qe, nmps, nlps, sw] = QE[st.i];
    if (d === st.mps) {
      this.A -= qe;
      if ((this.A & 0x8000) === 0) {
        if (this.A < qe) this.A = qe; else this.C = (this.C + qe) >>> 0;
        st.i = nmps;
        this.renorm();
      } else {
        this.C = (this.C + qe) >>> 0;
      }
    } else {
      this.A -= qe;
      if (this.A < qe) this.C = (this.C + qe) >>> 0; else this.A = qe;
      if (sw) st.mps ^= 1;
      st.i = nlps;
      this.renorm();
    }
  }
  flush() {
    const t = (this.C + this.A) >>> 0;
    this.C = (this.C | 0xffff) >>> 0;
    if (this.C >= t) this.C = (this.C - 0x8000) >>> 0;
    this.C = (this.C << this.ct) >>> 0; this.byteout();
    this.C = (this.C << this.ct) >>> 0; this.byteout();
    if (this.buf[this.bp] !== 0xff) this.bp++;
    return Buffer.from(this.buf.slice(1, this.bp));
  }
}

// ===== 세밀화 부호기 (6.3, 판 1) =====
//
// 복호기와 같은 차례로 문맥을 만들어 실제 화소를 부호로 적는다. 판 1 은
// 자리표(AT)가 없어 머리글이 짧다.
const RCOD = [[-1, -1], [0, -1], [1, -1], [-1, 0]];
const RREF = [[0, -1], [-1, 0], [0, 0], [1, 0], [0, 1], [1, 1]];

const at = (bm, x, y) => (y < 0 || y >= bm.length || x < 0 || x >= bm[0].length ? 0 : bm[y][x]);

export function encodeRefine(dst, ref, dx, dy) {
  const mq = new MQEnc();
  for (let y = 0; y < dst.length; y++) {
    for (let x = 0; x < dst[0].length; x++) {
      let ctx = 0;
      for (const [ox, oy] of RCOD) ctx = (ctx << 1) | at(dst, x + ox, y + oy);
      for (const [ox, oy] of RREF) ctx = (ctx << 1) | at(ref, x - dx + ox, y - dy + oy);
      mq.encode(ctx, dst[y][x]);
    }
  }
  return mq.flush();
}

// ===== 허프만 쓰기 =====
export const OOB = 2, LOW = 1;
// 규격 표 (부록 B). {앞자리 길이, 범위 비트, 낮은 값, 갈래}
export const B1 = [[1, 4, 0], [2, 8, 16], [3, 16, 272], [3, 32, 65808]];
export const B2 = [[1, 0, 0], [2, 0, 1], [3, 0, 2], [4, 3, 3], [5, 6, 11], [6, 32, 75], [6, 0, 0, OOB]];
export const B4 = [[1, 0, 1], [2, 0, 2], [3, 0, 3], [4, 3, 4], [5, 6, 12], [5, 32, 76]];
export const B6 = [[5, 10, -2048], [4, 9, -1024], [4, 8, -512], [4, 7, -256], [5, 6, -128], [5, 5, -64],
  [4, 5, -32], [2, 7, 0], [3, 7, 128], [3, 8, 256], [4, 9, 512], [4, 10, 1024],
  [6, 32, -2049, LOW], [6, 32, 2048]];
export const B8 = [[8, 3, -15], [9, 1, -7], [8, 1, -5], [9, 0, -3], [7, 0, -2], [4, 0, -1], [2, 1, 0],
  [5, 0, 2], [6, 0, 3], [3, 4, 4], [6, 1, 20], [4, 4, 22], [4, 5, 38], [5, 6, 70],
  [5, 7, 134], [6, 7, 262], [7, 8, 390], [6, 10, 646], [9, 32, -16, LOW], [9, 32, 1670],
  [2, 0, 0, OOB]];
export const B11 = [[1, 0, 1], [2, 1, 2], [4, 0, 4], [4, 1, 5], [5, 1, 7], [5, 2, 9], [6, 2, 13],
  [7, 2, 17], [7, 3, 21], [7, 4, 29], [7, 5, 45], [7, 6, 77], [7, 32, 141]];
export const B15 = [[7, 4, -24], [6, 2, -8], [5, 1, -4], [4, 0, -2], [3, 0, -1], [1, 0, 0], [3, 0, 1],
  [4, 0, 2], [5, 1, 3], [6, 2, 5], [7, 4, 9], [7, 32, -25, LOW], [7, 32, 25]];

/** 앞자리 번호를 길이순으로 매긴다 (B.3). */
export function assignCodes(pre) {
  const cnt = new Array(34).fill(0);
  for (const v of pre) if (v > 0 && v <= 32) cnt[v]++;
  const codes = new Array(pre.length).fill(0);
  // 길이마다의 첫 번호는 "앞 길이의 첫 번호 + 그 길이의 개수" 를 왼쪽으로
  // 한 칸 민 값이다. 나눠 준 번호를 도로 세면 안 된다.
  let base = 0;
  for (let len = 1; len <= 32; len++) {
    base = (base + cnt[len - 1]) << 1;
    let c = base;
    for (let i = 0; i < pre.length; i++) if (pre[i] === len) codes[i] = c++;
  }
  return codes;
}

export class BW {
  constructor() { this.bits = []; }
  put(v, n) { for (let i = n - 1; i >= 0; i--) this.bits.push((v >> i) & 1); }
  align() { while (this.bits.length % 8) this.bits.push(0); }
  raw(buf) { this.align(); for (const c of buf) this.put(c, 8); }
  bytes() {
    this.align();
    const b = Buffer.alloc(this.bits.length / 8);
    this.bits.forEach((v, i) => { if (v) b[i >> 3] |= 0x80 >> (i & 7); });
    return b;
  }
}

/** 표 하나로 값을 적는다. value 가 null 이면 OOB. */
export function hWrite(w, tab, value) {
  const codes = assignCodes(tab.map((l) => l[0]));
  if (value === null) {
    const i = tab.findIndex((l) => l[3] === OOB);
    if (i < 0) throw new Error('이 표에는 OOB 가 없다');
    w.put(codes[i], tab[i][0]);
    return;
  }
  for (let i = 0; i < tab.length; i++) {
    const [pre, rlen, low, kind] = tab[i];
    if (kind === OOB) continue;
    if (kind === LOW) continue;
    const span = rlen >= 32 ? Infinity : (1 << rlen);
    if (value >= low && value - low < span) {
      w.put(codes[i], pre);
      if (rlen > 0) w.put(value - low, Math.min(rlen, 32));
      return;
    }
  }
  throw new Error(`표에 담을 수 없는 값: ${value}`);
}

// ===== 세그먼트 틀 =====
export function seg(num, type, refs, page, data) {
  const head = Buffer.alloc(5 + 1 + refs.length + 1 + 4);
  head.writeUInt32BE(num, 0);
  head[4] = type;
  head[5] = refs.length << 5;
  refs.forEach((r, i) => { head[6 + i] = r; });
  head[6 + refs.length] = page;
  head.writeUInt32BE(data.length, 7 + refs.length);
  return Buffer.concat([head, data]);
}

/** 쪽 정보 세그먼트 (7.4.8).
 *
 * PDF 안에 담긴 JBIG2 는 파일 머리말이 없는 대신, 쪽에 딸린 첫 세그먼트가
 * 쪽 정보여야 한다. 이게 없으면 규격을 엄히 보는 복호기(poppler 따위)가
 * 통째로 거절한다. 우리 복호기는 너그럽지만, 남들도 읽을 수 있어야
 * 만든 것이 맞는지 서로 맞대 볼 수 있다.
 */
export function pageInfo(num, w, h) {
  const d = Buffer.alloc(19);
  d.writeUInt32BE(w, 0);
  d.writeUInt32BE(h, 4);
  d.writeUInt32BE(0, 8);   // 가로 해상도 — 모름
  d.writeUInt32BE(0, 12);  // 세로 해상도
  d[16] = 0x01;            // 끝내 무손실이다
  d.writeUInt16BE(0, 17);  // 띠로 나누지 않았다
  return seg(num, 48, [], 1, d);
}

/** 문서가 실어 오는 표 하나 (B.2.3). */
export function tableSeg(num, low, high, rlen, prefLens, oob) {
  const w = new BW();
  const ps = 4, rs = 4;
  w.put(prefLens[0], ps); w.put(rlen, rs);   // 하나짜리 범위 줄
  w.put(prefLens[1], ps);                     // 아래로 벗어나는 줄
  w.put(prefLens[2], ps);                     // 위로 벗어나는 줄
  if (oob) w.put(prefLens[3], ps);
  const head = Buffer.alloc(9);
  head[0] = (oob ? 1 : 0) | ((ps - 1) << 1) | ((rs - 1) << 4);
  head.writeInt32BE(low, 1);
  head.writeInt32BE(high, 5);
  return seg(num, 53, [], 1, Buffer.concat([head, w.bytes()]));
}

/** 그 표를 우리 쪽 표 꼴로도 만들어 둔다 (값을 적을 때 쓴다). */
export function tableDef(low, high, rlen, prefLens, oob) {
  const t = [[prefLens[0], rlen, low]];
  t.push([prefLens[1], 32, low - 1, LOW]);
  t.push([prefLens[2], 32, high]);
  if (oob) t.push([prefLens[3], 0, 0, OOB]);
  return t;
}

/** 그림 여럿을 가로로 이어 붙여 날것 비트로 만든다. */
export function rawStrip(syms) {
  const h = syms[0].length;
  const tot = syms.reduce((a, s) => a + s[0].length, 0);
  const stride = (tot + 7) >> 3;
  const out = Buffer.alloc(stride * h);
  let x0 = 0;
  for (const s of syms) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < s[0].length; x++) {
        if (s[y][x]) out[y * stride + ((x0 + x) >> 3)] |= 0x80 >> ((x0 + x) & 7);
      }
    }
    x0 += s[0].length;
  }
  return out;
}

/** 허프만 글자 사전 — 한 줄에 담아 날것 그림으로 (세밀화 없음). */
export function symDictRaw(num, syms, tabs) {
  const t_dh = tabs?.dh ?? B4;
  const t_dw = tabs?.dw ?? B2;
  const selDh = tabs?.dh ? 3 : 0;
  const selDw = tabs?.dw ? 3 : 0;
  const w = new BW();
  const h = syms[0].length;
  hWrite(w, t_dh, h);
  let prev = 0;
  for (const s of syms) { hWrite(w, t_dw, s[0].length - prev); prev = s[0].length; }
  hWrite(w, t_dw, null);          // OOB — 줄 끝
  hWrite(w, B1, 0);               // BMSIZE 0 = 날것
  w.raw(rawStrip(syms));
  hWrite(w, B1, 0);               // 안 내보낼 글자 0개
  hWrite(w, B1, syms.length);     // 그다음부터 전부 내보낸다
  const head = Buffer.alloc(10);
  head.writeUInt16BE(1 | (selDh << 2) | (selDw << 4), 0);
  head.writeUInt32BE(syms.length, 2);
  head.writeUInt32BE(syms.length, 6);
  return seg(num, 0, tabs?.refs ?? [], 1, Buffer.concat([head, w.bytes()]));
}

/** 허프만 글자 사전 — 앞선 글자를 다듬어 새 글자를 만든다 (6.5.8.2). */
export function symDictRefine(num, refSeg, nIn, target, ref) {
  const w = new BW();
  const h = target.length;
  hWrite(w, B4, h);
  hWrite(w, B2, target[0].length);
  hWrite(w, B1, 1);                       // REFAGGNINST = 1
  const codeLen = Math.max(1, Math.ceil(Math.log2(nIn + 1)));
  w.put(0, codeLen);                      // 밑그림으로 쓸 글자 번호
  hWrite(w, B15, 0);                      // RDX
  hWrite(w, B15, 0);                      // RDY
  const body = encodeRefine(target, ref, 0, 0);
  hWrite(w, B1, body.length);             // BMSIZE
  w.raw(body);
  hWrite(w, B2, null);                    // OOB — 줄 끝
  hWrite(w, B1, nIn);                     // 앞의 것(들)은 내보내지 않는다
  hWrite(w, B1, 1);                       // 새로 만든 하나만
  const head = Buffer.alloc(10);
  head.writeUInt16BE(1 | 2 | (1 << 12), 0); // SDHUFF · SDREFAGG · 세밀화 판 1
  head.writeUInt32BE(1, 2);
  head.writeUInt32BE(1, 6);
  return seg(num, 0, [refSeg], 1, Buffer.concat([head, w.bytes()]));
}

/** 허프만 글자 영역. refine 을 주면 둘째 글자를 그 그림으로 다듬는다. */
export function textRegion(num, refs, nsym, places, w2, h2, refine) {
  const w = new BW();
  // 글자 번호표 — 길이를 다시 허프만으로 담는다 (7.4.3.1.7)
  const lens = new Array(nsym).fill(nsym === 1 ? 1 : Math.ceil(Math.log2(nsym)));
  const runLens = new Array(35).fill(0);
  for (const L of new Set(lens)) runLens[L] = 1;   // 쓰는 길이마다 한 칸씩
  const runCodes = assignCodes(runLens);
  for (const v of runLens) w.put(v, 4);
  for (const L of lens) w.put(runCodes[L], runLens[L]);
  const symCodes = assignCodes(lens);
  w.align();

  // 규격 표 B.11 은 1 보다 작은 값을 담지 못한다. 첫 STRIPT 은 음수로
  // 뒤집혀 들어가므로 1 을 적어 -1 에서 시작해 한 줄 내려오면 0 이 된다.
  hWrite(w, B11, 1);                      // 첫 STRIPT → -1
  hWrite(w, B11, 1);                      // 이 줄의 DT → 0
  hWrite(w, B6, places[0].x);             // 첫 글자의 가로 자리
  for (let i = 0; i < places.length; i++) {
    const pl = places[i];
    w.put(symCodes[pl.id], lens[pl.id]);
    if (refine) {
      w.put(pl.ref ? 1 : 0, 1);           // RI
      if (pl.ref) {
        hWrite(w, B15, 0);                // RDW
        hWrite(w, B15, 0);                // RDH
        hWrite(w, B15, 0);                // RDX
        hWrite(w, B15, 0);                // RDY
        const body = encodeRefine(pl.ref.dst, pl.ref.src, 0, 0);
        hWrite(w, B1, body.length);       // BMSIZE
        w.raw(body);
      }
    }
    if (i + 1 < places.length) hWrite(w, B8, places[i + 1].ds);
    else hWrite(w, B8, null);             // OOB — 줄 끝
  }
  const head = Buffer.alloc(17 + 2 + 2 + 4);
  head.writeUInt32BE(w2, 0);
  head.writeUInt32BE(h2, 4);
  head.writeUInt32BE(0, 8);
  head.writeUInt32BE(0, 12);
  head[16] = 0;
  // SBHUFF · (세밀화) · 왼쪽 위 기준 · 세밀화 판 1
  head.writeUInt16BE(1 | (refine ? 2 : 0) | (1 << 4) | (1 << 15), 17);
  head.writeUInt16BE(0, 19);              // 표는 다 규격 것
  head.writeUInt32BE(places.length, 21);
  return seg(num, 6, refs, 1, Buffer.concat([head, w.bytes()]));
}

// ===== PDF 틀 =====
export function build(objs) {
  const parts = [Buffer.from('%PDF-1.4\n', 'latin1')];
  let len = parts[0].length;
  const off = [];
  for (let i = 0; i < objs.length; i++) {
    off.push(len);
    const head = Buffer.from(`${i + 1} 0 obj\n`, 'latin1');
    const body = Buffer.isBuffer(objs[i]) ? objs[i] : Buffer.from(objs[i], 'latin1');
    const tail = Buffer.from('\nendobj\n', 'latin1');
    parts.push(head, body, tail);
    len += head.length + body.length + tail.length;
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of off) x += `${String(o).padStart(10, '0')} 00000 n \n`;
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
  parts.push(Buffer.from(x, 'latin1'));
  return Buffer.concat(parts);
}

export function doc(S, name, data, w, h) {
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << /XObject << /I 5 0 R >> >> /Contents 4 0 R >>`,
    (() => {
      const c = `q ${w} 0 0 ${h} 0 0 cm /I Do Q`;
      return Buffer.concat([
        Buffer.from(`<< /Length ${c.length} >>\nstream\n`, 'latin1'),
        Buffer.from(c, 'latin1'), Buffer.from('\nendstream', 'latin1')]);
    })(),
    Buffer.concat([
      Buffer.from(`<< /Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode /Length ${data.length} >>\nstream\n`, 'latin1'),
      data, Buffer.from('\nendstream', 'latin1')]),
  ];
  fs.writeFileSync(`${S}/${name}`, build(objs));
}


/** 여러 높이 묶음을 담은 허프만 글자 사전.
 *
 * 한 묶음에 1024 자까지만 담을 수 있어(복호기 쪽 자리 한계) 큰 사전은
 * 높이를 달리해 여러 묶음으로 나눈다. 높이는 오름차순이어야 한다 —
 * 규격 표 B.4 가 1 보다 작은 차이를 담지 못한다. 묶음 안의 폭도 줄어들면
 * 안 된다(B.2 에 음수 줄이 없다).
 */
export function symDictMulti(num, classes, refs = []) {
  const w = new BW();
  let total = 0;
  let prevH = 0;
  for (const syms of classes) {
    const h = syms[0].length;
    hWrite(w, B4, h - prevH);
    prevH = h;
    let prevW = 0;
    for (const s of syms) { hWrite(w, B2, s[0].length - prevW); prevW = s[0].length; }
    hWrite(w, B2, null);         // OOB — 줄 끝
    hWrite(w, B1, 0);            // BMSIZE 0 = 날것
    w.raw(rawStrip(syms));
    total += syms.length;
  }
  hWrite(w, B1, 0);              // 안 내보낼 글자 0개
  hWrite(w, B1, total);          // 그다음부터 전부
  const head = Buffer.alloc(10);
  head.writeUInt16BE(1, 0);      // SDHUFF, 표는 다 규격 것
  head.writeUInt32BE(total, 2);
  head.writeUInt32BE(total, 6);
  return seg(num, 0, refs, 1, Buffer.concat([head, w.bytes()]));
}

/** 여러 줄에 걸쳐 글자를 놓는 허프만 글자 영역.
 *
 * rows 는 [{ dt, fs, ids: [번호, ...], gap }] 이다. dt 는 앞 줄과의 간격(1 이상),
 * fs 는 줄의 첫 가로 자리, gap 은 글자 사이 간격이다.
 */
export function textRegionRows(num, refs, nsym, rows, w2, h2) {
  const w = new BW();
  const bits = Math.max(1, Math.ceil(Math.log2(nsym)));
  const runLens = new Array(35).fill(0);
  runLens[bits] = 1;
  const runCodes = assignCodes(runLens);
  for (const v of runLens) w.put(v, 4);
  for (let i = 0; i < nsym; i++) w.put(runCodes[bits], 1);
  const symCodes = assignCodes(new Array(nsym).fill(bits));
  w.align();

  let n = 0;
  hWrite(w, B11, 1);             // 첫 STRIPT → -1
  for (const r of rows) {
    hWrite(w, B11, r.dt);
    hWrite(w, B6, r.fs);
    for (let i = 0; i < r.ids.length; i++) {
      w.put(symCodes[r.ids[i]], bits);
      n += 1;
      if (i + 1 < r.ids.length) hWrite(w, B8, r.gap);
      else hWrite(w, B8, null);  // OOB — 줄 끝
    }
  }
  const head = Buffer.alloc(17 + 2 + 2 + 4);
  head.writeUInt32BE(w2, 0);
  head.writeUInt32BE(h2, 4);
  head.writeUInt32BE(0, 8);
  head.writeUInt32BE(0, 12);
  head[16] = 0;
  head.writeUInt16BE(1 | (1 << 4) | (1 << 15), 17);   // SBHUFF · 왼쪽 위 기준
  head.writeUInt16BE(0, 19);
  head.writeUInt32BE(n, 21);
  return seg(num, 6, refs, 1, Buffer.concat([head, w.bytes()]));
}
