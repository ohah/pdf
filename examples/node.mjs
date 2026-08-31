// Node 에서 쓰는 법.
//
//   node examples/node.mjs 파일.pdf
//
// 브라우저 밖에는 Worker 도 canvas 도 없다. 그래도 뽑기와 편집은 그대로 된다 —
// 서버에서 본문을 색인하거나, 쪽을 골라 다시 내는 쓰임이 이 갈래다.
import { writeFile } from "node:fs/promises";
import { PDFDocument } from "../dist/index.js";

const file = process.argv[2] ?? "tests/fixtures/annots.pdf";
const pdf = await PDFDocument.open(file);          // 주소가 아니라 파일 경로 그대로

console.log(`${file} — ${pdf.pages}쪽${pdf.tagged ? " · 태그 PDF" : ""}`);
if (pdf.pageLabels.length) console.log("쪽 라벨:", pdf.pageLabels.slice(0, 5).join(", "), "…");
if (pdf.locked) console.log("권한:", Object.entries(pdf.permissions).filter(([, v]) => !v).map(([k]) => k).join(", "), "안 됨");

for (let p = 1; p <= Math.min(pdf.pages, 3); p++) {
  const text = (await pdf.text(p)).replace(/\s+/g, " ").trim();
  console.log(`\n${p}쪽 (${text.length}자)`);
  console.log("  " + text.slice(0, 120) + (text.length > 120 ? "…" : ""));
  for (const a of await pdf.annotations(p)) {
    console.log(`  [${a.subtype}] ${a.contents || a.uri || ""}`.trimEnd());
  }
}

// 앞 세 쪽만 골라 다시 낸다
const picked = await pdf.build({ pick: [0, 1, 2].filter((k) => k < pdf.pages) });
if (picked) {
  await writeFile("out.pdf", picked);
  console.log(`\nout.pdf — ${(picked.length / 1024).toFixed(1)}KB`);
}
pdf.close();
