// CM1 표를 CM2 로 다시 굽는다 — 범위를 델타·가변길이로 적어 절반 아래로 줄인다.
//
//   node scripts/cmap-cm2.mjs [--write]
//
// CM1 은 범위마다 6바이트(좁은 것) 또는 10바이트(넓은 것)를 고정으로 쓴다.
// 범위는 lo 오름차순이고 CID 도 대개 이어지므로, 앞 범위로부터의 차이만
// 적으면 대부분 한두 바이트로 준다. UniCNS-UTF8-H 가 185,725 → 72,589 이다.
//
// 엔진은 받자마자 CM1 꼴로 펴서 쓴다. 찾기가 이진 탐색이라 번호로 바로
// 집을 수 있어야 하기 때문이다 — 줄이는 것은 오가는 길에서만 한다.
import fs from 'node:fs';
import path from 'node:path';

const DIR = path.join(import.meta.dirname, '../cmaps');

export function readCM1(b) {
  if (b.length < 9 || b.toString('latin1', 0, 3) !== 'CM1') return null;
  const wmode = b[3], wide = b[4] === 1;
  const ns = b.readUInt16LE(5), nr = b.readUInt16LE(7);
  const sw = wide ? 9 : 5, rw = wide ? 10 : 6;
  let o = 9;
  const sp = [];
  for (let i = 0; i < ns; i++) {
    sp.push(wide ? [b[o], b.readUInt32LE(o + 1), b.readUInt32LE(o + 5)]
                 : [b[o], b.readUInt16LE(o + 1), b.readUInt16LE(o + 3)]);
    o += sw;
  }
  const cr = [];
  for (let i = 0; i < nr; i++) {
    cr.push(wide ? [b.readUInt32LE(o), b.readUInt32LE(o + 4), b.readUInt16LE(o + 8)]
                 : [b.readUInt16LE(o), b.readUInt16LE(o + 2), b.readUInt16LE(o + 4)]);
    o += rw;
  }
  return { wmode, wide, sp, cr };
}

const put = (out, n) => { // 가변길이 (7비트씩, 최상위 비트가 이어짐 표시)
  for (;;) { const b = n & 0x7f; n = Math.floor(n / 128); if (n) out.push(b | 0x80); else { out.push(b); return; } }
};
const zig = (n) => (n >= 0 ? n * 2 : -n * 2 - 1);

export function packCM2(c) {
  const head = [0x43, 0x4d, 0x32, c.wmode, c.wide ? 1 : 0];
  const sw = c.wide ? 9 : 5;
  const sb = Buffer.alloc(c.sp.length * sw);
  let o = 0;
  for (const [nb, lo, hi] of c.sp) {
    sb.writeUInt8(nb, o);
    if (c.wide) { sb.writeUInt32LE(lo, o + 1); sb.writeUInt32LE(hi, o + 5); }
    else { sb.writeUInt16LE(lo, o + 1); sb.writeUInt16LE(hi, o + 3); }
    o += sw;
  }
  const body = [];
  let prevHi = 0, prevCid = 0;
  for (const [lo, hi, cid] of c.cr) {
    put(body, zig(lo - prevHi));
    put(body, hi - lo);
    put(body, zig(cid - prevCid));
    prevHi = hi; prevCid = cid + (hi - lo);
  }
  const cnt = Buffer.alloc(4); cnt.writeUInt16LE(c.sp.length, 0); cnt.writeUInt16LE(c.cr.length, 2);
  return Buffer.concat([Buffer.from(head), cnt, sb, Buffer.from(body)]);
}

/** CM2 를 다시 CM1 로 편다 — 왕복이 맞는지 보는 데 쓴다. */
export function expandCM2(b) {
  if (b.length < 9 || b.toString('latin1', 0, 3) !== 'CM2') return null;
  const wmode = b[3], wide = b[4] === 1;
  const ns = b.readUInt16LE(5), nr = b.readUInt16LE(7);
  const sw = wide ? 9 : 5;
  let o = 9;
  const sp = [];
  for (let i = 0; i < ns; i++) {
    sp.push(wide ? [b[o], b.readUInt32LE(o + 1), b.readUInt32LE(o + 5)]
                 : [b[o], b.readUInt16LE(o + 1), b.readUInt16LE(o + 3)]);
    o += sw;
  }
  const get = () => { let n = 0, s = 1; for (;;) { const c = b[o++]; n += (c & 0x7f) * s; if (!(c & 0x80)) return n; s *= 128; } };
  const unzig = (n) => (n % 2 ? -(n + 1) / 2 : n / 2);
  const cr = [];
  let prevHi = 0, prevCid = 0;
  for (let i = 0; i < nr; i++) {
    const lo = prevHi + unzig(get());
    const hi = lo + get();
    const cid = prevCid + unzig(get());
    cr.push([lo, hi, cid]);
    prevHi = hi; prevCid = cid + (hi - lo);
  }
  return { wmode, wide, sp, cr };
}

/** CU1 — CID 로 바로 집는 유니코드 표. 머리 4바이트 + CID 마다 u16. */
export function readCU1(b) {
  if (b.length < 4 || b.toString('latin1', 0, 3) !== 'CU1') return null;
  const n = (b.length - 4) >> 1;
  const v = new Array(n);
  for (let i = 0; i < n; i++) v[i] = b.readUInt16LE(4 + i * 2);
  return { pad: b[3], v };
}

/** CU2 — 앞 값으로부터의 차이를 가변길이로. 빈 칸(0)이 이어지는 데가 많다. */
export function packCU2(c) {
  const body = [];
  let prev = 0;
  for (const x of c.v) { put(body, zig(x - prev)); prev = x; }
  const head = Buffer.alloc(8);
  head.write('CU2', 0, 'latin1');
  head.writeUInt8(c.pad, 3);
  head.writeUInt32LE(c.v.length, 4);
  return Buffer.concat([head, Buffer.from(body)]);
}

export function expandCU2(b) {
  if (b.length < 8 || b.toString('latin1', 0, 3) !== 'CU2') return null;
  const n = b.readUInt32LE(4);
  let o = 8;
  const get = () => { let x = 0, s = 1; for (;;) { const c = b[o++]; x += (c & 0x7f) * s; if (!(c & 0x80)) return x; s *= 128; } };
  const unzig = (x) => (x % 2 ? -(x + 1) / 2 : x / 2);
  const v = new Array(n);
  let prev = 0;
  for (let i = 0; i < n; i++) { prev += unzig(get()); v[i] = prev; }
  return { pad: b[3], v };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const write = process.argv.includes('--write');
  let a = 0, b2 = 0, bad = 0, n = 0;
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.bin')).sort()) {
    const raw = fs.readFileSync(path.join(DIR, f));
    const c = readCM1(raw);
    let p, back, same;
    if (c) {
      p = packCM2(c);
      back = expandCM2(p);
      same = back && back.wmode === c.wmode && back.wide === c.wide &&
        JSON.stringify(back.sp) === JSON.stringify(c.sp) &&
        JSON.stringify(back.cr) === JSON.stringify(c.cr);
    } else {
      const u = readCU1(raw);
      if (!u) continue;                      // 이미 줄인 것
      p = packCU2(u);
      const ub = expandCU2(p);
      same = ub && ub.pad === u.pad && ub.v.length === u.v.length &&
        ub.v.every((x, i) => x === u.v[i]);
    }
    if (!same) { console.log(`  ✗ ${f} 왕복이 안 맞는다`); bad++; }
    a += raw.length; b2 += p.length; n++;
    if (write && same) fs.writeFileSync(path.join(DIR, f), p);
  }
  console.log(`CM1 → CM2  ${n}개 · ${a.toLocaleString()} → ${b2.toLocaleString()} bytes (${(b2 * 100 / a).toFixed(0)}%) · 왕복 안 맞음 ${bad}`);
}
