import fs from 'fs';
const wasmBytes = fs.readFileSync('dist/pdf.wasm');

async function run(name, bytes, extra, pre) {
  const t0 = Date.now();
  let note = '';
  try {
    const m = await WebAssembly.instantiate(wasmBytes, {
      wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
    const ex = m.instance.exports;
    if (!ex.reserve(bytes.length, bytes.length * 2 + 65536)) return log(name, t0, '메모리 거절');
    new Uint8Array(ex.memory.buffer, ex.inputPtr(), bytes.length).set(bytes);
    if (!ex.parse(bytes.length)) return log(name, t0, '열지 못함');
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
  log(name, t0, note);
}
function log(name, t0, note) {
  const ms = Date.now() - t0;
  const flag = ms > 3000 ? ' ⚠느림' : '';
  console.log(`  ${name.padEnd(26)} ${String(ms).padStart(5)}ms  ${note}${flag}`);
}
export { run };
