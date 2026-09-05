// 두 번째 묶음 — 첫 묶음(mkfeat.mjs)이 안 건드린 자리.
//
//   node tests/mkfeat2.mjs tests/fixtures
//
// 겨눈 곳: 그림자 2·3형의 /Extend, 주석 겉모습 상태(/AS), 쪽 회전 180·270,
// 객체 스트림(/ObjStm)과 xref 스트림, 증분 갱신에서 지운 객체, 인라인 그림의
// 줄임 이름, /Mask 로 다른 그림 가리기, CCITT 2차원(K>0), /MissingWidth.
import fs from "node:fs";
import zlib from "node:zlib";

const OUT = process.argv[2] ?? "tests/fixtures";

function build(objs, extraTrailer = "") {
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
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R${extraTrailer} >>\nstartxref\n${len}\n%%EOF\n`;
  parts.push(Buffer.from(x, "latin1"));
  return Buffer.concat(parts);
}
const stream = (dict, data) => Buffer.concat([
  Buffer.from(`<< ${dict} /Length ${data.length} >>\nstream\n`, "latin1"),
  Buffer.isBuffer(data) ? data : Buffer.from(data, "latin1"),
  Buffer.from("\nendstream", "latin1")]);
function page(name, content, { w = 200, h = 200, res = "", extra = [], rotate = 0, annots = "" } = {}) {
  fs.writeFileSync(`${OUT}/${name}`, build([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}]${rotate ? ` /Rotate ${rotate}` : ""} /Resources << ${res} >>${annots} /Contents 4 0 R >>`,
    stream("", content),
    ...extra,
  ]));
}

// ① 그림자 2형(축) — /Extend 켠 것과 끈 것
page("u-axial.pdf",
  "q 20 150 160 40 re W n /Sh1 sh Q\nq 20 90 160 40 re W n /Sh2 sh Q\n" +
  "0 0 0 rg 20 20 40 40 re f\n",
  { res: "/Shading << /Sh1 5 0 R /Sh2 6 0 R >>",
    extra: [
      "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [60 0 140 0] /Extend [true true] /Function 7 0 R >>",
      "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [60 0 140 0] /Extend [false false] /Function 7 0 R >>",
      "<< /FunctionType 2 /Domain [0 1] /C0 [0.9 0.1 0.1] /C1 [0.1 0.1 0.9] /N 1 >>"] });
// ② 그림자 3형(원) — /Extend
page("u-radial.pdf",
  "q 10 10 180 180 re W n /Sh1 sh Q\n",
  { res: "/Shading << /Sh1 5 0 R >>",
    extra: ["<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [100 100 5 100 100 80] /Extend [true true] /Function 6 0 R >>",
      "<< /FunctionType 2 /Domain [0 1] /C0 [1 1 0.2] /C1 [0.2 0.2 0.8] /N 1 >>"] });
// ③ 주석 겉모습 상태 /AS — 켠 체크박스와 끈 체크박스
page("u-apstate.pdf", "0.9 0.9 0.9 rg 0 0 200 200 re f\n",
  { annots: " /Annots [5 0 R 6 0 R]",
    extra: [
      "<< /Type /Annot /Subtype /Widget /FT /Btn /T (on) /Rect [30 120 70 160] /F 4 /AS /Yes /AP << /N << /Yes 7 0 R /Off 8 0 R >> >> >>",
      "<< /Type /Annot /Subtype /Widget /FT /Btn /T (off) /Rect [110 120 150 160] /F 4 /AS /Off /AP << /N << /Yes 7 0 R /Off 8 0 R >> >> >>",
      stream("/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0.1 0.6 0.1 rg 0 0 40 40 re f 0 0 0 RG 3 w 8 20 m 18 10 l 32 30 l S"),
      stream("/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "1 1 1 rg 0 0 40 40 re f 0 0 0 RG 1 w 0.5 0.5 39 39 re S")] });
// ④ 쪽 회전 180 과 270
for (const r of [180, 270]) {
  page(`u-rot${r}.pdf`, "BT /F1 20 Tf 15 100 Td (R" + r + ") Tj ET\n0.8 0.2 0.2 rg 15 20 50 25 re f\n",
    { w: 160, h: 220, rotate: r, res: "/Font << /F1 5 0 R >>",
      extra: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"] });
}
// ⑤ 객체 스트림(/ObjStm) + xref 스트림
{
  const inner = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>",
  ];
  let hdr = "", body = "";
  inner.forEach((o, i) => { hdr += `${i + 1} ${body.length} `; body += o + "\n"; });
  const objstm = Buffer.from(hdr + body, "latin1");
  const packed = zlib.deflateSync(objstm);
  const content = "BT /F1 22 Tf 20 100 Td (ObjStm) Tj ET";
  const parts = [Buffer.from("%PDF-1.7\n", "latin1")];
  let len = parts[0].length;
  const off = {};
  const put = (num, buf) => { off[num] = len; const h = Buffer.from(`${num} 0 obj\n`, "latin1");
    const t = Buffer.from("\nendobj\n", "latin1"); parts.push(h, buf, t); len += h.length + buf.length + t.length; };
  put(4, stream("", content));
  put(5, Buffer.concat([Buffer.from(`<< /Type /ObjStm /N ${inner.length} /First ${hdr.length} /Filter /FlateDecode /Length ${packed.length} >>\nstream\n`, "latin1"), packed, Buffer.from("\nendstream", "latin1")]));
  put(6, Buffer.from("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "latin1"));
  // xref 스트림 (7번) — W [1 4 2]
  const xrefAt = len;
  const rows = [];
  const row = (t, a, b2) => { const r = Buffer.alloc(7); r[0] = t; r.writeUInt32BE(a, 1); r.writeUInt16BE(b2, 5); rows.push(r); };
  row(0, 0, 65535);
  for (let i = 1; i <= 3; i++) row(2, 5, i - 1);   // ObjStm 안 i 번째
  row(1, off[4], 0); row(1, off[5], 0); row(1, off[6], 0); row(1, xrefAt, 0);
  const xdata = zlib.deflateSync(Buffer.concat(rows));
  const xdict = `<< /Type /XRef /Size 8 /W [1 4 2] /Root 1 0 R /Filter /FlateDecode /Length ${xdata.length} >>`;
  parts.push(Buffer.from(`7 0 obj\n${xdict}\nstream\n`, "latin1"), xdata,
    Buffer.from(`\nendstream\nendobj\nstartxref\n${xrefAt}\n%%EOF\n`, "latin1"));
  fs.writeFileSync(`${OUT}/u-objstm.pdf`, Buffer.concat(parts));
}
// ⑥ 인라인 그림 — 줄임 이름(/W /H /BPC /CS /F)과 줄임 필터(/AHx)
page("u-inline.pdf",
  "q 80 0 0 80 20 100 cm BI /W 4 /H 4 /BPC 8 /CS /G /F /AHx ID\n" +
  "00405f8f a0bfd0ff 1f3f5f7f 8f9fafbf>\nEI Q\n" +
  "q 60 0 0 60 120 100 cm BI /W 2 /H 2 /BPC 8 /CS /RGB ID \xff\x00\x00\x00\xff\x00\x00\x00\xff\xff\xff\x00\nEI Q\n");
// ⑦ /Mask 로 다른 그림을 가리기 (스텐실 마스크 참조)
{
  const w = 4, h = 4;
  const rgb = Buffer.alloc(w * h * 3);
  for (let i = 0; i < w * h; i++) { rgb[i * 3] = 220; rgb[i * 3 + 1] = 40; rgb[i * 3 + 2] = 40; }
  const mask = Buffer.from([0b10010000, 0b01100000, 0b01100000, 0b10010000]); // 4x4 1비트
  page("u-mask.pdf", "0 0 0.8 rg 0 0 200 200 re f\nq 120 0 0 120 40 40 cm /I Do Q\n",
    { res: "/XObject << /I 5 0 R >>",
      extra: [stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Mask 6 0 R`, rgb),
        stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ImageMask true /BitsPerComponent 1 /Decode [0 1]`, mask)] });
}
// ⑧ /MissingWidth — /Widths 에 없는 글자
page("u-misswidth.pdf",
  "BT /F1 18 Tf 12 150 Td (AB AB AB) Tj ET\nBT /F1 18 Tf 12 110 Td (\\210\\211\\212) Tj ET\n",
  { res: "/Font << /F1 5 0 R >>",
    extra: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 65 /LastChar 66 /Widths [700 700] /FontDescriptor 6 0 R >>",
      "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /MissingWidth 500 /ItalicAngle 0 /Ascent 718 /Descent -207 /CapHeight 718 /StemV 88 /FontBBox [-166 -225 1000 931] >>"] });

console.log("u-axial·u-radial·u-apstate·u-rot180·u-rot270·u-objstm·u-inline·u-mask·u-misswidth 만듦");
