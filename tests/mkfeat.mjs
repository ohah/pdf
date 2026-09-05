// 규격의 빈 곳을 겨눈 견본들.
//
//   node tests/mkfeat.mjs tests/fixtures
//
// 있던 견본 113개가 넓게 덮고 있었지만, 세 뷰어(우리·pdf.js·poppler)로
// 맞대 보니 안 덮인 자리가 있었다. 여기서 만든 열둘로 결함 다섯을 잡았다:
//
//   t-decode     /Decode [1 0] 을 8비트 그림에 안 먹였다
//   t-bpc        2·4비트 회색 그림을 통째로 안 그렸다
//   t-sep        Separation 이 잉크 변환 함수를 안 탔다
//   t-uncolored  무색 무늬(/PaintType 2)가 준 색을 무시했다
//   t-blend      /ColorDodge·/ColorBurn 이 이름 앞머리 때문에 죽었다
//
// 나머지 일곱(clipnest·evenodd·smaskl·devn·trmode·dash·rot90)은 맞았다.
// 그것들도 남겨 둔다 — 되돌림을 잡는 그물이다.
import fs from "node:fs";

const OUT = process.argv[2] ?? "tests/fixtures";

function build(objs) {
  const parts = [Buffer.from("%PDF-1.7\n", "latin1")];
  let len = parts[0].length;
  const off = [];
  for (let i = 0; i < objs.length; i++) {
    off.push(len);
    const head = Buffer.from(`${i + 1} 0 obj\n`, "latin1");
    const body = Buffer.isBuffer(objs[i]) ? objs[i] : Buffer.from(objs[i], "latin1");
    const tail = Buffer.from("\nendobj\n", "latin1");
    parts.push(head, body, tail);
    len += head.length + body.length + tail.length;
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of off) x += `${String(o).padStart(10, "0")} 00000 n \n`;
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
  parts.push(Buffer.from(x, "latin1"));
  return Buffer.concat(parts);
}

const stream = (dict, data) => Buffer.concat([
  Buffer.from(`<< ${dict} /Length ${data.length} >>\nstream\n`, "latin1"),
  Buffer.isBuffer(data) ? data : Buffer.from(data, "latin1"),
  Buffer.from("\nendstream", "latin1")]);

/** 1=Catalog 2=Pages 3=Page 4=Contents, 그 뒤가 extra(5 0 R 부터) */
function page(name, content, { w = 200, h = 200, res = "", extra = [], rotate = 0 } = {}) {
  fs.writeFileSync(`${OUT}/${name}`, build([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}]${rotate ? ` /Rotate ${rotate}` : ""} /Resources << ${res} >> /Contents 4 0 R >>`,
    stream("", content),
    ...extra,
  ]));
}

// ① 혼합 모드 열둘 — 초록 바탕에 빨강 사각형
{
  const modes = ["Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten",
    "ColorDodge", "ColorBurn", "HardLight", "SoftLight", "Difference", "Exclusion"];
  let c = "0 0.6 0.3 rg 0 0 200 200 re f\n";
  const gs = modes.map((m, i) => `/G${i} << /Type /ExtGState /BM /${m} /ca 1 >>`).join(" ");
  modes.forEach((m, i) => {
    const x = 10 + (i % 4) * 48, y = 150 - Math.floor(i / 4) * 48;
    c += `q /G${i} gs 0.9 0.2 0.1 rg ${x} ${y} 40 40 re f Q\n`;
  });
  page("t-blend.pdf", c, { res: `/ExtGState << ${gs} >>` });
}
// ② 무색 무늬 — 색은 쓰는 쪽이 준다
page("t-uncolored.pdf",
  "/Cs1 cs 0.85 0.1 0.1 /P1 scn 10 110 80 80 re f\n" +
  "/Cs1 cs 0.1 0.3 0.85 /P1 scn 110 110 80 80 re f\n" +
  "0 0 0 rg 10 10 80 80 re f\n",
  { res: "/Pattern << /P1 5 0 R >> /ColorSpace << /Cs1 [/Pattern /DeviceRGB] >>",
    extra: [stream("/Type /Pattern /PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
      "1 w 0 0 m 10 10 l S 10 0 m 0 10 l S")] });
// ③ 점선·선끝·이음
{
  let c = "";
  ["[] 0", "[6 3] 0", "[6 3] 3", "[1 5] 0", "[10 2 2 2] 0"].forEach((d, i) => {
    c += `q 3 w ${d} d 1 J 0 0 0 RG 20 ${180 - i * 20} m 180 ${180 - i * 20} l S Q\n`;
  });
  [0, 1, 2].forEach((cap, i) => { c += `q 10 w ${cap} J 0 0 1 RG 30 ${70 - i * 20} m 90 ${70 - i * 20} l S Q\n`; });
  [0, 1, 2].forEach((j, i) => { c += `q 10 w ${j} j 1 0 0 RG 120 ${40 + i * 20} m 145 ${60 + i * 20} l 170 ${40 + i * 20} l S Q\n`; });
  page("t-dash.pdf", c);
}
// ④ 짝홀 채우기 vs 감김수 — 별은 둘이 다르게 나온다
{
  const star = (cx, cy, r) => {
    let p = "";
    for (let i = 0; i < 5; i++) {
      const a = -Math.PI / 2 + i * 4 * Math.PI / 5;
      p += `${(cx + r * Math.cos(a)).toFixed(2)} ${(cy + r * Math.sin(a)).toFixed(2)} ${i ? "l" : "m"} `;
    }
    return p + "h";
  };
  page("t-evenodd.pdf", `0.1 0.1 0.8 rg ${star(60, 130, 45)} f\n0.8 0.1 0.1 rg ${star(150, 130, 45)} f*\n`);
}
// ⑤ /Decode 로 뒤집은 그림 — 왼쪽이 원본, 오른쪽이 뒤집힌 것
{
  const w = 8, h = 8;
  const px = Buffer.alloc(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) px[y * w + x] = ((x + y) & 1) ? 230 : 30;
  page("t-decode.pdf", "q 80 0 0 80 20 100 cm /I Do Q\nq 80 0 0 80 110 100 cm /J Do Q\n",
    { res: "/XObject << /I 5 0 R /J 6 0 R >>",
      extra: [stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceGray /BitsPerComponent 8`, px),
        stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [1 0]`, px)] });
}
// ⑥ 2비트·4비트 회색 그림 (필터 없이 날바이트)
page("t-bpc.pdf", "q 80 0 0 80 15 100 cm /A Do Q\nq 80 0 0 80 105 100 cm /B Do Q\n",
  { res: "/XObject << /A 5 0 R /B 6 0 R >>",
    extra: [stream("/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 2",
      Buffer.from([0b00011011, 0b11100100, 0b00011011, 0b11100100])),
      stream("/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 4",
        Buffer.from([0x0f, 0x3c, 0xf0, 0xc3, 0x5a, 0xa5, 0x69, 0x96]))] });
// ⑦ Separation — 잉크 하나를 RGB 로 바꾸는 함수
page("t-sep.pdf", "/CsSep cs 0.2 scn 10 110 80 80 re f\n/CsSep cs 0.9 scn 110 110 80 80 re f\n",
  { res: "/ColorSpace << /CsSep [/Separation /Spot /DeviceRGB 5 0 R] >>",
    extra: [stream("/FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0.1 0.4 0.8] /N 1", "")] });
// ⑧ DeviceN — 잉크 둘
page("t-devn.pdf", "/CsN cs 0.9 0.1 scn 10 110 80 80 re f\n/CsN cs 0.1 0.9 scn 110 110 80 80 re f\n",
  { res: "/ColorSpace << /CsN [/DeviceN [/A /B] /DeviceRGB 5 0 R] >>",
    extra: [stream("/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]",
      "{ 2 copy 0.5 mul exch 0.5 mul add 3 1 roll pop pop dup dup }")] });
// ⑨ 쪽 회전 90도
page("t-rot90.pdf", "BT /F1 24 Tf 20 100 Td (Rotate 90) Tj ET\n0.8 0.2 0.2 rg 20 20 60 30 re f\n",
  { w: 200, h: 300, rotate: 90, res: "/Font << /F1 5 0 R >>",
    extra: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"] });
// ⑩ 글자 그리기 모드 0..7 (채우기·선·둘·안보임·오려내기)
{
  let c = "";
  for (let m = 0; m < 8; m++) c += `q BT /F1 20 Tf 1 0 0 RG 0 0 0.8 rg 0.8 w ${m} Tr 12 ${170 - m * 21} Td (Mode ${m}) Tj ET Q\n`;
  page("t-trmode.pdf", c, { res: "/Font << /F1 5 0 R >>",
    extra: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"] });
}
// ⑪ ExtGState 의 부드러운 가리개(SMask, 밝기)
page("t-smaskl.pdf", "q /GS1 gs 0.9 0.1 0.1 rg 0 0 200 200 re f Q\n",
  { res: "/ExtGState << /GS1 << /Type /ExtGState /SMask << /S /Luminosity /G 5 0 R >> >> >>",
    extra: [stream("/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group << /S /Transparency /CS /DeviceGray >>", "/Sh1 sh")] });
// ⑫ 겹쳐 오려 내기 (W n 과 W* n)
page("t-clipnest.pdf",
  "q 20 20 160 160 re W n 0.2 0.4 0.9 rg 0 0 200 200 re f\n" +
  "  60 60 m 140 60 l 140 140 l 60 140 l h 80 80 m 120 80 l 120 120 l 80 120 l h W* n\n" +
  "  0.9 0.5 0.1 rg 0 0 200 200 re f Q\n");

console.log("t-blend·t-uncolored·t-dash·t-evenodd·t-decode·t-bpc·t-sep·t-devn·t-rot90·t-trmode·t-smaskl·t-clipnest 만듦");
