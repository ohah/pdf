// 스캔 한 장 — 글자 사전이 globals 에 따로 있고, 사전이 둘이다.
//
// 예전에는 어디서 받아왔는지 적혀 있지 않은 스캔 문서를 그대로 두었다.
// 남의 문서일 수 있어 우리 부호기로 같은 성질을 지어 갈아 끼운다.
//
//   · /JBIG2Globals 에 사전 하나, 그림 자료 안에 사전 하나 — 둘을 이어 붙여야
//     글자 번호가 맞는다 (예전에 뒤 사전이 앞 사전을 덮어쓰던 버그를 잡은 자리)
//   · 쪽이 아주 커서(5188x6930) 4.5MB 짜리 비트맵을 잡는다
//   · 글자를 수천 번 놓는다
//
// 부호기는 jbig2enc.mjs 에 있다.
import { build, pageInfo, symDictMulti, textRegionRows } from './jbig2enc.mjs';
import fs from 'fs';

const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));

// 글자 모양 — 정해진 씨앗에서 뽑아 늘 같은 파일이 나오게 한다
let seed = 20260830;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
function glyph(w, h) {
  const g = Array.from({ length: h }, () => new Array(w).fill(0));
  // 테두리를 두르고 안을 성기게 찍는다 — 글자처럼 보이는 덩어리가 된다
  for (let x = 1; x < w - 1; x++) { g[0][x] = 1; g[h - 1][x] = 1; }
  for (let y = 1; y < h - 1; y++) { g[y][0] = 1; g[y][w - 1] = 1; }
  for (let y = 2; y < h - 2; y++) for (let x = 2; x < w - 2; x++) if (rnd() < 0.35) g[y][x] = 1;
  return g;
}
/** 높이가 다른 묶음 셋. 묶음마다 폭은 같게 둔다. */
const classes = (n) => [8, 10, 12].map((h) => Array.from({ length: n }, () => glyph(9, h)));

const CLASS_N = 400;
const A = classes(CLASS_N);      // globals 쪽 사전
const Bd = classes(CLASS_N);     // 그림 자료 쪽 사전
const NSYM = (A.length + Bd.length) * CLASS_N;

const globals = symDictMulti(0, A);

/** 글자를 줄 지어 놓는다. */
function rows(count, perRow, gap, dt) {
  const out = [];
  let left = count;
  while (left > 0) {
    const k = Math.min(perRow, left);
    out.push({ dt, fs: 40, gap, ids: Array.from({ length: k }, () => Math.floor(rnd() * NSYM)) });
    left -= k;
  }
  return out;
}

// 작은 그림 하나와 큰 그림 하나 — 예전 파일도 둘이었다
const SMALL = [1034, 204];
const BIG = [5188, 6930];
const small = Buffer.concat([
  pageInfo(3, SMALL[0], SMALL[1]),
  symDictMulti(1, Bd, []),
  textRegionRows(2, [0, 1], NSYM, rows(300, 60, 6, 16), SMALL[0], SMALL[1]),
]);
const big = Buffer.concat([
  pageInfo(3, BIG[0], BIG[1]),
  symDictMulti(1, Bd, []),
  textRegionRows(2, [0, 1], NSYM, rows(20000, 380, 4, 22), BIG[0], BIG[1]),
]);

const img = (n, data, w, h) => Buffer.concat([
  B(`<< /Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ImageMask true`
    + ` /BitsPerComponent 1 /Filter /JBIG2Decode`
    + ` /DecodeParms << /JBIG2Globals ${n} 0 R >> /Length ${data.length} >>\nstream\n`),
  data, B('\nendstream'),
]);
const content = 'q 500 0 0 100 40 680 cm /I0 Do Q q 500 0 0 660 40 10 cm /I1 Do Q';
fs.writeFileSync(`${S}/jb-globals.pdf`, build([
  B('<< /Type /Catalog /Pages 2 0 R >>'),
  B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
  B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 792]'
    + ' /Resources << /XObject << /I0 5 0 R /I1 6 0 R >> >> /Contents 4 0 R >>'),
  B(`<< /Length ${content.length} >>\nstream\n${content}\nendstream`),
  img(7, small, SMALL[0], SMALL[1]),
  img(7, big, BIG[0], BIG[1]),
  Buffer.concat([B(`<< /Length ${globals.length} >>\nstream\n`), globals, B('\nendstream')]),
]));
console.log(`jb-globals.pdf 만듦 — 글자 ${NSYM}자, 놓기 20300번`);
