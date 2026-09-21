// 글자 뽑기 견본 — 자간으로 갈라진 낱말과 합자.
//
//   node tests/mktext.mjs tests/fixtures
//
// "Pro" 15 "vided" 처럼 TJ 자간(양수=당김)으로 갈라진 조각은 한 낱말이고, 진짜 빈칸은
// 틈이 넓다. 합자 fi 는 ToUnicode 에서 <0C> <00660069> 처럼 글자 둘로 간다 —
// 앞 4자리만 읽으면 "fgures" 가 된다.
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
const stream = (dict, d) => Buffer.concat([B(`<< ${dict} /Length ${Buffer.byteLength(d, 'latin1')} >>\nstream\n`), B(d), B('\nendstream')]);
// 코드 0x0C 가 fi, 0x0E 가 ffi. Differences 로 이름을 주고 ToUnicode 로 글자 둘씩.
const tounicode = `/CIDInit /ProcSet findresource begin 12 dict begin begincmap
/CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange
2 beginbfchar
<0C> <00660069>
<0E> <006600660069>
endbfchar
endcmap CMapName currentdict /CMap defineresource pop end end`;
const content = [
  'BT /F1 12 Tf 40 150 Td [(Pro) 15 (vided) -1800 (proper) -2000 (attrib) 20 (ution)] TJ ET',
  'BT /F1 12 Tf 40 120 Td (the \\014gures are e\\016cient) Tj ET',
  'BT /F1 12 Tf 40 90 Td (hello) Tj 60 0 Td (world) Tj ET',
].join('\n');
fs.writeFileSync(`${S}/text-pieces.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /Differences [12 /fi 14 /ffi] >> /ToUnicode 6 0 R >>',
  stream('', content),
  stream('', tounicode),
]));
console.log('text-pieces.pdf 만듦');
