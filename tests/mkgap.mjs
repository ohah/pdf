// 아직 없는 기능을 못 박는 견본.
//
//   node tests/mkgap.mjs tests/fixtures
//
// 앞의 세 묶음과 성격이 다르다. 저기는 "poppler·pdf.js 와 화소가 같아야
// 한다"를 단언한다. 여기는 그럴 수 없다 — 아직 안 만든 기능이라 첫날부터
// 빨간불이 되고, 그러면 신호가 무뎌진다(scan4 기대치가 낡아 여섯 달 동안
// 낡은 dist 덕에 통과하다 터진 일이 있다).
//
// 그래서 여기서는 셋만 단언한다: 안 죽는다 · 결과가 흔들리지 않는다 ·
// 지금 무엇을 하는지 기록한다. 뒤의 것은 일부러 변경 감지기다.
//
// 왜 미리 만드나. 산문으로 적은 "우리는 X를 안 한다"는 썩는다 — pdfjbig2
// 머리 주석이 "세밀화·하프톤·허프만 사전은 안 다룬다" 고 적어 둔 채로
// 셋 다 구현돼 있었다. 실행되는 견본은 안 썩고, 누가 그 기능을 넣는 날
// 계약서가 이미 있다.
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
function page(name, content, { w = 200, h = 200, res = "", extra = [], annots = "", cat = "" } = {}) {
  fs.writeFileSync(`${OUT}/${name}`, build([
    `<< /Type /Catalog /Pages 2 0 R${cat} >>`,
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << ${res} >>${annots} /Contents 4 0 R >>`,
    stream("", content),
    ...extra,
  ]));
}

// ① /BS — 입력칸 테두리 굵기·모양 (파선·밑줄·도드라짐)
{
  const mk = (n, y, s, wdt) =>
    `<< /Type /Annot /Subtype /Widget /FT /Tx /T (t${n}) /Rect [20 ${y} 180 ${y + 28}] /F 4` +
    ` /BS << /W ${wdt} /S /${s}${s === "D" ? " /D [3 2]" : ""} >>` +
    ` /MK << /BC [0 0 0] /BG [0.95 0.95 0.95] >> /DA (0 g /Helv 10 Tf) >>`;
  page("g-bs.pdf", "0.98 0.98 0.98 rg 0 0 200 200 re f\n",
    { annots: " /Annots [5 0 R 6 0 R 7 0 R 8 0 R]",
      // 입력칸은 /AcroForm /Fields 에 들어 있어야 양식이다. 빼면 뷰어가
      // 그냥 주석으로 본다 — 겨누려던 길을 안 밟는다.
      cat: " /AcroForm << /Fields [5 0 R 6 0 R 7 0 R 8 0 R] /DA (0 g /Helv 10 Tf) >>",
      extra: [mk(0, 160, "S", 1), mk(1, 120, "D", 2), mk(2, 80, "U", 3), mk(3, 40, "B", 2)] });
}
// ② /TI — 리스트박스가 몇 번째 줄부터 보이나
page("g-ti.pdf", "0.98 0.98 0.98 rg 0 0 200 200 re f\n",
  { annots: " /Annots [5 0 R]",
    cat: " /AcroForm << /Fields [5 0 R] /DA (0 g /Helv 10 Tf) >>",
    extra: ["<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 0 /T (list) /Rect [20 40 180 160] /F 4" +
      " /Opt [(하나) (둘) (셋) (넷) (다섯) (여섯)] /TI 3 /I [3] /V (넷)" +
      " /MK << /BC [0 0 0] /BG [1 1 1] >> /DA (0 g /Helv 10 Tf) >>"] });
// ③ /W2 · /DW2 — 세로쓰기의 세로 이동량
{
  const cid = "<< /Type /Font /Subtype /Type0 /BaseFont /KoPubBatang-V /Encoding /Identity-V" +
    " /DescendantFonts [6 0 R] >>";
  const desc = "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /KoPubBatang" +
    " /CIDSystemInfo << /Registry (Adobe) /Ordering (Korea1) /Supplement 2 >>" +
    " /FontDescriptor 7 0 R /DW 1000 /DW2 [880 -1000] /W2 [1 [-500 500 -880] 2 [-300 300 -600]] >>";
  const fd = "<< /Type /FontDescriptor /FontName /KoPubBatang /Flags 4 /ItalicAngle 0" +
    " /Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 /FontBBox [-100 -200 1000 900] >>";
  page("g-vert-w2.pdf",
    "BT /F1 24 Tf 100 170 Td <0001000200010002> Tj ET\n0 0 0 rg 10 10 20 20 re f\n",
    { res: "/Font << /F1 5 0 R >>", extra: [cid, desc, fd] });
}
// ④ /Matte — 부드러운 가리개의 프리멀티플라이 바탕색
{
  const w = 4, h = 4;
  const a = Buffer.from([0, 80, 160, 255, 80, 160, 255, 0, 160, 255, 0, 80, 255, 0, 80, 160]);
  // /Matte 는 "이 색으로 미리 곱해 두었다" 는 뜻이다 (8.9.6.4). 그냥
  // /Matte 만 적고 원본 색을 두면 규격에 안 맞는 파일이 된다 — 그러면
  // 차이가 우리 결함인지 견본 결함인지 못 가른다.
  //   저장값 c' = m + a·(c − m),  바탕 m = [0.95 0.85 0.2]
  const matte = [0.95, 0.85, 0.2];
  const base = [40 / 255, 120 / 255, 220 / 255];
  const rgb = Buffer.alloc(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    const al = a[i] / 255;
    for (let k = 0; k < 3; k++) {
      const v = matte[k] + al * (base[k] - matte[k]);
      rgb[i * 3 + k] = Math.max(0, Math.min(255, Math.round(v * 255)));
    }
  }
  page("g-matte.pdf", "0.95 0.85 0.2 rg 0 0 200 200 re f\nq 120 0 0 120 40 40 cm /I Do Q\n",
    { res: "/XObject << /I 5 0 R >>",
      extra: [stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 6 0 R`, rgb),
        stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [0.95 0.85 0.2]`, a)] });
}
// ⑤ /Interpolate — 키워 그릴 때 부드럽게 하라는 표시
{
  const w = 4, h = 4;
  const g = Buffer.alloc(w * h);
  for (let i = 0; i < w * h; i++) g[i] = (i * 17) & 255;
  page("g-interp.pdf", "q 80 0 0 80 15 100 cm /A Do Q\nq 80 0 0 80 105 100 cm /B Do Q\n",
    { res: "/XObject << /A 5 0 R /B 6 0 R >>",
      extra: [stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Interpolate true`, g),
        stream(`/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Interpolate false`, g)] });
}
// 선형화(/Linearized)는 만들지 않는다.
//
// 규격에 맞는 선형화 파일은 첫 쪽 객체를 앞으로 모으고, 힌트 스트림(/H)과
// 첫 쪽 전용 상호참조표를 두고, /L·/O·/E·/T 가 실제 자리와 맞아야 한다.
// 그 값을 지어내면 "선형화된 파일" 이 아니라 "거짓말하는 딕셔너리" 를
// 시험하는 꼴이 된다 — 차이가 나도 우리 탓인지 견본 탓인지 못 가른다.
// 우리 엔진은 파일 전체를 훑으므로 선형화를 안 봐도 되고, 필요해지면
// 그때 제대로 만든다.

// ⑦ 라디오 그룹 — /Kids 가 값을 나눠 갖는 꼴
page("g-radio.pdf", "0.98 0.98 0.98 rg 0 0 200 200 re f\n",
  { annots: " /Annots [6 0 R 7 0 R]",
    cat: " /AcroForm << /Fields [5 0 R] /DA (0 g /Helv 10 Tf) >>",
    extra: [
      "<< /FT /Btn /Ff 49152 /T (pick) /V /a /Kids [6 0 R 7 0 R] >>",
      "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [30 120 60 150] /F 4 /AS /a" +
      " /AP << /N << /a 8 0 R /Off 9 0 R >> >> /MK << /BC [0 0 0] >> >>",
      "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [110 120 140 150] /F 4 /AS /Off" +
      " /AP << /N << /b 8 0 R /Off 9 0 R >> >> /MK << /BC [0 0 0] >> >>",
      stream("/Type /XObject /Subtype /Form /BBox [0 0 30 30]", "0 0 0 rg 8 8 14 14 re f 0 0 0 RG 1 w 0.5 0.5 29 29 re S"),
      stream("/Type /XObject /Subtype /Form /BBox [0 0 30 30]", "0 0 0 RG 1 w 0.5 0.5 29 29 re S")] });

console.log("g-bs·g-ti·g-vert-w2·g-matte·g-interp·g-radio 만듦");
