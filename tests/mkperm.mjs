// 권한이 제한된 암호 문서. 인쇄·복사를 막아 둔다.
//
//   node tests/mkperm.mjs tests/fixtures
//
// 표준 보안 처리기 R2/V1(RC4 40비트)다. /P 가 열쇠 유도에 들어가므로
// 손으로 고칠 수 없어 — 여기서 제대로 만든다.
import fs from 'node:fs';
import crypto from 'node:crypto';

const S = process.argv[2] ?? 'tests/fixtures';
const PAD = Buffer.from([
  0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
  0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
]);
const md5 = (b) => crypto.createHash('md5').update(b).digest();
const rc4 = (key, data) => {
  const s = Array.from({ length: 256 }, (_, i) => i);
  let j = 0;
  for (let i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 255;
    [s[i], s[j]] = [s[j], s[i]];
  }
  const out = Buffer.alloc(data.length);
  let i = 0;
  j = 0;
  for (let k = 0; k < data.length; k++) {
    i = (i + 1) & 255;
    j = (j + s[i]) & 255;
    [s[i], s[j]] = [s[j], s[i]];
    out[k] = data[k] ^ s[(s[i] + s[j]) & 255];
  }
  return out;
};

const P = -3904;                    // 인쇄(3)·복사(5) 끔
const id = Buffer.from('0123456789abcdef0123456789abcdef', 'hex');
const pLe = Buffer.alloc(4);
pLe.writeInt32LE(P, 0);

// O = RC4(소유자 암호로 만든 열쇠, 채운 사용자 암호). 둘 다 빈 암호로 둔다.
const ownerKey = md5(PAD).subarray(0, 5);
const O = rc4(ownerKey, PAD);
// 파일 열쇠
const fileKey = md5(Buffer.concat([PAD, O, pLe, id])).subarray(0, 5);
const U = rc4(fileKey, PAD);

const objKey = (num, gen) =>
  md5(Buffer.concat([
    fileKey,
    Buffer.from([num & 255, (num >> 8) & 255, (num >> 16) & 255, gen & 255, (gen >> 8) & 255]),
  ])).subarray(0, Math.min(16, fileKey.length + 5));

const content = Buffer.from('BT /F1 24 Tf 40 700 Td (permission test) Tj ET', 'latin1');
const encContent = rc4(objKey(4, 0), content);

const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  Buffer.concat([Buffer.from(`<< /Length ${encContent.length} >>\nstream\n`, 'latin1'), encContent, Buffer.from('\nendstream', 'latin1')]),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  `<< /Filter /Standard /V 1 /R 2 /P ${P} /O <${O.toString('hex')}> /U <${U.toString('hex')}> >>`,
];

let out = '%PDF-1.4\n';
const off = [];
objs.forEach((o, i) => {
  off.push(out.length);
  out += `${i + 1} 0 obj\n`;
  out += Buffer.isBuffer(o) ? o.toString('latin1') : o;
  out += '\nendobj\n';
});
const x = out.length;
out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of off) out += `${String(o).padStart(10, '0')} 00000 n \n`;
out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Encrypt 6 0 R /ID [<${id.toString('hex')}> <${id.toString('hex')}>] >>\nstartxref\n${x}\n%%EOF\n`;
fs.writeFileSync(`${S}/enc-perm.pdf`, Buffer.from(out, 'latin1'));
console.log(`enc-perm.pdf 만듦 — /P ${P} (인쇄·복사 금지, 빈 암호로 열린다)`);
