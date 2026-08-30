// 딸린 파일(첨부)이 있는 문서.
//
// 카탈로그의 /Names /EmbeddedFiles 이름나무에 "이름 → 파일 명세" 로 들어 있다.
// 한글 이름과 압축된 것, 안 압축된 것을 섞어 둔다.
import fs from 'node:fs';
import zlib from 'node:zlib';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));

const A = Buffer.from('첫째 붙임 파일입니다.\n두 줄짜리.\n', 'utf8');
const Bz = zlib.deflateSync(Buffer.from('second attachment, deflated. '.repeat(20), 'latin1'));
const utf16 = (t) => {
  let h = 'FEFF';
  for (const ch of t) h += ch.codePointAt(0).toString(16).padStart(4, '0');
  return `<${h.toUpperCase()}>`;
};

const c = 'BT /F1 18 Tf 40 700 Td (attachments) Tj ET';
const objs = [
  '<< /Type /Catalog /Pages 2 0 R /Names 6 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 760] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  `<< /Length ${c.length} >>\nstream\n${c}\nendstream`,
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  // 이름나무 — 마디를 한 겹 더 둔다
  '<< /EmbeddedFiles << /Kids [7 0 R] >> >>',
  `<< /Names [${utf16('붙임1.txt')} 8 0 R (second.bin) 9 0 R] >>`,
  '<< /Type /Filespec /F (붙임1.txt) /EF << /F 10 0 R >> >>',
  '<< /Type /Filespec /F (second.bin) /EF << /F 11 0 R >> >>',
  Buffer.concat([B(`<< /Length ${A.length} >>\nstream\n`), A, B('\nendstream')]),
  Buffer.concat([B(`<< /Length ${Bz.length} /Filter /FlateDecode >>\nstream\n`), Bz, B('\nendstream')]),
];
let out = B('%PDF-1.5\n');
const offs = [];
for (let i = 0; i < objs.length; i++) {
  offs.push(out.length);
  out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), B(objs[i]), B('\nendobj\n')]);
}
let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
fs.writeFileSync(`${S}/attach.pdf`, Buffer.concat([out, B(x)]));

// XFA 양식 — 내용이 XML 로 따로 들어 있어 쪽에는 안내 한 줄뿐이다
{
  const xml = Buffer.from('<xdp:xdp xmlns:xdp="http://ns.adobe.com/xdp/"><template/></xdp:xdp>', 'latin1');
  const c2 = 'BT /F1 12 Tf 40 700 Td (Please open with Acrobat) Tj ET';
  const objs2 = [
    '<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [] /XFA 6 0 R >> >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 760] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    `<< /Length ${c2.length} >>\nstream\n${c2}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    Buffer.concat([B(`<< /Length ${xml.length} >>\nstream\n`), xml, B('\nendstream')]),
  ];
  let o2 = B('%PDF-1.7\n');
  const of2 = [];
  for (let i = 0; i < objs2.length; i++) {
    of2.push(o2.length);
    o2 = Buffer.concat([o2, B(`${i + 1} 0 obj\n`), B(objs2[i]), B('\nendobj\n')]);
  }
  let x2 = `xref\n0 ${objs2.length + 1}\n0000000000 65535 f \n`;
  for (const o of of2) x2 += String(o).padStart(10, '0') + ' 00000 n \n';
  x2 += `trailer\n<< /Size ${objs2.length + 1} /Root 1 0 R >>\nstartxref\n${o2.length}\n%%EOF\n`;
  fs.writeFileSync(`${S}/xfa.pdf`, Buffer.concat([o2, B(x2)]));
}
console.log('attach.pdf·xfa.pdf 만듦');
