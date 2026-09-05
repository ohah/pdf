// 두 엔진의 화소를 자리를 짚어 뽑아 본다 (compare-pdfjs.mjs 로 걸린 것 들여다볼 때).
//   npx vite examples --port 4277 &
//   node tests/sample-px.mjs icc.pdf "60,60;150,110"
import { chromium } from "playwright";
const [doc, pts] = process.argv.slice(2);
const b = await chromium.launch();
const p = await b.newPage();
await p.goto(`http://localhost:4277/sample.html?doc=${doc}&pts=${encodeURIComponent(pts)}`, { waitUntil: "domcontentloaded" });
await p.waitForFunction(() => document.title === "done", null, { timeout: 120000 });
for (const s of await p.evaluate(() => window.__s))
  console.log(`  (${s.x},${s.y})  우리 ${String(s.ours).padEnd(15)} pdfjs ${s.pdfjs}`);
await b.close();
