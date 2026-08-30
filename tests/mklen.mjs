// 스트림 길이가 곧이곧대로가 아닌 문서.
//
// /Length 는 대개 숫자지만, `35 0 R` 처럼 딴 객체를 가리켜도 된다. 한글
// 워드프로세서가 뽑은 문서가 그 꼴이라 쪽이 통째로 비어 나왔다. 아예 틀린
// 길이를 적어 놓은 문서도 흔하다 — 그럴 때는 endstream 을 찾아 고쳐야 한다.
//
// 네 갈래를 같은 내용으로 만들어 둔다. 넷 다 같은 글자가 나와야 한다.
import fs from 'node:fs';
import zlib from 'node:zlib';

const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const TEXT = 'BT /F1 18 Tf 40 700 Td (LENGTH TEST ABC) Tj 0 -30 Td (second line 123) Tj ET';
const body = zlib.deflateSync(Buffer.from(TEXT, 'latin1'));

/** kind: 'ok' 곧은 숫자 · 'ref' 딴 객체 · 'small' 너무 작게 · 'big' 너무 크게 */
function make(kind) {
  const lenTxt = kind === 'ref' ? '6 0 R'
    : kind === 'small' ? '5'
    : kind === 'big' ? String(body.length + 4096)
    : String(body.length);
  const objs = [
    B('<< /Type /Catalog /Pages 2 0 R >>'),
    B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 760] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'),
    Buffer.concat([B(`<< /Length ${lenTxt} /Filter /FlateDecode >>\nstream\n`), body, B('\nendstream')]),
    B('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    B(String(body.length)),   // 6번 — ref 갈래가 가리키는 길이 객체
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
  return Buffer.concat([out, B(x)]);
}

for (const k of ['ok', 'ref', 'small', 'big']) fs.writeFileSync(`${S}/len-${k}.pdf`, make(k));
console.log('len-ok·len-ref·len-small·len-big 만듦');
