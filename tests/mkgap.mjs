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

// /BS 는 만들어졌다 — tests/mkform.mjs 의 bs.pdf 와 verify.mjs 로 갔다.
// /TI 는 만들어졌다 — tests/mkform.mjs 의 list.pdf 와 verify.mjs·앱 시험으로 갔다.
// /W2·/DW2 세로쓰기는 만들어졌다 — tests/mkfeat3.mjs 의 v-vert-w2·v-vert-dw2 와 verify.mjs 로 갔다.
// /Matte·/Interpolate 는 만들어졌다 — tests/mkfeat3.mjs 의 v-matte·v-interp 와 node.mjs 로 갔다.

// 선형화(/Linearized)는 만들지 않는다.
//
// 규격에 맞는 선형화 파일은 첫 쪽 객체를 앞으로 모으고, 힌트 스트림(/H)과
// 첫 쪽 전용 상호참조표를 두고, /L·/O·/E·/T 가 실제 자리와 맞아야 한다.
// 그 값을 지어내면 "선형화된 파일" 이 아니라 "거짓말하는 딕셔너리" 를
// 시험하는 꼴이 된다 — 차이가 나도 우리 탓인지 견본 탓인지 못 가른다.
// 우리 엔진은 파일 전체를 훑으므로 선형화를 안 봐도 되고, 필요해지면
// 그때 제대로 만든다.

// 라디오 묶음은 만들어졌다 — tests/mkform.mjs 의 radio.pdf 와 verify.mjs 로 갔다.

console.log("지금은 빈틈 견본이 없다 — 새 빈틈이 생기면 여기에 만든다");
