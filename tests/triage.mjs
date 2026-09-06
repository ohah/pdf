// pdf.js 와 크게 다른 견본을 poppler 를 세 번째 눈으로 넣어 가린다.
//
//   npx vite examples --port 4277 &
//   node tests/triage.mjs [문서…]
//
// 우리와 pdf.js 가 다를 때, 둘 중 누가 틀렸는지는 둘만 봐서는 못 정한다.
// poppler(pdftoppm)로 같은 쪽을 한 번 더 그려 2대1로 가린다.
//
//   우리가 poppler 에 가깝다   → pdf.js 쪽 문제이거나 받아들일 차이
//   pdf.js 가 poppler 에 가깝다 → 우리 결함일 가능성이 크다
//   셋 다 다르다               → 셋 다 다르게 해석하는 자리다. 사람이 본다
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { chromium } from "playwright";
import { createCanvas, loadImage } from "@napi-rs/canvas";

const FX = "tests/fixtures";
const SCALE = 1.5;              // compare.html 과 같아야 한다
const DPI = Math.round(72 * SCALE);
const docs = process.argv.slice(2);
if (!docs.length) { console.error("문서를 달라"); process.exit(2); }

/** 화소를 꺼낸다. 크기가 다르면 겹치는 데까지만 본다. */
async function pix(src) {
  const img = await loadImage(src);
  const cv = createCanvas(img.width, img.height);
  const g = cv.getContext("2d");
  g.fillStyle = "#fff"; g.fillRect(0, 0, img.width, img.height);
  g.drawImage(img, 0, 0);
  return { w: img.width, h: img.height, d: g.getImageData(0, 0, img.width, img.height).data };
}

/** 크게 다른 화소의 비율. compare.html 과 같은 잣대(채널 하나라도 32 초과). */
function badPct(A, B) {
  const w = Math.min(A.w, B.w), h = Math.min(A.h, B.h);
  if (!w || !h) return null;
  let bad = 0, n = 0;
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const ia = (y * A.w + x) * 4, ib = (y * B.w + x) * 4;
      let d = 0;
      for (let c = 0; c < 3; c++) d = Math.max(d, Math.abs(A.d[ia + c] - B.d[ib + c]));
      if (d > 32) bad++;
      n++;
    }
  return (bad / n) * 100;
}

const b = await chromium.launch();
const p = await b.newPage();
await p.goto(`http://localhost:4277/compare.html?png=1&docs=${encodeURIComponent(docs.join(","))}`,
             { waitUntil: "domcontentloaded" });
await p.waitForFunction(() => document.title === "done", null, { timeout: 600_000 });
const rows = await p.evaluate(() => window.__cmp);
await b.close();

const pad = (s, n) => String(s).padEnd(n);
const rp = (s, n) => String(s).padStart(n);
console.log(pad("문서", 22) + rp("우리↔pdfjs", 12) + rp("우리↔poppler", 14) + rp("pdfjs↔poppler", 15) + "  가림");
const out = [];
for (const r of rows) {
  if (r.err || !r.pngA) { console.log(pad(r.name, 22) + "  " + (r.err ?? "그림 없음")); continue; }
  let pop;
  try {
    const base = `/tmp/tri-${r.name.replace(/\W/g, "_")}`;
    execFileSync("pdftoppm", ["-r", String(DPI), "-png", "-f", "1", "-l", "1", `${FX}/${r.name}`, base]);
    const f = fs.readdirSync("/tmp").filter((x) => x.startsWith(base.slice(5)) && x.endsWith(".png"))[0];
    pop = await pix(`/tmp/${f}`);
  } catch (e) {
    console.log(pad(r.name, 22) + "  poppler 실패: " + String(e.message).slice(0, 50));
    continue;
  }
  const A = await pix(Buffer.from(r.pngA.split(",")[1], "base64"));
  const B = await pix(Buffer.from(r.pngB.split(",")[1], "base64"));
  const ap = badPct(A, pop), bp = badPct(B, pop);
  // 어느 쪽이 poppler 에 더 가까운가. 둘 다 멀면 셋 다 다른 자리다.
  const near = ap === null || bp === null ? "?" :
    ap > 20 && bp > 20 ? "셋 다 다름" :
    ap < bp * 0.6 ? "우리가 가까움" :
    bp < ap * 0.6 ? "pdfjs 가 가까움 ← 볼 것" : "비슷";
  console.log(pad(r.name, 22) + rp(r.bad.toFixed(2), 12) + rp(ap?.toFixed(2) ?? "-", 14) + rp(bp?.toFixed(2) ?? "-", 15) + "  " + near);
  out.push({ name: r.name, ab: r.bad, ap, bp, near });
}
console.log(`\n볼 것 ${out.filter((x) => x.near.includes("←")).length}개 · 셋 다 다름 ${out.filter((x) => x.near === "셋 다 다름").length}개`);
