// 우리 엔진과 pdf.js 로 같은 쪽을 그려 화소를 맞댄다.
//
//   npx vite examples --port 4277 &
//   node tests/compare-pdfjs.mjs [문서…]
//
// 두 그림이 똑같을 수는 없다 — 글자 뭉개기와 글리프 래스터가 서로 다르다.
// 그래서 "크게 다른 화소의 비율"(채널 하나라도 32 넘게 어긋난 화소)을 본다.
// 그림이 안 나오거나 색이 뒤집히거나 자리가 틀어지면 그 값이 확 뛰고,
// 글자 가장자리 차이로는 잘 안 뛴다.
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const FX = "tests/fixtures";
const args = process.argv.slice(2);
const docs = args.length
  ? args
  : fs.readdirSync(FX).filter((f) => f.endsWith(".pdf") && !f.startsWith(".")).sort();

// 크게 다른 화소가 이 비율을 넘으면 들여다볼 것으로 친다
const BAD_PCT = Number(process.env.BAD_PCT ?? 2.0);

const b = await chromium.launch();
const p = await b.newPage();
p.on("pageerror", (e) => console.log("  ! " + String(e.message).slice(0, 100)));
const url = `http://localhost:4277/compare.html?docs=${encodeURIComponent(docs.join(","))}`;
await p.goto(url, { waitUntil: "domcontentloaded" });
await p.waitForFunction(() => document.title === "done", null, { timeout: 600_000 });
const rows = await p.evaluate(() => window.__cmp);
await b.close();

const pad = (s, n) => String(s).padEnd(n);
const rp = (s, n) => String(s).padStart(n);
// 한쪽이 아예 안 그린 쪽은 "얼마나 다른가" 로 볼 것이 아니다. 갈라 놓는다.
//   theirs — pdf.js 가 못 그렸다 (우리 잘못이 아니다)
//   ours   — 우리가 못 그렸다 (우리 잘못이다)
let real = [], errs = [], oursBlank = [], theirsBlank = [];
for (const r of rows) {
  if (r.err) { errs.push(r); continue; }
  if (r.inkB > 0.5 && r.inkA < r.inkB / 20) { oursBlank.push(r); continue; }
  if (r.inkA > 0.5 && r.inkB < r.inkA / 20) { theirsBlank.push(r); continue; }
  real.push(r);
}
real.sort((x, y) => y.bad - x.bad);
console.log(pad("문서", 24) + rp("크기", 11) + rp("크게다름%", 11) + rp("평균차", 9) + rp("최대", 6) + rp("잉크 우리/pdfjs", 18));
for (const r of real.slice(0, 20)) {
  console.log(pad(r.name, 24) + rp(`${r.w}x${r.h}`, 11) + rp(r.bad.toFixed(2), 11) +
    rp(r.mean.toFixed(2), 9) + rp(r.max, 6) + rp(`${r.inkA.toFixed(1)}/${r.inkB.toFixed(1)}`, 18));
}
const over = real.filter((r) => r.bad > BAD_PCT);
console.log(`\n견본 ${rows.length}개 · 맞댈 수 있던 것 ${real.length} · 크게다름 ${BAD_PCT}% 초과 ${over.length}`);
if (theirsBlank.length) {
  console.log(`\npdf.js 가 못 그린 쪽 ${theirsBlank.length}개 (우리는 그렸다):`);
  console.log("  " + theirsBlank.map((r) => `${r.name} ${r.inkA.toFixed(0)}%`).join(", "));
}
if (oursBlank.length) {
  console.log(`\n우리가 못 그린 쪽 ${oursBlank.length}개 — 이건 우리 잘못이다:`);
  for (const r of oursBlank) console.log(`  ${r.name}: 우리 ${r.inkA.toFixed(2)}% / pdfjs ${r.inkB.toFixed(2)}%`);
}
if (errs.length) {
  console.log(`\n못 연 것 ${errs.length}개:`);
  for (const r of errs) console.log(`  ${r.name}: ${r.err}`);
}
// 실패의 증거만 찾지 않고, 성공의 증거를 요구한다.
//
// 여태 "우리가 못 그린 쪽" 이 있을 때만 1 로 끝났다. 그러면 견본이 조용히
// 줄거나 맞댈 수 있는 수가 무너져도 통과다 — 견본 디렉터리가 바뀌거나
// 브라우저가 반쯤 죽어도 "OK" 로 적힌다. 실제로 vite 가 안 떠 이 시험이
// 종료 코드 1 로 죽었는데 검증 실행기가 "pdfjs OK" 라고 적은 일이 있다.
//
// 바닥값은 지금 수(견본 139 · 맞댄 것 129)보다 넉넉히 낮게 둔다. 견본을
// 더 넣는 것은 막지 않고, 무너지는 것만 잡는다.
const MIN_DOCS = 130;
const MIN_REAL = 120;
let bad = 0;
if (rows.length < MIN_DOCS) {
  console.log(`\n✗ 견본이 ${MIN_DOCS}개는 돼야 하는데 ${rows.length}개만 돌았다`);
  bad = 1;
}
if (real.length < MIN_REAL) {
  console.log(`\n✗ 맞댈 수 있는 것이 ${MIN_REAL}개는 돼야 하는데 ${real.length}개다`);
  bad = 1;
}
if (errs.length) {
  console.log(`\n✗ 못 연 것이 ${errs.length}개 있다 — 견본이 규격에 안 맞거나 우리가 못 연다`);
  bad = 1;
}
if (oursBlank.length) bad = 1;
process.exit(bad);
