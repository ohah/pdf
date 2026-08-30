// 셰이딩 1·4·5·6·7 형과 표본 함수(/FunctionType 0) 시험 파일.
import fs from 'node:fs';
const S = process.argv[2];

function build(objs) {
  const parts = [Buffer.from('%PDF-1.4\n', 'latin1')];
  let len = parts[0].length;
  const off = [];
  for (let i = 0; i < objs.length; i++) {
    off.push(len);
    const head = Buffer.from(`${i + 1} 0 obj\n`, 'latin1');
    const body = Buffer.isBuffer(objs[i]) ? objs[i] : Buffer.from(objs[i], 'latin1');
    const tail = Buffer.from('\nendobj\n', 'latin1');
    parts.push(head, body, tail);
    len += head.length + body.length + tail.length;
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of off) x += `${String(o).padStart(10, '0')} 00000 n \n`;
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
  parts.push(Buffer.from(x, 'latin1'));
  return Buffer.concat(parts);
}
const stream = (dict, data) => Buffer.concat([
  Buffer.from(`<< ${dict} /Length ${data.length} >>\nstream\n`, 'latin1'),
  data, Buffer.from('\nendstream', 'latin1')]);

/** 셰이딩 객체 하나를 /Sh1 로 걸고 sh 로 칠하는 한 쪽짜리 문서 */
function page(shadeObj) {
  const content = 'q 0 0 300 200 re W n /Sh1 sh Q';
  return build([
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Shading << /Sh1 5 0 R >> >> /Contents 4 0 R >>',
    stream('', Buffer.from(content, 'latin1')),
    shadeObj,
  ]);
}

const be16 = (v) => { const b = Buffer.alloc(2); b.writeUInt16BE(Math.max(0, Math.min(65535, v))); return b; };
const u8 = (v) => Buffer.from([Math.max(0, Math.min(255, v))]);
// Decode 가 [0 300 0 200] 이므로 좌표를 0~65535 로 편다
const X = (v) => be16(Math.round((v / 300) * 65535));
const Y = (v) => be16(Math.round((v / 200) * 65535));
const RGB = (r, g, b) => Buffer.concat([u8(r * 255), u8(g * 255), u8(b * 255)]);

const DEC = '/Decode [0 300 0 200 0 1 0 1 0 1]';
const BITS = '/BitsPerCoordinate 16 /BitsPerComponent 8 /BitsPerFlag 8';

// --- 4형: 자유 삼각 그물. 빨강·초록·파랑 꼭짓점.
fs.writeFileSync(`${S}/sh4.pdf`, page(stream(
  `/ShadingType 4 /ColorSpace /DeviceRGB ${BITS} ${DEC}`,
  Buffer.concat([
    u8(0), X(20), Y(20), RGB(1, 0, 0),
    u8(0), X(280), Y(30), RGB(0, 1, 0),
    u8(0), X(150), Y(180), RGB(0, 0, 1),
  ]))));

// --- 5형: 격자. 두 줄 × 두 칸.
fs.writeFileSync(`${S}/sh5.pdf`, page(stream(
  `/ShadingType 5 /ColorSpace /DeviceRGB /VerticesPerRow 2 ${BITS} ${DEC}`,
  Buffer.concat([
    X(20), Y(20), RGB(1, 0, 0), X(280), Y(20), RGB(0, 1, 0),
    X(20), Y(180), RGB(0, 0, 1), X(280), Y(180), RGB(1, 1, 0),
  ]))));

// --- 6형: Coons 조각 하나. 테두리 점 12 개.
const ring = [
  [20, 20], [20, 74], [20, 127], [20, 180],
  [113, 180], [206, 180], [280, 180],
  [280, 127], [280, 74], [280, 20],
  [206, 20], [113, 20],
];
fs.writeFileSync(`${S}/sh6.pdf`, page(stream(
  `/ShadingType 6 /ColorSpace /DeviceRGB ${BITS} ${DEC}`,
  Buffer.concat([
    u8(0),
    ...ring.map(([x, y]) => Buffer.concat([X(x), Y(y)])),
    RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1), RGB(1, 1, 0),
  ]))));

// --- 7형: 텐서 조각. 안쪽 점 넷이 더 붙는다.
const inner = [[113, 74], [113, 127], [206, 127], [206, 74]];
fs.writeFileSync(`${S}/sh7.pdf`, page(stream(
  `/ShadingType 7 /ColorSpace /DeviceRGB ${BITS} ${DEC}`,
  Buffer.concat([
    u8(0),
    ...ring.map(([x, y]) => Buffer.concat([X(x), Y(y)])),
    ...inner.map(([x, y]) => Buffer.concat([X(x), Y(y)])),
    RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1), RGB(1, 1, 0),
  ]))));

// --- 1형: x·y 를 받는 함수. 표본 함수 4×4 로 준다.
{
  const N = 4;
  const samp = [];
  for (let j = 0; j < N; j++) for (let i = 0; i < N; i++)
    samp.push(Math.round((i / (N - 1)) * 255), 0, Math.round((j / (N - 1)) * 255));
  fs.writeFileSync(`${S}/sh1.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Shading << /Sh1 5 0 R >> >> /Contents 4 0 R >>',
    stream('', Buffer.from('q /Sh1 sh Q', 'latin1')),
    '<< /ShadingType 1 /ColorSpace /DeviceRGB /Domain [0 1 0 1] /Matrix [280 0 0 180 10 10] /Function 6 0 R >>',
    stream('/FunctionType 0 /Domain [0 1 0 1] /Size [4 4] /BitsPerSample 8 /Range [0 1 0 1 0 1]',
      Buffer.from(samp)),
  ]));
}

// --- 표본 함수를 쓰는 2형(축). 빨강 → 파랑.
fs.writeFileSync(`${S}/fn0.pdf`, build([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Shading << /Sh1 5 0 R >> >> /Contents 4 0 R >>',
  stream('', Buffer.from('q 0 0 300 200 re W n /Sh1 sh Q', 'latin1')),
  '<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 300 0] /Function 6 0 R /Extend [true true] >>',
  stream('/FunctionType 0 /Domain [0 1] /Size [2] /BitsPerSample 8 /Range [0 1 0 1 0 1]',
    Buffer.from([255, 0, 0, 0, 0, 255])),
]));

// --- 계산기 함수(/FunctionType 4)를 쓰는 축 셰이딩.
// t 를 받아 (t, 1-t, 0.5) 를 낸다 — 빨강에서 초록으로 간다.
{
  const ps = '{ dup 1 exch sub 0.5 }';
  fs.writeFileSync(`${S}/fn4.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Shading << /Sh1 5 0 R >> >> /Contents 4 0 R >>',
    stream('', Buffer.from('q 0 0 300 200 re W n /Sh1 sh Q', 'latin1')),
    '<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 300 0] /Function 6 0 R /Extend [true true] >>',
    stream('/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]', Buffer.from(ps, 'latin1')),
  ]));
}

// --- 성분마다 함수가 따로 오는 축 셰이딩 (/Function [f1 f2 f3])
{
  const f = (a, b) => `<< /FunctionType 2 /Domain [0 1] /C0 [${a}] /C1 [${b}] /N 1 >>`;
  fs.writeFileSync(`${S}/fnarr.pdf`, build([
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Shading << /Sh1 5 0 R >> >> /Contents 4 0 R >>',
    stream('', Buffer.from('q 0 0 300 200 re W n /Sh1 sh Q', 'latin1')),
    `<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 300 0] /Function [6 0 R 7 0 R 8 0 R] /Extend [true true] >>`,
    f(0, 1), f(1, 0), f(0.25, 0.75),
  ]));
}
console.log('sh1·sh4·sh5·sh6·sh7·fn0·fn4·fnarr 만듦');
