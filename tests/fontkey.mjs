// 글꼴 캐시 열쇠가 바이트를 다 보는지.
//
//   node tests/fontkey.mjs
//
// 예전 열쇠는 512바이트만 골라 봤다. 50KB 글꼴이면 99%를 안 보는 셈이라
// 길이가 같고 표본 밖만 다른 글꼴이 같은 열쇠가 됐다. 이 캐시는 모듈
// 수준이라 문서를 넘나든다 — 스텐실 캐시에서 실제로 겪은 그 사고다.
import { fontKey } from "../dist/bytes.js";

let pass = 0, fail = 0;
const ok = (name, cond, got) => {
  if (cond) { pass++; return; }
  fail++; console.log(`  실패 ${name}${got !== undefined ? ` (실제: ${got})` : ""}`);
};

const make = (n, seed = 97) => {
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = (i * seed) & 255;
  return b;
};

// ① 같은 바이트면 같은 열쇠
{
  const a = make(50000), b = make(50000);
  ok("같은 바이트는 같은 열쇠", fontKey(a) === fontKey(b), fontKey(a));
}

// ② 한 바이트만 달라도 열쇠가 다르다 — 자리를 가리지 않고
{
  const a = make(50000);
  let same = 0;
  const spots = [0, 1, 7, 96, 97, 98, 12345, 49998, 49999];
  for (const i of spots) {
    const b = a.slice(); b[i] ^= 0xff;
    if (fontKey(a) === fontKey(b)) same++;
  }
  ok("한 바이트만 달라도 열쇠가 다르다", same === 0, `${same}/${spots.length} 자리가 같은 열쇠`);
}

// ③ 길이가 다르면 열쇠가 다르다
{
  ok("길이가 다르면 다른 열쇠", fontKey(make(1000)) !== fontKey(make(1001)));
}

// ④ 4바이트 배수가 아닌 길이도 꼬리까지 본다
{
  const a = make(1003);
  const b = a.slice(); b[1002] ^= 0xff;
  ok("4의 배수가 아닌 꼬리도 본다", fontKey(a) !== fontKey(b));
}

// ⑤ 큰 글꼴도 제때 끝난다 (CJK 부분집합은 5MB 까지 간다)
{
  const big = make(5 * 1024 * 1024);
  const t = process.hrtime.bigint();
  fontKey(big);
  const ms = Number(process.hrtime.bigint() - t) / 1e6;
  ok("5MB 글꼴 열쇠가 50ms 안에 끝난다", ms < 50, `${ms.toFixed(1)}ms`);
}

console.log(`  글꼴 열쇠 ${pass + fail}개 중 통과 ${pass}, 실패 ${fail}`);
process.exit(fail ? 1 : 0);
