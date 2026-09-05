// 세 번째 묶음 — *코드가 있는데 견본이 없던* 자리만.
//
//   node tests/mkfeat3.mjs tests/fixtures [자료디렉터리]
//
// 앞의 두 묶음을 만들며 배운 것: 견본은 코드가 있는데 틀린 곳에서만 결함을
// 캔다. 코드가 없는 곳(/Matte·/BS·/TI·/W2·/Interpolate)에서는 이미 아는
// 빈틈을 다시 적을 뿐이다. 그래서 여기서는 엔진이 실제로 보는 것만 겨눈다:
//
//   /CalRGB·/CalGray   색공간 훑기와 셰이딩 양쪽에서 본다
//   CCITT /K>0·/K<0    2차원 부호. 견본은 /K -1 하나뿐이었다
//   /BlackIs1          코드는 있고 견본이 없었다
//   /EncodedByteAlign  줄마다 바이트 경계를 맞추는 꼴
//   16비트 그림        견본 하나뿐이었다
//
// CCITT 자료는 libtiff 로 만든다(ppm2tiff → tiffcp -c g3/g4). 스트립을
// 그대로 꺼내 쓰므로 손으로 부호를 짤 필요가 없다.
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const OUT = process.argv[2] ?? "tests/fixtures";
const TMP = process.argv[3] ?? fs.mkdtempSync("/tmp/ccitt-");

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
function page(name, content, { w = 200, h = 200, res = "", extra = [] } = {}) {
  fs.writeFileSync(`${OUT}/${name}`, build([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << ${res} >> /Contents 4 0 R >>`,
    stream("", content),
    ...extra,
  ]));
}

// ── CCITT 자료를 libtiff 로 만든다
const W = 32, H = 32;
function makePbm() {
  const rows = [];
  for (let y = 0; y < H; y++) {
    const r = [];
    for (let x = 0; x < W; x++) r.push(((x >> 2) + (y >> 2)) % 2 === 0 || x === y ? 1 : 0);
    rows.push(r);
  }
  const out = [Buffer.from(`P4\n${W} ${H}\n`, "latin1")];
  for (const r of rows) {
    const line = Buffer.alloc(W / 8);
    for (let b = 0; b < W / 8; b++) {
      let v = 0;
      for (let k = 0; k < 8; k++) v = (v << 1) | r[b * 8 + k];
      line[b] = v;
    }
    out.push(line);
  }
  return Buffer.concat(out);
}
/** TIFF 의 첫 스트립을 꺼낸다 (한 스트립으로 굽는다) */
function stripOf(tif) {
  const d = fs.readFileSync(tif);
  const le = d.readUInt16LE(0) === 0x4949;
  const u16 = (o) => le ? d.readUInt16LE(o) : d.readUInt16BE(o);
  const u32 = (o) => le ? d.readUInt32LE(o) : d.readUInt32BE(o);
  let ifd = u32(4);
  const n = u16(ifd);
  let so = 0, sc = 0;
  for (let i = 0; i < n; i++) {
    const e = ifd + 2 + i * 12;
    const tag = u16(e), cnt = u32(e + 4), val = u32(e + 8);
    if (tag === 273) so = cnt === 1 ? val : u32(val);
    if (tag === 279) sc = cnt === 1 ? val : u32(val);
  }
  return d.subarray(so, so + sc);
}
fs.writeFileSync(`${TMP}/pat.pbm`, makePbm());
execFileSync("ppm2tiff", [`${TMP}/pat.pbm`, `${TMP}/pat.tif`]);
const kinds = { "g3": -0, "g3:2d": 4, "g4": -1 };
const data = {};
for (const [mode, k] of Object.entries(kinds)) {
  const f = `${TMP}/cc-${mode.replace(":", "_")}.tif`;
  execFileSync("tiffcp", ["-c", mode, "-r", String(H), `${TMP}/pat.tif`, f]);
  data[mode] = { k, bytes: stripOf(f) };
}

// ① CCITT — 1차원(K 0)·2차원(K 4)·G4(K -1) 를 나란히
{
  let c = "", res = [], extra = [], i = 0;
  for (const [mode, o] of Object.entries(data)) {
    const nm = `I${i}`;
    c += `q 55 0 0 55 ${10 + i * 62} 110 cm /${nm} Do Q\n`;
    res.push(`/${nm} ${5 + i} 0 R`);
    extra.push(stream(
      `/Type /XObject /Subtype /Image /Width ${W} /Height ${H} /ImageMask true` +
      ` /BitsPerComponent 1 /Filter /CCITTFaxDecode` +
      ` /DecodeParms << /K ${o.k} /Columns ${W} /Rows ${H} /BlackIs1 true >>`, o.bytes));
    i++;
  }
  page("v-ccitt-k.pdf", c, { res: `/XObject << ${res.join(" ")} >>`, extra });
}
// ② /BlackIs1 켠 것과 끈 것
{
  const o = data["g4"];
  page("v-ccitt-black.pdf",
    "q 70 0 0 70 15 110 cm /A Do Q\nq 70 0 0 70 105 110 cm /B Do Q\n",
    { res: "/XObject << /A 5 0 R /B 6 0 R >>",
      extra: [
        stream(`/Type /XObject /Subtype /Image /Width ${W} /Height ${H} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns ${W} /Rows ${H} /BlackIs1 true >>`, o.bytes),
        stream(`/Type /XObject /Subtype /Image /Width ${W} /Height ${H} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns ${W} /Rows ${H} >>`, o.bytes)] });
}
// ③ /CalRGB·/CalGray — 색 채우기와 셰이딩 양쪽
page("v-cal.pdf",
  "/CsR cs 0.9 0.2 0.1 sc 10 150 80 40 re f\n" +
  "/CsG cs 0.35 sc 110 150 80 40 re f\n" +
  "q 10 30 180 100 re W n /Sh1 sh Q\n",
  { res: "/ColorSpace << /CsR [/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2.2 2.2 2.2] >>]" +
      " /CsG [/CalGray << /WhitePoint [0.9505 1 1.089] /Gamma 2.2 >>] >> /Shading << /Sh1 5 0 R >>",
    extra: ["<< /ShadingType 2 /ColorSpace [/CalRGB << /WhitePoint [0.9505 1 1.089] >>] /Coords [10 0 190 0] /Extend [true true] /Function 6 0 R >>",
      "<< /FunctionType 2 /Domain [0 1] /C0 [0.1 0.7 0.2] /C1 [0.8 0.2 0.7] /N 1 >>"] });
// ④ 16비트 그림 — 회색과 RGB
{
  const w = 4, h = 4;
  const g16 = Buffer.alloc(w * h * 2);
  for (let i = 0; i < w * h; i++) g16.writeUInt16BE(Math.round(i * 65535 / (w * h - 1)), i * 2);
  const rgb16 = Buffer.alloc(w * h * 3 * 2);
  for (let i = 0; i < w * h; i++) {
    rgb16.writeUInt16BE(Math.round(i * 65535 / (w * h - 1)), i * 6);
    rgb16.writeUInt16BE(65535 - Math.round(i * 65535 / (w * h - 1)), i * 6 + 2);
    rgb16.writeUInt16BE(30000, i * 6 + 4);
  }
  page("v-bpc16.pdf", "q 80 0 0 80 15 100 cm /A Do Q\nq 80 0 0 80 105 100 cm /B Do Q\n",
    { res: "/XObject << /A 5 0 R /B 6 0 R >>",
      extra: [stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceGray /BitsPerComponent 16`, g16),
        stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceRGB /BitsPerComponent 16`, rgb16)] });
}
// ⑤ /EncodedByteAlign — 줄마다 바이트 경계를 맞춘 꼴
{
  const f = `${TMP}/cc-align.tif`;
  execFileSync("tiffcp", ["-c", "g3", "-r", String(H), `${TMP}/pat.tif`, f]);
  page("v-ccitt-align.pdf", "q 120 0 0 120 40 40 cm /A Do Q\n",
    { res: "/XObject << /A 5 0 R >>",
      extra: [stream(`/Type /XObject /Subtype /Image /Width ${W} /Height ${H} /ImageMask true /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K 0 /Columns ${W} /Rows ${H} /EncodedByteAlign false /BlackIs1 true >>`, stripOf(f))] });
}
console.log("v-ccitt-k·v-ccitt-black·v-cal·v-bpc16·v-ccitt-align 만듦");
