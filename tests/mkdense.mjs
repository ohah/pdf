// 작은 파일에 빽빽한 쪽 — 내용 스트림이 1MB 를 넘는다.
//
// 예전에는 이 쪽이 통째로 백지로 나왔다. 내용을 모으는 자리를 "남은 자리의
// 8분의 3" 으로 잡았고, 그 자리는 파일 크기에 딸린 값이라 작은 파일에서는
// 모자랐다. 같은 쪽이 9MB 파일에서는 멀쩡히 그려졌다.
import fs from 'node:fs';
const objs = [];
let c = '0 0 0 rg\n';
for (let i = 0; i < 5000; i++) {
  const x = 5 + (i % 600), y = 780 - (i % 700);
  c += `${x} ${y} 1 1 re f\n% ${'x'.repeat(200)}\n`;
}
objs.push('<</Type/Catalog/Pages 2 0 R>>');
objs.push('<</Type/Pages/Count 1/Kids[3 0 R]>>');
objs.push('<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<<>>/Contents 4 0 R>>');
objs.push(`<</Length ${c.length}>>stream\n${c}endstream `);
let b = '%PDF-1.7\n';
const off = [];
objs.forEach((o, i) => { off.push(b.length); b += `${i + 1} 0 obj${o}endobj\n`; });
const xs = b.length;
b += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
  + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
b += `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${xs}\n%%EOF\n`;
fs.writeFileSync(new URL('./fixtures/dense.pdf', import.meta.url), Buffer.from(b, 'latin1'));
console.log('dense.pdf', (b.length / 1048576).toFixed(2) + 'MB · 내용', (c.length / 1048576).toFixed(2) + 'MB');
