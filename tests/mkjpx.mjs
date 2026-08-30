// JPEG 2000 시험 파일.
//
// 자료는 두 군데서 왔다. t.jp2·gray.jp2 는 macOS 인코더가 만든 것(9/7,
// LRCP, 한 층), p0_*.j2k 는 JPEG2000 적합성 시험 자료(openjpeg-data)다 —
// 5/3, 여러 층, 프리싱크트, 타일, 부표본이 골고루 들어 있다.
import fs from 'node:fs';
const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));

function doc(name, jp2, w, h) {
  const st = (d, x) => Buffer.concat([B(`<< ${x} /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
  const objs = [
    B('<< /Type /Catalog /Pages 2 0 R >>'),
    B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    B(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << /XObject << /I 5 0 R >> >> /Contents 4 0 R >>`),
    st(B(`q ${w} 0 0 ${h} 0 0 cm /I Do Q`), ''),
    st(jp2, `/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode`),
  ];
  let out = B('%PDF-1.5\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), objs[i], B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  fs.writeFileSync(`${S}/${name}`, Buffer.concat([out, B(x)]));
}

/** 주 머리말에 RGN 표식을 끼워 넣는다 (관심 구역, 부록 H).
 *
 * 눈여겨볼 구역을 나머지보다 위 비트면에 올려 담는 꼴이다. 복호기는 문턱을
 * 넘는 계수를 그만큼 도로 내려야 한다. 올림값을 아주 크게 주면 넘는 계수가
 * 없으니 원본과 한 픽셀도 다르지 않아야 하고, 작게 주면 달라져야 한다. */
function withRgn(j2k, comp, shift) {
  const lsiz = j2k.readUInt16BE(4);
  const at = 4 + lsiz;                    // SOC(2) + FF51(2) + SIZ 몸통
  const rgn = Buffer.from([0xff, 0x5e, 0x00, 0x05, comp, 0x00, shift]);
  return Buffer.concat([j2k.subarray(0, at), rgn, j2k.subarray(at)]);
}

for (const [f, name, w, h] of [
  ['t.jp2', 'jpx-rgb.pdf', 64, 48],
  ['gray.jp2', 'jpx-gray.pdf', 96, 72],
  ['p0_01.j2k', 'jpx-53.pdf', 128, 128],
  ['p0_09.j2k', 'jpx-tiny.pdf', 17, 37],
  ['p0_10.j2k', 'jpx-tiles.pdf', 256, 256],
  ['p0_11.j2k', 'jpx-prec.pdf', 128, 1],
  ['p0_14.j2k', 'jpx-mct.pdf', 49, 49],
  ['p0_16.j2k', 'jpx-layers.pdf', 128, 128],
]) doc(name, fs.readFileSync(`${S}/jpx/${f}`), w, h);

{
  const base = fs.readFileSync(`${S}/jpx/p0_01.j2k`);
  doc('jpx-roi-high.pdf', withRgn(base, 0, 30), 128, 128);  // 넘는 계수가 없다
  doc('jpx-roi-low.pdf', withRgn(base, 0, 3), 128, 128);    // 여럿이 넘는다
}
console.log('jpx-* 8개 만듦');
