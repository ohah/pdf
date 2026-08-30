// 무작위 퍼저.
//
// r1~r7 은 정해진 입력이라 몇 번을 돌려도 같은 길만 밟는다. 여기서는 씨앗을
// 바꿔 가며 붙임감을 마구 헝클어 넣는다 — 돌릴 때마다 다른 파일이 된다.
// 넘어지면 씨앗을 찍어 두므로 그 값으로 다시 만들어 볼 수 있다.
//
//   node tests/r8.mjs <붙임감 폴더> [씨앗]
import fs from 'fs';
import path from 'path';
import { run } from './adv.mjs';

const S = process.argv[2];
const seed0 = Number(process.argv[3] ?? (Date.now() % 1000000));
let seed = seed0;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
const pick = (a) => a[Math.floor(rnd() * a.length) % a.length];
const int = (n) => Math.floor(rnd() * n);

const names = fs.readdirSync(S).filter((f) => /\.pdf$/i.test(f) && !f.startsWith('.'));

/** 헝클기 한 가지. 이름과 함수를 함께 준다. */
const MUT = [
  ['바이트 몇 개 뒤집기', (b) => {
    const c = Buffer.from(b);
    const n = 1 + int(20);
    for (let i = 0; i < n; i++) c[int(c.length)] ^= 1 << int(8);
    return c;
  }],
  ['한 토막 잘라내기', (b) => {
    const at = int(b.length);
    const len = int(Math.max(1, b.length - at));
    return Buffer.concat([b.subarray(0, at), b.subarray(at + len)]);
  }],
  ['한 토막 두 번 붙이기', (b) => {
    const at = int(b.length);
    const len = int(Math.min(4096, b.length - at));
    return Buffer.concat([b.subarray(0, at + len), b.subarray(at, at + len), b.subarray(at + len)]);
  }],
  ['숫자를 큰 값으로', (b) => Buffer.from(
    b.toString('latin1').replace(/\b\d{1,6}\b/g, (m) => (rnd() < 0.1 ? '4294967295' : m)), 'latin1')],
  ['숫자를 음수로', (b) => Buffer.from(
    b.toString('latin1').replace(/\b(\d{1,4})\b/g, (m) => (rnd() < 0.08 ? '-' + m : m)), 'latin1')],
  ['이름을 딴 이름으로', (b) => {
    const keys = ['/Length', '/Width', '/Height', '/Filter', '/Type', '/Subtype', '/Kids',
      '/Count', '/Contents', '/Resources', '/MediaBox', '/CropBox', '/Mask', '/Decode',
      '/BitsPerComponent', '/ColorSpace', '/Group', '/Encoding', '/FontFile2', '/Names'];
    const from = pick(keys);
    const to = pick(keys);
    return Buffer.from(b.toString('latin1').split(from).join(to), 'latin1');
  }],
  ['참조를 엉뚱한 데로', (b) => Buffer.from(
    b.toString('latin1').replace(/(\d+) 0 R/g, (m, n) => (rnd() < 0.2 ? `${int(50)} 0 R` : m)), 'latin1')],
  ['스트림 표식 지우기', (b) => Buffer.from(
    b.toString('latin1').replace(/endstream/g, (m) => (rnd() < 0.3 ? 'endstrea_' : m)), 'latin1')],
  ['xref 망가뜨리기', (b) => Buffer.from(
    b.toString('latin1').replace(/startxref\s+\d+/, `startxref ${int(1e6)}`), 'latin1')],
  ['0 바이트 심기', (b) => {
    const c = Buffer.from(b);
    const n = 1 + int(50);
    for (let i = 0; i < n; i++) c[int(c.length)] = 0;
    return c;
  }],
  ['머리글 뒤에 쓰레기', (b) => Buffer.concat([
    b.subarray(0, 9), Buffer.alloc(int(2000), 0x41), b.subarray(9),
  ])],
];

console.log(`8회차 — 무작위 헝클기 (씨앗 ${seed0})`);
const N = Number(process.env.FUZZ_N ?? 60);
for (let i = 0; i < N; i++) {
  const name = pick(names);
  const src = fs.readFileSync(path.join(S, name));
  const [mname, fn] = pick(MUT);
  let bad;
  try {
    bad = fn(src);
  } catch {
    continue;
  }
  // 가끔 두 번 헝클어 본다
  if (rnd() < 0.35) {
    const [m2, f2] = pick(MUT);
    try { bad = f2(bad); } catch { /* 그대로 둔다 */ }
    await run(`${name} ${mname}+${m2}`.slice(0, 40), bad);
  } else {
    await run(`${name} ${mname}`.slice(0, 40), bad);
  }
}
