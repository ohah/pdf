// 실문서 100편 맞대기(tests/corpus-*.{mjs,py})에서 드러난 결함들의 견본.
//   bigobj.pdf     객체 스트림이 원본보다 크게 풀림(pikepdf·iText) — /Pages 가 그 안에
//   bigcontent.pdf 쪽 내용이 4배 넘게 풀림(arXiv 그림 쪽) — 글자까지 백지가 됐다
//   mediaref.pdf   /MediaBox 가 딴 객체(arXiv GenPDF) — A4 가 Letter 로 읽혀 자리가 50pt 어긋났다
//   fontscope.pdf  폼 XObject 의 글꼴 이름이 쪽 글꼴과 같음(InDesign) — 남의 ToUnicode 로 깨졌다
//   formq.pdf      폼 안의 q 가 짝이 없고(잘린 스트림) 2MB 넘음 — 배율이 새어 캡션이 밀렸다
//   cols.pdf       두 단 + 오른쪽 여백 색인 탭 + 전폭 각주 — 탭 앞 빈 띠를 골로 골라 단이 안 갈렸다
//   layers.pdf     같은 기준선에 크기 다른 글이 겹쳐 찍힘(고친 문서) — 글자가 끼어들었다
//   cropclip.pdf   CropBox 밖의 워터마크 — text() 에 딸려 나왔다
//
//   node tests/mkcorpus.mjs tests/fixtures
import fs from 'node:fs';
import zlib from 'node:zlib';
const S = process.argv[2] ?? 'tests/fixtures';
const B = (x) => Buffer.from(x, 'latin1');
function build(objs, opts = {}) {
  let out = B('%PDF-1.7\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    // null 자리는 평문으로 안 적는다(객체 스트림 안에만 있는 객체)
    if (objs[i] == null) { offs.push(0); continue; }
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), Buffer.isBuffer(objs[i]) ? objs[i] : B(objs[i]), B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + (o ? ' 00000 n \n' : ' 00000 f \n');
  x += `trailer\n<< /Size ${objs.length + 1} /Root ${opts.root ?? 1} 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}
const stream = (d, extra = '') => Buffer.concat([B(`<< /Length ${Buffer.byteLength(d, 'latin1')} ${extra} >>\nstream\n`), Buffer.isBuffer(d) ? d : B(d), B('\nendstream')]);
const flate = (d, extra = '') => { const z = zlib.deflateSync(Buffer.isBuffer(d) ? d : B(d)); return stream(z, `/Filter /FlateDecode ${extra}`); };
const T = (x, y, s, size = 12, f = 'F1') => `BT /${f} ${size} Tf ${x} ${y} Td (${s.replace(/([()])/g, '\\$1')}) Tj ET`;
const HELV = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>';

// 1. bigobj — 카탈로그·쪽 나무·큰 객체(4MB, 잘 눌림)를 한 객체 스트림에
{
  const big = 'x'.repeat(4 * 1024 * 1024);
  const inner = [
    ['1', '<< /Type /Catalog /Pages 2 0 R >>'],
    ['2', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'],
    ['3', '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>'],
    ['6', `(${big})`],
  ];
  let head = '', body = '';
  for (const [n, o] of inner) { head += `${n} ${body.length} `; body += o + '\n'; }
  const data = head + '\n' + body;
  // 번호 1·2·3·6 은 객체 스트림(7) 안, 4·5·7 은 평문. 규격대로 xref 스트림(8)으로 적는다 —
  // 옛 꼴 xref 는 객체 스트림 안의 객체를 가리킬 수 없어 pdf.js 가 못 연다
  let out = B('%PDF-1.7\n');
  const off = {};
  const put = (n, o) => { off[n] = out.length; out = Buffer.concat([out, B(`${n} 0 obj\n`), Buffer.isBuffer(o) ? o : B(o), B('\nendobj\n')]); };
  put(4, HELV);
  put(5, stream(T(20, 100, 'Pages inside a big object stream')));
  put(7, flate(data, `/Type /ObjStm /N ${inner.length} /First ${head.length + 1}`));
  // xref 스트림: /W [1 4 2] — 0 빈 것, 1 평문(자리), 2 객체 스트림 안(스트림 번호, 차례)
  const rows = [];
  const row = (t, a, b) => { const r = Buffer.alloc(7); r[0] = t; r.writeUInt32BE(a, 1); r.writeUInt16BE(b, 5); rows.push(r); };
  row(0, 0, 65535);
  const inObj = { 1: 0, 2: 1, 3: 2, 6: 3 };
  const xrefAt = out.length;
  for (let n = 1; n <= 8; n++) {
    if (n in inObj) row(2, 7, inObj[n]);
    else if (n === 8) row(1, xrefAt, 0);
    else row(1, off[n], 0);
  }
  put(8, stream(Buffer.concat(rows), '/Type /XRef /W [1 4 2] /Size 9 /Root 1 0 R'));
  out = Buffer.concat([out, B(`startxref\n${xrefAt}\n%%EOF\n`)]);
  fs.writeFileSync(`${S}/bigobj.pdf`, out);
}

// 2. bigcontent — 쪽 내용이 3MB 로 풀리는데 눌리면 몇 KB
{
  const junk = '0 0 m 1 1 l S\n'.repeat(250000); // 3.5MB
  const content = junk + T(20, 100, 'Text after a huge content stream');
  fs.writeFileSync(`${S}/bigcontent.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    HELV, flate(content)]));
}

// 3. mediaref — /MediaBox 와 /CropBox 가 딴 객체
{
  fs.writeFileSync(`${S}/mediaref.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox 6 0 R /CropBox 7 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    HELV, stream(T(50, 800, 'Top of an A4 page')), '[0 0 595.276 841.89]', '[10 10 585 831]']));
}

// 4. fontscope — 쪽의 /F1 은 보통 Helvetica, 폼의 /F1 은 A→B 로 바꾼 Differences
{
  const form = stream(T(20, 50, 'A'), '/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Resources << /Font << /F1 6 0 R >> >>');
  fs.writeFileSync(`${S}/fontscope.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> /XObject << /Fm1 7 0 R >> >> /Contents 5 0 R >>',
    HELV, stream(T(20, 150, 'A') + ' /Fm1 Do'),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /Differences [65 /B] >> >>',
    form]));
}

// 5. formq — 폼 안에 짝 없는 q 와 2MB 넘는 내용, 그 뒤 쪽 글자
{
  const junk = '0 0 m 1 1 l S\n'.repeat(180000); // 2.5MB
  const form = flate('q 2 0 0 2 0 0 cm\n' + junk + T(10, 10, 'inside form'), '/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >>');
  fs.writeFileSync(`${S}/formq.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> /XObject << /Fm1 6 0 R >> >> /Contents 5 0 R >>',
    HELV, stream('q 1 0 0 1 20 20 cm q /Fm1 Do Q Q 1 0 0 1 0 0 cm ' + T(100, 150, 'after form')), form]));
}

// 6. cols — 두 단(각 12줄) + 오른쪽 여백의 세로 색인 탭 + 전폭 각주 셋 + 머리글
{
  const lines = [];
  lines.push(T(72, 760, 'Running head across the page', 9));
  for (let i = 0; i < 20; i++) {
    lines.push(T(72, 700 - i * 14, `left column line ${i + 1} of the text`, 10));
    lines.push(T(320, 700 - i * 14, `right column line ${i + 1} continues`, 10));
  }
  for (let i = 0; i < 2; i++) lines.push(T(72, 100 - i * 12, `${i + 1}) footnote ${i + 1} runs the whole width of the page from left margin to right margin here`, 8));
  // 여백 탭 — 쪽 오른쪽 바깥쪽에 큰 글자 몇 줄(단 폭보다 넓은 빈 띠를 만든다)
  for (let i = 0; i < 3; i++) lines.push(T(560, 600 - i * 40, 'TAB', 20));
  fs.writeFileSync(`${S}/cols.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    HELV, stream(lines.join('\n'))]));
}

// 7. layers — 같은 기준선에 9pt 옛 글과 23pt 새 글이 겹쳐 찍힘
{
  const c = [T(100, 150, 'old small title here', 9), T(60, 150, '2026', 23), T(120, 150, 'big new title', 23), T(60, 100, 'normal line with a', 12) + ' ' + T(170, 104, '2', 7)].join('\n');
  fs.writeFileSync(`${S}/layers.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    HELV, stream(c)]));
}

// 8. cropclip — MediaBox 는 크고 CropBox 로 자른 쪽. 위 여백(CropBox 밖)에 워터마크
{
  const c = [T(50, 780, 'CONFIDENTIAL watermark outside crop', 8), T(60, 600, 'Body text inside crop', 12)].join('\n');
  fs.writeFileSync(`${S}/cropclip.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 841] /CropBox [30 56 564 760] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    HELV, stream(c)]));
}
console.log('bigobj·bigcontent·mediaref·fontscope·formq·cols·layers·cropclip 만듦');
