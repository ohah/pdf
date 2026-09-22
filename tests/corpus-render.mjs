// 실문서 표본의 쪽을 우리·pdf.js·mupdf 셋으로 그려 맞댄다.
//
//   <venv>/bin/python tests/corpus-mupdf.py <pdf디렉터리> <png디렉터리>
//   CORPUS=<pdf디렉터리> CORPUS_PNG=<png디렉터리> npx vite examples --port 4278 &
//   node tests/corpus-render.mjs <출력.json> [문서…]
//
// 잣대는 compare-pdfjs 와 같다 — 채널 하나라도 32 넘게 다른 화소의 비율. 셋을 다 맞대므로
// "우리↔pdf.js" 가 크더라도 "pdf.js↔mupdf" 도 크면 기준끼리 갈리는 쪽이다.
import fs from "node:fs";
import { chromium } from "playwright";
const out = process.argv[2] ?? "corpus-render.json";
const pages = JSON.parse(fs.readFileSync(`${process.env.CORPUS_PNG}/pages.json`, "utf8"));
const docs = process.argv.length > 3 ? process.argv.slice(3) : Object.keys(pages).sort();
const LANES = Number(process.env.LANES ?? 3);
const b = await chromium.launch();
const slice = Math.ceil(docs.length / LANES);
const lanes = [];
for (let i = 0; i < docs.length; i += slice) lanes.push(docs.slice(i, i + slice));
const got = await Promise.all(lanes.map(async (part) => {
  const p = await b.newPage();
  p.on("pageerror", (e) => console.log("  ! " + String(e.message).slice(0, 100)));
  await p.goto(`http://localhost:4278/corpus.html?docs=${encodeURIComponent(part.join(","))}`, { waitUntil: "domcontentloaded" });
  await p.waitForFunction(() => document.title === "done", null, { timeout: 3_600_000 });
  const r = await p.evaluate(() => window.__cmp);
  await p.close();
  return r;
}));
await b.close();
const rows = got.flat();
fs.writeFileSync(out, JSON.stringify(rows));
const pad = (s, n) => String(s).padEnd(n), rp = (s, n) => String(s).padStart(n);
// 문서별로 "우리↔mupdf 가 pdf.js↔mupdf 보다 얼마나 더 나쁜가" 로 줄 세운다
const byDoc = new Map();
for (const r of rows) { const a = byDoc.get(r.name) ?? []; a.push(r); byDoc.set(r.name, a); }
const summary = [];
for (const [name, rs] of byDoc) {
  const ok = rs.filter((r) => r.ac && r.bc);
  const errs = rs.filter((r) => r.err || r.cerr);
  if (!ok.length) { summary.push({ name, err: errs.map((e) => e.err ?? e.cerr).join("; ").slice(0, 80) }); continue; }
  const avg = (k, f) => ok.reduce((s, r) => s + r[k].bad, 0) / ok.length;
  const worst = ok.reduce((w, r) => (r.ac.bad - r.bc.bad > (w.ac.bad - w.bc.bad) ? r : w), ok[0]);
  summary.push({ name, n: ok.length, ac: avg("ac"), bc: avg("bc"), ab: avg("ab"), ms: Math.round(ok.reduce((s, r) => s + r.msA, 0) / ok.length), msB: Math.round(ok.reduce((s, r) => s + r.msB, 0) / ok.length), worst, errs: errs.length });
}
summary.sort((x, y) => ((y.ac ?? 99) - (y.bc ?? 0)) - ((x.ac ?? 99) - (x.bc ?? 0)));
console.log(pad("문서", 16) + rp("쪽", 3) + rp("우리↔mu%", 10) + rp("pdfjs↔mu%", 11) + rp("우리↔pdfjs%", 12) + rp("ms 우리/pdfjs", 15) + "  최악 쪽");
for (const s of summary) {
  if (s.err) { console.log(pad(s.name, 16) + " ERR " + s.err); continue; }
  console.log(pad(s.name, 16) + rp(s.n, 3) + rp(s.ac.toFixed(2), 10) + rp(s.bc.toFixed(2), 11) + rp(s.ab.toFixed(2), 12) + rp(`${s.ms}/${s.msB}`, 15) + `  p${s.worst.page} 우리↔mu ${s.worst.ac.bad.toFixed(1)} pdfjs↔mu ${s.worst.bc.bad.toFixed(1)} 잉크 ${s.worst.ac.inkA}/${s.worst.ac.inkB}${s.errs ? ` · 오류 ${s.errs}` : ""}`);
}
const okS = summary.filter((s) => !s.err);
console.log(`\n문서 ${summary.length} · 쪽 ${rows.length} · 평균 우리↔mu ${(okS.reduce((a, s) => a + s.ac, 0) / okS.length).toFixed(2)}% · pdfjs↔mu ${(okS.reduce((a, s) => a + s.bc, 0) / okS.length).toFixed(2)}% · 우리↔pdfjs ${(okS.reduce((a, s) => a + s.ab, 0) / okS.length).toFixed(2)}%`);
