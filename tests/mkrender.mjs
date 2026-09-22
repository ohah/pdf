// 실문서 100편 그리기 맞대기(tests/corpus-render.mjs)에서 드러난 결함들의 견본.
//   groupref.pdf   폼의 /Group 이 딴 객체(Illustrator) — 투명 그룹으로 안 묶여 ca 0 이 안 먹었다
//   formimg.pdf    폼 /X1 안의 그림 이름도 /X1(InDesign) — 폼이 제 자신을 끝없이 불렀다
//   devnsh.pdf     [/DeviceN[/Cyan/Magenta]/DeviceCMYK fn] 축 셰이딩, 빈칸 없음 — 회색이 됐다
//   fracw.pdf      /Widths 555.6 — 정수로 잘라 줄 끝에서 0.3pt 밀렸다
//   patbase.pdf    `0.1 0 0 0.1 cm` 아래의 타일 무늬(pdfTeX 사진) — 열 배 작은 칸이 되풀이됐다
//   rgb4.pdf       4비트 RGB + PNG 예측기(DecodeParms 에 BPC 없음) — 줄이 밀려 줄무늬가 됐다
//   sepimg.pdf     [/Separation /Black] 흑백 그림 + /Decode [1 0] — 잉크 함수를 안 태웠다
//   idxcmyk.pdf    /Indexed /DeviceCMYK 팔레트 — 칸을 3바이트로 읽어 잡음이 됐다
//
//   node tests/mkrender.mjs tests/fixtures
import fs from 'node:fs';
import zlib from 'node:zlib';
const S = process.argv[2] ?? 'tests/fixtures';
const B = (x) => Buffer.from(x, 'latin1');
function build(objs) {
  let out = B('%PDF-1.7\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), Buffer.isBuffer(objs[i]) ? objs[i] : B(objs[i]), B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}
const stream = (d, extra = '') => Buffer.concat([B(`<< /Length ${Buffer.isBuffer(d) ? d.length : Buffer.byteLength(d, 'latin1')} ${extra} >>\nstream\n`), Buffer.isBuffer(d) ? d : B(d), B('\nendstream')]);
const flate = (d, extra = '') => { const z = zlib.deflateSync(Buffer.isBuffer(d) ? d : B(d)); return stream(z, `/Filter /FlateDecode ${extra}`); };
const HELV = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>';
const page = (res, contents, extra = '') => `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources ${res} /Contents ${contents} 0 R ${extra} >>`;
const head = (pg) => ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>', pg];

// 1. groupref — 바깥 ca 0, 폼(/Group 6 0 R 투명 그룹) 안에서 ca 1 로 되돌려 칠한다 → 안 보여야 한다
fs.writeFileSync(`${S}/groupref.pdf`, build([
  ...head(page('<< /ExtGState << /GS0 5 0 R >> /XObject << /Fm0 4 0 R >> >>', 7)),
  stream('1 0 0 rg /GS1 gs 20 20 160 160 re f', '/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group 6 0 R /Resources << /ExtGState << /GS1 8 0 R >> >>'),
  '<< /Type /ExtGState /ca 0 /CA 0 >>',
  '<< /Type /Group /S /Transparency /I false /K false >>',
  stream('q /GS0 gs /Fm0 Do Q'),
  '<< /Type /ExtGState /ca 1 /CA 1 >>',
]));

// 2. formimg — 쪽의 /X1 은 폼, 폼 안의 /X1 은 그림(4×4 파랑)
{
  const px = Buffer.alloc(4 * 4 * 3); for (let i = 0; i < 16; i++) { px[i * 3] = 0; px[i * 3 + 1] = 0; px[i * 3 + 2] = 255; }
  fs.writeFileSync(`${S}/formimg.pdf`, build([
    ...head(page('<< /XObject << /X1 4 0 R >> >>', 6)),
    stream('q 160 0 0 160 20 20 cm /X1 Do Q', '/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources << /XObject << /X1 5 0 R >> >>'),
    stream(px, '/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8'),
    stream('q /X1 Do Q'),
  ]));
}

// 3. devnsh — 시안→마젠타 축 셰이딩. 빈칸 없이 붙어 온 색공간 배열
fs.writeFileSync(`${S}/devnsh.pdf`, build([
  ...head(page('<< /Shading << /Sh0 4 0 R >> >>', 6)),
  '<< /ShadingType 2 /ColorSpace 5 0 R /Coords [20 0 180 0] /Extend [true true] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0] /C1 [0 1] /N 1 >> >>',
  '[/DeviceN[/Cyan/Magenta]/DeviceCMYK<</FunctionType 4/Domain[0 1 0 1]/Range[0 1 0 1 0 1 0 1]/Length 20>>]',
  stream('q 20 20 160 160 re W n /Sh0 sh Q'),
]));
// FunctionType 4 는 스트림이어야 한다 — 위 배열 안 사전 대신 딴 객체로
{
  const fn4 = stream('{ 0 0 }', '/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1 0 1]');
  fs.writeFileSync(`${S}/devnsh.pdf`, build([
    ...head(page('<< /Shading << /Sh0 4 0 R >> >>', 6)),
    '<< /ShadingType 2 /ColorSpace 5 0 R /Coords [20 0 180 0] /Extend [true true] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0] /C1 [0 1] /N 1 >> >>',
    '[/DeviceN[/Cyan/Magenta]/DeviceCMYK 7 0 R]',
    stream('q 20 20 160 160 re W n /Sh0 sh Q'),
    fn4,
  ]));
}

// 4. fracw — 폭이 소수인 글꼴로 "nnnnnnnnnn"(열 자, 555.6 → 55.56pt)
fs.writeFileSync(`${S}/fracw.pdf`, build([
  ...head(page('<< /Font << /F1 4 0 R >> >>', 5)),
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /FirstChar 110 /LastChar 110 /Widths [555.6] >>',
  stream('BT /F1 10 Tf 20 100 Td (nnnnnnnnnn) Tj ET'),
]));

// 5. patbase — `0.1 0 0 0.1 cm` 아래에서 타일 무늬(XStep 1600 = 160pt, 칸은 왼쪽 반 빨강·오른쪽 반 파랑)로 채운다
//    무늬 공간은 쪽 기준이라 칸 하나가 20~180 을 덮어야 한다: (60,100) 빨강, (140,100) 파랑
fs.writeFileSync(`${S}/patbase.pdf`, build([
  ...head(page('<< /Pattern << /P0 4 0 R >> >>', 5)),
  stream('1 0 0 rg 0 0 80 160 re f 0 0 1 rg 80 0 80 160 re f', '/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 160 160] /XStep 160 /YStep 160 /Matrix [1 0 0 1 20 20] /Resources << >>'),
  stream('q 0.1 0 0 0.1 0 0 cm /Pattern cs /P0 scn 200 200 1600 1600 re f Q'),
]));

// 6. rgb4 — 4비트 RGB 8×4, PNG 예측기(줄마다 필터 0), DecodeParms 에 BitsPerComponent 없음(= 8 로 봐야 한다)
{
  // 8비트 기준 줄 길이: Columns 8 × Colors 3 = 24 바이트 = 4비트 화소 16개 = 그림 두 줄
  // 그림: 위 두 줄 빨강(F00), 아래 두 줄 파랑(00F). 4비트 RGB 세 표본 = 12비트 → 화소 둘이 3바이트
  const rowPx = (r, g, b) => { const row = []; for (let i = 0; i < 8; i += 2) row.push((r << 4) | g, (b << 4) | r, (g << 4) | b); return Buffer.from(row); };
  const red = rowPx(15, 0, 0), blue = rowPx(0, 0, 15);
  const raw = Buffer.concat([B('\0'), red, red, B('\0'), blue, blue]);
  fs.writeFileSync(`${S}/rgb4.pdf`, build([
    ...head(page('<< /XObject << /Im0 4 0 R >> >>', 5)),
    flate(raw, '/Type /XObject /Subtype /Image /Width 8 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 4 /DecodeParms << /Predictor 15 /Colors 3 /Columns 8 >>'),
    stream('q 160 0 0 160 20 20 cm /Im0 Do Q'),
  ]));
}

// 7. sepimg — [/Separation /Black /DeviceCMYK fn] 흑백 4×4, 값 0 + /Decode [1 0] → 잉크 1 → 인쇄 검정(35,31,32)
fs.writeFileSync(`${S}/sepimg.pdf`, build([
  ...head(page('<< /XObject << /Im0 4 0 R >> >>', 6)),
  stream(Buffer.alloc(16, 0), '/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace 5 0 R /BitsPerComponent 8 /Decode [1 0]'),
  '[/Separation /Black /DeviceCMYK<</FunctionType 2/Domain[0 1]/C0[0 0 0 0]/C1[0 0 0 1]/N 1>>]',
  stream('q 160 0 0 160 20 20 cm /Im0 Do Q'),
]));

// 8. idxcmyk — /Indexed /DeviceCMYK 팔레트 두 칸(시안·순검정), 그림은 다 1번
fs.writeFileSync(`${S}/idxcmyk.pdf`, build([
  ...head(page('<< /XObject << /Im0 4 0 R >> >>', 5)),
  stream(Buffer.alloc(16, 1), '/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace [/Indexed /DeviceCMYK 1 <FF000000 000000FF>] /BitsPerComponent 8'),
  stream('q 160 0 0 160 20 20 cm /Im0 Do Q'),
]));
console.log('wrote 8 fixtures to', S);
