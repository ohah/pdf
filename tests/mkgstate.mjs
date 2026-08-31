// 투명 그룹이 부르는 쪽의 그리기 상태를 물려받는지 보는 붙임감.
//
//   node tests/mkgstate.mjs tests/fixtures
//
// 쪽은 `1 0 0 rg`(빨강) 로 칠할 색을 정해 두고 /ca 0.5 를 건 뒤 폼을 부른다.
// 폼 안에는 색을 정하는 명령이 없다 — 규격대로면 빨강을 물려받아야 한다.
// 그룹 판을 갓 만든 캔버스로 두면 검정으로 나온다.
import fs from 'node:fs';
const S = process.argv[2] ?? 'tests/fixtures';

const form = '0 0 100 100 re f';
const content = 'q 1 0 0 rg /GS0 gs /Fm0 Do Q';
const objs = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /ExtGState << /GS0 5 0 R >> /XObject << /Fm0 6 0 R >> >> /Contents 4 0 R >>',
  `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  '<< /Type /ExtGState /ca 0.5 /CA 0.5 >>',
  `<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Group << /S /Transparency /CS /DeviceRGB >> /Length ${form.length} >>\nstream\n${form}\nendstream`,
];

let out = '%PDF-1.7\n';
const off = [];
objs.forEach((o, i) => {
  off.push(out.length);
  out += `${i + 1} 0 obj\n${o}\nendobj\n`;
});
const xref = out.length;
out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of off) out += `${String(o).padStart(10, '0')} 00000 n \n`;
out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
fs.writeFileSync(`${S}/gstate.pdf`, Buffer.from(out, 'latin1'));
console.log('gstate.pdf 만듦 — 투명 그룹이 빨강을 물려받아야 한다');
