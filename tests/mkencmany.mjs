// 스트림 없는 객체가 수천 개인 암호 문서 — 여는 시간이 객체 수에 비례해야 한다.
//
//   node tests/mkencmany.mjs tests/fixtures [객체수=30000] [이름=.enc-many.pdf]
//
// 5MB 가 넘어 저장소에 넣지 않는다 — node.mjs 가 돌릴 때 만든다.
//
// 예전에는 스트림을 풀 때 객체마다 "stream" 을 파일 끝까지 찾아, 스트림 없는
// 객체(구조 요소 따위)가 앞에 몰려 있으면 객체 수 × 파일 크기가 들었다 —
// 756쪽 PDF 규격서를 여는 데 56초(pdf.js 46ms). RC4 40비트, 빈 암호.
import fs from 'node:fs';
import crypto from 'node:crypto';
const S = process.argv[2] ?? 'tests/fixtures';
const N = Number(process.argv[3] ?? 30000);
const NAME = process.argv[4] ?? '.enc-many.pdf';
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const PAD = Buffer.from('28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A', 'hex');
const md5 = (...bs) => crypto.createHash('md5').update(Buffer.concat(bs.map(B))).digest();
function rc4(key, data) {
  const s = new Uint8Array(256); for (let i = 0; i < 256; i++) s[i] = i;
  for (let i = 0, j = 0; i < 256; i++) { j = (j + s[i] + key[i % key.length]) & 255; [s[i], s[j]] = [s[j], s[i]]; }
  const out = Buffer.alloc(data.length);
  for (let k = 0, i = 0, j = 0; k < data.length; k++) { i = (i + 1) & 255; j = (j + s[i]) & 255; [s[i], s[j]] = [s[j], s[i]]; out[k] = data[k] ^ s[(s[i] + s[j]) & 255]; }
  return out;
}
// 표준 보안 처리기 R2 — 사용자·소유자 암호 모두 빈 값
const id0 = Buffer.alloc(16, 7);
const P = -1;
const O = rc4(md5(PAD).subarray(0, 5), PAD);
const key = md5(PAD, O, Buffer.from([P & 255, (P >> 8) & 255, (P >> 16) & 255, (P >>> 24) & 255]), id0).subarray(0, 5);
const U = rc4(key, PAD);
const objKey = (num) => md5(key, Buffer.from([num & 255, (num >> 8) & 255, (num >> 16) & 255, 0, 0])).subarray(0, 10);

const objs = [];
objs.push('<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>');
objs.push('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 ${N + 6} 0 R >> >> /Contents ${N + 5} 0 R >>`);
// 구조 요소 N 개 — 스트림 없는 객체가 앞에 몰린다
objs.push(`<< /Type /StructTreeRoot /K [${Array.from({ length: N }, (_, i) => `${5 + i} 0 R`).join(' ')}] >>`);
for (let i = 0; i < N; i++) objs.push(`<< /Type /StructElem /S /P /P 4 0 R /Pg 3 0 R /K ${i} >>`);
const contentNum = N + 5;
const plain = B('BT /F1 24 Tf 40 100 Td (many objects) Tj ET');
const enc = rc4(objKey(contentNum), plain);
objs.push(Buffer.concat([B(`<< /Length ${enc.length} >>\nstream\n`), enc, B('\nendstream')]));
objs.push('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
// 뒤에 큰 스트림 하나(2MB) — 앞 객체마다 여기까지 훑으면 객체 수 × 2MB 가 든다
const big = rc4(objKey(N + 7), Buffer.alloc(3 * 1024 * 1024, 0x41));
objs.push(Buffer.concat([B(`<< /Length ${big.length} >>\nstream\n`), big, B('\nendstream')]));
const encNum = N + 8;
objs.push(`<< /Filter /Standard /V 1 /R 2 /Length 40 /P ${P} /O <${O.toString('hex')}> /U <${U.toString('hex')}> >>`);

let out = B('%PDF-1.4\n');
const offs = [];
for (let i = 0; i < objs.length; i++) {
  offs.push(out.length);
  out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), B(objs[i]), B('\nendobj\n')]);
}
let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Encrypt ${encNum} 0 R /ID [<${id0.toString('hex')}> <${id0.toString('hex')}>] >>\nstartxref\n${out.length}\n%%EOF\n`;
fs.writeFileSync(`${S}/${NAME}`, Buffer.concat([out, B(x)]));
console.log(`${NAME} 만듦 (객체 ${objs.length}개, ${out.length + x.length}바이트)`);
