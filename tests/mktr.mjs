// 글자 그리기 모드 — Tr 0~7. 4~7 은 글자 모양으로 오려 낸다.
import fs from 'node:fs';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const stream = (d) => Buffer.concat([B(`<< /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
function build(objs) {
  let out = B('%PDF-1.4\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), B(objs[i]), B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}
// 오려 내기: q 안에서 Tr 7 로 글자를 잡고, 그 뒤 사각형을 칠한다.
// 글자 모양으로만 색이 남아야 한다.
const content = [
  'q BT 7 Tr /F1 40 Tf 20 120 Td (CLIP) Tj ET 1 0 0 rg 0 0 300 200 re f Q',
  'BT 3 Tr /F1 12 Tf 20 20 Td (hidden) Tj ET',
  'q BT 4 Tr /F1 20 Tf 20 60 Td (BOTH) Tj ET 0 0 1 rg 0 40 300 40 re f Q',
].join('\n');
fs.writeFileSync(`${S}/trclip.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  stream(B(content)),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
]));
console.log('trclip.pdf 만듦');
