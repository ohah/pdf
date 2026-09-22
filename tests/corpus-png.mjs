// 한 쪽을 셋으로 그려 PNG 로 남긴다 — 눈으로 볼 때.
//   node tests/corpus-png.mjs <출력디렉터리> <문서> <쪽> [배율]
import fs from "node:fs";
import { chromium } from "playwright";
const [out, name, page, scale = "1"] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const b = await chromium.launch();
const p = await b.newPage();
await p.goto(`http://localhost:4278/corpus.html?docs=${name}&page=${page}&png=1&scale=${scale}`, { waitUntil: "domcontentloaded" });
await p.waitForFunction(() => document.title === "done", null, { timeout: 600_000 });
const rows = await p.evaluate(() => window.__cmp);
await b.close();
const r = rows[0];
for (const [k, f] of [["pngA", "ours"], ["pngB", "pdfjs"], ["pngC", "mupdf"]]) if (r[k]) fs.writeFileSync(`${out}/${name}-${page}-${f}.png`, Buffer.from(r[k].split(",")[1], "base64"));
console.log(JSON.stringify({ ...r, pngA: undefined, pngB: undefined, pngC: undefined }));
