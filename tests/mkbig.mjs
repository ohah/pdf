// 속도 재기용 큰 PDF 를 만든다. 쪽마다 45줄짜리 글이 들어간다.
//
//   node tests/mkbig.mjs 2000 tests/fixtures/.big.pdf     # 11MB
//   node tests/mkbig.mjs 6000 tests/fixtures/.huge.pdf    # 34MB
//
// 점(.)으로 시작하는 이름은 .gitignore 가 걸러 준다 — 저장소에 안 들어간다.
import { writeFileSync } from "node:fs";
const N = Number(process.argv[2] ?? 2000);
const out = process.argv[3] ?? "big.pdf";
const parts = [];
const offs = [];
let pos = 0;
const put = (s) => { const b = Buffer.from(s, "latin1"); parts.push(b); pos += b.length; };
const obj = (n, body) => { offs[n] = pos; put(`${n} 0 obj\n${body}\nendobj\n`); };
put("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n");
// 1 Catalog, 2 Pages, 3 Font, 쪽마다 (4+2i) Page, (5+2i) Contents
const kids = [];
for (let i = 0; i < N; i++) kids.push(`${4 + 2 * i} 0 R`);
obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
obj(2, `<< /Type /Pages /Count ${N} /Kids [${kids.join(" ")}] >>`);
obj(3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
for (let i = 0; i < N; i++) {
  const lines = [];
  for (let L = 0; L < 45; L++) {
    lines.push(`BT /F1 11 Tf 40 ${760 - L * 16} Td (page ${i + 1} line ${L + 1} ${"lorem ipsum dolor sit amet consectetur ".repeat(2)}) Tj ET`);
  }
  const st = lines.join("\n");
  obj(4 + 2 * i, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + 2 * i} 0 R >>`);
  obj(5 + 2 * i, `<< /Length ${st.length} >>\nstream\n${st}\nendstream`);
}
const xref = pos;
const max = 4 + 2 * N;
put(`xref\n0 ${max}\n0000000000 65535 f \n`);
for (let n = 1; n < max; n++) put(`${String(offs[n] ?? 0).padStart(10, "0")} 00000 n \n`);
put(`trailer\n<< /Size ${max} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
writeFileSync(out, Buffer.concat(parts));
console.log(out, (Buffer.concat(parts).length / 1048576).toFixed(1) + "MB", N + "쪽");
