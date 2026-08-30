// 표시 내용(BDC)과 인코딩.
//
// <</MCID 299>>BDC 의 << 를 한 글자씩 넘기면 둘째 < 가 16진 문자열의
// 시작으로 보인다. 실제 문서에서 라벨마다 "Í0" 같은 군더더기가 찍히고
// 글자 자리까지 밀렸다.
//
// WinAnsi 의 0x95 는 가운뎃점(•)이다. 코드를 그대로 유니코드로 보면
// 제어문자가 되어 목록 앞의 점이 통째로 사라진다.
import fs from 'node:fs';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const stream = (d) => Buffer.concat([B(`<< /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
function build(objs) {
  let out = B('%PDF-1.7\n');
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
const content =
  '/OC BMC \n' +
  'BT\n/F1 12 Tf\n1 0 0 1 20 160 Tm\n' +
  '/Span <</MCID 299 >>BDC \n(AGE)Tj\nEMC \n' +
  '/Span <</MCID 300 >>BDC \n0 -20 Td\n(HEIGHT)Tj\nEMC \n' +
  // 가운뎃점 (WinAnsi 0x95) 과 따옴표 (0x93 0x94)
  '0 -20 Td\n(\x95 bullet \x93quoted\x94)Tj\n' +
  // /Differences 로 세 칸 밀어 놓은 글꼴
  '/F2 12 Tf\n0 -20 Td\n(DEF)Tj\n' +
  'ET\nEMC\n';
fs.writeFileSync(`${S}/mcid.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>',
  stream(B(content)),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  // 코드 68(D) 69(E) 70(F) 에 A B C 를 앉힌다 — 세 칸 밀린 인코딩
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [68 /A /B /C] >> >>',
]));
console.log('mcid.pdf 만듦');
