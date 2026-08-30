// 전자 서명이 붙은 시험 문서.
//
// 서명은 "/ByteRange 로 정한 두 토막을 이어 붙인 바이트" 에 대해 만든다.
// 가운데 구멍에는 그 서명(PKCS#7 뭉치)이 16진으로 들어간다. 그래서 만드는
// 차례가 거꾸로다 — 먼저 구멍만 뚫린 파일을 다 쓰고, 자리를 재고, 그 바이트에
// 서명한 뒤, 구멍을 메운다.
//
// 열쇠와 인증서는 fixtures/sig/ 에 넣어 두었다(openssl 로 만든 자체 서명).
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const HOLE = 4096;   // 뭉치가 들어갈 자리 (16진 글자 수)

/** PDF 글자열. 한글은 UTF-16BE 에 BOM 을 붙여 16진으로 적는다. */
function pdfStr(t) {
  let hex = 'FEFF';
  for (const ch of t) {
    const cp = ch.codePointAt(0);
    if (cp > 0xffff) {
      const v = cp - 0x10000;
      hex += (0xd800 + (v >> 10)).toString(16).padStart(4, '0');
      hex += (0xdc00 + (v & 0x3ff)).toString(16).padStart(4, '0');
    } else hex += cp.toString(16).padStart(4, '0');
  }
  return `<${hex.toUpperCase()}>`;
}

function body(sigLen) {
  // 자리를 재려면 길이가 확정돼야 한다. /ByteRange 도 자릿수를 고정해 둔다.
  const rangeTxt = (a, b2, c, d) =>
    `[${String(a).padStart(10)} ${String(b2).padStart(10)} ${String(c).padStart(10)} ${String(d).padStart(10)}]`;
  return { rangeTxt, sigLen };
}

function buildPdf(rangePlaceholder) {
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /SigFlags 3 >> >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>',
    (() => {
      const c = 'BT /F1 14 Tf 20 50 Td (SIGNED DOCUMENT) Tj ET';
      return `<< /Length ${c.length} >>\nstream\n${c}\nendstream`;
    })(),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Type /Annot /Subtype /Widget /FT /Sig /T ${pdfStr('서명칸')} /Rect [10 10 190 40] /V 7 0 R /F 4 >>`,
    `<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /Name ${pdfStr('PDF 시험 서명자')} /M (D:20260830120000+09'00') /Reason ${pdfStr('시험용')} /ByteRange ${rangePlaceholder} /Contents <${'0'.repeat(HOLE)}> >>`,
  ];
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

// 열쇠와 인증서가 없으면 새로 만든다. 개인 열쇠는 저장소에 담지 않는다 —
// 어차피 시험용 자체 서명이고, 서명된 문서 자체는 붙임감으로 들어간다.
if (!fs.existsSync(`${S}/sig/key.pem`)) {
  fs.mkdirSync(`${S}/sig`, { recursive: true });
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048',
    '-keyout', `${S}/sig/key.pem`, '-out', `${S}/sig/cert.pem`,
    '-days', '36500', '-nodes', '-subj', '/CN=PDF 시험 서명자/O=allthatnba'],
    { stdio: 'ignore' });
  console.log('열쇠와 인증서를 새로 만들었다');
}

const PH = `[${'0'.padStart(10)} ${'0'.padStart(10)} ${'0'.padStart(10)} ${'0'.padStart(10)}]`;
let pdf = buildPdf(PH);

// 구멍 자리를 잰다. <...> 를 통째로 빼고 서명한다.
const lt = pdf.indexOf(B(`<${'0'.repeat(HOLE)}>`));
const a = 0, b2 = lt, c = lt + HOLE + 2, d = pdf.length - c;
const range = `[${String(a).padStart(10)} ${String(b2).padStart(10)} ${String(c).padStart(10)} ${String(d).padStart(10)}]`;
if (range.length !== PH.length) throw new Error('자리 길이가 어긋난다');
pdf = Buffer.concat([pdf.subarray(0, pdf.indexOf(B(PH))), B(range),
  pdf.subarray(pdf.indexOf(B(PH)) + PH.length)]);

const signed = Buffer.concat([pdf.subarray(a, a + b2), pdf.subarray(c, c + d)]);
fs.writeFileSync('/tmp/.pdfsig.bin', signed);
const der = execFileSync('openssl', ['smime', '-sign', '-binary', '-in', '/tmp/.pdfsig.bin',
  '-signer', `${S}/sig/cert.pem`, '-inkey', `${S}/sig/key.pem`,
  '-outform', 'DER', '-md', 'sha256'], { maxBuffer: 1 << 22 });
if (der.length * 2 > HOLE) throw new Error('뭉치가 구멍보다 크다');
const hex = Buffer.from(der.toString('hex').padEnd(HOLE, '0'), 'latin1');
hex.copy(pdf, lt + 1);
fs.writeFileSync(`${S}/signed.pdf`, pdf);

// 서명 뒤에 한 글자를 바꾼 것 — 요약값이 어긋나야 한다
const tampered = Buffer.from(pdf);
const at = tampered.indexOf(B('SIGNED DOCUMENT'));
tampered[at] = 'F'.charCodeAt(0);
fs.writeFileSync(`${S}/signed-tampered.pdf`, tampered);

console.log(`signed.pdf 만듦 (뭉치 ${der.length}B, 서명 대상 ${signed.length}B)`);
