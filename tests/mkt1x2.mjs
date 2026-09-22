// Type1(FontFile) 글꼴이 한 쪽에 둘 — type1x2.pdf. 둘째 글꼴로만 글자를 찍는다.
// 둘째 글꼴의 글리프 프로그램 자리가 첫 글꼴 기준으로 어긋나던 결함의 견본
// (pdfTeX 논문의 본문이 조각나던 것). type1.pdf 의 글꼴 프로그램을 두 번 싣는다.
//
//   node tests/mkt1x2.mjs tests/fixtures
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';
const src = fs.readFileSync(`${S}/type1.pdf`);
const txt = src.toString('latin1');
// 7 0 obj 의 스트림(글꼴 프로그램)을 그대로 뗀다
const m = /7 0 obj\s*(<<[^]*?>>)\s*stream\r?\n/.exec(txt);
const dictStr = m[1];
const start = m.index + m[0].length;
const end = txt.indexOf('endstream', start);
const font = src.subarray(start, end);
const B = (x) => Buffer.from(x, 'latin1');
const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>',
  '<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R /F2 8 0 R >> >> /Contents 4 0 R >>',
  Buffer.concat([B('<< /Length 68 >>\nstream\nBT /F1 64 Tf 60 700 Td (A) Tj ET\nBT /F2 64 Tf 60 600 Td (ABCD) Tj ET\nendstream')]),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Test /FirstChar 65 /LastChar 68 /Widths [600 600 600 600] /FontDescriptor 6 0 R >>',
  '<< /Type /FontDescriptor /FontName /Test /Flags 4 /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontBBox [0 0 600 800] /FontFile 7 0 R >>',
  Buffer.concat([B(dictStr + '\nstream\n'), font, B('endstream')]),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Test2 /FirstChar 65 /LastChar 68 /Widths [600 600 600 600] /FontDescriptor 9 0 R >>',
  '<< /Type /FontDescriptor /FontName /Test2 /Flags 4 /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontBBox [0 0 600 800] /FontFile 10 0 R >>',
  Buffer.concat([B(dictStr + '\nstream\n'), font, B('endstream')]),
];
let out = B('%PDF-1.4\n');
const offs = [];
for (let i = 0; i < objs.length; i++) { offs.push(out.length); out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), Buffer.isBuffer(objs[i]) ? objs[i] : B(objs[i]), B('\nendobj\n')]); }
let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
fs.writeFileSync(`${S}/type1x2.pdf`, Buffer.concat([out, B(x)]));
console.log('type1x2.pdf 만듦 — Type1 글꼴 둘, 둘째로 ABCD');
