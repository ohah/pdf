// 입력 칸(AcroForm). 글상자·여러 줄·확인란·목록을 하나씩 담는다.
import fs from 'node:fs';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const stream = (dict, d) => Buffer.concat([B(`<< ${dict} /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
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
// 겉모습: 값을 그려 둔 그림
const ap = (w, h, txt) => stream(
  `/Type /XObject /Subtype /Form /BBox [0 0 ${w} ${h}] /Resources << /Font << /Helv 11 0 R >> >>`,
  B(`/Tx BMC q BT /Helv 10 Tf 0 g 2 4 Td (${txt}) Tj ET Q EMC`));

fs.writeFileSync(`${S}/form.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R /AcroForm 10 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << >> /Contents 4 0 R'
    + ' /Annots [5 0 R 6 0 R 7 0 R 8 0 R] >>',
  stream('', B('BT ET')),
  // 글상자
  '<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Mario) /Rect [20 160 200 180]'
    + ' /DA (/Helv 10 Tf 0 g) /MaxLen 40 /Q 0 /AP << /N 9 0 R >> >>',
  // 여러 줄
  '<< /Type /Annot /Subtype /Widget /FT /Tx /T (memo) /Ff 4096 /V (one\\ntwo)'
    + ' /Rect [20 100 200 150] /DA (/Helv 9 Tf 0 g) /AP << /N 9 0 R >> >>',
  // 확인란
  '<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Off /AS /Off'
    + ' /Rect [20 70 36 86] /AP << /N << /Yes 9 0 R /Off 9 0 R >> >> >>',
  // 목록
  '<< /Type /Annot /Subtype /Widget /FT /Ch /T (pick) /V (b) /Opt [(a) (b) (c)]'
    + ' /Rect [20 30 120 50] /DA (/Helv 10 Tf 0 g) /AP << /N 9 0 R >> >>',
  ap(180, 20, 'Mario'),
  '<< /Fields [5 0 R 6 0 R 7 0 R 8 0 R] /DR << /Font << /Helv 11 0 R >> >> /DA (/Helv 0 Tf 0 g) >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
]));
// 라디오 묶음 — 부모 하나(/FT /Btn, /Ff 의 15번 비트)에 위젯 둘이 /Kids 로
// 달려 값을 나눠 갖는다. 값(/V)은 부모가 들고, 위젯은 /AS 로 켜짐만 든다.
fs.writeFileSync(`${S}/radio.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (0 g /Helv 10 Tf) >> >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Annots [6 0 R 7 0 R] /Contents 4 0 R >>',
  stream('', B('0.98 0.98 0.98 rg 0 0 200 200 re f\n')),
  '<< /FT /Btn /Ff 49152 /T (pick) /V /a /Kids [6 0 R 7 0 R] >>',
  '<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [30 120 60 150] /F 4 /AS /a'
    + ' /AP << /N << /a 8 0 R /Off 9 0 R >> >> /MK << /BC [0 0 0] >> >>',
  '<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [110 120 140 150] /F 4 /AS /Off'
    + ' /AP << /N << /b 8 0 R /Off 9 0 R >> >> /MK << /BC [0 0 0] >> >>',
  stream('/Type /XObject /Subtype /Form /BBox [0 0 30 30]', B('0 0 0 rg 8 8 14 14 re f 0 0 0 RG 1 w 0.5 0.5 29 29 re S')),
  stream('/Type /XObject /Subtype /Form /BBox [0 0 30 30]', B('0 0 0 RG 1 w 0.5 0.5 29 29 re S')),
]));
console.log('form.pdf·radio.pdf 만듦');
