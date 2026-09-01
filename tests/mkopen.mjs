// /OpenAction 이 있는 문서 넷 — 배열·동작 딕셔너리·이름 붙은 자리·참조.
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
// 쪽 넷 + 글꼴 하나. 3쪽(=색인 2)으로 가라고 여러 꼴로 적는다.
const pages = (cat) => {
  const objs = [cat, '<</Type/Pages/Count 4/Kids[3 0 R 4 0 R 5 0 R 6 0 R]>>'];
  for (let i = 0; i < 4; i++)
    objs.push(`<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 400]/Resources<</Font<</F1 7 0 R>>>>/Contents ${8 + i} 0 R>>`);
  objs.push('<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>');
  for (let i = 0; i < 4; i++) {
    const c = `BT /F1 24 Tf 30 200 Td (Sheet ${i + 1}) Tj ET\n`;
    objs.push(`<</Length ${c.length}>>stream\n${c}endstream `);
  }
  return objs;
};
const here = (n) => new URL(`./fixtures/${n}`, import.meta.url);
// 가) 배열로 바로 — /XYZ 로 자리까지
fs.writeFileSync(here('open-xyz.pdf'), build(pages(
  '<</Type/Catalog/Pages 2 0 R/OpenAction[5 0 R /XYZ 40 320 2]>>')));
// 나) 동작 딕셔너리 + /Fit
fs.writeFileSync(here('open-dict.pdf'), build(pages(
  '<</Type/Catalog/Pages 2 0 R/OpenAction<</S/GoTo/D[5 0 R /Fit]>>>>')));
// 다) 이름 붙은 자리
{
  const objs = pages('<</Type/Catalog/Pages 2 0 R/Names<</Dests 12 0 R>>/OpenAction<</S/GoTo/D(third)>>>>');
  objs.push('<</Names[(third) [5 0 R /FitH 300]]>>');
  fs.writeFileSync(here('open-name.pdf'), build(objs));
}
// 라) 갈 데가 없는 동작(자바스크립트) — 1쪽 그대로여야 한다
fs.writeFileSync(here('open-js.pdf'), build(pages(
  '<</Type/Catalog/Pages 2 0 R/OpenAction<</S/JavaScript/JS(app.alert\\(1\\))>>>>')));
console.log('open-xyz / open-dict / open-name / open-js 만듦');
