// 아직 없는 기능이 "조용히 달라지지" 않게 못 박는다.
//
//   node tests/gap.mjs [fixtures]
//   node tests/gap.mjs [fixtures] --update      ← 기능을 넣었으면 기준을 갱신
//
// 이것은 *일부러* 변경 감지기다. 앞의 시험들과 성격이 다르다.
//
//   맞아야 하는 것  → poppler·pdf.js 와 화소가 같은지 본다 (verify·node·compare)
//   아직 없는 기능  → 여기. 정답과 맞대면 첫날부터 빨간불이라 신호가 무뎌진다
//                     (scan4 기대치가 낡은 채 여섯 달 통과한 일이 있다).
//
// 그래서 셋만 본다:
//   ① 안 죽는다            — 열리고 그려진다
//   ② 결과가 안 흔들린다    — 두 번 그려 같은 값이 나온다
//   ③ 지금 무엇을 하는가    — 손자국을 기준과 맞댄다
//
// 왜 미리 만드나. 산문으로 적은 "우리는 X 를 안 한다" 는 썩는다 — pdfjbig2
// 머리 주석이 "세밀화·하프톤·허프만 사전은 안 다룬다" 고 적어 둔 채로 셋 다
// 구현돼 있었다. 실행되는 견본은 안 썩고, 누가 그 기능을 넣는 날 계약서가
// 이미 있다.
import fs from 'fs';

const FX = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : 'tests/fixtures';
const UPDATE = process.argv.includes('--update');
const BASE = 'tests/gap-baseline.json';

const wasm = fs.readFileSync('dist/pdf.wasm');
const stub = () => new Proxy({}, { get: () => () => 0 });

/** 한 문서의 손자국 — 쪽 크기·글자·그린 명령·그림·주석·입력칸 수 */
async function print(file) {
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: stub() });
  const ex = m.instance.exports;
  const bytes = fs.readFileSync(`${FX}/${file}`);
  if (!ex.reserve(bytes.length, bytes.length * 3 + 201326592)) return { err: 'no-memory' };
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), bytes.length).set(bytes);
  if (!ex.parse(bytes.length)) return { err: 'no-parse' };
  ex.renderPage(0);
  const dec = new TextDecoder();
  const text = dec.decode(new Uint8Array(ex.memory.buffer, ex.textPtr(), Math.min(ex.textLen(), 400)));
  return {
    pages: ex.pageCount(),
    w: Math.round(ex.pageWidth(0)), h: Math.round(ex.pageHeight(0)),
    items: ex.itemCount(), ops: ex.opsLen(), imgs: ex.imageSlots?.() ?? 0,
    anns: ex.annCount?.() ?? 0, fields: ex.fieldCount?.() ?? 0,
    fonts: ex.fontCount?.() ?? 0,
    text: text.replace(/\s+/g, ' ').trim().slice(0, 60),
  };
}

const files = fs.readdirSync(FX).filter((f) => f.startsWith('g-') && f.endsWith('.pdf')).sort();
const now = {};
let pass = 0, fail = 0;
const bad = [];
const ok = (name, cond, got) => { if (cond) { pass++; return; } fail++; bad.push(`${name}${got !== undefined ? ` (${got})` : ''}`); };

for (const f of files) {
  const a = await print(f);
  ok(`${f}: 열리고 그려진다`, !a.err, a.err);
  if (a.err) { now[f] = a; continue; }
  const b = await print(f);
  ok(`${f}: 두 번 그려 같다`, JSON.stringify(a) === JSON.stringify(b), '두 번이 다르다');
  now[f] = a;
}

const old = fs.existsSync(BASE) ? JSON.parse(fs.readFileSync(BASE, 'utf8')) : null;
if (UPDATE || !old) {
  fs.writeFileSync(BASE, JSON.stringify(now, null, 2) + '\n');
  console.log(`  빈틈 ${files.length}개 · 기준을 ${old ? '갱신' : '처음 기록'}했다`);
} else {
  for (const f of files) {
    const a = JSON.stringify(now[f]), b = JSON.stringify(old[f]);
    ok(`${f}: 동작이 그대로다`, a === b,
      old[f] === undefined ? '기준에 없다 — --update 로 넣는다' : `${b} → ${a}`);
  }
  for (const f of Object.keys(old)) if (!files.includes(f)) ok(`${f}: 견본이 사라졌다`, false);
}
console.log(`  빈틈 ${pass + fail}개 중 통과 ${pass}, 실패 ${fail}`);
if (bad.length) {
  bad.forEach((b) => console.log('    ✗ ' + b));
  console.log('    기능을 넣어 동작이 바뀐 것이라면: node tests/gap.mjs tests/fixtures --update');
}
process.exit(fail ? 1 : 0);
