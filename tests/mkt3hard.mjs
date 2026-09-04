// Type3 글리프 중 "받아 적으면 안 되는" 것들을 모아 둔 문서.
//
// 글리프가 낸 명령을 받아 두고 되풀이하는 길이 생겼다. 벡터만 그리는
// 글리프는 늘 같은 명령을 내지만, 그림이나 글자를 품거나 상태를 건드리는
// 글리프는 그렇지 않다 — 명령 안에 그림 번호·글자 자리가 섞여 든다.
// 그런 것을 걸러 내는지 보려면 그런 글리프가 있어야 한다.
//
// 글리프마다 두 번 이상 나오게 두어, 되풀이 길을 반드시 밟게 한다.
import fs from 'node:fs';

const S = process.argv[2] ?? 'tests/fixtures';
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const st = (d, extra = '') =>
  Buffer.concat([B(`<< /Length ${d.length}${extra} >>\nstream\n`), B(d), B('\nendstream')]);

// 2×2 RGB 그림
const IMG = Buffer.from([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]);

const objs = [
  /* 1 */ B('<< /Type /Catalog /Pages 2 0 R >>'),
  /* 2 */ B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
  /* 3 */ B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 220]'
    + ' /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'),
  // 같은 글리프를 크기·자리를 달리해 여러 번 쓴다
  /* 4 */ st('BT /F1 24 Tf 20 170 Td (ABCDABCD) Tj ET\n'
    + 'BT /F1 48 Tf 20 90 Td (ABCD) Tj ET\n'
    + 'BT /F1 12 Tf 20 40 Td (DCBA) Tj ET'),
  /* 5 */ B('<< /Type /Font /Subtype /Type3 /FontBBox [0 0 750 750]'
    + ' /FontMatrix [0.001 0 0 0.001 0 0]'
    + ' /CharProcs << /A 6 0 R /B 7 0 R /C 8 0 R /D 9 0 R >>'
    + ' /Encoding << /Type /Encoding /Differences [65 /A /B /C /D] >>'
    + ' /FirstChar 65 /LastChar 68 /Widths [750 750 750 750]'
    + ' /Resources << /XObject << /Im0 10 0 R >> /Font << /H1 11 0 R >>'
    + ' /ExtGState << /GS0 12 0 R >> >> >>'),
  // A — 벡터만. 받아 적어도 된다.
  /* 6 */ st('750 0 0 0 750 750 d1\n0 0 750 750 re f'),
  // B — 그림을 품는다. 그릴 때마다 그림 자리가 새로 잡힌다.
  /* 7 */ st('750 0 0 0 750 750 d0\nq 750 0 0 750 0 0 cm /Im0 Do Q'),
  // C — 글자를 품는다. 글자층 자리가 그때그때 다르다.
  /* 8 */ st('750 0 0 0 750 750 d0\nBT /H1 600 Tf 0 100 Td (x) Tj ET'),
  // D — 투명도를 건드린다.
  /* 9 */ st('750 0 0 0 750 750 d0\nq /GS0 gs 0 0 750 750 re f Q'),
  /* 10 */ st(IMG, ' /Type /XObject /Subtype /Image /Width 2 /Height 2'
    + ' /ColorSpace /DeviceRGB /BitsPerComponent 8'),
  /* 11 */ B('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  /* 12 */ B('<< /Type /ExtGState /ca 0.5 /CA 0.5 >>'),
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
fs.writeFileSync(`${S}/t3hard.pdf`, Buffer.concat([out, B(x)]));
console.log('t3hard.pdf 지음');
