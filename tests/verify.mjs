// 기능이 실제로 맞게 동작하는지 단언으로 확인한다.
import fs from 'fs';
const wasm = fs.readFileSync('dist/pdf.wasm');
const S = process.argv[2];
const dec = new TextDecoder();
let pass = 0, fail = 0;
const bad = [];

function ok(name, cond, got) {
  if (cond) { pass++; return; }
  fail++; bad.push(`${name}${got !== undefined ? ` (실제: ${got})` : ''}`);
}

const loadNoForm = (f) => load(f, 0, true, false);
async function load(file, page = 0, feed = true, formOn = true) {
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const buf = fs.readFileSync(`${S}/${file}`);
  if (!ex.reserve(buf.length, buf.length * 3 + 201326592)) return null;
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), buf.length).set(buf);
  if (!ex.parse(buf.length)) return null;
  // 미리 정의된 CMap — 화면 쪽이 하는 일을 그대로 한다
  ex.setFormLayer?.(formOn ? 1 : 0);
  if (ex.needCount && feed) {
    ex.cmapReset();
    for (let i = 0; i < ex.needCount(); i++) {
      const nm = dec.decode(new Uint8Array(ex.memory.buffer, ex.needPtr() + ex.needOff(i), ex.needLen(i)));
      const f = `cmaps/${nm}.bin`;
      if (!fs.existsSync(f)) continue;
      const b = fs.readFileSync(f);
      if (b.length > ex.cmapRoom()) continue;
      new Uint8Array(ex.memory.buffer, ex.cmapPtr(), b.length).set(b);
      ex.cmapAdd(i, b.length);
    }
  }
  ex.renderPage(page);
  const ops = new Float32Array(ex.memory.buffer, ex.opsPtr(), ex.opsLen());
  const counts = {};
  for (let i = 0; i < ops.length;) { const k = ops[i], n = ops[i + 1]; counts[k] = (counts[k] || 0) + 1; i += 2 + n; }
  const text = dec.decode(new Uint8Array(ex.memory.buffer, ex.textPtr(), ex.textLen()));
  const fld = [];
  for (let i = 0; i < (ex.fieldCount?.() ?? 0); i++) {
    const S2 = (o, l) => (l > 0 ? dec.decode(new Uint8Array(ex.memory.buffer, ex.fieldTextPtr() + o, l)) : '');
    fld.push({
      obj: ex.fieldObj(i), kind: ex.fieldKind(i), flags: ex.fieldFlags(i),
      rect: [0, 1, 2, 3].map((k) => ex.fieldRect(i, k)),
      name: S2(ex.fieldNameOff(i), ex.fieldNameLen(i)),
      value: S2(ex.fieldValOff(i), ex.fieldValLen(i)),
      on: S2(ex.fieldOnOff(i), ex.fieldOnLen(i)),
      opts: S2(ex.fieldOptsOff(i), ex.fieldOptsLen(i)),
      checked: ex.fieldChecked(i) === 1,
    });
  }
  const drew = [...dec.decode(new Uint8Array(ex.memory.buffer, ex.drawPtr(), ex.drawLen()))]
    .map((c) => (c.codePointAt(0) ?? 0) - 0xe000);
  // 그림 한 장의 비트를 그대로 꺼낸다 (JBIG2·팩스 시험용)
  const slot = (i) => {
    if (i >= ex.imageSlots() || !ex.slotLen(i)) return null;
    const bits = Buffer.from(new Uint8Array(ex.memory.buffer, ex.imageAreaPtr() + ex.slotOff(i), ex.slotLen(i)).slice());
    let ones = 0;
    for (const v of bits) for (let k = 0; k < 8; k++) if ((v >> k) & 1) ones++;
    return { w: ex.slotWidth(i), h: ex.slotHeight(i), kind: ex.slotKind(i), bits, dark: 1 - ones / (bits.length * 8) };
  };
  const need = [];
  for (let i = 0; i < (ex.needCount?.() ?? 0); i++)
    need.push(dec.decode(new Uint8Array(ex.memory.buffer, ex.needPtr() + ex.needOff(i), ex.needLen(i))));
  return { ex, ops, counts, text, need, drew, slot, fld, pages: ex.pageCount() };
}

// --- 글꼴
{
  const r = await load('korean.pdf');
  ok('한글: 박힌 글꼴 3개', r && [0,1,2].every(i => r.ex.fontFileLen(i) > 0), r && [0,1,2].map(i=>r.ex.fontFileLen(i)).join(','));
  ok('한글: 번호로 집기(PUA)', r && r.ex.fontIsPua(0) === 1);
  ok('한글: 본문 뽑힘', r && r.text.startsWith('임베디드 글꼴 시험'));
  ok('한글: 글자 명령', r && r.counts[17] > 90, r && r.counts[17]);
}
{
  const r = await load('cff.pdf');
  ok('CFF: OpenType 껍데기', r && r.ex.fontFileLen(0) > 1000, r && r.ex.fontFileLen(0));
  ok('CFF: 종류표시 512', r && (r.ex.fontKind(0) & 512) !== 0, r && r.ex.fontKind(0));
  ok('CFF: 본문', r && r.text === 'ABCabc123', r && JSON.stringify(r.text));
}
{
  const r = await load('type1.pdf');
  ok('Type1: 종류표시 1024', r && (r.ex.fontKind(0) & 1024) !== 0, r && r.ex.fontKind(0));
  ok('Type1: 외곽선을 채움', r && r.counts[6] === 4, r && r.counts[6]);
  ok('Type1: 곡선 있음', r && r.counts[3] >= 4, r && r.counts[3]);
  ok('Type1: 글자명령 없음(외곽선)', r && !r.counts[17]);
}
{
  // 글리프가 외곽선이 아니라 작은 콘텐츠 스트림인 글꼴
  const r = await load('type3.pdf');
  ok('Type3: 글리프 그림 표시', r && (r.ex.fontKind(0) & 32) !== 0, r && r.ex.fontKind(0));
  ok('Type3: 글자로도 읽힘', r && r.text === 'ABAB', r && JSON.stringify(r.text));
  ok('Type3: 글리프를 실제로 그림', r && r.counts[6] === 4, r && r.counts[6]);
}
{
  const r = await load('pdf/modern.pdf');
  ok('여러 쪽 문서: 4쪽', r && r.pages === 4, r && r.pages);
  ok('여러 쪽 문서: 본문 정상', r && r.text.includes('페이지 1'), r && JSON.stringify(r.text.slice(0,12)));
}
// --- 그림
{
  const r = await load('ccitt.pdf');
  ok('CCITT: 스텐실로 풀림', r && r.ex.imageSlots() === 1 && r.ex.slotKind(0) === 4, r && `${r.ex.imageSlots()}/${r.ex.slotKind(0)}`);
  ok('CCITT: 크기 64x24', r && r.ex.slotWidth(0) === 64 && r.ex.slotHeight(0) === 24);
}
{
  const r = await load('indexed.pdf');
  ok('Indexed: RGB 로 폄', r && r.ex.slotKind(0) === 1, r && r.ex.slotKind(0));
  ok('Indexed: 자료 4x4x3', r && r.ex.slotLen(0) === 48, r && r.ex.slotLen(0));
}
{
  const r = await load('misc2.pdf');
  ok('스텐실: kind 4', r && r.ex.slotKind(0) === 4, r && r.ex.slotKind(0));
  // Tr 3 은 스캔 문서에 얹힌 OCR 글자다. 그리지는 않지만 명령은 낸다 —
  // 그래야 글자층에 들어가 긁어 복사하고 찾을 수 있다.
  // 명령은 글자 하나가 아니라 이어지는 묶음 단위다.
  ok('Tr 3: 명령은 내고 그리지는 않음', r && r.counts[17] === 7, r && r.counts[17]);
  ok("' 연산자: 줄 세 개", r && r.text.includes('line1line2line3'));
}
// --- 필터
{
  const r = await load('filters.pdf');
  for (const w of ['LZW works', 'A85+Flate works', 'RunLength works', 'Hex works'])
    ok(`필터: ${w}`, r && r.text.includes(w));
  ok('Predictor: 그림 RGB', r && r.ex.slotKind(0) === 1, r && r.ex.slotKind(0));
}
// --- 암호
for (const [f, want] of [['enc-rc4.pdf','ENCRYPTED OK'],['enc-aes.pdf','ENCRYPTED OK'],['enc-aes256.pdf','AES256 OK']]) {
  const r = await load(f);
  ok(`암호 ${f}`, r && r.text.includes(want), r && JSON.stringify(r.text.slice(0,20)));
}
// --- 색·셰이딩·주석·폼
{
  const r = await load('cs.pdf');
  ok('색공간: 채우기 색 5회', r && r.counts[11] >= 5, r && r.counts[11]);
  ok('색공간: 본문', r && r.text.includes('colorspaces'));
}
{
  const r = await load('shade.pdf');
  ok('셰이딩: sh 명령', r && r.counts[27] === 1, r && r.counts[27]);
  ok('셰이딩: 무늬를 색으로', r && r.counts[28] === 1, r && r.counts[28]);
  ok('섞는 방식', r && r.counts[26] >= 1, r && r.counts[26]);
  // 양식 층을 켜면 위젯 겉모습은 우리가 안 그린다 — 화면에 진짜 칸을
  // 얹기 때문이다. 껐을 때는 그대로 그린다.
  const rn = await loadNoForm('shade.pdf');
  ok('주석 겉모습', rn && rn.text.includes('FIELD'), rn && JSON.stringify(rn.text.slice(0, 20)));
}
{
  const r = await load('rich0.pdf');
  ok('폼 XObject 두 번', r && (r.text.match(/FORM/g) || []).length === 2, r && r.text);
  const r2 = await load('rich.pdf');
  ok('회전 90', r2 && r2.ex.pageRotate() === 90, r2 && r2.ex.pageRotate());
  ok('MediaBox 상속', r2 && Math.round(r2.ex.pageWidth()) === 595, r2 && r2.ex.pageWidth());
}
// --- 레이어
{
  const r = await load('ocg.pdf');
  ok('꺼진 레이어 제외', r && r.counts[17] === 2, r && r.counts[17]);
}
// --- 링크·목차
{
  const r = await load('links.pdf');
  ok('링크 2개', r && r.ex.linkCount() === 2, r && r.ex.linkCount());
  const uri = r && dec.decode(new Uint8Array(r.ex.memory.buffer, r.ex.linkTextPtr() + r.ex.linkOff(0), r.ex.linkLen(0)));
  ok('링크 URI', uri === 'https://example.com/hello', JSON.stringify(uri));
  ok('링크 쪽 이동', r && r.ex.linkPage(1) === 1, r && r.ex.linkPage(1));
  ok('목차 3개', r && r.ex.outlineCount() === 3, r && r.ex.outlineCount());
  const t0 = r && dec.decode(new Uint8Array(r.ex.memory.buffer, r.ex.outlineTextPtr() + r.ex.outlineOff(0), r.ex.outlineLen(0)));
  ok('목차 UTF-16 제목', t0 === '한글 장', JSON.stringify(t0));
  ok('목차 깊이', r && r.ex.outlineDepth(2) === 1, r && r.ex.outlineDepth(2));
}
// --- 워터마크
{
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const src = fs.readFileSync(`${S}/korean.pdf`);
  ex.reserve(src.length, src.length * 3 + 1048576);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), src.length).set(src);
  ex.parse(src.length);
  ex.clearPick(); ex.addPick(0); ex.setRotate(0); ex.clearWatermark();
  for (const c of 'ㅁㄴㅇㄹ') ex.addWatermarkChar(c.codePointAt(0));
  const n = ex.apply();
  const out = Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n)).toString('latin1');
  ok('워터마크: A4G9 안 나옴', !out.includes('(A4G9)'));
  const mm = out.match(/BT \/\w+ (\d+) Tf [\d.]+ [\d.]+ -?[\d.]+ [\d.]+ (\d+) (\d+) Tm/);
  ok('워터마크: 가운데 근처', mm && Math.abs(+mm[2] - 155) < 200 && Math.abs(+mm[3] - 338) < 200, mm && `${mm[2]},${mm[3]}`);
  ok('워터마크: 크기 자동', mm && +mm[1] > 100, mm && mm[1]);
}
{
  // 영문 워터마크는 그대로 찍히고 내용도 남는다
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const src = fs.readFileSync(`${S}/pdf/scanned.pdf`);
  ex.reserve(src.length, src.length * 3 + 1048576);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), src.length).set(src);
  ex.parse(src.length);
  const np = ex.pageCount();
  ex.clearPick(); for (let i = 0; i < np; i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark();
  for (const c of 'SECRET') ex.addWatermarkChar(c.codePointAt(0));
  const n = ex.apply();
  fs.writeFileSync(`${S}/v-wm.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n)));
  const r = await load('v-wm.pdf');
  ok('워터마크 왕복: 그림 남음', r && r.ex.imageSlots() >= 1, r && r.ex.imageSlots());
  ok('워터마크 왕복: 글자 찍힘', r && r.text.includes('SECRET'), r && JSON.stringify(r.text.slice(-10)));
}
// --- 쪽 고르기·회전·압축
{
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const src = fs.readFileSync(`${S}/pdf/multi.pdf`);
  ex.reserve(src.length, src.length * 3 + 1048576);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), src.length).set(src);
  ex.parse(src.length);
  ex.clearPick(); ex.addPick(0); ex.addPick(2); ex.setRotate(90); ex.clearWatermark();
  const n = ex.apply();
  fs.writeFileSync(`${S}/v-pick.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n)));
  const r = await load('v-pick.pdf');
  ok('쪽 고르기: 2쪽', r && r.pages === 2, r && r.pages);
  ok('회전 90 적용', r && r.ex.pageRotate() === 90, r && r.ex.pageRotate());
}
{
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const src = fs.readFileSync(`${S}/pdf/scanned.pdf`);
  ex.reserve(src.length, src.length * 3 + 1048576);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), src.length).set(src);
  ex.parse(src.length);
  ex.clearPick(); ex.addPick(0); ex.setRotate(0); ex.clearWatermark();
  const n = ex.compact();
  ok('파일 줄이기: 작아짐', n > 0 && n <= src.length, `${src.length}→${n}`);
  fs.writeFileSync(`${S}/v-small.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n)));
  const r = await load('v-small.pdf');
  ok('파일 줄이기: 다시 열림', r && r.pages === 1, r && r.pages);
}
// --- 병합
{
  const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
  const ex = m.instance.exports;
  const a = fs.readFileSync(`${S}/korean.pdf`);
  const b2 = fs.readFileSync(`${S}/pdf/modern.pdf`);
  ex.reserve(a.length, a.length * 3 + b2.length * 3 + 1048576);
  new Uint8Array(ex.memory.buffer, ex.inputPtr(), a.length).set(a);
  ex.parse(a.length);
  new Uint8Array(ex.memory.buffer, ex.secondPtr(), b2.length).set(b2);
  ex.parseSecond(b2.length);
  const n = ex.merge();
  fs.writeFileSync(`${S}/v-merge.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n)));
  const r = await load('v-merge.pdf');
  ok('병합: 5쪽', r && r.pages === 5, r && r.pages);
}

// --- 새로 붙인 것들
{
  const r = await load('tile.pdf');
  ok('타일 무늬: 실제로 깔림', r && r.counts[6] > 100, r && r.counts[6]);
  ok('타일 무늬: 경로로 자름', r && r.counts[10] === 1, r && r.counts[10]);
}
{
  const r = await load('links.pdf');
  const d2 = new TextDecoder();
  const title = r && d2.decode(new Uint8Array(r.ex.memory.buffer, r.ex.infoTextPtr() + r.ex.infoOff(0), r.ex.infoLen(0)));
  ok('문서 속성: 제목', title === '시험 문서', JSON.stringify(title));
  const prod = r && d2.decode(new Uint8Array(r.ex.memory.buffer, r.ex.infoTextPtr() + r.ex.infoOff(4), r.ex.infoLen(4)));
  ok('문서 속성: 만든 도구', prod === 'allthatnba pdf', JSON.stringify(prod));
}

{
  const r = await load('cmap.pdf');
  ok('미리 정의된 CMap: UHC 두 바이트', r && r.text.startsWith('가각간'), r && JSON.stringify(r.text));
  ok('미리 정의된 CMap: 한·두 바이트 섞임', r && r.text.endsWith('A가B'), r && JSON.stringify(r.text));
  ok('미리 정의된 CMap: 받을 목록', r && r.need.join() === 'KSCms-UHC-H,Korea1-UCS2', r && r.need.join());
  const b = await load('cmap.pdf', 0, false);
  ok('표 없어도 ToUnicode 로 읽음', b && b.text === '가각간A가B', b && JSON.stringify(b.text));
}
{
  // ToUnicode 가 아예 없는 문서 — Adobe 표가 없으면 글자를 알 길이 없다
  const r = await load('cmap2.pdf');
  ok('ToUnicode 없이 CID→유니코드', r && r.text === '가각간', r && JSON.stringify(r.text));
  ok('ToUnicode 없이 한 묶음', r && r.counts[17] === 1, r && r.counts[17]);
  const b = await load('cmap2.pdf', 0, false);
  ok('표를 안 넣으면 못 읽는다', b && b.text !== '가각간', b && JSON.stringify(b.text));
}

// --- JPEG 2000
{
  // 기대값은 pdf.js 의 JPX 복호기와 픽셀까지 맞대 확인한 것이다.
  // 9/7(되돌릴 수 없는) 판은 실수 반올림 때문에 1 만큼 어긋날 수 있다.
  for (const [f, w, h, p1, pm, p2] of [
    ['jpx-rgb', 64, 48, '2,5,28', '133,107,217', '252,226,28'],
    ['jpx-gray', 96, 72, '4,4,4', '216,216,216', '167,167,167'],
    ['jpx-53', 128, 128, '186,186,186', '208,208,208', '62,62,62'],
    ['jpx-tiny', 17, 37, '128,128,128', '255,255,255', '128,128,128'],
    ['jpx-tiles', 256, 256, '128,128,255', '99,128,0', '85,108,0'],
    ['jpx-mct', 49, 49, '128,128,128', '0,255,0', '128,128,128'],
    ['jpx-layers', 128, 128, '186,186,186', '208,208,208', '62,62,62'],
  ]) {
    const r = await load(`${f}.pdf`);
    const sl = r && r.slot(0);
    ok(`JPX ${f}: 풀림`, sl && sl.kind === 1 && sl.w === w && sl.h === h,
      sl ? `${sl.kind} ${sl.w}x${sl.h}` : '없음');
    if (!sl) continue;
    const at = (x, y) => [sl.bits[(y * w + x) * 3], sl.bits[(y * w + x) * 3 + 1], sl.bits[(y * w + x) * 3 + 2]];
    const near = (got, want) => want.split(',').every((v, i) => Math.abs(got[i] - +v) <= 2);
    ok(`JPX ${f}: 값이 맞음`,
      near(at(1, 1), p1) && near(at(w >> 1, h >> 1), pm) && near(at(w - 2, h - 2), p2),
      `${at(1,1)} | ${at(w>>1,h>>1)} | ${at(w-2,h-2)}`);
  }
  // 프리싱크트가 걸린 한 줄짜리
  const pr = await load('jpx-prec.pdf');
  const sp = pr && pr.slot(0);
  ok('JPX 프리싱크트: 128x1 풀림', sp && sp.w === 128 && sp.h === 1, sp && `${sp.w}x${sp.h}`);
  ok('JPX 프리싱크트: 가운데 값', sp && Math.abs(sp.bits[64 * 3] - 88) <= 2, sp && sp.bits[64 * 3]);
}

// --- 부드러운 가리개 (/SMask)
{
  const r = await load('smask.pdf');
  const seq = [];
  for (let i = 0; i < r.ops.length;) { const k = r.ops[i], n = r.ops[i + 1]; seq.push(k); i += 2 + n; }
  ok('SMask: 시작·끝 신호', r && r.counts[30] === 1 && r.counts[31] === 1, `${r?.counts[30]}/${r?.counts[31]}`);
  ok('SMask: /None 이 끄기 신호', r && r.counts[32] === 1, r && r.counts[32]);
  ok('SMask: 밝기로 가림', seq.length > 0 && r.ops[seq.indexOf(30) >= 0 ? 0 : 0] !== undefined &&
    (() => { for (let i = 0; i < r.ops.length;) { const k = r.ops[i], n = r.ops[i + 1];
      if (k === 30) return r.ops[i + 2] === 1; i += 2 + n; } return false; })());
  // 가리개 그림의 내용이 시작과 끝 사이에 들어 있어야 한다
  const a2 = seq.indexOf(30), b2 = seq.indexOf(31);
  ok('SMask: 가리개 그림이 사이에', a2 >= 0 && b2 > a2 + 3, `${a2}..${b2}`);
}

// --- 새로 다는 주석
{
  const r = await load('cff.pdf');
  const ex = r.ex;
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.clearPageRotate(); ex.clearNotes();
  ex.addNote(0, 0, 50, 700, 200, 715, 1, 0.9, 0.2);
  ex.addNote(3, 0, 50, 600, 200, 660, 0.9, 0.1, 0.1);
  ex.addNote(4, 0, 220, 600, 320, 660, 0.1, 0.4, 0.9);
  ex.addNote(5, 0, 400, 700, 420, 720, 1, 0.8, 0);
  for (const ch of '한글 메모') ex.addNoteChar(ch.codePointAt(0));
  ex.addNote(6, 0, 50, 400, 300, 500, 0.2, 0.7, 0.2);
  for (let i = 0; i < 20; i++) ex.addNotePoint(50 + i * 12, 450 + i);
  const n = ex.apply();
  ok('주석: 만들어짐', n > 0, n);
  if (n > 0) {
    const out = Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice());
    fs.writeFileSync(`${S}/.notes.pdf`, out);
    const txt = out.toString('latin1');
    for (const k of ['Highlight', 'Square', 'Circle', 'Text', 'Ink', 'QuadPoints', 'InkList'])
      ok(`주석: ${k}`, txt.includes(k));
    ok('주석: 한글 메모는 UTF-16', txt.includes('FEFF'));
    // 다시 열어 겉모습이 그려지는지
    const r2 = await loadNoForm('.notes.pdf');
    let saves = 0;
    for (let i = 0; i < r2.ops.length;) { if (r2.ops[i] === 14) saves++; i += 2 + r2.ops[i + 1]; }
    ok('주석: 겉모습이 그려짐', saves >= 10, saves);
    ok('주석: 원본 글자도 그대로', r2.text.includes('ABCabc123'), JSON.stringify(r2.text));
  }
}

// --- 쪽마다 회전
{
  const r = await load('pdf/multi.pdf');
  const ex = r.ex;
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.clearPageRotate();
  ex.setPageRotate(1, 90);
  ex.setPageRotate(2, 270);
  const n = ex.apply();
  ok('쪽 회전: 만들어짐', n > 0, n);
  if (n > 0) {
    fs.writeFileSync(`${S}/.rot.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice()));
    const got = [];
    const r2 = await load('.rot.pdf');
    for (let i = 0; i < r2.ex.pageCount(); i++) { r2.ex.renderPage(i); got.push(r2.ex.pageRotate()); }
    ok('쪽 회전: 정한 쪽만 돌아감', got.join() === '0,90,270,0,0', got.join());
  }
}

// --- 입력 칸 (AcroForm)
{
  const r = await load('form.pdf');
  ok('양식: 칸 4개', r && r.fld.length === 4, r && r.fld.length);
  ok('양식: 글상자', r && r.fld[0].kind === 0 && r.fld[0].name === 'name' && r.fld[0].value === 'Mario',
    r && JSON.stringify(r.fld[0]));
  ok('양식: 자리', r && r.fld[0].rect.join() === '20,160,200,180', r && r.fld[0].rect.join());
  ok('양식: 여러 줄 깃발', r && (r.fld[1].flags & 4096) !== 0 && r.fld[1].value === 'one\ntwo',
    r && JSON.stringify(r.fld[1].value));
  ok('양식: 확인란과 켜짐 이름', r && r.fld[2].kind === 1 && r.fld[2].on === 'Yes' && !r.fld[2].checked,
    r && JSON.stringify(r.fld[2]));
  ok('양식: 목록 항목', r && r.fld[3].kind === 3 && r.fld[3].opts === 'a\nb\nc\n', r && JSON.stringify(r.fld[3].opts));
  // 양식 층을 켜면 위젯 겉모습은 안 그린다
  ok('양식: 겉모습을 안 그림', r && !r.text.includes('Mario'), r && JSON.stringify(r.text));

  // 채워서 저장하고 다시 읽는다
  const ex = r.ex;
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.addFieldEdit(5, 0);
  for (const ch of 'Luigi & Co') ex.addFieldEditChar(ch.codePointAt(0));
  ex.addFieldEdit(7, 1);
  for (const ch of 'Yes') ex.addFieldEditChar(ch.codePointAt(0));
  const n = ex.apply();
  ok('양식: 만들어짐', n > 0, n);
  if (n > 0) {
    fs.writeFileSync(`${S}/.form2.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice()));
    const r2 = await load('.form2.pdf');
    ok('양식: 값이 남음', r2 && r2.fld[0].value === 'Luigi & Co', r2 && JSON.stringify(r2.fld[0].value));
    ok('양식: 확인란이 켜짐', r2 && r2.fld[2].checked && r2.fld[2].value === 'Yes',
      r2 && JSON.stringify(r2.fld[2]));
    ok('양식: 안 고친 칸은 그대로', r2 && r2.fld[3].value === 'b', r2 && r2.fld[3].value);
    // 겉모습도 새로 그려졌는지 — 양식 층을 끄고 본문을 뽑는다
    const r3 = await loadNoForm('.form2.pdf');
    ok('양식: 겉모습도 새로 그림', r3 && r3.text.includes('Luigi & Co'), r3 && JSON.stringify(r3.text));
  }

  // 한글은 표준 글꼴에 없다. 값은 UTF-16 으로 담고, 겉모습은 화면 글꼴로
  // 그린 1비트 마스크를 심는다.
  const rk = await load('form.pdf');
  const ek = rk.ex;
  ek.clearPick();
  for (let i = 0; i < ek.pageCount(); i++) ek.addPick(i);
  ek.setRotate(0); ek.clearWatermark(); ek.clearLabels(); ek.clearFieldEdits();
  ek.addFieldEdit(5, 0);
  for (const ch of '마리오 형제') ek.addFieldEditChar(ch.codePointAt(0));
  {
    const W = 64, H = 16, st = (W + 7) >> 3;
    const bits = new Uint8Array(st * H).fill(0xff);
    for (let y = 6; y < 10; y++) for (let x = 8; x < 56; x++) bits[y * st + (x >> 3)] &= ~(0x80 >> (x & 7));
    new Uint8Array(ek.memory.buffer, ek.fieldMaskPtr(), bits.length).set(bits);
    ok('양식: 마스크 붙임', ek.setFieldEditMask(W, H, bits.length) === 1);
  }
  const nk = ek.apply();
  ok('양식: 한글 판이 만들어짐', nk > 0, nk);
  if (nk > 0) {
    fs.writeFileSync(`${S}/.form3.pdf`, Buffer.from(new Uint8Array(ek.memory.buffer, ek.outputPtr(), nk).slice()));
    const r4 = await load('.form3.pdf');
    ok('양식: 한글 값이 남음', r4 && r4.fld[0].value === '마리오 형제', r4 && JSON.stringify(r4.fld[0].value));
    const r5 = await loadNoForm('.form3.pdf');
    const s5 = r5 && r5.slot(0);
    ok('양식: 겉모습에 그림이 심김', s5 && s5.kind === 4 && s5.w === 64 && s5.h === 16,
      s5 ? `${s5.kind} ${s5.w}x${s5.h}` : '없음');
  }
}

// --- 표시 내용(BDC)과 인코딩
{
  const r = await load('mcid.pdf');
  const runs = [];
  const dec2 = new TextDecoder();
  const dtext = new Uint8Array(r.ex.memory.buffer, r.ex.drawPtr(), r.ex.drawLen());
  for (let i = 0; i < r.ops.length;) {
    const k = r.ops[i], n = r.ops[i + 1];
    if (k === 17) runs.push(dec2.decode(dtext.subarray(r.ops[i + 5], r.ops[i + 5] + r.ops[i + 6])));
    i += 2 + n;
  }
  // <</MCID 299>>BDC 의 둘째 < 를 16진 문자열 시작으로 보면 "Í0" 이 찍힌다
  ok('BDC: 딕셔너리가 글자가 되지 않음', r && !r.text.includes('\u00cd'), r && JSON.stringify(r.text.slice(0, 20)));
  ok('BDC: 라벨이 그대로', runs[0] === 'AGE' && runs[1] === 'HEIGHT', JSON.stringify(runs.slice(0, 2)));
  // WinAnsi 0x95 는 가운뎃점, 0x93·0x94 는 겹따옴표
  ok('WinAnsi: 가운뎃점과 따옴표', runs[2] === '• bullet “quoted”', JSON.stringify(runs[2]));
  // /Differences [68 /A /B /C] 는 D E F 를 A B C 로 옮긴다
  ok('/Differences: 코드를 옮김', runs[3] === 'ABC', JSON.stringify(runs[3]));
  ok('묶음으로 그림', runs.length === 4, runs.length);
}

// --- 글자 그리기 모드
{
  const r = await load('trclip.pdf');
  const modeCount = {};
  for (let i = 0; i < r.ops.length;) {
    const k = r.ops[i], n = r.ops[i + 1];
    if (k === 17) modeCount[r.ops[i + 13]] = (modeCount[r.ops[i + 13]] || 0) + 1;
    i += 2 + n;
  }
  ok('Tr 4~7: 오려 내기 신호 두 번', r && r.counts[29] === 2, r && r.counts[29]);
  ok('Tr 7: 오려 내기 전용 묶음', modeCount[7] === 1, JSON.stringify(modeCount));
  ok('Tr 4: 칠하고 오려 내기', modeCount[4] === 1, JSON.stringify(modeCount));
  ok('Tr 3: 안 보여도 뽑힘', modeCount[3] === 1, JSON.stringify(modeCount));
  ok('Tr: 본문이 다 나옴', r && r.text === 'CLIPhiddenBOTH', r && JSON.stringify(r.text));
}

// --- JBIG2
{
  // 부록 H 의 같은 그림을 MMR 과 산술 부호로 각각 담았다.
  // 둘이 비트까지 같으면 새로 짠 산술 복호기가 맞다는 뜻이다.
  const a = await load('jb-mmr.pdf');
  const b = await load('jb-arith.pdf');
  const sa = a && a.slot(0);
  const sb = b && b.slot(0);
  ok('JBIG2: MMR 영역이 풀림', sa && sa.kind === 4 && sa.w === 64 && sa.h === 56, sa && `${sa.kind} ${sa.w}x${sa.h}`);
  ok('JBIG2: 산술 영역이 풀림', sb && sb.kind === 4 && sb.w === 64 && sb.h === 56, sb && `${sb.kind} ${sb.w}x${sb.h}`);
  ok('JBIG2: 두 부호가 같은 그림', sa && sb && sa.bits.equals(sb.bits));

  // 실제 문서 — 글자 사전과 글자 영역
  const t = await load('jb-sym.pdf');
  const st = t && t.slot(0);
  ok('JBIG2: 글자 사전 8자', t && t.ex.jbSymN() === 8, t && t.ex.jbSymN());
  ok('JBIG2: 글자 10번 놓임', t && t.ex.jbDbgN() === 10, t && t.ex.jbDbgN());
  ok('JBIG2: 글자 영역 크기', st && st.w === 132 && st.h === 14, st && `${st.w}x${st.h}`);
  ok('JBIG2: 검정 비율', st && st.dark > 0.15 && st.dark < 0.22, st && st.dark.toFixed(3));

  // 부록 H 쪽3 — 사전을 다듬어 글자를 만들고 글자 영역에서 또 다듬는다
  const rf = await load('jb-refine.pdf');
  const srf = rf && rf.slot(0);
  ok('JBIG2: 세밀화로 글자를 만듦', rf && rf.ex.jbSymN() === 4, rf && rf.ex.jbSymN());
  // 사전 안에서 겹쳐 만든 둘 + 글자 영역의 넷 + 다듬은 둘
  ok('JBIG2: 세밀화 배치 여덟 번', rf && rf.ex.jbDbgN() === 8, rf && rf.ex.jbDbgN());
  ok('JBIG2: 세밀화 검정 비율', srf && srf.dark > 0.2 && srf.dark < 0.32, srf && srf.dark.toFixed(3));

  // 부록 H 쪽1 과 쪽2 — 같은 그림을 허프만·MMR 과 산술로 각각 담았다.
  // 글자 사전·글자 영역·보통 영역·무늬 사전·하프톤이 다 들어 있다.
  const p1 = await load('jb-page1.pdf');
  const p2 = await load('jb-page2.pdf');
  const s1 = p1 && p1.slot(0);
  const s2 = p2 && p2.slot(0);
  ok('JBIG2: 쪽1(허프만·MMR) 풀림', s1 && s1.w === 64 && s1.h === 56 && s1.dark > 0.1, s1 && s1.dark?.toFixed(3));
  ok('JBIG2: 쪽2(산술) 풀림', s2 && s2.w === 64 && s2.h === 56 && s2.dark > 0.1, s2 && s2.dark?.toFixed(3));
  ok('JBIG2: 두 부호 방식이 같은 그림', s1 && s2 && s1.bits.equals(s2.bits));
  const hf = await load('jb-half.pdf');
  const shf = hf && hf.slot(0);
  ok('JBIG2: 하프톤만 떼어도 풀림', shf && shf.dark > 0.05 && shf.dark < 0.3, shf && shf.dark.toFixed(3));

  // 스캔 한 장 — globals 에 사전이 따로 있고 사전이 둘이다.
  // 둘을 이어 붙여야 글자 번호가 맞는다 (예전에 뒤 사전이 앞 사전을 덮었다).
  const g = await load('jb-globals.pdf');
  ok('JBIG2: globals 사전까지 이어 붙임', g && g.ex.jbSymN() === 2400, g && g.ex.jbSymN());
  ok('JBIG2: 글자를 수천 번 놓음', g && g.ex.jbDbgN() > 6000, g && g.ex.jbDbgN());
  const sg = g && g.slot(1);
  ok('JBIG2: 큰 쪽이 풀림', sg && sg.kind === 4 && sg.w === 5188 && sg.h === 6930, sg && `${sg.kind} ${sg.w}x${sg.h}`);
  ok('JBIG2: 큰 쪽 검정 비율', sg && sg.dark > 0.005 && sg.dark < 0.1, sg && sg.dark.toFixed(4));
  const sm = g && g.slot(0);
  ok('JBIG2: 작은 쪽도 풀림', sm && sm.w === 1034 && sm.h === 204 && sm.dark > 0.01,
    sm && `${sm.w}x${sm.h} ${sm.dark.toFixed(4)}`);
}

// --- 셰이딩
{
  // 명령 목록에서 채우기 색과 셰이딩 마디를 뽑는다
  function colorsOf(r) {
    const o = r.ops; const cols = []; const stops = [];
    for (let i = 0; i < o.length;) {
      const k = o[i], n = o[i + 1];
      if (k === 11) cols.push([o[i + 2], o[i + 3], o[i + 4]]);
      if (k === 27) { const m = o[i + 11]; for (let j = 0; j < m; j++) stops.push([o[i + 13 + j * 4], o[i + 14 + j * 4], o[i + 15 + j * 4]]); }
      i += 2 + n;
    }
    return { cols, stops };
  }
  const near = (list, want, tol = 0.25) =>
    list.some((c) => Math.abs(c[0] - want[0]) < tol && Math.abs(c[1] - want[1]) < tol && Math.abs(c[2] - want[2]) < tol);

  {
    // 표본 함수를 안 읽던 때는 빨강→파랑이 회색 띠가 됐다
    const r = await load('fn0.pdf');
    const { stops } = colorsOf(r);
    ok('표본 함수: 마디 8개', stops.length === 8, stops.length);
    ok('표본 함수: 빨강에서 시작', near([stops[0]], [1, 0, 0], 0.05), stops[0]?.join());
    ok('표본 함수: 파랑에서 끝', near([stops[7]], [0, 0, 1], 0.05), stops[7]?.join());
  }
  {
    // 계산기 함수 — { dup 1 exch sub 0.5 } 는 t 를 (t, 1-t, 0.5) 로 만든다
    const r = await load('fn4.pdf');
    const { stops } = colorsOf(r);
    ok('계산기 함수: 마디 8개', stops.length === 8, stops.length);
    ok('계산기 함수: 처음 (0,1,0.5)', near([stops[0]], [0, 1, 0.5], 0.02), stops[0]?.join());
    ok('계산기 함수: 끝 (1,0,0.5)', near([stops[7]], [1, 0, 0.5], 0.02), stops[7]?.join());
  }
  {
    // 성분마다 함수가 따로인 경우
    const r = await load('fnarr.pdf');
    const { stops } = colorsOf(r);
    ok('함수 배열: 처음 (0,1,0.25)', near([stops[0]], [0, 1, 0.25], 0.02), stops[0]?.join());
    ok('함수 배열: 끝 (1,0,0.75)', near([stops[7]], [1, 0, 0.75], 0.02), stops[7]?.join());
  }
  {
    const r = await load('sh1.pdf');
    const { cols } = colorsOf(r);
    ok('셰이딩 1형: 격자를 메움', r.counts[6] === 576, r.counts[6]);
    ok('셰이딩 1형: x 가 빨강', near(cols, [0.67, 0, 0], 0.12), cols.length);
    ok('셰이딩 1형: y 가 파랑', near(cols, [0, 0, 0.67], 0.12));
  }
  {
    const r = await load('sh4.pdf');
    const { cols } = colorsOf(r);
    ok('셰이딩 4형: 삼각형을 쪼갬', r.counts[6] > 50, r.counts[6]);
    ok('셰이딩 4형: 빨강 꼭짓점', near(cols, [1, 0, 0]));
    ok('셰이딩 4형: 초록 꼭짓점', near(cols, [0, 1, 0]));
    ok('셰이딩 4형: 파랑 꼭짓점', near(cols, [0, 0, 1]));
  }
  {
    const r = await load('sh5.pdf');
    const { cols } = colorsOf(r);
    ok('셰이딩 5형: 격자 그물', r.counts[6] > 100, r.counts[6]);
    ok('셰이딩 5형: 노랑 모서리', near(cols, [1, 1, 0]));
    ok('셰이딩 5형: 파랑 모서리', near(cols, [0, 0, 1]));
  }
  for (const [f, n] of [['sh6.pdf', 6], ['sh7.pdf', 7]]) {
    const r = await load(f);
    const { cols } = colorsOf(r);
    ok(`셰이딩 ${n}형: 조각을 훑음`, r.counts[6] === 100, r.counts[6]);
    ok(`셰이딩 ${n}형: 네 모서리 색`, near(cols, [1, 0, 0]) && near(cols, [0, 1, 0]) &&
      near(cols, [0, 0, 1]) && near(cols, [1, 1, 0]));
  }
}

// --- CIDToGIDMap
{
  const a = await load('c2g0.pdf');
  ok('CIDToGIDMap /Identity: CID 가 곧 글리프', a && a.drew.join() === '1,2,3', a && a.drew.join());
  const b = await load('c2g.pdf');
  ok('CIDToGIDMap 스트림: 표대로 옮김', b && b.drew.join() === '300,1000,2', b && b.drew.join());
  ok('CIDToGIDMap: 번호로 집기 유지', b && b.ex.fontIsPua(0) === 1, b && b.ex.fontIsPua(0));
  ok('CIDToGIDMap: 글꼴 실림', b && b.ex.fontFileLen(0) > 1000, b && b.ex.fontFileLen(0));
}

// --- 라벨 (쪽 위에 얹기)
{
  // 라벨을 얹은 결과를 다시 열어 본문을 뽑는다
  async function stamp(file, list) {
    const r0 = await load(file);
    if (!r0) return null;
    const ex = r0.ex;
    ex.clearPick();
    for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
    ex.setRotate(0);
    ex.clearWatermark();
    ex.clearLabels();
    for (const L of list) {
      ex.addLabel(L.p, L.x, L.y, L.s ?? 20, 0.85, 0.1, 0.1);
      for (const ch of L.t) ex.addLabelChar(ch.codePointAt(0));
    }
    const n = ex.apply();
    if (!n) return null;
    const out = Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice());
    fs.writeFileSync(`${S}/.stamp.pdf`, out);
    return await load('.stamp.pdf');
  }
  const r = await stamp('cff.pdf', [{ p: 0, x: 60, y: 700, t: 'DRAFT' }]);
  ok('라벨: 영문이 쪽에 들어감', r && r.text.endsWith('DRAFT'), r && JSON.stringify(r.text));
  const k = await stamp('korean.pdf', [{ p: 0, x: 60, y: 700, t: '글꼴' }, { p: 0, x: 60, y: 650, t: '시험' }]);
  ok('라벨: 한글 두 개', k && k.text.endsWith('글꼴시험'), k && JSON.stringify(k.text.slice(-8)));
  const m = await stamp('korean.pdf', [{ p: 0, x: 60, y: 700, t: '뷁' }]);
  ok('라벨: 문서에 없는 글자는 조용히 빠짐', m && !m.text.includes('뷁'));
  const z = await stamp('cff.pdf', [{ p: 5, x: 60, y: 700, t: 'GHOST' }]);
  ok('라벨: 없는 쪽이면 안 그림', z && !z.text.includes('GHOST'), z && JSON.stringify(z.text));
  const e = await stamp('cff.pdf', [{ p: 0, x: 60, y: 700, t: 'A(B)C' }]);
  ok('라벨: 괄호가 문자열을 안 깨뜨림', e && e.text.endsWith('A(B)C'), e && JSON.stringify(e.text));
  ok('라벨 없이도 원본 그대로', (await stamp('cff.pdf', []))?.text === 'ABCabc123');

  // 표준 글꼴에 없는 글자는 화면 글꼴로 그린 그림으로 심는다
  {
    const r0 = await load('cff.pdf');
    const ex = r0.ex;
    ex.clearPick();
    for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
    ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
    const mkbits = (W, H) => {
      const st2 = (W + 7) >> 3;
      const b = new Uint8Array(st2 * H).fill(0xff);
      for (let y = H >> 2; y < H - (H >> 2); y++)
        for (let x = 2; x < W - 2; x++) b[y * st2 + (x >> 3)] &= ~(0x80 >> (x & 7));
      return b;
    };
    ex.addLabel(0, 60, 700, 20, 0.9, 0.1, 0.1);
    for (const ch of '한글라벨') ex.addLabelChar(ch.codePointAt(0));
    const b1 = mkbits(80, 20);
    new Uint8Array(ex.memory.buffer, ex.fieldMaskPtr(), b1.length).set(b1);
    ok('라벨 그림 붙임', ex.setLabelMask(80, 20, b1.length, 60, 20) === 1);
    for (const ch of '대외비') ex.addWatermarkChar(ch.codePointAt(0));
    const b2 = mkbits(120, 40);
    new Uint8Array(ex.memory.buffer, ex.fieldMaskPtr(), b2.length).set(b2);
    ok('워터마크 그림 붙임', ex.setWatermarkMask(120, 40, b2.length, 120, 40) === 1);
    const n = ex.apply();
    ok('한글 라벨·워터마크 만들어짐', n > 0, n);
    if (n > 0) {
      fs.writeFileSync(`${S}/.ko.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice()));
      const r2 = await load('.ko.pdf');
      ok('한글: 그림 두 장이 심김', r2 && r2.ex.imageSlots() === 2, r2 && r2.ex.imageSlots());
      let dos = 0;
      for (let i = 0; i < r2.ops.length;) { if (r2.ops[i] === 18) dos++; i += 2 + r2.ops[i + 1]; }
      ok('한글: 그림 두 번 그림', dos === 2, dos);
      ok('한글: 마스크로 심김', r2 && r2.ex.slotKind(0) === 4 && r2.ex.slotKind(1) === 4);
    }
  }
}

// --- JBIG2 허프만 판의 빈 자리 (tests/mkjbig2h.mjs 가 만든다)
//
// 새 길로 담은 것과 옛 길로 담은 것을 짝지어 냈다. 같은 그림이 나와야 한다 —
// 틀이 한 비트라도 어긋나면 짝이 갈린다.
{
  for (const [a, b, name] of [
    ['jbh-std.pdf', 'jbh-tab.pdf', '문서가 실어 온 표'],
    ['jbh-refagg-base.pdf', 'jbh-refagg.pdf', '사전 안 세밀화'],
    ['jbh-tref-base.pdf', 'jbh-tref.pdf', '글자 영역 세밀화'],
  ]) {
    const ra = await load(a);
    const rb = await load(b);
    const sa = ra && ra.slot(0);
    const sb = rb && rb.slot(0);
    ok(`JBIG2 ${name}: 둘 다 풀림`, sa && sb && sa.w === 24 && sb.w === 24,
      `${sa ? sa.w : '-'} ${sb ? sb.w : '-'}`);
    ok(`JBIG2 ${name}: 같은 그림`, sa && sb && sa.bits.equals(sb.bits));
  }
  // 세밀화로 만든 쪽은 사전에 글자가 하나뿐인데도 두 글자가 나온다
  const tr = await load('jbh-tref.pdf');
  ok('JBIG2 글자 영역 세밀화: 사전은 한 글자', tr && tr.ex.jbSymN() === 1, tr && tr.ex.jbSymN());
}

// --- JPX 관심 구역 (RGN)
{
  const base = await load('jpx-53.pdf');
  const hi = await load('jpx-roi-high.pdf');
  const lo = await load('jpx-roi-low.pdf');
  const sb2 = base && base.slot(0);
  const sh = hi && hi.slot(0);
  const sl2 = lo && lo.slot(0);
  // 올림값이 아주 크면 문턱을 넘는 계수가 없다 — 원본과 한 바이트도 달라지면 안 된다
  ok('JPX 관심구역: 큰 올림값은 원본 그대로', sb2 && sh && sb2.bits.equals(sh.bits));
  // 작으면 여럿이 넘어 내려간다
  let diff = 0;
  if (sb2 && sl2) for (let i = 0; i < sb2.bits.length; i++) if (sb2.bits[i] !== sl2.bits[i]) diff++;
  ok('JPX 관심구역: 작은 올림값은 달라짐', diff > sb2.bits.length / 2, diff);
}

// --- 암호 걸기 (AES-256, 판 5·R6)
{
  const seal = async (file, pw) => {
    const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
    const ex = m.instance.exports;
    const buf = fs.readFileSync(`${S}/${file}`);
    if (!ex.reserve(buf.length, buf.length * 4 + 201326592)) return null;
    new Uint8Array(ex.memory.buffer, ex.inputPtr(), buf.length).set(buf);
    ex.clearPassword();
    if (!ex.parse(buf.length)) return null;
    ex.clearPick();
    for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
    ex.setRotate(0); ex.clearWatermark(); ex.clearLabels();
    ex.clearFieldEdits(); ex.clearPageRotate(); ex.clearNotes();
    ex.setEncrypt(1);
    for (const ch of pw) ex.addEncryptChar(ch.codePointAt(0));
    // 브라우저가 넣어 줄 난수 자리. 시험에서는 정해진 값을 쓴다.
    const rnd = Buffer.alloc(64);
    for (let i = 0; i < 64; i++) rnd[i] = (i * 197 + 41) & 255;
    new Uint8Array(ex.memory.buffer, ex.encRandomPtr(), 64).set(rnd);
    const n = ex.compact();
    if (!n) return null;
    return Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice());
  };
  const openWith = async (name, pw) => {
    const m = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }) });
    const ex = m.instance.exports;
    const buf = fs.readFileSync(`${S}/${name}`);
    if (!ex.reserve(buf.length, buf.length * 3 + 201326592)) return null;
    new Uint8Array(ex.memory.buffer, ex.inputPtr(), buf.length).set(buf);
    ex.clearPassword();
    for (const ch of pw) ex.addPasswordChar(ch.codePointAt(0));
    const okp = ex.parse(buf.length);
    ex.renderPage(0);
    return {
      ok: okp, need: ex.needPassword(), enc: ex.isEncrypted(),
      text: dec.decode(new Uint8Array(ex.memory.buffer, ex.textPtr(), ex.textLen())),
    };
  };
  for (const [file, pw] of [['cff.pdf', ''], ['mcid.pdf', '열쇠말1'], ['korean.pdf', '']]) {
    const plain = await load(file);
    const sealed = await seal(file, pw);
    ok(`암호 ${file}: 만들어짐`, sealed && sealed.includes('/AESV3'), sealed && sealed.length);
    if (!sealed) continue;
    fs.writeFileSync(`${S}/.enc.pdf`, sealed);
    const good = await openWith('.enc.pdf', pw);
    ok(`암호 ${file}: 맞는 암호로 본문이 그대로`, good && good.text === plain.text,
      good && JSON.stringify(good.text.slice(0, 24)));
    ok(`암호 ${file}: 잠긴 것으로 잡힘`, good && good.enc === 1 && good.need === 0,
      good && `${good.enc} ${good.need}`);
    const bad2 = await openWith('.enc.pdf', pw === '' ? '엉뚱한암호' : '틀린암호');
    ok(`암호 ${file}: 틀린 암호는 물어봄`, bad2 && bad2.need === 1, bad2 && bad2.need);
  }
  // 이미 잠긴 문서는 빈 암호로 열려야 한다 (예전부터 되던 것)
  for (const f of ['enc-rc4.pdf', 'enc-aes.pdf', 'enc-aes256.pdf']) {
    const r = await openWith(f, '');
    ok(`암호 ${f}: 빈 암호로 열림`, r && r.enc === 1 && r.need === 0 && r.text.length > 3,
      r && `${r.enc} ${r.need} ${JSON.stringify(r.text.slice(0, 12))}`);
  }
}
// --- 입력 칸 이름 바꾸기·지우기·새로 만들기
{
  const mk = async (file, fn) => {
    const r = await load(file);
    if (!r) return null;
    const ex = r.ex;
    ex.clearPick();
    for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
    ex.setRotate(0); ex.clearWatermark(); ex.clearLabels();
    ex.clearFieldEdits(); ex.clearNewFields(); ex.clearPageRotate(); ex.clearNotes();
    fn(ex, r.fld);
    const n = ex.apply();
    if (!n) return null;
    fs.writeFileSync(`${S}/.fld.pdf`, Buffer.from(new Uint8Array(ex.memory.buffer, ex.outputPtr(), n).slice()));
    return load('.fld.pdf');
  };
  const base = await load('form.pdf');
  ok('칸: 원래 4개', base && base.fld.length === 4, base && base.fld.length);

  const named = await mk('form.pdf', (ex, fl) => {
    ex.addFieldEdit(fl[0].obj, 3);
    for (const ch of '이름바꾼칸') ex.addFieldEditChar(ch.codePointAt(0));
  });
  ok('칸 이름: 한글로 바뀜', named && named.fld[0]?.name === '이름바꾼칸',
    named && JSON.stringify(named.fld[0]?.name));
  ok('칸 이름: 값은 그대로', named && named.fld[0]?.value === base.fld[0].value,
    named && JSON.stringify(named.fld[0]?.value));
  ok('칸 이름: 나머지 칸은 그대로', named && named.fld.length === 4
    && named.fld[1]?.name === base.fld[1].name, named && named.fld.length);

  const cut = await mk('form.pdf', (ex, fl) => ex.addFieldEdit(fl[0].obj, 4));
  ok('칸 지우기: 하나 줄어듦', cut && cut.fld.length === 3, cut && cut.fld.length);
  ok('칸 지우기: 지운 것만 빠짐', cut && !cut.fld.some((f) => f.obj === base.fld[0].obj));

  const made = await mk('form.pdf', (ex) => {
    ex.addNewField(0, 0, 60, 300, 300, 330);
    for (const ch of '새 글상자') ex.addNewFieldChar(ch.codePointAt(0));
    ex.addNewField(0, 1, 60, 260, 80, 280);
    for (const ch of '새 확인란') ex.addNewFieldChar(ch.codePointAt(0));
  });
  ok('칸 만들기: 둘 늘어남', made && made.fld.length === 6, made && made.fld.length);
  ok('칸 만들기: 이름이 한글로 실림',
    made && made.fld.some((f) => f.name === '새 글상자') && made.fld.some((f) => f.name === '새 확인란'),
    made && made.fld.map((f) => f.name).join(','));
  ok('칸 만들기: 자리가 맞음',
    made && made.fld.some((f) => Math.abs(f.rect[0] - 60) < 1 && Math.abs(f.rect[3] - 330) < 1),
    made && JSON.stringify(made.fld[4]?.rect));
  ok('칸 만들기: 갈래가 맞음',
    made && made.fld.find((f) => f.name === '새 확인란')?.kind === 1,
    made && made.fld.find((f) => f.name === '새 확인란')?.kind);

  // 양식이 아예 없던 문서
  const fresh = await mk('cff.pdf', (ex) => {
    ex.addNewField(0, 0, 60, 300, 300, 330);
    for (const ch of '빈 문서 칸') ex.addNewFieldChar(ch.codePointAt(0));
  });
  ok('칸 만들기: 양식 없던 문서에도 생김', fresh && fresh.fld.length === 1, fresh && fresh.fld.length);
  ok('칸 만들기: 그 이름', fresh && fresh.fld[0]?.name === '빈 문서 칸',
    fresh && JSON.stringify(fresh.fld[0]?.name));
  ok('칸 만들기: 본문은 그대로', fresh && fresh.text === 'ABCabc123', fresh && JSON.stringify(fresh.text));

  // 한꺼번에 — 이름 바꾸고 지우고 만들기
  const mix = await mk('form.pdf', (ex, fl) => {
    ex.addFieldEdit(fl[1].obj, 3);
    for (const ch of '메모칸') ex.addFieldEditChar(ch.codePointAt(0));
    ex.addFieldEdit(fl[2].obj, 4);
    ex.addNewField(0, 0, 60, 300, 300, 330);
    for (const ch of '덧붙인칸') ex.addNewFieldChar(ch.codePointAt(0));
  });
  ok('칸: 한꺼번에 고쳐도 개수가 맞음', mix && mix.fld.length === 4, mix && mix.fld.length);
  ok('칸: 한꺼번에 — 이름·지움·새것이 다 반영', mix
    && mix.fld.some((f) => f.name === '메모칸')
    && !mix.fld.some((f) => f.obj === base.fld[2].obj)
    && mix.fld.some((f) => f.name === '덧붙인칸'),
    mix && mix.fld.map((f) => f.name).join(','));
}

// --- 스트림 길이가 곧이곧대로가 아닌 문서
//
// /Length 가 딴 객체를 가리키는 꼴(`35 0 R`)은 흔하다. 앞의 숫자만 읽으면
// 35 바이트만 떼어 와 압축이 안 풀리고 쪽이 통째로 빈다.
{
  const want = 'LENGTH TEST ABCsecond line 123';
  for (const [k, why] of [
    ['ok', '곧은 숫자'],
    ['ref', '딴 객체를 가리킴'],
    ['small', '너무 작게 적힘'],
    ['big', '너무 크게 적힘'],
  ]) {
    const r = await load(`len-${k}.pdf`);
    ok(`스트림 길이(${why}): 글자가 나옴`, r && r.text === want, r && JSON.stringify(r.text));
  }
}

// --- 우리가 지어 내보내는 글꼴이 브라우저 검사를 통과할 꼴인가
//
// 크롬은 글꼴을 한 번 걸러 본다(OTS). 규격이 있어야 한다고 정한 표가 빠지면
// 통째로 거절하고, 그러면 FontFace 가 안 실려 글자가 한 자도 안 그려진다 —
// 우리는 글리프를 사용자 영역 번호로 집기 때문에 대체 글꼴에도 그 번호가 없다.
{
  const need = ['head', 'hhea', 'hmtx', 'maxp', 'cmap', 'name', 'OS/2', 'post'];
  // type1.pdf 는 외곽선을 직접 그리는 길이라 글꼴 파일을 안 내보낸다
  for (const f of ['korean.pdf', 'cff.pdf', 'c2g.pdf']) {
    const r = await load(f);
    if (!r) { ok(`글꼴 ${f}: 열림`, false); continue; }
    let checked = 0;
    let missing = '';
    let unsorted = '';
    for (let i = 0; i < r.ex.fontCount(); i++) {
      const len = r.ex.fontFileLen(i);
      if (!len) continue;
      const b = Buffer.from(new Uint8Array(r.ex.memory.buffer,
        r.ex.fontAreaPtr() + r.ex.fontFileOff(i), len).slice());
      if (b.length < 12) { missing += `${i}:짧음 `; continue; }
      const n = b.readUInt16BE(4);
      const tags = [];
      for (let k = 0; k < n; k++) tags.push(b.toString('latin1', 12 + k * 16, 16 + k * 16));
      const have = new Set(tags.map((t) => t.trim()));
      // CFF 를 감싼 것은 glyf 대신 CFF 를 쓴다
      const want = have.has('CFF') ? need : [...need, 'glyf', 'loca'];
      for (const w of want) if (!have.has(w.trim())) missing += `${i}:${w} `;
      if (tags.slice().sort().join() !== tags.join()) unsorted += `${i} `;
      checked++;
    }
    ok(`글꼴 ${f}: 박힌 글꼴이 있음`, checked > 0, checked);
    ok(`글꼴 ${f}: 있어야 할 표가 다 있음`, missing === '', missing);
    ok(`글꼴 ${f}: 표 목록이 이름순`, unsorted === '', unsorted);
  }
}

// --- 그리는 글자와 긁는 글자는 다르다
//
// 번호로 집는 글꼴은 사용자 영역(U+E000+글리프번호)으로 찍어야 그려진다.
// 그걸 그대로 글자층에 얹으면 긁어 붙였을 때 깨진 글자가 나온다.
{
  const pua = (t) => [...t].filter((c) => c.codePointAt(0) >= 0xe000 && c.codePointAt(0) <= 0xf8ff).length;
  for (const [f, want] of [['korean.pdf', '임베디드'], ['c2g.pdf', null], ['cff.pdf', 'ABCabc123']]) {
    const r = await load(f);
    if (!r) { ok(`글자층 ${f}: 열림`, false); continue; }
    const draw = dec.decode(new Uint8Array(r.ex.memory.buffer, r.ex.drawPtr(), r.ex.drawLen()));
    const read = dec.decode(new Uint8Array(r.ex.memory.buffer, r.ex.readPtr(), r.ex.readLen()));
    ok(`글자층 ${f}: 읽는 글자가 나옴`, read.length > 0, read.length);
    ok(`글자층 ${f}: 사용자 영역이 안 섞임`, pua(read) === 0, pua(read));
    if (want) ok(`글자층 ${f}: 내용이 맞음`, read.includes(want), JSON.stringify(read.slice(0, 20)));
    // 번호로 집는 글꼴이면 그리는 쪽에는 사용자 영역이 있어야 한다
    if (r.ex.fontIsPua(0) === 1) {
      ok(`글자층 ${f}: 그리는 쪽은 번호로 집음`, pua(draw) > 0, pua(draw));
    }
    // 두 곳간이 나란한지 — 글자 명령마다 자리가 안쪽에 있어야 한다
    let bad = 0;
    for (let i = 0; i < r.ops.length;) {
      const k = r.ops[i];
      const n = r.ops[i + 1];
      if (k === 17 && n > 13) {
        const roff = r.ops[i + 14];
        const rlen = r.ops[i + 15];
        if (roff < 0 || rlen < 0 || roff + rlen > r.ex.readLen()) bad++;
      }
      i += 2 + n;
    }
    ok(`글자층 ${f}: 자리가 곳간 안쪽`, bad === 0, bad);
  }
}

// --- 이름으로 가리킨 목적지
//
// `/Dest /2장` 처럼 이름만 적힌 링크가 흔하다. 실제 자리는 /Names /Dests
// 이름나무나 옛 꼴 /Dests 딕셔너리에 있다. 예전에는 배열 꼴만 봐서
// 그런 링크와 목차가 통째로 안 먹었다.
{
  for (const [k, why] of [
    ['tree', '이름나무'], ['dict', '옛 딕셔너리'], ['array', '곧은 배열'],
  ]) {
    const r = await load(`dest-${k}.pdf`);
    ok(`목적지(${why}): 목차가 둘째 쪽을 가리킴`,
      r && r.ex.outlineCount() === 1 && r.ex.outlinePage(0) === 1,
      r && `${r.ex.outlineCount()}/${r.ex.outlineCount() ? r.ex.outlinePage(0) : '-'}`);
    ok(`목적지(${why}): 링크가 둘째 쪽을 가리킴`,
      r && r.ex.linkCount() === 1 && r.ex.linkPage(0) === 1,
      r && `${r.ex.linkCount()}/${r.ex.linkCount() ? r.ex.linkPage(0) : '-'}`);
  }
}

// --- 레이어(선택 콘텐츠) 켜고 끄기
{
  const r = await load('ocg.pdf');
  ok('레이어: 둘 걷힘', r && r.ex.ocCount() === 2, r && r.ex.ocCount());
  const nm = (i) => dec.decode(new Uint8Array(r.ex.memory.buffer,
    r.ex.ocTextPtr() + r.ex.ocNameOff(i), r.ex.ocNameLen(i)));
  ok('레이어: 이름이 읽힘', r && nm(0) === 'Visible' && nm(1) === 'Hidden',
    r && `${nm(0)}/${nm(1)}`);
  ok('레이어: 처음 상태', r && r.ex.ocIsOn(0) === 1 && r.ex.ocIsOn(1) === 0,
    r && `${r.ex.ocIsOn(0)}${r.ex.ocIsOn(1)}`);
  const ops = () => {
    r.ex.renderPage(0);
    const o = new Float32Array(r.ex.memory.buffer, r.ex.opsPtr(), r.ex.opsLen());
    let n = 0;
    for (let k = 0; k < o.length;) { n++; k += 2 + o[k + 1]; }
    return n;
  };
  const base = ops();
  r.ex.setOcOn(0, 0);
  const off = ops();
  r.ex.setOcOn(0, 1);
  r.ex.setOcOn(1, 1);
  const all = ops();
  ok('레이어: 끄면 줄어듦', off < base, `${base}→${off}`);
  ok('레이어: 켜면 늘어남', all > base, `${base}→${all}`);
}

// --- 딸린 파일·XFA·Lab
{
  const r = await load('attach.pdf');
  ok('딸린 파일: 둘 걷힘', r && r.ex.attCount() === 2, r && r.ex.attCount());
  const nm = (i) => dec.decode(new Uint8Array(r.ex.memory.buffer,
    r.ex.attTextPtr() + r.ex.attNameOff(i), r.ex.attNameLen(i)));
  ok('딸린 파일: 한글 이름', r && nm(0) === '붙임1.txt', r && JSON.stringify(nm(0)));
  const n0 = r && r.ex.attLoad(0);
  const body = n0
    ? dec.decode(new Uint8Array(r.ex.memory.buffer, r.ex.attPtr(), n0))
    : '';
  ok('딸린 파일: 안 압축된 것', body.startsWith('첫째 붙임'), JSON.stringify(body.slice(0, 12)));
  const n1 = r && r.ex.attLoad(1);
  const body1 = n1
    ? dec.decode(new Uint8Array(r.ex.memory.buffer, r.ex.attPtr(), Math.min(n1, 20)))
    : '';
  ok('딸린 파일: 압축된 것도 풀림', body1.startsWith('second attachment'), JSON.stringify(body1));
  ok('딸린 파일: XFA 아님', r && r.ex.isXfa() === 0, r && r.ex.isXfa());
}
{
  const r = await load('xfa.pdf');
  ok('XFA: 알아봄', r && r.ex.isXfa() === 1, r && r.ex.isXfa());
}
{
  // L*a*b* 로 칠한 네모 셋 — 흰·빨강·초록이 나와야 한다
  const r = await load('lab.pdf');
  const cols = [];
  if (r) {
    for (let i = 0; i < r.ops.length;) {
      if (r.ops[i] === 11) cols.push([0, 1, 2].map((k) => Math.round(r.ops[i + 2 + k] * 255)));
      i += 2 + r.ops[i + 1];
    }
  }
  const near = (c, w) => c && c.every((v, i) => Math.abs(v - w[i]) <= 6);
  ok('Lab: 흰색', cols.some((c) => near(c, [255, 255, 255])), JSON.stringify(cols));
  ok('Lab: 빨강', cols.some((c) => near(c, [255, 0, 0])), JSON.stringify(cols));
  ok('Lab: 초록', cols.some((c) => near(c, [13, 255, 2])), JSON.stringify(cols));
}

// --- 두 번째 조사에서 메운 것들
{
  // CropBox — 인쇄용 문서는 재단선을 MediaBox 에 두고 CropBox 로 잘라 보여 준다
  const r = await load('crop.pdf');
  ok('CropBox: 잘라 낸 크기', r && Math.round(r.ex.pageWidth()) === 400
    && Math.round(r.ex.pageHeight()) === 600,
    r && `${r.ex.pageWidth()}x${r.ex.pageHeight()}`);
  ok('CropBox: 원점도 옮김', r && r.ex.pageOriginX() === 100 && r.ex.pageOriginY() === 100,
    r && `${r.ex.pageOriginX()},${r.ex.pageOriginY()}`);
}
{
  // CMYK JPEG — 브라우저가 못 푸는 것을 우리가 푼다
  const r = await load('cmyk.pdf');
  const sl = r && r.slot(0);
  ok('CMYK JPEG: RGB 로 풀림', sl && sl.kind === 1 && sl.w === 96 && sl.h === 72,
    sl && `${sl.kind} ${sl.w}x${sl.h}`);
  ok('CMYK JPEG: 화소가 다 있음', sl && sl.bits.length === 96 * 72 * 3, sl && sl.bits.length);
  // 온통 같은 값이면 잘못 푼 것이다
  const uniq = sl ? new Set([...sl.bits.subarray(0, 3000)]).size : 0;
  ok('CMYK JPEG: 민무늬가 아님', uniq > 20, uniq);
}
{
  // /Mask — 스텐실과 색 키 두 갈래
  const st = await load('mask-stencil.pdf');
  const ms = st && st.ex.slotSMask(0);
  ok('Mask(스텐실): 가리개가 붙음', ms > 0, ms);
  if (ms > 0) {
    const px = new Uint8Array(st.ex.memory.buffer, st.ex.imageAreaPtr() + st.ex.slotOff(ms - 1), 8);
    ok('Mask(스텐실): 왼쪽만 보임', px[0] === 255 && px[4] === 0, [...px].join(','));
  }
  const ky = await load('mask-key.pdf');
  const ms2 = ky && ky.ex.slotSMask(0);
  ok('Mask(색 키): 가리개가 붙음', ms2 > 0, ms2);
  if (ms2 > 0) {
    const px = new Uint8Array(ky.ex.memory.buffer, ky.ex.imageAreaPtr() + ky.ex.slotOff(ms2 - 1), 40);
    ok('Mask(색 키): 빨강만 뚫림', px[0] === 0 && px[32] === 255, `${px[0]}/${px[32]}`);
  }
}
{
  // 16비트 그림 — 높은 바이트만 남겨 8비트로 편다
  const r = await load('bpc16.pdf');
  const sl = r && r.slot(0);
  ok('16비트: 회색으로 풀림', sl && sl.kind === 2 && sl.w === 8 && sl.h === 4,
    sl && `${sl.kind} ${sl.w}x${sl.h}`);
  ok('16비트: 왼쪽 어둡고 오른쪽 밝음',
    sl && sl.bits[0] === 0 && sl.bits[7] === 255, sl && `${sl.bits[0]}/${sl.bits[7]}`);
}
{
  // 세로쓰기 — 글자마다 자리가 아래로 내려가야 글자층이 세로로 선다
  const r = await load('vert.pdf');
  const runs = [];
  if (r) {
    for (let i = 0; i < r.ops.length;) {
      if (r.ops[i] === 17) runs.push([Math.round(r.ops[i + 2]), Math.round(r.ops[i + 3])]);
      i += 2 + r.ops[i + 1];
    }
  }
  ok('세로쓰기: 글자마다 따로 나감', runs.length === 8, runs.length);
  ok('세로쓰기: x 는 그대로', runs.every((q) => q[0] === runs[0][0]), JSON.stringify(runs.slice(0, 3)));
  ok('세로쓰기: y 가 내려감', runs.length > 1 && runs[1][1] < runs[0][1],
    JSON.stringify(runs.slice(0, 3)));
  ok('세로쓰기: 글자도 맞음', r && r.text === '세로쓰기시험입니', r && JSON.stringify(r.text));
}
{
  // 투명 그룹 — 통째로 한 판에 그려 한 번에 겹쳐야 겹친 데가 안 진해진다
  const r = await load('group.pdf');
  const seq = [];
  if (r) {
    for (let i = 0; i < r.ops.length;) { seq.push(r.ops[i]); i += 2 + r.ops[i + 1]; }
  }
  ok('투명 그룹: 시작·끝 명령이 나감', seq.includes(33) && seq.includes(34), seq.join(','));
  ok('투명 그룹: 시작이 먼저', seq.indexOf(33) < seq.indexOf(34));
}


// 문서 한 벌 정보 — 쪽 라벨·열 때 설정·지문·권한
{
  const r = await load('labels.pdf');
  const S = (ptr, off, len) => (len > 0 ? dec.decode(new Uint8Array(r.ex.memory.buffer, ptr + off, len)) : '');
  const e = r.ex;
  const labs = [];
  for (let i = 0; i < e.pageLabelCount(); i++) labs.push(S(e.pageLabelPtr(), e.pageLabelOff(i), e.pageLabelLen(i)));
  ok('쪽 라벨: 로마자와 접두사', JSON.stringify(labs) === '["i","ii","A-1","A-2"]', JSON.stringify(labs));
  const meta = (i) => S(e.metaTextPtr(), e.metaOff(i), e.metaLen(i));
  ok('열 때 옆판(/PageMode)', meta(0) === 'UseOutlines', meta(0));
  ok('쪽 배치(/PageLayout)', meta(1) === 'TwoColumnLeft', meta(1));
  ok('파일 지문(/ID)', meta(2) === '0102ab', meta(2));
  ok('태그 PDF(/MarkInfo)', meta(3) === '1', meta(3));
  ok('문서 언어(/Lang)', meta(4) === 'ko-KR', meta(4));
  ok('암호 없으면 권한 -1', e.permissions() === -1, e.permissions());
}
{
  const r = await load('enc-perm.pdf');
  const p2 = r.ex.permissions();
  const can = (b) => ((p2 >>> 0) & (1 << (b - 1))) !== 0;
  ok('권한 비트를 읽는다', p2 === -3904, p2);
  ok('인쇄 금지', !can(3));
  ok('복사 금지', !can(5));
  ok('권한 제한 문서도 열린다', r.text.includes('permission'), r.text.slice(0, 20));
}

// 주석 열거 — 종류·글·쓴이·색·깃발
{
  const r = await load('annots.pdf');
  const e = r.ex;
  const S = (o, l) => (l > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.annTextPtr() + o, l)) : '');
  ok('주석 다섯을 걷는다', e.annCount() === 5, e.annCount());
  const subs = [];
  for (let i = 0; i < e.annCount(); i++) subs.push(S(e.annSubOff(i), e.annSubLen(i)));
  ok('종류를 읽는다', subs.join(',') === 'Highlight,Text,Square,Link,StrikeOut', subs.join(','));
  ok('한글 글이 살아 있다', S(e.annBodyOff(0), e.annBodyLen(0)) === '중요한 곳', S(e.annBodyOff(0), e.annBodyLen(0)));
  ok('쓴이(/T)가 /Type 에 안 걸린다', S(e.annAuthorOff(0), e.annAuthorLen(0)) === '윤보경', S(e.annAuthorOff(0), e.annAuthorLen(0)));
  ok('색(/C)이 /Contents 에 안 걸린다', e.annHasColor(1) === 1 && e.annColor(1, 0) === 1 && e.annColor(1, 1) === 0);
  ok('회색 하나도 색으로 읽는다', Math.abs(e.annColor(4, 0) - 0.5) < 1e-6, e.annColor(4, 0));
  ok('깃발(/F)을 읽는다', e.annFlags(0) === 4, e.annFlags(0));
  ok('자리를 읽는다', e.annRect(0, 0) === 100 && e.annRect(0, 3) === 720, [e.annRect(0, 0), e.annRect(0, 3)]);
}

// 이름 목적지 · 뷰어 설정 · XMP
{
  const r = await load('dests.pdf');
  const e = r.ex;
  const S = (ptr, off, len) => (len > 0 ? dec.decode(new Uint8Array(e.memory.buffer, ptr + off, len)) : '');
  const names = [];
  for (let i = 0; i < e.destCount(); i++) names.push(`${S(e.destTextPtr(), e.destNameOff(i), e.destNameLen(i))}:${e.destPageOf(i)}`);
  ok('이름 목적지 셋', names.join(',') === 'chapter1:0,chapter2:1,last:2', names.join(','));
  const prefs = {};
  for (let i = 0; i < e.viewPrefCount(); i++) {
    prefs[S(e.viewPrefTextPtr(), e.viewPrefKeyOff(i), e.viewPrefKeyLen(i))] =
      S(e.viewPrefTextPtr(), e.viewPrefValOff(i), e.viewPrefValLen(i));
  }
  ok('뷰어 설정: 참/거짓', prefs.HideToolbar === 'true', JSON.stringify(prefs));
  ok('뷰어 설정: 이름값', prefs.Direction === 'R2L' && prefs.PrintScaling === 'None', JSON.stringify(prefs));
  const xl = e.xmpLen();
  const xmp = xl > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.xmpPtr(), xl)) : '';
  ok('XMP 를 통째로 준다', xmp.includes('x:xmpmeta'), xl);
  ok('XMP 안 한글이 살아 있다', xmp.includes('XMP 제목'), xmp.slice(0, 40));
}

// 구조 나무 · 글자 항목의 글꼴·세로쓰기
{
  const r = await load('struct.pdf');
  const e = r.ex;
  const S = (o, l) => (l > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.structTextPtr() + o, l)) : '');
  const roles = [];
  for (let i = 0; i < e.structCount(); i++) roles.push(S(e.structRoleOff(i), e.structRoleLen(i)));
  ok('구조 나무를 읽는다', roles.join(',') === 'Root,Document,H1,P', roles.join(','));
  ok('/S 가 /StructElem 에 안 걸린다', roles[1] === 'Document', roles[1]);
  ok('대체 글(UTF-16)', S(e.structAltOff(2), e.structAltLen(2)) === '문서 제목', S(e.structAltOff(2), e.structAltLen(2)));
  ok('마디가 놓인 쪽', e.structPageOf(2) === 0, e.structPageOf(2));
  ok('본문 표식(MCID)', e.structMcid(2) === 0 && e.structMcid(3) === 1, [e.structMcid(2), e.structMcid(3)]);
}
{
  const r = await load('korean.pdf');
  ok('글자 덩이에 글꼴 번호가 붙는다', r.ex.itemFont(0) > 0, r.ex.itemFont(0));
}
{
  const r = await load('vert.pdf');
  let any = false;
  for (let i = 0; i < r.ex.itemCount(); i++) if (r.ex.itemVertical(i) === 1) any = true;
  ok('세로쓰기를 알아본다', any);
}

console.log(`  기능 단언 ${pass + fail}개 중 통과 ${pass}, 실패 ${fail}`);
if (bad.length) bad.forEach((b3) => console.log('    ✗ ' + b3));
process.exit(fail ? 1 : 0);
