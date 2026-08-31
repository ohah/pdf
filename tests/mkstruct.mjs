// 태그 PDF — 구조 나무가 든 붙임감.
//
//   node tests/mkstruct.mjs tests/fixtures
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'utf8'));
/** PDF 문자열. 한글이 섞이면 규격대로 UTF-16BE(BOM) 16진수로 적는다. */
const str = (t) => (/^[\x20-\x7e]*$/.test(t)
  ? `(${t})`
  : `<${Buffer.from('\ufeff' + t, 'utf16le').swap16().toString('hex')}>`);

const content = B(`/P <</MCID 0>> BDC BT /F1 18 Tf 40 700 Td (Title) Tj ET EMC
/P <</MCID 1>> BDC BT /F1 12 Tf 40 660 Td (Body text here) Tj ET EMC`);

const objs = [
  B('<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo << /Marked true >> /Lang (en-US) >>'),
  B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
  B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /StructParents 0 >>'),
  B('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  Buffer.concat([B(`<< /Length ${content.length} >>\nstream\n`), content, B('\nendstream')]),
  B('<< /Type /StructTreeRoot /K [7 0 R] >>'),
  B('<< /Type /StructElem /S /Document /P 6 0 R /K [8 0 R 9 0 R] >>'),
  B(`<< /Type /StructElem /S /H1 /P 7 0 R /Pg 3 0 R /Alt ${str('문서 제목')} /K 0 >>`),
  B('<< /Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 1 >>'),
];
const parts = [B('%PDF-1.7\n')];
let len = parts[0].length;
const off = [];
objs.forEach((o, i) => {
  off.push(len);
  const head = B(`${i + 1} 0 obj\n`);
  const tail = B('\nendobj\n');
  parts.push(head, o, tail);
  len += head.length + o.length + tail.length;
});
let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of off) x += `${String(o).padStart(10, '0')} 00000 n \n`;
x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
parts.push(B(x));
fs.writeFileSync(`${S}/struct.pdf`, Buffer.concat(parts));
console.log('struct.pdf 만듦 — Document > H1(대체글) · P');
