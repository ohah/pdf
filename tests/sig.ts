// 전자 서명 확인 시험. bun 으로 돌린다.
import fs from 'node:fs';
import { checkSignature } from '../src/sig';

const wasm = fs.readFileSync('dist/pdf.wasm');
let pass = 0, fail = 0;
const bad: string[] = [];
const ok = (name: string, cond: unknown, got?: unknown) => {
  if (cond) { pass++; return; }
  fail++;
  bad.push(`${name}${got !== undefined ? ` (실제: ${got})` : ''}`);
};

async function sigsOf(file: string) {
  const m = await WebAssembly.instantiate(wasm, {
    wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }),
  });
  const ex = m.instance.exports as any;
  const buf = fs.readFileSync(`tests/fixtures/${file}`);
  ex.reserve(buf.length, buf.length * 3 + 201326592);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), buf.length).set(buf);
  if (!ex.parse(buf.length)) return null;
  const dec = new TextDecoder();
  // 자리를 먼저 받아 둔다 — 서명 곳간을 잡느라 메모리가 늘면 앞서 잡은
  // 버퍼가 떨어져 나간다
  const sigAt = ex.sigTextPtr();
  const S = (o: number, l: number) =>
    dec.decode(new Uint8Array(ex.memory.buffer, sigAt + o, l));
  const out = [];
  for (let i = 0; i < ex.sigCount(); i++) {
    out.push({
      range: [0, 1, 2, 3].map((k) => ex.sigRange(i, k)),
      der: new Uint8Array(ex.memory.buffer, sigAt + ex.sigDerOff(i), ex.sigDerLen(i)).slice(),
      covers: ex.sigCovers(i) === 1,
      name: S(ex.sigNameOff(i), ex.sigNameLen(i)),
      reason: S(ex.sigReasonOff(i), ex.sigReasonLen(i)),
      sub: S(ex.sigSubOff(i), ex.sigSubLen(i)),
    });
  }
  return { file: new Uint8Array(buf), sigs: out };
}

{
  const r = await sigsOf('signed.pdf');
  ok('서명: 하나 걷힘', r && r.sigs.length === 1, r && r.sigs.length);
  if (r && r.sigs[0]) {
    const s = r.sigs[0];
    ok('서명: 이름이 한글로 읽힘', s.name === 'PDF 시험 서명자', JSON.stringify(s.name));
    ok('서명: 까닭', s.reason === '시험용', JSON.stringify(s.reason));
    ok('서명: 꼴', s.sub === 'adbe.pkcs7.detached', s.sub);
    ok('서명: 문서 전체를 덮음', s.covers);
    ok('서명: 뭉치가 실림', s.der.length > 800, s.der.length);
    const v = await checkSignature(r.file, s.der, s.range, s.covers);
    ok('서명: 요약값이 맞음', v.digestOk, v.note);
    ok('서명: 열쇠로 맞아떨어짐', v.cryptoOk, v.note);
    ok('서명: 통째로 맞음', v.ok, v.note);
    ok('서명: 서명자 이름', v.signer.includes('PDF'), v.signer);
    ok('서명: 요약 알고리즘', v.hash === 'SHA-256', v.hash);
    ok('서명: 서명 알고리즘', v.algo.startsWith('RSA'), v.algo);
  }
}
{
  // 서명 뒤에 한 글자를 바꾼 문서 — 요약값이 어긋나야 한다
  const r = await sigsOf('signed-tampered.pdf');
  const s = r && r.sigs[0];
  ok('서명(바뀐 문서): 걷히기는 함', !!s);
  if (r && s) {
    const v = await checkSignature(r.file, s.der, s.range, s.covers);
    ok('서명(바뀐 문서): 요약값이 어긋남', !v.digestOk);
    ok('서명(바뀐 문서): 맞지 않다고 함', !v.ok, v.note);
  }
}

{
  // 뭉치가 망가져도 죽지 않고 "확인 못 함" 으로 떨어져야 한다
  const r = await sigsOf('signed.pdf');
  const s = r!.sigs[0];
  const cases: [string, Uint8Array][] = [
    ['빈 뭉치', new Uint8Array(0)],
    ['앞 절반', s.der.subarray(0, s.der.length >> 1)],
    ['뒤 절반', s.der.subarray(s.der.length >> 1)],
    ['한 바이트', new Uint8Array([0x30])],
    ['길이만 거대', new Uint8Array([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])],
    ['0xff 채움', new Uint8Array(200).fill(0xff)],
    ['비트 뒤집기', (() => {
      const c = s.der.slice();
      for (let i = 0; i < c.length; i += 17) c[i] ^= 0xff;
      return c;
    })()],
  ];
  for (const [name, der] of cases) {
    let threw = false;
    let v: Awaited<ReturnType<typeof checkSignature>> | null = null;
    try {
      v = await checkSignature(r!.file, der, s.range, s.covers);
    } catch (e) {
      threw = true;
    }
    ok(`서명(망가진 뭉치 ${name}): 죽지 않음`, !threw);
    ok(`서명(망가진 뭉치 ${name}): 맞다고 하지 않음`, !threw && v && !v.ok, v?.note);
  }
  // 바이트 범위가 파일 밖
  for (const [name, range] of [
    ['거대', [0, 4294967295, 0, 4294967295]],
    ['0', [0, 0, 0, 0]],
    ['거꾸로', [s.range[2], s.range[3], s.range[0], s.range[1]]],
  ] as [string, number[]][]) {
    let threw = false;
    let v = null;
    try { v = await checkSignature(r!.file, s.der, range, false); } catch { threw = true; }
    ok(`서명(범위 ${name}): 죽지 않고 맞다고도 안 함`, !threw && v && !v.ok, v?.note);
  }
}

console.log(`  서명 ${pass + fail}개 중 통과 ${pass}, 실패 ${fail}`);
if (bad.length) bad.forEach((b) => console.log('    ✗ ' + b));
process.exit(fail ? 1 : 0);
