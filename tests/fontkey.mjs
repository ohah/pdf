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
  // 벽시계가 아니라 CPU 시간으로 잰다.
  //
  // 기계가 바쁘면 벽시계는 튄다 — 검증 한 바퀴에서 170.3ms 가 찍혀 걸렸는데
  // 홀로 재면 3ms 다(기준의 16분의 1). 일부러 부하를 걸어도(load 16) 벽시계는
  // 2.3~3.4ms 라 그 170ms 를 재현하지는 못했다. 브라우저와 vite 까지 함께
  // 도는 자리라 더 심했던 것으로 보이나 원인을 확정하지는 못했다.
  //
  // 원인과 무관하게 CPU 시간이 훨씬 덜 흔들린다(부하에서 3.2 → 4.7ms).
  // 여기서 보려는 것은 "덩치를 따라 선형인가" 이지 "이 기계가 지금 한가한가"가
  // 아니다.
  const big = make(5 * 1024 * 1024);
  const c0 = process.cpuUsage();
  fontKey(big);
  const c = process.cpuUsage(c0);
  const ms = (c.user + c.system) / 1000;
  ok("5MB 글꼴 열쇠가 CPU 50ms 안에 끝난다", ms < 50, `${ms.toFixed(1)}ms`);
}

console.log(`  글꼴 열쇠 ${pass + fail}개 중 통과 ${pass}, 실패 ${fail}`);
process.exit(fail ? 1 : 0);
