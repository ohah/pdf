import fs from 'fs';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
import { run } from './adv.mjs';
const S = process.argv[2];
const cff = fs.readFileSync(S + '/cff.pdf').toString('latin1');
function withCff(bytes) {
  const i = cff.indexOf('8 0 obj');
  const j = cff.indexOf('endobj', i) + 6;
  const s = Buffer.from(bytes).toString('latin1');
  return Buffer.from(cff.slice(0, i) +
    `8 0 obj\n<< /Subtype /CIDFontType0C /Length ${bytes.length} >>\nstream\n` +
    s + '\nendstream\nendobj' + cff.slice(j), 'latin1');
}
function mkForm(formBody, extra = '', pageExtra = '') {
  const objs = [];
  const out = [];
  const push = (n, b) => out.push(`${n} 0 obj\n${b}\nendobj\n`);
  let s = '%PDF-1.5\n';
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, `<< /Type /Page /Parent 2 0 R ${pageExtra} /Resources << /Font << /F1 6 0 R >> /XObject << /Fm1 5 0 R >> /ExtGState << /G 5 0 R >> >> /Contents 4 0 R >>`);
  const c = 'q /Fm1 Do Q '.repeat(50) + ' /G gs [1 2 3 4 5 6 7 8 9] 0 d 0 0 10 10 re f';
  push(4, `<< /Length ${c.length} >>\nstream\n${c}\nendstream`);
  push(5, `<< /Type /XObject /Subtype /Form ${extra} /Length ${formBody.length} >>\nstream\n${formBody}\nendstream`);
  push(6, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  s += out.join('') + 'trailer\n<< /Size 7 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s, 'latin1');
}
console.log('5회차 — CFF·폼·상태');
await run('CFF 12바이트', withCff(Buffer.from([1,0,4,1,0,0,0,0,0,0,0,0])));
await run('CFF 무작위 4KB', withCff(Buffer.from(Array.from({length:4096},()=>(Math.random()*256)|0))));
await run('CFF 머리만 맞음', withCff(Buffer.concat([Buffer.from([1,0,4,4]), Buffer.alloc(2000)])));
await run('CFF 글리프 6만', withCff((() => {
  const b = Buffer.alloc(64); b[0]=1;b[1]=0;b[2]=4;b[3]=1;
  b.writeUInt16BE(0, 4); // Name INDEX count 0
  b.writeUInt16BE(0, 6); // Top DICT INDEX count 0 → CharStrings 없음
  return b; })()));
await run('CFF 자기참조 오프셋', withCff((() => {
  const b = Buffer.alloc(256); b[0]=1;b[1]=0;b[2]=4;b[3]=1;
  b.writeUInt16BE(0,4); b.writeUInt16BE(1,6); b[8]=1; b[9]=1; b[10]=6;
  b[11]=29; b.writeInt32BE(-5, 12); b[16]=17; // CharStrings = -5
  return b; })()));
await run('폼 자기 자신 그리기', mkForm('q /Fm1 Do Q '.repeat(20), '/BBox [0 0 100 100]'));
await run('폼 BBox 거대', mkForm('0 0 1 rg 0 0 10 10 re f', '/BBox [-1e9 -1e9 1e9 1e9]'));
await run('폼 Matrix 이상', mkForm('0 0 1 rg 0 0 10 10 re f', '/BBox [0 0 10 10] /Matrix [1e30 0 0 1e30 0 0]'));
await run('폼 내용 5MB', mkForm('1 1 m 2 2 l '.repeat(400000), '/BBox [0 0 10 10]'));
await run('폼 BBox 없음', mkForm('0 0 1 rg 0 0 10 10 re f', ''));
await run('ExtGState 가 폼', mkForm('0 0 1 rg 0 0 10 10 re f', '/BBox [0 0 10 10]'));
await run('MediaBox 상속', mkForm('0 0 1 rg 0 0 10 10 re f', '/BBox [0 0 10 10]'));
await run('Rotate 이상값', mkForm('0 0 1 rg 0 0 10 10 re f', '/BBox [0 0 10 10]', '/Rotate 987654321'));
await run('Rotate 음수', mkForm('0 0 1 rg 0 0 10 10 re f', '/BBox [0 0 10 10]', '/Rotate -450'));
await run('Parent 순환', (() => {
  let s = '%PDF-1.5\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  s += '2 0 obj\n<< /Type /Pages /Parent 7 0 R /Count 1 /Kids [3 0 R] >>\nendobj\n';
  s += '7 0 obj\n<< /Type /Pages /Parent 2 0 R /Count 1 /Kids [3 0 R] >>\nendobj\n';
  s += '3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>\nendobj\n';
  const c = 'BT /F1 12 Tf (x) Tj ET';
  s += `4 0 obj\n<< /Length ${c.length} >>\nstream\n${c}\nendstream\nendobj\n`;
  s += 'trailer\n<< /Size 8 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s, 'latin1'); })());

// --- Type1 과 색 공간
const t1 = fs.readFileSync(S + '/type1.pdf').toString('latin1');
function withT1(bytes) {
  const i = t1.indexOf('7 0 obj');
  const j = t1.indexOf('endobj', i) + 6;
  const b = Buffer.from(bytes).toString('latin1');
  return Buffer.from(t1.slice(0, i) +
    `7 0 obj\n<< /Length1 40 /Length2 ${bytes.length - 40} /Length3 0 /Length ${bytes.length} >>\nstream\n` +
    b + '\nendstream\nendobj' + t1.slice(j), 'latin1');
}
const rnd = (n) => Buffer.from(Array.from({length:n},()=>(Math.random()*256)|0));
await run('Type1 무작위 4KB', withT1(rnd(4096)));
await run('Type1 eexec 만 있음', withT1(Buffer.concat([Buffer.from('%!PS\ncurrentfile eexec\n'), rnd(2000)])));
await run('Type1 CharStrings 거대길이', withT1(Buffer.from(
  '%!PS\ncurrentfile eexec\n' + '\x00'.repeat(64) + '/CharStrings 5 dict\n/A 999999999 RD xx ND\n', 'latin1')));
await run('Type1 Subrs 순환', withT1(Buffer.from(
  '%!PS\ncurrentfile eexec\n' + 'x'.repeat(64), 'latin1')));
await run('Type1 빈 스트림', withT1(Buffer.alloc(0)));
function mkCs(csDict, ops) {
  const c = ops;
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, `<< /Type /Page /Parent 2 0 R /Resources << /ColorSpace ${csDict} >> /Contents 4 0 R >>`);
  push(4, `<< /Length ${c.length} >>\nstream\n${c}\nendstream`);
  s2 += 'trailer\n<< /Size 5 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
await run('색공간 자기참조', mkCs('<< /A [/ICCBased 3 0 R] >>', '/A cs 1 1 1 scn 0 0 9 9 re f'));
await run('색공간 성분 999', mkCs('<< /A [/DeviceN [/a /b /c] /DeviceRGB 3 0 R] >>',
  '/A cs ' + '0.5 '.repeat(200) + 'scn 0 0 9 9 re f'));
await run('scn 인자 없음', mkCs('<< /A /DeviceRGB >>', '/A cs scn 0 0 9 9 re f'));
await run('없는 색공간 이름', mkCs('<< /A /DeviceRGB >>', '/ZZZ cs 1 0 0 scn 0 0 9 9 re f'));
await run('Pattern 색공간', mkCs('<< /A /Pattern >>', '/A cs /P0 scn 0 0 9 9 re f'));
await run('cs 10만 번', mkCs('<< /A /DeviceRGB >>', '/A cs '.repeat(100000) + '0 0 9 9 re f'));

// --- 새로 붙인 것들
function mkImg(dict, data, ops) {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, '<< /Type /Page /Parent 2 0 R /Resources << /XObject << /I 5 0 R >> /Font << /F1 6 0 R >> >> /Contents 4 0 R >>');
  push(4, `<< /Length ${ops.length} >>\nstream\n${ops}\nendstream`);
  s2 += `5 0 obj\n<< ${dict} /Length ${data.length} >>\nstream\n` + data.toString('latin1') + '\nendstream\nendobj\n';
  push(6, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  s2 += 'trailer\n<< /Size 7 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
const zl = (b) => require('zlib').deflateSync(b);
await run('스텐실 폭 2만', mkImg('/Type /XObject /Subtype /Image /Width 20000 /Height 20000 /ImageMask true /BitsPerComponent 1 /Filter /FlateDecode', Buffer.alloc(10), 'q 1 0 0 1 0 0 cm /I Do Q'));
await run('스텐실 자료 부족', mkImg('/Type /XObject /Subtype /Image /Width 64 /Height 64 /ImageMask true /BitsPerComponent 1 /Filter /FlateDecode', Buffer.alloc(4), 'q 1 0 0 1 0 0 cm /I Do Q'));
await run('SMask 자기참조', mkImg('/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 5 0 R', Buffer.alloc(20), 'q /I Do Q'));
await run('BPC 4 회색', mkImg('/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 4 /Filter /FlateDecode', Buffer.alloc(40), 'q /I Do Q'));
await run('Tr 10만 번', mkImg('/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8', Buffer.alloc(4), 'BT /F1 12 Tf ' + '3 Tr 0 Tr '.repeat(50000) + '(x) Tj ET'));
await run("따옴표 연산자 10만", mkImg('/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8', Buffer.alloc(4), 'BT /F1 12 Tf 12 TL ' + "(a) ' ".repeat(100000) + 'ET'));
await run('Ts 거대', mkImg('/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8', Buffer.alloc(4), 'BT /F1 12 Tf 1e30 Ts (x) Tj ET'));
