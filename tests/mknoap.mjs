// 겉모습(/AP)이 없는 주석. 뷰어가 규격의 기본 모양으로 대신 그려야 한다.
//
//   node tests/mknoap.mjs tests/fixtures
//
// pdf.js 도 poppler 도 이것들을 그린다 — 네모·동그라미·선·잉크·형광펜·
// 밑줄·취소선·물결·다각형·꺾은선. 색은 /C(테두리)·/IC(속), 굵기는 /BS /W,
// 투명도는 /CA 다. 글자가 드는 것(/FreeText)과 아이콘(/Text)은 안 넣는다 —
// 글꼴·아이콘 그림은 뷰어마다 달라 맞댈 수 없다.
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';

const notes = [
  // 네모 — 속 노랑, 테두리 파랑 3pt
  '<< /Type /Annot /Subtype /Square /Rect [20 300 140 380] /C [0 0 1] /IC [1 1 0] /BS << /W 3 >> /F 4 >>',
  // 동그라미 — 속 없음, 테두리 빨강 2pt, 반투명
  '<< /Type /Annot /Subtype /Circle /Rect [160 300 280 380] /C [1 0 0] /BS << /W 2 >> /CA 0.5 /F 4 >>',
  // 선 — 초록 4pt
  '<< /Type /Annot /Subtype /Line /Rect [300 300 390 380] /L [305 305 385 375] /C [0 0.6 0] /BS << /W 4 >> /F 4 >>',
  // 잉크 — 두 획, 보라 2pt
  '<< /Type /Annot /Subtype /Ink /Rect [20 180 140 280] /InkList [[25 190 50 270 80 200 110 260] [30 230 130 230]] /C [0.5 0 0.5] /BS << /W 2 >> /F 4 >>',
  // 형광펜 — 노랑, 두 줄
  '<< /Type /Annot /Subtype /Highlight /Rect [160 180 280 280] /QuadPoints [165 270 275 270 165 250 275 250  165 230 275 230 165 210 275 210] /C [1 1 0] /F 4 >>',
  // 밑줄 — 파랑
  '<< /Type /Annot /Subtype /Underline /Rect [300 240 390 280] /QuadPoints [305 275 385 275 305 250 385 250] /C [0 0 1] /F 4 >>',
  // 취소선 — 빨강
  '<< /Type /Annot /Subtype /StrikeOut /Rect [300 180 390 230] /QuadPoints [305 225 385 225 305 195 385 195] /C [1 0 0] /F 4 >>',
  // 물결 — 초록
  '<< /Type /Annot /Subtype /Squiggly /Rect [20 100 140 160] /QuadPoints [25 150 135 150 25 120 135 120] /C [0 0.5 0] /F 4 >>',
  // 다각형 — 닫힘, 속 하늘색
  '<< /Type /Annot /Subtype /Polygon /Rect [160 20 280 160] /Vertices [170 30 270 60 250 150 180 140] /C [0 0 0] /IC [0.6 0.8 1] /BS << /W 2 >> /F 4 >>',
  // 꺾은선 — 열림, 점선
  '<< /Type /Annot /Subtype /PolyLine /Rect [300 20 390 160] /Vertices [305 30 385 60 310 100 380 150] /C [0.3 0.3 0.3] /BS << /W 2 /S /D /D [4 2] >> /F 4 >>',
];
const content = '0.97 0.97 0.97 rg 0 0 400 400 re f';
const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << >> /Contents 4 0 R /Annots [${notes.map((_, i) => `${5 + i} 0 R`).join(' ')}] >>`,
  `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  ...notes,
];
let out = '%PDF-1.7\n';
const offs = [];
objs.forEach((o, i) => { offs.push(Buffer.byteLength(out, 'latin1')); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
const xref = Buffer.byteLength(out, 'latin1');
out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of offs) out += String(o).padStart(10, '0') + ' 00000 n \n';
out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
fs.writeFileSync(`${S}/noap.pdf`, out, 'latin1');
console.log('noap.pdf 만듦');
