// Type3 글꼴 — 글리프가 외곽선이 아니라 작은 콘텐츠 스트림이다.
//
// 크롬이 맥에서 뽑은 문서에 흔해서 예전에는 그 문서로 시험했는데, 그 문서에는
// 애플 독점 글꼴이 함께 박혀 있었다. 시험하려던 것은 Type3 하나뿐이므로
// 여기서 손으로 지어 쓴다.
import fs from 'node:fs';

const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const st = (d) => Buffer.concat([B(`<< /Length ${d.length} >>\nstream\n`), B(d), B('\nendstream')]);

// 글리프 하나가 곧 그림이다. d1 로 폭과 상자를 먼저 알린다.
const SQUARE = '750 0 0 0 750 750 d1\n0 0 750 750 re f';
const TRI = '750 0 0 0 750 750 d1\n0 0 m 750 0 l 375 750 l f';

const objs = [
  B('<< /Type /Catalog /Pages 2 0 R >>'),
  B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
  B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'),
  st('BT /F1 36 Tf 30 120 Td (ABAB) Tj ET'),
  // 글자 이름을 /A·/B 로 두면 이름표로 유니코드를 되찾을 수 있다
  B('<< /Type /Font /Subtype /Type3 /FontBBox [0 0 750 750]'
    + ' /FontMatrix [0.001 0 0 0.001 0 0]'
    + ' /CharProcs << /A 6 0 R /B 7 0 R >>'
    + ' /Encoding << /Type /Encoding /Differences [65 /A /B] >>'
    + ' /FirstChar 65 /LastChar 66 /Widths [750 750] /Resources << >> >>'),
  st(SQUARE),
  st(TRI),
];

let out = B('%PDF-1.4\n');
const offs = [];
for (let i = 0; i < objs.length; i++) {
  offs.push(out.length);
  out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), objs[i], B('\nendobj\n')]);
}
let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
fs.writeFileSync(`${S}/type3.pdf`, Buffer.concat([out, B(x)]));
console.log('type3.pdf 만듦');
