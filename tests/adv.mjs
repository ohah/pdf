import fs from 'fs';
const wasmBytes = fs.readFileSync('dist/pdf.wasm');

// 느림은 벽시계가 아니라 CPU 시간으로 가른다.
//
// 기계가 바쁘면 견본이 다 같이 느려진다. 검증 한 바퀴에서 3102ms 가 찍혔는데
// 홀로 다섯 번 재니 1547~1606ms 였다 — 기준의 절반이다. 중앙값이 1ms 라 다른
// 견본과의 비율로는 못 가르고, 기준선을 박아 두면 기계가 바뀔 때 낡는다.
//
// 넘으면 한 번 더 재서 작은 쪽을 쓰는 것도 해 봤는데 안 먹혔다. 부하가 계속
// 걸려 있으면 두 번 다 느리다(6607ms → 6103ms, 둘 다 걸림). 잠깐 튄 것만 잡는다.
//
// CPU 시간은 부하를 거의 안 탄다. 재서 확인했다 — load 30 에서 벽시계는
// 1499 → 5982ms(4배)인데 CPU 는 1498 → 1853ms(1.24배)였다.
const LIMIT = Number(process.env.ADV_SLOW_MS || 3000);

async function run(name, bytes, extra, pre) {
  const t0 = Date.now();
  const c0 = process.cpuUsage();
  let note = '';
  try {
    const m = await WebAssembly.instantiate(wasmBytes, {
      wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
    const ex = m.instance.exports;
    if (!ex.reserve(bytes.length, bytes.length * 2 + 65536)) return log(name, t0, c0, '메모리 거절');
    new Uint8Array(ex.memory.buffer, ex.inputPtr(), bytes.length).set(bytes);
    if (!ex.parse(bytes.length)) return log(name, t0, c0, '열지 못함');
    if (pre) pre(ex);
    const n = ex.pageCount();
    let items = 0, ops = 0, fonts = 0, fbytes = 0;
    for (let i = 0; i < Math.min(n, 40); i++) {
      ex.renderPage(i);
      items += ex.itemCount(); ops += ex.opsLen();
      const fc = ex.fontCount(); fonts += fc;
      for (let f = 0; f < fc; f++) {
        const L = ex.fontFileLen(f); fbytes += L;
        if (L) new Uint8Array(ex.memory.buffer, ex.fontAreaPtr() + ex.fontFileOff(f), L)[0];
      }
    }
    note = `쪽${n} 글자${items} 명령${ops} 글꼴${fonts}/${fbytes}B`;
    if (extra) note += ' ' + extra(ex, bytes);
  } catch (e) {
    note = '예외: ' + String(e.message).slice(0, 90);
  }
  log(name, t0, c0, note);
}
function log(name, t0, c0, note) {
  const ms = Date.now() - t0;
  const c = process.cpuUsage(c0);
  const cpu = Math.round((c.user + c.system) / 1000);
  const flag = cpu > LIMIT ? ' ⚠느림' : '';
  // 벽시계가 CPU 보다 한참 크면 기계가 바빴다는 뜻이다. 남겨 두면
  // "왜 오늘 오래 걸렸지"를 다음에 안 헷갈린다.
  const busy = ms > cpu * 2 + 500 ? ` (벽시계 ${ms}ms — 기계가 바빴다)` : '';
  console.log(`  ${name.padEnd(26)} ${String(cpu).padStart(5)}ms  ${note}${flag}${busy}`);
}
export { run };
