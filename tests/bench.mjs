// @ohah/pdf 와 pdf.js 를 같은 브라우저·같은 문서로 재 본다.
//
//   node tests/mkbig.mjs 2000 tests/fixtures/.big.pdf    # 큰 문서는 만들어 둔다
//   node tests/mkbig.mjs 6000 tests/fixtures/.huge.pdf
//   npx vite examples --port 4277 &
//   node tests/bench.mjs
//
// 같은 브라우저에서 같은 문서를 셋씩 돌려 가운데 값을 적는다. pdf.js 도
// 우리도 열 때마다 워커를 새로 띄우므로 워커 뜨는 값이 양쪽 다 들어 있다.
import { chromium } from "playwright";

const b = await chromium.launch();
const p = await b.newPage();
const errs = [];
p.on("pageerror", (e) => errs.push(String(e).slice(0, 120)));
await p.goto("http://localhost:4277/bench.html");
await p.waitForFunction(() => document.title === "done", null, { timeout: 300000 });
const rows = await p.evaluate(() => window.__bench);
await b.close();

const ms = (v) => (v === undefined ? "—" : `${v.toFixed(0)}ms`);
const pad = (s, n) => String(s).padEnd(n);
console.log(pad("문서", 12), pad("크기", 8), pad("쪽", 6),
  pad("열기 (우리/pdf.js)", 22), pad("1쪽 그리기", 22), "글자 뽑기");
for (const r of rows) {
  const o = r.ours ?? {}, t = r.theirs ?? {};
  console.log(
    pad(r.name, 12),
    pad(`${(r.size / 1048576).toFixed(1)}MB`, 8),
    pad(`${o.n ?? "?"}/${t.n ?? "?"}`, 6),
    pad(`${ms(o.open)} / ${ms(t.open)}`, 22),
    pad(`${ms(o.draw)} / ${ms(t.draw)}`, 22),
    `${ms(o.text)} / ${ms(t.text)} (${r.pages}쪽)`,
    o.err ? `우리 오류: ${o.err}` : "", t.err ? `pdf.js 오류: ${t.err}` : "",
  );
}
if (errs.length) console.log("\n콘솔 오류:", errs.slice(0, 5).join(" | "));
