// 견본마다 뽑아낸 값을 기준과 맞댄다.
//
//   node tests/snap.mjs [fixtures]
//   node tests/snap.mjs [fixtures] --update    ← 일부러 바꿨을 때
//
// A/B(tests/ab.mjs)는 wasm 두 개를 맞댄다. 그래서 기준 wasm 이 있어야 하고,
// 상시 시험에는 못 넣어 손으로만 돌렸다 — 그 사이 run.sh 는 값이 바뀌어도
// 통과했다. 글자 이동량을 1.05배로 고장 내도 안 걸린 것이 그 때문이다.
//
// 여기서는 기준을 *파일*에 둔다. 추출 정의는 A/B 와 같은 것(snapshot.mjs)을
// 쓴다 — 베끼면 한쪽만 고쳐져 어긋난다.
//
// 이것은 일부러 변경 감지기다. 값을 바꾸는 수정을 했다면 --update 로 기준을
// 옮기고, 그 diff 가 곧 "무엇이 달라졌는가" 의 기록이 된다.
import fs from 'node:fs';
import crypto from 'node:crypto';
import { snap } from './snapshot.mjs';

const args = process.argv.slice(2);
const S = args.find((a) => !a.startsWith('--')) ?? 'tests/fixtures';
const UPDATE = args.includes('--update');
const BASE = 'tests/snap-baseline.json';
const MIN_DOCS = 140;

const mod = await WebAssembly.compile(fs.readFileSync('dist/pdf.wasm'));
const files = fs.readdirSync(S).filter((f) => f.endsWith('.pdf')).sort();

/** 손자국 — 전체 해시와, 실패했을 때 눈으로 볼 몇 가지 */
function print(text) {
  const num = (k) => {
    const m = new RegExp(`(?:^|\\n)${k}=([^\\n]*)`).exec(text);
    return m ? m[1].slice(0, 24) : '';
  };
  return {
    h: crypto.createHash('sha256').update(text).digest('hex').slice(0, 16),
    쪽: num('쪽'), 글자: num('p0글자'), 명령: num('p0명령'), 그림: num('p0그림'),
  };
}

const now = {};
for (const f of files) {
  let t;
  try { t = await snap(mod, f, S); } catch (e) { t = `던짐: ${e.message}`; }
  now[f] = print(t);
}

let pass = 0, fail = 0;
const bad = [];
const ok = (name, cond, got) => { if (cond) { pass++; return; } fail++; bad.push(`${name}${got !== undefined ? ` (${got})` : ''}`); };

// 견본이 조용히 줄면 "다름 0" 으로 통과한다 — 성공의 증거를 요구한다.
ok(`견본이 ${MIN_DOCS}개는 돈다`, files.length >= MIN_DOCS, `${files.length}개`);

const old = fs.existsSync(BASE) ? JSON.parse(fs.readFileSync(BASE, 'utf8')) : null;
if (UPDATE || !old) {
  fs.writeFileSync(BASE, JSON.stringify(now, null, 1) + '\n');
  console.log(`  손자국 견본 ${files.length}개 · 기준을 ${old ? '갱신' : '처음 기록'}했다`);
} else {
  for (const f of files) {
    const a = now[f], b = old[f];
    if (!b) { ok(`${f}: 기준에 있다`, false, '새 견본 — --update 로 넣는다'); continue; }
    ok(`${f}`, a.h === b.h,
      a.h === b.h ? undefined
        : `쪽 ${b.쪽}→${a.쪽} · 글자 ${b.글자}→${a.글자} · 명령 ${b.명령}→${a.명령} · 그림 ${b.그림}→${a.그림}`);
  }
  for (const f of Object.keys(old)) if (!files.includes(f)) ok(`${f}: 견본이 사라졌다`, false);
}
console.log(`  손자국 ${pass + fail}개 중 통과 ${pass}, 실패 ${fail}`);
if (bad.length) {
  bad.slice(0, 12).forEach((b) => console.log('    ✗ ' + b));
  console.log('    일부러 바꾼 것이라면: node tests/snap.mjs tests/fixtures --update');
}
process.exit(fail ? 1 : 0);
