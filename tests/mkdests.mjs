// 이름 목적지·뷰어 설정·XMP 가 든 붙임감.
//
//   node tests/mkdests.mjs tests/fixtures
//
// XMP 는 XML 이라 UTF-8 로 담아야 한다. 그래서 문자열이 아니라 바이트로
// 이어 붙여 짓는다 — latin1 문자열로 만들면 한글이 한 바이트로 잘린다.
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'utf8'));

const xmp = B(`<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF
 xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
 xmlns:dc="http://purl.org/dc/elements/1.1/">
 <rdf:Description rdf:about=""><dc:title><rdf:Alt>
  <rdf:li xml:lang="x-default">XMP 제목</rdf:li>
 </rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>
<?xpacket end="w"?>`);
const content = B('BT /F1 12 Tf 40 100 Td (dest) Tj ET');

const objs = [
  B('<< /Type /Catalog /Pages 2 0 R /Names << /Dests 7 0 R >> /ViewerPreferences << /HideToolbar true /DisplayDocTitle true /Direction /R2L /PrintScaling /None >> /Metadata 8 0 R >>'),
  B('<< /Type /Pages /Kids [3 0 R 5 0 R 6 0 R] /Count 3 >>'),
  B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 9 0 R >>'),
  B('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 9 0 R >>'),
  B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 9 0 R >>'),
  B('<< /Names [ (chapter1) [3 0 R /XYZ 0 200 0] (chapter2) [5 0 R /Fit] (last) [6 0 R /Fit] ] >>'),
  Buffer.concat([B(`<< /Type /Metadata /Subtype /XML /Length ${xmp.length} >>\nstream\n`), xmp, B('\nendstream')]),
  Buffer.concat([B(`<< /Length ${content.length} >>\nstream\n`), content, B('\nendstream')]),
];

const parts = [B('%PDF-1.7\n')];
let len = parts[0].length;
const off = [];
objs.forEach((o, i) => {
  off.push(len);
  const head = B(`${i + 1} 0 obj\n`);
  const tail = B('\nendobj\n');
  parts.push(head, o, tail);
  len += head.length + o.length + tail.length;
});
let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of off) x += `${String(o).padStart(10, '0')} 00000 n \n`;
x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
parts.push(B(x));
fs.writeFileSync(`${S}/dests.pdf`, Buffer.concat(parts));
console.log('dests.pdf 만듦 — 이름 목적지 셋·뷰어 설정 넷·XMP(한글 제목)');
