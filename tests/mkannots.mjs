// 여러 갈래 주석이 든 붙임감. 한글은 규격대로 UTF-16BE + BOM 으로 적는다.
//
//   node tests/mkannots.mjs tests/fixtures
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';

/** PDF 문자열. 한글이 섞이면 UTF-16BE(BOM) 16진 문자열로 적는다. */
const str = (t) => {
  if (/^[\x20-\x7e]*$/.test(t)) return `(${t.replace(/([()\\])/g, '\\$1')})`;
  const buf = Buffer.from('﻿' + t, 'utf16le').swap16();
  return `<${buf.toString('hex')}>`;
};

const notes = [
  `<< /Type /Annot /Subtype /Highlight /Rect [100 700 300 720] /C [1 1 0] /Contents ${str('중요한 곳')} /T ${str('윤보경')} /M (D:20260901120000+09'00') /F 4 >>`,
  `<< /Type /Annot /Subtype /Text /Rect [50 600 70 620] /Contents ${str('메모 내용')} /T ${str('다른 사람')} /C [1 0 0] >>`,
  '<< /Type /Annot /Subtype /Square /Rect [200 400 380 500] /C [0 0 1] >>',
  '<< /Type /Annot /Subtype /Link /Rect [50 300 200 320] /A << /S /URI /URI (https://example.com) >> >>',
  `<< /Type /Annot /Subtype /StrikeOut /Rect [50 200 250 216] /C [0.5] /Contents ${str('지운 줄')} >>`,
];
const content = 'BT /F1 12 Tf 40 750 Td (annots) Tj ET';
const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /Annots [${notes.map((_, i) => `${6 + i} 0 R`).join(' ')}] >>`,
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  ...notes,
];
let out = '%PDF-1.7\n';
const off = [];
objs.forEach((o, i) => { off.push(out.length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
const x = out.length;
out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of off) out += `${String(o).padStart(10, '0')} 00000 n \n`;
out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;
fs.writeFileSync(`${S}/annots.pdf`, Buffer.from(out, 'latin1'));
console.log('annots.pdf 만듦 — 형광펜·메모·네모·링크·취소선');
