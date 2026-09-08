// 일본어 세로쓰기 CMap 을 쓰는 문서.
//
// UniJIS-UTF16-V 는 범위가 늘 앞으로만 가지 않는다 — 코드 0x2032 는 앞
// 범위(…8243)보다 뒤로 물러난 자리(8242)에서 시작한다. 줄여 실은 표(CM2)는
// 그 차이를 부호 있는 값으로 담으므로, 이 문서가 제대로 나오지 않으면
// 부호 처리가 틀렸다는 뜻이다. 한국어 견본만으로는 이 길을 못 밟는다.
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
// 0x2032 는 되돌이 바로 뒤, 0x2031 은 그 앞 범위 안이다. 둘을 나란히 둔다.
const content = 'BT /F1 24 Tf 40 200 Td <20312032> Tj ET';
fs.writeFileSync(`${S}/vert-jis.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>',
  '<< /Type /Font /Subtype /Type0 /BaseFont /KozMinPr6N-Regular /Encoding /UniJIS-UTF16-V /DescendantFonts [5 0 R] >>',
  '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /KozMinPr6N-Regular /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 6 >> /FontDescriptor 7 0 R /DW 1000 >>',
  `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  '<< /Type /FontDescriptor /FontName /KozMinPr6N-Regular /Flags 4 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 >>',
]));
console.log('vert-jis.pdf 만듦');
