// PDF → Markdown 견본. 세 쪽 — 제목 계층·문단·하이픈·목록·코드·괘선 표·
// 머리말·꼬리말·쪽 번호·두 단.
//
//   node tests/mkmd.mjs tests/fixtures
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
const T = (f, size, x, y, s) => `BT /${f} ${size} Tf ${x} ${y} Td (${s.replace(/([()])/g, '\\$1')}) Tj ET`;
const header = (n) => [T('R', 8, 72, 760, 'Running Head: Markdown Fixture'), T('R', 8, 300, 40, String(n))].join('\n');
// 1쪽 — 제목 계층·문단(하이픈)·목록
const p1 = [
  header(1),
  T('B', 20, 72, 700, 'Markdown Fixture Title'),
  T('B', 14, 72, 660, '1 Introduction'),
  T('R', 10, 72, 640, 'This paragraph runs across two lines and breaks a com-'),
  T('R', 10, 72, 628, 'pound word at the line end. The second para-'),
  T('R', 10, 72, 616, 'graph follows after a gap.'),
  T('R', 10, 72, 590, 'Second paragraph starts here with a self-attention term'),
  T('R', 10, 72, 578, 'and continues on the next line with self-'),
  T('R', 10, 72, 566, 'attention again.'),
  T('B', 12, 72, 536, '1.1 A List'),
  T('R', 10, 72, 516, '\\225 first item'),
  T('R', 10, 72, 504, '\\225 second item that wraps'),
  T('R', 10, 84, 492, 'onto another line'),
  T('R', 10, 72, 480, '\\225 third item'),
].join('\n');
// 2쪽 — 코드·괘선 표
const p2 = [
  header(2),
  T('B', 14, 72, 700, '2 Code and Table'),
  T('C', 9, 72, 680, 'int main(void) {'),
  T('C', 9, 72, 669, '  return 0;'),
  T('C', 9, 72, 658, '}'),
  T('R', 10, 72, 630, 'Table 1: A ruled table.'),
  // 괘선: 가로 4, 세로 3 — 칸마다 끊어 그린다(진짜 문서가 그렇다)
  '0.5 w 72 620 m 200 620 l S 200 620 m 320 620 l S',
  '72 600 m 200 600 l S 200 600 m 320 600 l S 72 580 m 200 580 l S 200 580 m 320 580 l S 72 560 m 200 560 l S 200 560 m 320 560 l S',
  '72 620 m 72 560 l S 200 620 m 200 560 l S 320 620 m 320 560 l S',
  T('B', 10, 76, 606, 'Name'), T('B', 10, 204, 606, 'Value'),
  T('R', 10, 76, 586, 'alpha'), T('R', 10, 204, 586, '1.5'),
  T('R', 10, 76, 566, 'beta'), T('R', 10, 204, 566, '2.0'),
  T('R', 10, 72, 530, 'Text after the table.'),
].join('\n');
// 3쪽 — 두 단
const col = (x, tag) => Array.from({ length: 6 }, (_, i) => T('R', 10, x, 700 - i * 12, `${tag} line ${i + 1} of the column text here`)).join('\n');
const p3 = [header(3), T('B', 14, 72, 730, '3 Two Columns'), col(72, 'Left'), col(320, 'Right'),
  // 굵은 요약 문장이 딩뱃(PUA) 글머리로 시작 — 제목이 아니라 목록이다
  T('B', 11, 72, 600, '\\225 Bold summary sentence that is not a heading'),
  // 제목 뒤 색 바탕 띠 — 그림이 아니다
  '0.9 0.9 1 rg 68 556 200 18 re f', T('B', 14, 72, 560, '4 Heading On A Bar'),
  T('R', 10, 72, 540, 'Body after the bar heading.')].join('\n');
const page = (c) => `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /R 6 0 R /B 7 0 R /C 8 0 R >> >> /Contents ${c} 0 R >>`;
fs.writeFileSync(`${S}/md.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>',
  page(9), page(10), page(11),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>',
  stream(p1), stream(p2), stream(p3),
]));
console.log('md.pdf 만듦');
