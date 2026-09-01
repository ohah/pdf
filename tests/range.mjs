// 범위 요청 — 토막만 받아 첫 쪽을 그리고, 나머지는 나중에 받는다.
//
//   node tests/range.mjs
//
// 서버를 띄워 Range 를 받아 주는 자리와 안 받아 주는 자리를 둘 다 본다.
import http from 'node:http';
import fs from 'node:fs';
import { PDFDocument } from '../dist/index.js';

const FX = new URL('./fixtures/', import.meta.url);
const file = (n) => fs.readFileSync(new URL(n, FX));

let fails = 0;
const ok = (name, cond, got) => {
  if (cond) console.log(`  통과  ${name}`);
  else { console.log(`  ✗    ${name}${got !== undefined ? ' (' + JSON.stringify(got) + ')' : ''}`); fails++; }
};

// 큰 문서를 하나 만든다 — 512KB 를 넘어야 토막 받기가 켜진다
const big = (() => {
  const N = 60, objs = [];
  let b = '%PDF-1.7\n'; const off = [];
  const push = (o) => { off.push(b.length); b += `${off.length} 0 obj${o}endobj\n`; };
  let kids = '';
  for (let i = 0; i < N; i++) kids += `${3 + i * 2} 0 R `;
  push('<</Type/Catalog/Pages 2 0 R>>');
  push(`<</Type/Pages/Count ${N}/Kids [${kids}]>>`);
  for (let i = 0; i < N; i++) {
    push(`<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 400]/Resources<</Font<</F1 ${3 + N * 2} 0 R>>>>/Contents ${4 + i * 2} 0 R>>`);
    let c = `BT /F1 20 Tf 30 200 Td (Sheet ${i + 1}) Tj ET\n`;
    // 파일을 키운다 — 쪽마다 만 바이트쯤
    c += '% ' + 'x'.repeat(10000) + '\n';
    push(`<</Length ${c.length}>>stream\n${c}endstream `);
  }
  push('<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>');
  const xs = b.length;
  b += `xref\n0 ${off.length + 1}\n0000000000 65535 f \n`
    + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
  b += `trailer<</Size ${off.length + 1}/Root 1 0 R>>\nstartxref\n${xs}\n%%EOF\n`;
  return Buffer.from(b, 'latin1');
})();

let asked = [];
const serve = (ranges) => new Promise((res) => {
  const s = http.createServer((req, rep) => {
    asked.push(req.headers.range ?? 'full');
    const r = ranges ? /bytes=(\d+)-(\d+)/.exec(req.headers.range ?? '') : null;
    if (r) {
      const a = Number(r[1]), b2 = Math.min(Number(r[2]), big.length - 1);
      rep.writeHead(206, {
        'content-type': 'application/pdf',
        'content-range': `bytes ${a}-${b2}/${big.length}`,
        'content-length': b2 - a + 1,
      });
      rep.end(big.subarray(a, b2 + 1));
      return;
    }
    rep.writeHead(200, { 'content-type': 'application/pdf', 'content-length': big.length });
    rep.end(big);
  });
  s.listen(0, () => res(s));
});

// 1) Range 를 받아 주는 서버
{
  const s = await serve(true);
  const url = `http://127.0.0.1:${s.address().port}/big.pdf`;
  asked = [];
  const d = await PDFDocument.open(url);
  const got = asked.length;
  // 선형화되지 않은 문서라, 앞머리·꼬리에 든 쪽만 먼저 보인다(여기서는 51쪽).
  // 그래서 partial 을 함께 준다 — 화면이 "아직 다 안 왔다" 를 알 수 있게.
  ok('토막만 받아 연다', d.pages > 0 && d.partial && got >= 2 && got <= 4,
    { pages: d.pages, partial: d.partial, 요청: got });
  const bytesAsked = asked.filter((a) => a !== 'full').length;
  ok('통째로 받지 않았다', bytesAsked === asked.length, asked);
  const t = await d.text(1);
  ok('첫 쪽 글자', t.includes('Sheet 1'), t.slice(0, 20));
  if (d.partial) {
    await d.complete();
    ok('마저 받은 뒤에도 쪽 수 그대로', d.pages === 60, d.pages);
    const t60 = await d.text(60);
    ok('마지막 쪽 글자', t60.includes('Sheet 60'), t60.slice(0, 20));
  } else {
    ok('마저 받을 것이 없으면 partial 은 false', true);
  }
  d.close();
  s.close();
}

// 2) Range 를 안 받아 주는 서버 — 통째로 받는 길로 되돌아간다
{
  const s = await serve(false);
  const url = `http://127.0.0.1:${s.address().port}/big.pdf`;
  asked = [];
  const d = await PDFDocument.open(url);
  ok('범위를 안 받아 줘도 열린다', d.pages === 60, d.pages);
  ok('그때는 통째로 받는다', d.partial === false, d.partial);
  const t = await d.text(60);
  ok('끝 쪽까지 읽힌다', t.includes('Sheet 60'), t.slice(0, 20));
  d.close();
  s.close();
}

// 3) range: false 로 끄면 한 번에 받는다
{
  const s = await serve(true);
  const url = `http://127.0.0.1:${s.address().port}/big.pdf`;
  asked = [];
  const d = await PDFDocument.open(url, { range: false });
  ok('끄면 한 번만 받는다', asked.length === 1 && asked[0] === 'full', asked);
  ok('끄고도 다 읽힌다', d.pages === 60, d.pages);
  d.close();
  s.close();
}

console.log(fails === 0 ? '범위 요청 통과' : `범위 요청 실패 ${fails}개`);
process.exit(fails === 0 ? 0 : 1);
