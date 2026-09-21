// 괘선 없는 표 견본 — bare.pdf. 표 하나와, 표처럼 보이지만 아닌 것 셋.
//   표        머리글 + 세 행, 칸 사이가 넓게 벌어진 숫자 표(괘선 없음)
//   저자 줄   "이름   소속" 두 칸 × 세 줄 — 숫자가 없으니 표가 아니다
//   수식      "y = ax + b   (1)" 번호 붙은 수식 세 줄 — 표가 아니다
//   본문      양끝 맞춤으로 낱말 사이가 조금 벌어진 문단 — 표가 아니다
//
//   node tests/mkbare.mjs tests/fixtures
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';
const B = (x) => Buffer.from(x, 'latin1');
function build(objs) {
  let out = B('%PDF-1.7\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), Buffer.isBuffer(objs[i]) ? objs[i] : B(objs[i]), B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}
const stream = (d) => Buffer.concat([B(`<< /Length ${Buffer.byteLength(d, 'latin1')} >>\nstream\n`), B(d), B('\nendstream')]);
const T = (x, y, s, size = 10) => `BT /F1 ${size} Tf ${x} ${y} Td (${s.replace(/([()])/g, '\\$1')}) Tj ET`;
const row = (y, cells, xs) => cells.map((c, i) => T(xs[i], y, c)).join(' ');
const content = [
  T(72, 740, 'Borderless Table Fixture', 16),
  // 표 — 칸 x 72 / 200 / 300 / 400
  row(700, ['Model', 'Layers', 'Params', 'Top-1'], [72, 200, 300, 400]),
  row(686, ['ViT-Base', '12', '86M', '84.2'], [72, 200, 300, 400]),
  row(672, ['ViT-Large', '24', '307M', '85.3'], [72, 200, 300, 400]),
  row(658, ['ViT-Huge', '32', '632M', '85.1'], [72, 200, 300, 400]),
  // 저자 줄
  row(620, ['Ada Lovelace', 'Analytical Engine Co.'], [72, 300]),
  row(606, ['Alan Turing', 'Bletchley Park'], [72, 300]),
  row(592, ['Grace Hopper', 'Harvard University'], [72, 300]),
  // 번호 붙은 수식
  row(560, ['y = ax + b', '(1)'], [150, 480]),
  row(546, ['z = cy + d', '(2)'], [150, 480]),
  row(532, ['w = ez + f', '(3)'], [150, 480]),
  // 양끝 맞춤 본문 — 낱말마다 따로 찍고 사이를 8pt(크기의 0.8) 벌린다
  ...[500, 488, 476].map((y, k) => ['Justified', 'text', 'with', 'wide', 'gaps', 'line', String(k + 1), 'here'].map((w, i) => T(72 + i * 52, y, w)).join(' ')),
  // 쪽 폭을 다 쓰는 본문 — 실제 문서처럼. 없으면 위의 두 칸 줄들이 두 단으로 보인다
  ...[440, 428, 416, 404, 392, 380, 368, 356, 344].map((y, k) => T(72, y, `Body paragraph line ${k + 1} runs the full width of the page so that no column gutter is found here.`)),
].join('\n');
const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  stream(content),
];
fs.writeFileSync(`${S}/bare.pdf`, build(objs));
console.log('bare.pdf 만듦 — 괘선 없는 표 하나, 표 아닌 것 셋');
