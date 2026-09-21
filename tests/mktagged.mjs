// 태그 PDF 견본 — 구조 나무가 "이건 제목·문단·목록·표·코드" 를 다 적어 둔 두 쪽.
// 어림으로는 틀리게 생긴 것들만 골랐다: 본문 크기의 제목, 20pt 문단, 괘선 없는 표,
// 고정폭 아닌 코드, 두 쪽에 걸친 문단(MCR 꼴), 자원(/Properties)에 적은 MCID,
// 안긴 목록, /Artifact 머리글, 태그 안 붙은 줄 하나.
//
//   node tests/mktagged.mjs tests/fixtures
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
const T = (size, x, y, s) => `BT /F1 ${size} Tf ${x} ${y} Td (${s.replace(/([()])/g, '\\$1')}) Tj ET`;
const MC = (tag, id, body) => `/${tag} <</MCID ${id}>> BDC ${body} EMC`;

const p1 = [
  '/Artifact <</Type /Pagination>> BDC ' + T(8, 72, 760, 'Running head page 1') + ' EMC',
  MC('H1', 0, T(12, 72, 700, 'Plain Sized Heading')),
  MC('P', 1, T(12, 72, 680, 'First paragraph line one') + ' ' + T(12, 72, 666, 'and line two of it.')),
  MC('P', 2, T(20, 72, 630, 'Big but just a paragraph')),
  MC('Lbl', 3, T(12, 72, 600, '\x95')) + ' ' + MC('LBody', 4, T(12, 86, 600, 'Alpha item')),
  MC('Lbl', 5, T(12, 100, 586, '1.')) + ' ' + MC('LBody', 6, T(12, 114, 586, 'Numbered child')),
  MC('Lbl', 7, T(12, 72, 572, '\x95')) + ' ' + MC('LBody', 8, T(12, 86, 572, 'Beta item')),
  '/P /MC0 BDC ' + T(12, 72, 545, 'Property paragraph') + ' EMC',
  MC('TH', 10, T(12, 72, 515, 'Name')) + ' ' + MC('TH', 11, T(12, 200, 515, 'Score')),
  MC('TD', 12, T(12, 72, 500, 'Ann')) + ' ' + MC('TD', 13, T(12, 200, 500, '9')),
  MC('Code', 14, T(12, 72, 470, 'let x = 1;')),
  T(12, 72, 440, 'Loose untagged line'),
  MC('P', 15, T(12, 72, 410, 'This paragraph starts on page one')),
].join('\n');
const p2 = [
  '/Artifact BMC ' + T(8, 72, 760, 'Running head page 2') + ' EMC',
  MC('P', 0, T(12, 72, 700, 'and ends on page two.')),
  MC('H', 1, T(12, 72, 670, 'Section Heading')),
  MC('P', 2, T(12, 72, 650, 'Section body.')),
  MC('TD', 3, T(12, 72, 620, 'Boxed Title')),
  MC('P', 4, T(12, 72, 590, 'Intro before nested table')),
  MC('TD', 5, T(12, 72, 570, 'Left cell')) + ' ' + MC('TD', 6, T(12, 200, 570, 'Right cell')),
].join('\n');

const E = (role, k, extra = '') => `<< /Type /StructElem /S /${role} ${extra} /K ${k} >>`;
const objs = [
  '<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 8 0 R /MarkInfo << /Marked true >> >>',
  '<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> /Properties << /MC0 << /MCID 9 >> >> >> /Contents 5 0 R /StructParents 0 >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  stream(p1),
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R /StructParents 1 >>',
  stream(p2),
  '<< /Type /StructTreeRoot /K [9 0 R] >>',
  E('Document', '[10 0 R 11 0 R 12 0 R 13 0 R 24 0 R 25 0 R 32 0 R 33 0 R 34 0 R 35 0 R]'),
  E('H1', '0', '/Pg 3 0 R'),                    // 10
  E('P', '1', '/Pg 3 0 R'),                     // 11
  E('P', '2', '/Pg 3 0 R'),                     // 12
  E('L', '[14 0 R 21 0 R]', '/Pg 3 0 R'),       // 13
  E('LI', '[15 0 R 16 0 R]'),                   // 14
  E('Lbl', '3'),                                // 15
  E('LBody', '[4 17 0 R]'),                     // 16
  E('L', '[18 0 R]'),                           // 17
  E('LI', '[19 0 R 20 0 R]'),                   // 18
  E('Lbl', '5'),                                // 19
  E('LBody', '6'),                              // 20
  E('LI', '[22 0 R 23 0 R]'),                   // 21
  E('Lbl', '7'),                                // 22
  E('LBody', '8'),                              // 23
  E('P', '9', '/Pg 3 0 R'),                     // 24
  E('Table', '[26 0 R 29 0 R]', '/Pg 3 0 R'),   // 25
  E('TR', '[27 0 R 28 0 R]'),                   // 26
  E('TH', '10'),                                // 27
  E('TH', '11'),                                // 28
  E('TR', '[30 0 R 31 0 R]'),                   // 29
  E('TD', '12'),                                // 30
  E('TD', '13'),                                // 31
  '<< /Type /StructElem /S /Figure /Pg 3 0 R /Alt (A chart of scores) >>', // 32
  E('Code', '14', '/Pg 3 0 R'),                 // 33
  E('P', '[<< /Type /MCR /Pg 3 0 R /MCID 15 >> << /Type /MCR /Pg 6 0 R /MCID 0 >>]'), // 34
  E('Sect', '[36 0 R]'),                        // 35
  E('Sect', '[37 0 R 38 0 R 39 0 R 42 0 R]'),   // 36
  E('H', '1', '/Pg 6 0 R'),                     // 37
  E('P', '2', '/Pg 6 0 R'),                     // 38
  E('Table', '[40 0 R]', '/Pg 6 0 R'),          // 39 — 칸 하나짜리 표(Word 의 제목 띠)
  E('TR', '[41 0 R]'),                          // 40
  E('TD', '3'),                                 // 41
  E('P', '[4 43 0 R]', '/Pg 6 0 R'),            // 42 — 문단 안에 안긴 표(InDesign)
  E('Table', '[44 0 R]'),                       // 43
  E('TR', '[45 0 R 46 0 R]'),                   // 44
  E('TD', '5'),                                 // 45
  E('TD', '6'),                                 // 46
];
fs.writeFileSync(`${S}/tagged.pdf`, build(objs));
console.log('tagged.pdf 만듦 — 두 쪽, 구조 나무 H1·P·L(안긴)·Table·Figure·Code·Sect/H');
