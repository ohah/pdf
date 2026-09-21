// 글자 폭이 엉뚱해지던 두 꼴의 견본 — widths.pdf.
//   1) Type0 의 /DescendantFonts 가 "[6 0 R]" 배열 객체이고 /W 도 딴 객체(Word·InDesign)
//   2) q…Q 안에서 준 Tc 가 Q 뒤에 새는 것
// 셋째 줄은 대조군(표준 Helvetica).
//
//   node tests/mkwidths.mjs tests/fixtures
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
const tu = `/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def
1 begincodespacerange <0000> <FFFF> endcodespacerange
1 beginbfrange <0041> <0043> <0041> endbfrange
endcmap CMapName currentdict /CMap defineresource pop end end`;
const content = [
  'q 5 Tc BT /F1 10 Tf 72 700 Td <004100420043> Tj ET Q',
  'BT /F1 10 Tf 72 680 Td <004100420043> Tj ET',
  'BT /F2 10 Tf 72 660 Td (ABC) Tj ET',
].join('\n');
const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 11 0 R >>',
  '<< /Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts 7 0 R /ToUnicode 8 0 R >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 10 0 R /DW 1000 /W 9 0 R /CIDToGIDMap /Identity >>',
  '[6 0 R]',
  stream(tu),
  '[65 [500 500 500]]',
  '<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>',
  stream(content),
];
fs.writeFileSync(`${S}/widths.pdf`, build(objs));
console.log('widths.pdf 만듦 — 자손 글꼴 배열 객체·/W 참조·Tc 새어 나감');
