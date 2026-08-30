// ExtGState /SMask — 그림 하나를 그려 그 밝기로 뒤엣것을 가린다.
import fs from 'node:fs';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
const stream = (dict, d) => Buffer.concat([B(`<< ${dict} /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
function build(objs) {
  let out = B('%PDF-1.4\n');
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
// 가리개 그림: 왼쪽 절반만 하얗다 → 뒤에 칠한 빨강도 왼쪽 절반만 남는다
const maskContent = '1 g 0 0 150 200 re f';
const content = 'q /GS1 gs 1 0 0 rg 0 0 300 200 re f Q q /GS0 gs 0 0 1 rg 0 0 300 200 re f Q';
fs.writeFileSync(`${S}/smask.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /ExtGState << /GS1 5 0 R /GS0 7 0 R >> >> /Contents 4 0 R >>',
  stream('', B(content)),
  '<< /Type /ExtGState /ca 0.9 /SMask << /S /Luminosity /G 6 0 R /BC [0] >> >>',
  stream('/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Group << /S /Transparency /CS /DeviceGray >>', B(maskContent)),
  '<< /Type /ExtGState /SMask /None >>',
]));
console.log('smask.pdf 만듦');
