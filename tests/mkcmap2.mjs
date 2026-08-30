// ToUnicode 가 없는 옛 한글 문서. 글자는 CID → 유니코드 표로만 찾을 수 있다.
import fs from 'fs';
const S = process.argv[2];
function build(objs) {
  let out = '%PDF-1.4\n';
  const off = [];
  for (let i = 0; i < objs.length; i++) { off.push(out.length); out += `${i + 1} 0 obj\n${objs[i]}\nendobj\n`; }
  const x = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of off) out += `${String(o).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}
const content = 'BT /F1 24 Tf 20 40 Td <B0A1B0A2B0A3> Tj ET';
fs.writeFileSync(`${S}/cmap2.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>',
  '<< /Type /Font /Subtype /Type0 /BaseFont /Batang /Encoding /KSCms-UHC-H /DescendantFonts [5 0 R] >>',
  '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /Batang /CIDSystemInfo << /Registry (Adobe) /Ordering (Korea1) /Supplement 1 >> /FontDescriptor 7 0 R /DW 1000 >>',
  `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  '<< /Type /FontDescriptor /FontName /Batang /Flags 4 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 >>',
]));
console.log('cmap2.pdf 만듦');
