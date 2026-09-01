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

const [baseFile, newFile, dirArg] = process.argv.slice(2);
const S = dirArg ?? 'tests/fixtures';
const dec = new TextDecoder();
const stub = () => new Proxy({}, { get: () => () => 0 });

const mods = {
  base: await WebAssembly.compile(fs.readFileSync(baseFile)),
  now: await WebAssembly.compile(fs.readFileSync(newFile)),
};

/** 한 문서에서 꺼낼 수 있는 것을 전부 꺼내 문자열로 만든다 */
async function snap(mod, file) {
  const m = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: stub() });
  const e = m.exports;
  const buf = fs.readFileSync(`${S}/${file}`);
  const out = [];
  const put = (k, v) => out.push(`${k}=${v}`);
  if (!e.reserve(buf.length, buf.length * 3 + 201326592)) return 'reserve 실패';
  new Uint8Array(e.memory.buffer, e.inputPtr(), buf.length).set(buf);
  const okd = e.parse(buf.length);
  put('parse', okd);
  if (!okd) return out.join('\n');
  // 미리 정의된 CMap — 화면 쪽이 하는 일을 그대로 한다
  if (e.needCount) {
    const names = [];
    e.cmapReset();
    for (let i = 0; i < e.needCount(); i++) {
      const nm = dec.decode(new Uint8Array(e.memory.buffer, e.needPtr() + e.needOff(i), e.needLen(i)));
      names.push(nm);
      const f = `cmaps/${nm}.bin`;
      if (!fs.existsSync(f)) continue;
      const b = fs.readFileSync(f);
      if (b.length > e.cmapRoom()) continue;
      const cmapAt1 = e.cmapPtr();
      new Uint8Array(e.memory.buffer, cmapAt1, b.length).set(b);
      e.cmapAdd(i, b.length);
    }
    put('cmap필요', names.join(','));
  }
  const str = (ptr, off, len) => (len > 0 ? dec.decode(new Uint8Array(e.memory.buffer, ptr + off, len)) : '');
  put('쪽수', e.pageCount());
  put('잘림', e.pagesTruncated?.() ?? 0);
  put('암호', `${e.isEncrypted?.() ?? 0}/${e.needPassword?.() ?? 0}/${e.permissions?.() ?? 0}`);
  put('XFA', e.isXfa?.() ?? 0);
  for (let i = 0; i < (e.outlineCount?.() ?? 0); i++)
    put(`목차${i}`, `${e.outlineDepth(i)}:${e.outlinePage(i)}:${str(e.outlineTextPtr(), e.outlineOff(i), e.outlineLen(i))}`);
  for (let i = 0; i < (e.infoCount?.() ?? 0); i++)
    put(`정보${i}`, str(e.infoTextPtr(), e.infoOff(i), e.infoLen(i)));
  for (let i = 0; i < (e.metaCount?.() ?? 0); i++)
    put(`메타${i}`, str(e.metaTextPtr(), e.metaOff(i), e.metaLen(i)));
  for (let i = 0; i < (e.pageLabelCount?.() ?? 0); i++)
    put(`라벨${i}`, str(e.pageLabelPtr(), e.pageLabelOff(i), e.pageLabelLen(i)));
  for (let i = 0; i < (e.destCount?.() ?? 0); i++)
    put(`목적지${i}`, `${e.destPageOf(i)}:${str(e.destTextPtr(), e.destNameOff(i), e.destNameLen(i))}`);
  for (let i = 0; i < (e.viewPrefCount?.() ?? 0); i++)
    put(`뷰어설정${i}`, `${str(e.viewPrefTextPtr(), e.viewPrefKeyOff(i), e.viewPrefKeyLen(i))}=${str(e.viewPrefTextPtr(), e.viewPrefValOff(i), e.viewPrefValLen(i))}`);
  put('XMP', e.xmpLen?.() ?? 0);
  for (let i = 0; i < (e.structCount?.() ?? 0); i++)
    put(`구조${i}`, `${e.structDepth(i)}:${e.structPageOf(i)}:${e.structMcid(i)}:${str(e.structTextPtr(), e.structRoleOff(i), e.structRoleLen(i))}:${str(e.structTextPtr(), e.structAltOff(i), e.structAltLen(i))}`);
  for (let i = 0; i < (e.attCount?.() ?? 0); i++)
    put(`붙임${i}`, str(e.attTextPtr(), e.attNameOff(i), e.attNameLen(i)));
  for (let i = 0; i < (e.ocCount?.() ?? 0); i++)
    put(`레이어${i}`, `${e.ocIsOn(i)}:${str(e.ocTextPtr(), e.ocNameOff(i), e.ocNameLen(i))}`);
  for (let i = 0; i < (e.sigCount?.() ?? 0); i++)
    put(`서명${i}`, `${e.sigObj(i)}:${e.sigCovers(i)}:${e.sigDerLen(i)}:${str(e.sigTextPtr(), e.sigNameOff(i), e.sigNameLen(i))}:${str(e.sigTextPtr(), e.sigDateOff(i), e.sigDateLen(i))}`);
  // 쪽마다 — 많으면 앞뒤로 스무 쪽씩만 본다(값이 너무 든다)
  const n = e.pageCount();
  const pages = n <= 40 ? [...Array(n).keys()] : [...Array(20).keys(), ...Array(20).keys()].map((k, i) => (i < 20 ? k : n - 20 + (k)));
  for (const p of pages) {
    e.renderPage(p);
    put(`p${p}크기`, `${e.pageWidth()}x${e.pageHeight()}@${e.pageOriginX()},${e.pageOriginY()}r${e.pageRotate()}`);
    put(`p${p}글자`, dec.decode(new Uint8Array(e.memory.buffer, e.textPtr(), e.textLen())));
    put(`p${p}그림`, `${e.imageCount()}/${e.formCount()}/${e.imageSlots?.() ?? 0}`);
    const ops = new Float32Array(e.memory.buffer, e.opsPtr(), e.opsLen());
    let h = 2166136261;
    for (let i = 0; i < ops.length; i++) { h = ((h ^ (Math.round(ops[i] * 1000) | 0)) * 16777619) >>> 0; }
    put(`p${p}명령`, `${ops.length}:${h.toString(36)}`);
    for (let i = 0; i < e.itemCount(); i++)
      put(`p${p}덩이${i}`, `${e.itemX(i)},${e.itemY(i)},${e.itemSize(i)},${e.itemFont?.(i) ?? 0},${e.itemVertical?.(i) ?? 0},${str(e.textPtr(), e.itemOff(i), e.itemLen(i))}`);
    for (let i = 0; i < (e.fontCount?.() ?? 0); i++)
      put(`p${p}글꼴${i}`, `${e.fontKind(i)}:${e.fontIsPua(i)}:${e.fontGlyphs?.(i) ?? 0}:${e.fontFileLen?.(i) ?? 0}:${str(e.fontNamePtr(), 0, e.fontNameLen(i))}`);
    for (let i = 0; i < (e.linkCount?.() ?? 0); i++)
      put(`p${p}링크${i}`, `${[0, 1, 2, 3].map((k) => e.linkRect(i, k)).join(',')}:${e.linkPage(i)}:${str(e.linkTextPtr(), e.linkOff(i), e.linkLen(i))}`);
    for (let i = 0; i < (e.fieldCount?.() ?? 0); i++)
      put(`p${p}칸${i}`, `${e.fieldObj(i)}:${e.fieldKind(i)}:${e.fieldFlags(i)}:${e.fieldChecked(i)}:${[0, 1, 2, 3].map((k) => e.fieldRect(i, k)).join(',')}:${str(e.fieldTextPtr(), e.fieldNameOff(i), e.fieldNameLen(i))}=${str(e.fieldTextPtr(), e.fieldValOff(i), e.fieldValLen(i))}`);
    for (let i = 0; i < (e.annCount?.() ?? 0); i++)
      put(`p${p}주석${i}`, `${e.annObj(i)}:${e.annFlags(i)}:${[0, 1, 2, 3].map((k) => e.annRect(i, k)).join(',')}:${str(e.annTextPtr(), e.annSubOff(i), e.annSubLen(i))}:${str(e.annTextPtr(), e.annBodyOff(i), e.annBodyLen(i))}`);
  }
  return out.join('\n');
}

const files = fs.readdirSync(S).filter((f) => f.endsWith('.pdf')).sort();
let same = 0;
const diffs = [];
for (const f of files) {
  let a, b;
  try { a = await snap(mods.base, f); } catch (e2) { a = `던짐: ${e2.message}`; }
  try { b = await snap(mods.now, f); } catch (e2) { b = `던짐: ${e2.message}`; }
  if (a === b) { same++; continue; }
  const la = a.split('\n'), lb = b.split('\n');
  const at = la.findIndex((x, i) => x !== lb[i]);
  diffs.push(`${f}\n    전: ${(la[at] ?? '(없음)').slice(0, 110)}\n    후: ${(lb[at] ?? '(없음)').slice(0, 110)}`);
}
console.log(`A/B  견본 ${files.length}개 중 같음 ${same}, 다름 ${diffs.length}`);
for (const d of diffs.slice(0, 12)) console.log('  ' + d);
process.exit(diffs.length === 0 ? 0 : 1);
