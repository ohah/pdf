// AES-256(V5/R6)으로 잠근 견본을 우리 writer 로 만든다.
//
//   node tests/mkenc256.mjs tests/fixtures
//
// 예전 견본은 손으로 만든 것이라 규격에 안 맞았다 — 우리는 너그럽게 읽었지만
// pdf.js 는 "Invalid argument for stringToBytes" 로 거부했다. 그래서 그림
// 맞대기에서 늘 "못 연 것 1개" 로 남았다. 우리 writer 가 내는 파일은 pdf.js
// 가 정상으로 여는 것을 확인했으므로, 그걸로 갈아 끼운다.
//
// 암호는 비운다 — 열 때 암호를 묻지 않아야 지금 시험이 그대로 돈다.
import fs from "node:fs";

const OUT = process.argv[2] ?? "tests/fixtures";

function build(objs) {
  const parts = [Buffer.from("%PDF-1.7\n", "latin1")];
  let len = parts[0].length;
  const off = [];
  for (let i = 0; i < objs.length; i++) {
    off.push(len);
    const head = Buffer.from(`${i + 1} 0 obj\n`, "latin1");
    const body = Buffer.from(objs[i], "latin1");
    const tail = Buffer.from("\nendobj\n", "latin1");
    parts.push(head, body, tail);
    len += head.length + body.length + tail.length;
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of off) x += `${String(o).padStart(10, "0")} 00000 n \n`;
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
  parts.push(Buffer.from(x, "latin1"));
  return Buffer.concat(parts);
}

const content = "BT /F1 24 Tf 40 700 Td (AES256 OK) Tj ET";
const plain = build([
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>",
  "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
  `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]);

const stub = () => new Proxy({}, { get: () => () => 0 });
const mod = await WebAssembly.compile(fs.readFileSync("dist/pdf.wasm"));
const { exports: e } = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: stub() });
if (!e.reserve(plain.length, plain.length * 3 + 201326592)) throw new Error("자리를 못 잡았다");
new Uint8Array(e.memory.buffer, e.inputPtr(), plain.length).set(plain);
if (!e.parse(plain.length)) throw new Error("우리가 만든 원본을 못 읽는다");
e.clearPick();
for (let i = 0; i < e.pageCount(); i++) e.addPick(i);
e.setRotate(0);
e.clearWatermark();
e.clearLabels();
e.clearNotes?.();
e.clearFieldEdits?.();
e.clearPageRotate?.();
e.setEncrypt(1);           // 암호 글자는 하나도 안 넣는다 = 빈 암호
// 암호는 compact() 만 건다 — apply() 는 안 건다. 처음에 apply() 를 불러
// /Encrypt 도 없는 파일을 내고는 "잠갔다" 고 여겼다.
const n = e.compact();
if (!n) throw new Error("잠그지 못했다");
const out = Buffer.from(new Uint8Array(e.memory.buffer, e.outputPtr(), n));
fs.writeFileSync(`${OUT}/enc-aes256.pdf`, out);
console.log(`enc-aes256.pdf 만듦 (${out.length}바이트, AES-256 V5/R6, 빈 암호)`);
