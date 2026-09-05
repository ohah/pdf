// 우리가 고쳐 내보낸 PDF 를 pdf.js 로 다시 열어 본다.
//
//   npx vite examples --port 4277 &
//   node tests/roundtrip-pdfjs.mjs [문서…]
//
// 지금까지의 시험은 우리가 쓴 것을 우리만 읽어 봤다. A/B 는 우리 엔진끼리,
// 앱 화면 시험도 우리 뷰어로 다시 연다. 그래서 겉모습 폼의 /Subtype 이
// 규격에 없는 이름(/core.Form)으로 나가도 아무도 몰랐다 — 우리 읽기 쪽은
// /AP → /N 만 따라가고 /Subtype 을 안 보기 때문이다.
//
// 여기서는 주석·라벨·워터마크를 얹어 새 PDF 를 만든 뒤, 그것을 pdf.js 로
// 열어 그린다. pdf.js 가 못 열거나, 우리보다 눈에 띄게 덜 그리면 실패다.
import fs from "node:fs";
import { chromium } from "playwright";

const FX = "tests/fixtures";
const args = process.argv.slice(2);
const docs = args.length ? args
  : ["korean.pdf", "modern.pdf", "multi.pdf", "form.pdf", "annots.pdf",
     "scan4.pdf", "type3.pdf", "cs.pdf", "shade.pdf", "tile.pdf"];

const b = await chromium.launch();
const p = await b.newPage();
p.on("pageerror", (e) => console.log("  ! " + String(e.message).slice(0, 100)));
await p.goto(`http://localhost:4277/roundtrip.html?docs=${encodeURIComponent(docs.join(","))}`,
  { waitUntil: "domcontentloaded" });
await p.waitForFunction(() => document.title === "done", null, { timeout: 600_000 });
const rows = await p.evaluate(() => window.__rt);
await b.close();

const pad = (s, n) => String(s).padEnd(n), rp = (s, n) => String(s).padStart(n);
console.log(pad("문서", 16) + rp("만든 크기", 11) + rp("쪽 우리/pdfjs", 15) + rp("잉크 우리", 11) + rp("pdfjs", 9));
let bad = [];
for (const r of rows) {
  if (r.err) { console.log(pad(r.name, 16) + "  ✗ " + r.err); bad.push(`${r.name}: ${r.err}`); continue; }
  console.log(pad(r.name, 16) + rp(r.bytes, 11) + rp(`${r.oursPages}/${r.theirsPages}`, 15) +
    rp(r.oursInk.toFixed(2) + "%", 11) + rp(r.theirsInk.toFixed(2) + "%", 9));
  if (r.oursPages !== r.theirsPages) bad.push(`${r.name}: 쪽 수가 다르다 ${r.oursPages}/${r.theirsPages}`);
  // 우리가 그린 것의 절반도 안 그렸으면 무언가 못 읽은 것이다
  if (r.oursInk > 0.5 && r.theirsInk < r.oursInk * 0.5)
    bad.push(`${r.name}: pdf.js 가 훨씬 덜 그렸다 (우리 ${r.oursInk.toFixed(2)}% / 저쪽 ${r.theirsInk.toFixed(2)}%)`);
}
console.log(`\n견본 ${rows.length}개 · 문제 ${bad.length}개`);
for (const x of bad) console.log("  ✗ " + x);
process.exit(bad.length ? 1 : 0);
