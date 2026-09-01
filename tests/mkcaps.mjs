// 상한 시험용 문서 — 한 쪽에 그림 40개, 글꼴 40개, 자리 다 다른 네모 20만 개.
import fs from 'node:fs';
function build(objs) {
  let b = '%PDF-1.7\n'; const off = [];
  objs.forEach((o, i) => { off.push(b.length); b += `${i + 1} 0 obj${o}endobj\n`; });
  const xs = b.length;
  b += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
    + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
  b += `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${xs}\n%%EOF\n`;
  return Buffer.from(b, 'latin1');
}
const here = (n) => new URL(`./fixtures/${n}`, import.meta.url);
// 그림 40개 — 저마다 다른 색
{
  const N = 40, imgs = [];
  let res = '', c = '';
  for (let i = 0; i < N; i++) {
    const r = (i * 13) % 256, g = (i * 37 + 40) % 256, bl = (i * 61 + 80) % 256;
    imgs.push(`<</Type/XObject/Subtype/Image/Width 1/Height 1/ColorSpace/DeviceRGB/BitsPerComponent 8/Length 3>>stream\n${String.fromCharCode(r, g, bl)}\nendstream `);
    res += `/Im${i} ${5 + i} 0 R `;
    c += `q 60 0 0 60 ${20 + (i % 8) * 70} ${700 - Math.floor(i / 8) * 70} cm /Im${i} Do Q\n`;
  }
  fs.writeFileSync(here('caps-imgs.pdf'), build([
    '<</Type/Catalog/Pages 2 0 R>>', '<</Type/Pages/Count 1/Kids[3 0 R]>>',
    `<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<</XObject<<${res}>>>>/Contents 4 0 R>>`,
    `<</Length ${c.length}>>stream\n${c}endstream `, ...imgs]));
}
// 글꼴 40개 — 저마다 한 글자씩
{
  const N = 40, fonts = [];
  let res = '', c = '';
  const base = ['Helvetica', 'Times-Roman', 'Courier'];
  for (let i = 0; i < N; i++) {
    fonts.push(`<</Type/Font/Subtype/Type1/BaseFont/${base[i % 3]}>>`);
    res += `/F${i} ${5 + i} 0 R `;
    c += `BT /F${i} 14 Tf ${20 + (i % 10) * 55} ${700 - Math.floor(i / 10) * 40} Td (Font${i}) Tj ET\n`;
  }
  fs.writeFileSync(here('caps-fonts.pdf'), build([
    '<</Type/Catalog/Pages 2 0 R>>', '<</Type/Pages/Count 1/Kids[3 0 R]>>',
    `<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<</Font<<${res}>>>>/Contents 4 0 R>>`,
    `<</Length ${c.length}>>stream\n${c}endstream `, ...fonts]));
}
// 네모 20만 개 — 자리가 다 다르다
{
  let c = '0 0 0 rg\n';
  for (let i = 0; i < 200000; i++) {
    const x = 6 + (i % 300) * 2, y = 780 - (Math.floor(i / 300) % 390) * 2;
    c += `${x} ${y} 1 1 re f\n`;
  }
  fs.writeFileSync(here('caps-ops.pdf'), build([
    '<</Type/Catalog/Pages 2 0 R>>', '<</Type/Pages/Count 1/Kids[3 0 R]>>',
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<<>>/Contents 4 0 R>>',
    `<</Length ${c.length}>>stream\n${c}endstream `]));
}
console.log('caps-imgs / caps-fonts / caps-ops 만듦');
