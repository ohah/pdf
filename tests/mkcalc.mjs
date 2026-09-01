// 셈하는 양식 — 수량 × 단가 = 금액, 그리고 합계.
import fs from 'node:fs';
const objs = [];
const push = (o) => { objs.push(o); return objs.length; };
const S = (s) => `(${s.replace(/([()\\])/g, '\\$1')})`;

push('<</Type/Catalog/Pages 2 0 R/AcroForm<</Fields[5 0 R 6 0 R 7 0 R 8 0 R]/CO[7 0 R 8 0 R]/DA(/Helv 0 Tf 0 g)>>>>');
push('<</Type/Pages/Count 1/Kids[3 0 R]>>');
push('<</Type/Page/Parent 2 0 R/MediaBox[0 0 400 300]/Annots[5 0 R 6 0 R 7 0 R 8 0 R]/Resources<</Font<</Helv 4 0 R>>>>/Contents 9 0 R>>');
push('<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>');
// 수량·단가는 사람이 채운다
push(`<</Type/Annot/Subtype/Widget/FT/Tx/T(qty)/Rect[20 240 120 265]/V(3)/DA(/Helv 11 Tf 0 g)>>`);
push(`<</Type/Annot/Subtype/Widget/FT/Tx/T(price)/Rect[140 240 240 265]/V(1500)/DA(/Helv 11 Tf 0 g)>>`);
// 금액 = 수량 × 단가
push(`<</Type/Annot/Subtype/Widget/FT/Tx/T(amount)/Rect[260 240 380 265]/V()/DA(/Helv 11 Tf 0 g)/AA<</C<</S/JavaScript/JS${S('event.value = this.getField("qty").value * this.getField("price").value;')}>>/F<</S/JavaScript/JS${S('AFNumber_Format(2, 0, 0, 0, "", true);')}>>>>>>`);
// 합계 = 금액 더하기 (AFSimple_Calculate)
push(`<</Type/Annot/Subtype/Widget/FT/Tx/T(total)/Rect[260 200 380 225]/V()/DA(/Helv 11 Tf 0 g)/AA<</C<</S/JavaScript/JS${S('AFSimple_Calculate("SUM", new Array("amount"));')}>>>>>>`);
const c = 'BT /Helv 10 Tf 20 280 Td (qty x price = amount) Tj ET\n';
push(`<</Length ${c.length}>>stream\n${c}endstream `);

let b = '%PDF-1.7\n'; const off = [];
objs.forEach((o, i) => { off.push(b.length); b += `${i + 1} 0 obj${o}endobj\n`; });
const xs = b.length;
b += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
  + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
b += `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${xs}\n%%EOF\n`;
fs.writeFileSync(new URL('./fixtures/calc.pdf', import.meta.url), Buffer.from(b, 'latin1'));
console.log('calc.pdf 만듦');
