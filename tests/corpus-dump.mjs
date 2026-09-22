// 실문서 표본의 글자를 우리 엔진과 pdf.js 로 뽑아 JSON 으로 남긴다.
// tests/corpus-compare.py 가 pymupdf 와 셋을 맞댄다.
//
//   node tests/corpus-dump.mjs <pdf디렉터리> <출력디렉터리> [쪽수=8]
import fs from "node:fs";
import path from "node:path";
import { PDFDocument } from "../dist/index.js";

const dir = process.argv[2], out = process.argv[3], N = Number(process.argv[4] ?? 8);
fs.mkdirSync(out, { recursive: true });
const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");

/** 앞 5쪽 + 나머지에서 고르게 3쪽 */
function pick(n) {
  const s = new Set();
  for (let i = 1; i <= Math.min(5, n); i++) s.add(i);
  if (n > 5) for (let k = 1; k <= 3; k++) s.add(Math.min(n, 5 + Math.round((n - 5) * k / 3)));
  return [...s].slice(0, N);
}

for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".pdf")).sort()) {
  const name = f.replace(/\.pdf$/, "");
  const dst = path.join(out, name + ".json");
  if (fs.existsSync(dst)) continue;
  const data = new Uint8Array(fs.readFileSync(path.join(dir, f)));
  const rec = { file: f, pages: {}, err: null };
  const t0 = performance.now();
  try {
    const pdf = await PDFDocument.open(data.slice());
    rec.n = pdf.pages;
    rec.tagged = pdf.structure() !== null;
    for (const p of pick(pdf.pages)) {
      const q = await pdf.get(p, false);
      const lines = await pdf.lines(p);
      rec.pages[p] = {
        w: q.w, h: q.h, x0: q.x0, y0: q.y0, rot: q.rot,
        // 조각: 자리는 위 기준(pt). y 는 기준선
        ours: lines.flatMap((l) => l.pieces.map((c) => [c.text, +c.x.toFixed(2), +(q.y0 + q.h - c.y).toFixed(2), +c.w.toFixed(2), +c.size.toFixed(2)])),
        oursText: lines.map((l) => l.text).join("\n"),
      };
    }
    pdf.close();
  } catch (e) { rec.err = String(e?.message ?? e); }
  rec.ms = Math.round(performance.now() - t0);
  // pdf.js — 글만(자리는 pymupdf 가 맡는다)
  try {
    const task = pdfjs.getDocument({ data, cMapUrl: "node_modules/pdfjs-dist/cmaps/", cMapPacked: true, standardFontDataUrl: "node_modules/pdfjs-dist/standard_fonts/", isEvalSupported: false, verbosity: 0 });
    const doc = await task.promise;
    for (const p of Object.keys(rec.pages).map(Number)) {
      const page = await doc.getPage(p);
      const tc = await page.getTextContent();
      rec.pages[p].pdfjs = tc.items.filter((it) => "str" in it).map((it) => it.str + (it.hasEOL ? "\n" : "")).join("");
      page.cleanup();
    }
    await task.destroy();
  } catch (e) { rec.pdfjsErr = String(e?.message ?? e); }
  fs.writeFileSync(dst, JSON.stringify(rec));
  console.log(name.padEnd(18), rec.err ? "ERR " + rec.err : `${rec.n}쪽 ${rec.ms}ms${rec.tagged ? " 태그" : ""}${rec.pdfjsErr ? " pdfjs✗ " + rec.pdfjsErr.slice(0, 40) : ""}`);
}
