// 같은 엔진에 문서를 거듭 열어, 잡아 둔 메모리가 계속 자라지 않는지 본다.
//
//   node tests/mem-check.mjs [fixtures]
//
// 곳간(그림·글꼴·인라인·폼·Type1)은 처음 쓸 때 잡고 그 뒤로는 다시 쓴다.
// 다시 쓰지 않으면 문서를 열 때마다 새로 잡아 메모리가 계단처럼 오른다.
//
// RSS 로는 안 보인다 — 잡아만 두고 안 건드린 쪽은 실제 메모리를 안 쓰기
// 때문이다. 재 보니 곳간 재사용을 없앤 판에서 RSS(again)는 7.2 → 8.9MB 로
// 거의 그대로인데, 잡아 둔 선형 메모리는 57 → 105MB 로 뛰었다. 그래서
// 이쪽을 본다.
//
// 절대값에 문턱을 두지 않는다 — 문서마다 정당하게 다르다(scan4 는 큰
// JPX 라 57MB 를 쓴다). 대신 "두 번째 뒤로는 안 자란다" 를 본다.
import fs from "node:fs";

const FX = (process.argv[2] ?? "tests/fixtures").replace(/\/$/, "");
const wasm = fs.readFileSync("dist/pdf.wasm");
// 글자·명령·큰 그림·구조 — 갈래를 갈라 고른다
const DOCS = ["korean.pdf", "dense.pdf", "scan4.pdf", "many-outline.pdf", "jpx-mct.pdf"];
const ROUNDS = 5;

let ok = 0, bad = 0;
const t = (name, cond, got) => {
  if (cond) ok++;
  else { bad++; console.log(`    ✗ ${name}${got === undefined ? "" : ` (실제: ${got})`}`); }
};

for (const f of DOCS) {
  if (!fs.existsSync(`${FX}/${f}`)) continue;
  const buf = fs.readFileSync(`${FX}/${f}`);
  const m = await WebAssembly.instantiate(wasm, {
    wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const sizes = [];
  for (let r = 0; r < ROUNDS; r++) {
    if (!ex.reserve(buf.length, buf.length * 2 + 65536)) break;
    new Uint8Array(ex.memory.buffer, ex.inputPtr(), buf.length).set(buf);
    if (!ex.parse(buf.length)) break;
    for (let i = 0; i < Math.min(ex.pageCount(), 3); i++) ex.renderPage(i);
    sizes.push(ex.memory.buffer.byteLength / 1048576);
  }
  if (sizes.length < ROUNDS) { t(`${f} 를 ${ROUNDS}번 열 수 있다`, false, sizes.length); continue; }
  // 첫 번째는 곳간을 잡느라 자란다. 두 번째부터는 그대로여야 한다.
  const settled = sizes[1];
  const grew = sizes.slice(2).some((v) => v > settled + 0.01);
  t(`${f}: 거듭 열어도 안 자란다`, !grew, sizes.map((v) => v.toFixed(0)).join("→") + "MB");
}

// 잴 것이 없는데 통과로 치면 안 된다.
t("견본을 실제로 쟀다", ok + bad >= 5, ok + bad);
console.log(`  메모리 ${ok + bad}개 중 통과 ${ok}, 실패 ${bad}`);
process.exit(bad ? 1 : 0);
