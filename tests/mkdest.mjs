// 이름으로 가리킨 목적지.
//
// `/Dest /2장` 처럼 이름만 적힌 링크가 흔하다. 실제 자리는 카탈로그의
// /Names /Dests 이름나무(새 꼴)나 /Dests 딕셔너리(옛 꼴)에 있다.
// 세 갈래를 한 문서씩 만들어 둔다.
import fs from 'node:fs';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));

function build(objs) {
  let out = B('%PDF-1.5\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), B(objs[i]), B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}

/** kind: 'tree' 이름나무 · 'dict' 옛 딕셔너리 · 'array' 곧은 배열 */
function make(kind) {
  const dest = kind === 'array' ? '[5 0 R /XYZ 0 700 0]' : '/두번째';
  const cat = kind === 'tree'
    ? '<< /Type /Catalog /Pages 2 0 R /Names 8 0 R /Outlines 6 0 R >>'
    : kind === 'dict'
      ? '<< /Type /Catalog /Pages 2 0 R /Dests 9 0 R /Outlines 6 0 R >>'
      : '<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>';
  const c1 = 'BT /F1 20 Tf 60 700 Td (page one) Tj ET';
  const c2 = 'BT /F1 20 Tf 60 700 Td (page two) Tj ET';
  return build([
    cat,
    '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 760] /Resources << /Font << /F1 10 0 R >> >>`
      + ` /Contents 4 0 R /Annots [11 0 R] >>`,
    `<< /Length ${c1.length} >>\nstream\n${c1}\nendstream`,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 760] /Resources << /Font << /F1 10 0 R >> >> /Contents 7 0 R >>',
    // 목차 — 둘째 쪽을 가리킨다
    '<< /Type /Outlines /First 12 0 R /Last 12 0 R /Count 1 >>',
    `<< /Length ${c2.length} >>\nstream\n${c2}\nendstream`,
    // 이름나무 (마디를 한 겹 더 둬서 /Kids 도 타 본다)
    '<< /Dests 13 0 R >>',
    // 옛 꼴 딕셔너리
    '<< /두번째 [5 0 R /Fit] >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    // 링크 주석 — 목적지 꼴은 갈래마다 다르다
    `<< /Type /Annot /Subtype /Link /Rect [50 690 250 720] /Dest ${dest} >>`,
    `<< /Title (둘째 쪽으로) /Parent 6 0 R /Dest ${dest} >>`,
    '<< /Kids [14 0 R] >>',
    '<< /Names [(두번째) [5 0 R /Fit]] >>',
  ]);
}

for (const k of ['tree', 'dict', 'array']) fs.writeFileSync(`${S}/dest-${k}.pdf`, make(k));
console.log('dest-tree·dest-dict·dest-array 만듦');
