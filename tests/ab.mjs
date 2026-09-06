// 고치기 전 wasm 과 고친 wasm 이 같은 답을 내는지 하나하나 맞댄다.
//
//   git stash && npm run build:wasm && cp dist/pdf.wasm /tmp/base.wasm
//   git stash pop && npm run build:wasm
//   node tests/ab.mjs /tmp/base.wasm dist/pdf.wasm [fixtures]
//
// 빠르게 하려고 안을 뜯어고칠 때 쓴다. "결과가 같다" 는 주장이 아니라
// 확인이어야 한다 — 견본마다 내보내는 값을 전부 꺼내 글자 하나까지 맞댄다.
// 쪽 수·글자·덩이 자리·그린 명령·글꼴·입력칸·링크·주석·목차·정보·라벨·
// 목적지·구조·서명·권한까지 본다.
import fs from 'node:fs';
import { snap } from './snapshot.mjs';

const [baseFile, newFile, dirArg] = process.argv.slice(2);
const S = dirArg ?? 'tests/fixtures';

const mods = {
  base: await WebAssembly.compile(fs.readFileSync(baseFile)),
  now: await WebAssembly.compile(fs.readFileSync(newFile)),
};


const files = fs.readdirSync(S).filter((f) => f.endsWith('.pdf')).sort();
let same = 0;
const diffs = [];
for (const f of files) {
  let a, b;
  try { a = await snap(mods.base, f, S); } catch (e2) { a = `던짐: ${e2.message}`; }
  try { b = await snap(mods.now, f, S); } catch (e2) { b = `던짐: ${e2.message}`; }
  if (a === b) { same++; continue; }
  const la = a.split('\n'), lb = b.split('\n');
  const at = la.findIndex((x, i) => x !== lb[i]);
  diffs.push(`${f}\n    전: ${(la[at] ?? '(없음)').slice(0, 110)}\n    후: ${(lb[at] ?? '(없음)').slice(0, 110)}`);
}
console.log(`A/B  견본 ${files.length}개 중 같음 ${same}, 다름 ${diffs.length}`);
for (const d of diffs.slice(0, 12)) console.log('  ' + d);
process.exit(diffs.length === 0 ? 0 : 1);
