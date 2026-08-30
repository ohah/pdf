import fs from 'fs';
import { run } from './adv.mjs';
const S = process.argv[2];
const base = fs.readFileSync(S + '/korean.pdf');
const mod = fs.readFileSync(S + '/pdf/modern.pdf');

// 여러 쪽짜리를 만든다
function manyPages(n) {
  let out = '%PDF-1.4\n';
  const kids = [];
  let obj = 3;
  const bodies = [];
  for (let i = 0; i < n; i++) {
    const c = `BT /F1 12 Tf 40 700 Td (page ${i}) Tj ET 0 0 100 100 re f`;
    kids.push(`${obj} 0 R`);
    bodies.push(`${obj} 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 ${obj+2} 0 R >> >> /Contents ${obj+1} 0 R >>\nendobj\n`);
    bodies.push(`${obj+1} 0 obj\n<< /Length ${c.length} >> stream\n${c}\nendstream\nendobj\n`);
    bodies.push(`${obj+2} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n`);
    obj += 3;
  }
  out += `1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n`;
  out += `2 0 obj\n<< /Type /Pages /MediaBox [0 0 612 792] /Count ${n} /Kids [${kids.join(' ')}] >>\nendobj\n`;
  out += bodies.join('');
  out += `trailer\n<< /Size ${obj} /Root 1 0 R >>\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}
console.log('4회차 — 자원 고갈과 왕복');
await run('5000쪽', manyPages(5000));
await run('폰트 200개 한 쪽', (() => {
  let res = [];
  for (let i = 0; i < 200; i++) res.push(`/F${i} 5 0 R`);
  const c = 'BT ' + Array.from({length:200},(_,i)=>`/F${i} 12 Tf 40 ${700-i} Td (f${i}) Tj`).join(' ') + ' ET';
  let out = '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  out += '2 0 obj\n<< /Type /Pages /MediaBox [0 0 612 792] /Count 1 /Kids [3 0 R] >>\nendobj\n';
  out += `3 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /Font << ${res.join(' ')} >> >> /Contents 4 0 R >>\nendobj\n`;
  out += `4 0 obj\n<< /Length ${c.length} >> stream\n${c}\nendstream\nendobj\n`;
  out += '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\ntrailer\n<< /Size 6 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(out, 'latin1');
})());
await run('20MB 채움', Buffer.concat([base, Buffer.alloc(20*1024*1024, 0x20)]));
await run('한글 문서 100번 반복 열기', base, (ex, b) => {
  for (let k = 0; k < 100; k++) { ex.parse(b.length); ex.renderPage(0); }
  return `글꼴영역 ${ex.fontFileLen(0)}B 유지`;
});
// 왕복: 회전 → 워터마크 → 압축 → 병합 결과를 다시 연다
const wasmBytes = fs.readFileSync('dist/pdf.wasm');
async function tool(bytes, fn) {
  const m = await WebAssembly.instantiate(wasmBytes, { wasi_snapshot_preview1: new Proxy({},{get:()=>()=>0}) });
  const ex = m.instance.exports;
  ex.reserve(bytes.length, bytes.length*3 + 1024*1024);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), bytes.length).set(bytes);
  if (!ex.parse(bytes.length)) return null;
  const len = fn(ex, ex.pageCount(), bytes);
  if (!len) return null;
  return Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), len));
}
const rot = await tool(base, (ex, n) => { ex.clearPick(); for(let i=0;i<n;i++) ex.addPick(i); ex.setRotate(90); return ex.apply(); });
await run('회전 결과 다시 열기', rot ?? Buffer.alloc(0));
const wm = await tool(base, (ex, n) => {
  ex.clearPick(); for(let i=0;i<n;i++) ex.addPick(i); ex.setRotate(0);
  ex.clearWatermark(); for (const ch of 'SECRET') ex.addWatermarkChar(ch.charCodeAt(0));
  return ex.apply(); });
await run('워터마크 결과 다시 열기', wm ?? Buffer.alloc(0));
const comp = await tool(base, (ex, n) => { ex.clearPick(); for (let i = 0; i < n; i++) ex.addPick(i); return ex.compact(); });
await run('압축 결과 다시 열기', comp ?? Buffer.alloc(0));
// 왕복 3번
let cur = base;
for (let i = 0; i < 3; i++) {
  cur = (await tool(cur, (ex, n) => { ex.clearPick(); for(let k=0;k<n;k++) ex.addPick(k); ex.setRotate(90); return ex.apply(); })) ?? cur;
}
await run('회전 3번 왕복', cur);
