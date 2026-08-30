// Adobe 의 "미리 정의된 CMap" 을 작은 이진 표로 굽는다.
//
// KSCms-UHC-H 같은 이름만 적힌 CMap 은 표가 PDF 안에 없다. 원본은 Adobe 가
// 내놓는 PostScript 문법 파일이라, 그대로 실으면 6.8MB 에 파서도 따로
// 필요하다. 여기서 필요한 것(코드 폭, 코드→CID)만 뽑아 이진으로 굽는다.
//
//   원본: https://github.com/adobe-type-tools/cmap-resources  (BSD 3-clause)
//   쓰는 법: node scripts/build-cmaps.mjs <cmap-resources 를 푼 경로>
//
// 결과는 cmaps/ 에 들어가고 커밋한다. 뷰어는 문서가 실제로 쓰는
// 이름만 그때그때 받아 간다.
import fs from 'node:fs';
import path from 'node:path';

const src = process.argv[2];
const OUT = path.join(import.meta.dirname, '../cmaps');
if (!src || !fs.existsSync(src)) {
  console.error('쓰는 법: node scripts/build-cmaps.mjs <cmap-resources 경로>');
  process.exit(1);
}

/** CMap 원본 하나를 읽는다. usecmap 은 부모를 펼쳐 넣는다. */
function parse(dir, name, seen = new Set()) {
  if (seen.has(name)) return null; // 고리
  seen.add(name);
  const p = path.join(dir, name);
  if (!fs.existsSync(p)) return null;
  const s = fs.readFileSync(p, 'latin1');

  let wmode = /\/WMode\s+(\d+)/.exec(s);
  wmode = wmode ? +wmode[1] : 0;

  let space = [], cid = [];
  const use = /\/([\w-]+)\s+usecmap/.exec(s);
  if (use) {
    const parent = parse(dir, use[1], seen);
    if (parent) { space = parent.space; cid = parent.cid; wmode = wmode || parent.wmode; }
  }

  const hex = (h) => parseInt(h, 16);
  // <lo> <hi>  — 코드 폭은 자릿수로 정해진다
  for (const blk of s.matchAll(/begincodespacerange([\s\S]*?)endcodespacerange/g))
    for (const m of blk[1].matchAll(/<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>/g))
      space.push({ bytes: m[1].length >> 1, lo: hex(m[1]), hi: hex(m[2]) });

  // <lo> <hi> cid
  for (const blk of s.matchAll(/begincidrange([\s\S]*?)endcidrange/g))
    for (const m of blk[1].matchAll(/<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(\d+)/g))
      cid.push({ lo: hex(m[1]), hi: hex(m[2]), cid: +m[3] });

  // <code> cid — 한 칸짜리는 폭 0 인 범위로 둔다
  for (const blk of s.matchAll(/begincidchar([\s\S]*?)endcidchar/g))
    for (const m of blk[1].matchAll(/<([0-9a-fA-F]+)>\s*(\d+)/g))
      cid.push({ lo: hex(m[1]), hi: hex(m[1]), cid: +m[2] });

  return { wmode, space, cid };
}

/**
 * 이진으로 굽는다. 리틀엔디언.
 *
 * 코드가 두 바이트 안에 들어가는 CMap 이 대부분이라, 그런 파일은 칸을
 * 절반으로 줄인다. 첫 바이트 뒤 'W' 자리가 어느 쪽인지 알려 준다.
 */
function pack(c) {
  // 붙어 있는 범위는 하나로 합친다
  const cr = [];
  for (const r of c.cid.sort((a, b) => a.lo - b.lo)) {
    const p = cr[cr.length - 1];
    if (p && r.lo === p.hi + 1 && r.cid === p.cid + (p.hi - p.lo) + 1) p.hi = r.hi;
    else cr.push({ ...r });
  }
  const sp = c.space;
  let max = 0;
  for (const r of cr) max = Math.max(max, r.hi);
  for (const r of sp) max = Math.max(max, r.hi);
  const wide = max > 0xffff;
  const rec = wide ? 10 : 6;
  const b = Buffer.alloc(9 + sp.length * (wide ? 9 : 5) + cr.length * rec);
  b.write('CM1', 0, 'latin1');
  b.writeUInt8(c.wmode, 3);
  b.writeUInt8(wide ? 1 : 0, 4);
  b.writeUInt16LE(sp.length, 5);
  b.writeUInt16LE(cr.length, 7);
  let o = 9;
  for (const r of sp) {
    b.writeUInt8(r.bytes, o);
    if (wide) { b.writeUInt32LE(r.lo, o + 1); b.writeUInt32LE(r.hi, o + 5); o += 9; }
    else { b.writeUInt16LE(r.lo, o + 1); b.writeUInt16LE(r.hi, o + 3); o += 5; }
  }
  for (const r of cr) {
    const cid = Math.min(65535, r.cid);
    if (wide) { b.writeUInt32LE(r.lo, o); b.writeUInt32LE(r.hi, o + 4); b.writeUInt16LE(cid, o + 8); }
    else { b.writeUInt16LE(r.lo, o); b.writeUInt16LE(r.hi, o + 2); b.writeUInt16LE(cid, o + 4); }
    o += rec;
  }
  return b;
}

/**
 * CID → 유니코드 표.
 *
 * ToUnicode 가 없는 옛 문서는 이게 없으면 글자를 복사할 수 없다. Adobe 가
 * 따로 주는 표가 있지만, Uni*-UCS2-H(유니코드→CID)를 뒤집으면 같은 것이
 * 나온다. CID 로 바로 찾도록 평평한 배열로 둔다.
 */
function packUcs2(c) {
  let max = 0;
  for (const r of c.cid) max = Math.max(max, r.cid + (r.hi - r.lo));
  const b = Buffer.alloc(4 + (max + 1) * 2);
  b.write('CU1', 0, 'latin1');
  for (const r of c.cid) {
    if (r.lo > 0xffff) continue; // 서러게이트 짝은 건너뛴다
    for (let u = r.lo; u <= r.hi && u <= 0xffff; u++) {
      const id = r.cid + (u - r.lo);
      if (id <= max && b.readUInt16LE(4 + id * 2) === 0) b.writeUInt16LE(u, 4 + id * 2);
    }
  }
  return b;
}

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

const REG = fs.readdirSync(src).filter((d) => /^Adobe-/.test(d));
const list = [];
let total = 0;
for (const reg of REG) {
  const dir = path.join(src, reg, 'CMap');
  if (!fs.existsSync(dir)) continue;
  const ord = reg.replace(/^Adobe-/, '').replace(/-\d+$/, '');
  for (const name of fs.readdirSync(dir)) {
    const c = parse(dir, name);
    if (!c || (!c.cid.length && !c.space.length)) continue;
    const b = pack(c);
    fs.writeFileSync(path.join(OUT, name + '.bin'), b);
    list.push(name);
    total += b.length;
  }
  // 이 계열의 CID → 유니코드
  const uni = fs.readdirSync(dir).find((n) => /^Uni.*-UCS2-H$/.test(n)) ||
              fs.readdirSync(dir).find((n) => /^Uni.*-UTF16-H$/.test(n));
  if (uni) {
    const b = packUcs2(parse(dir, uni));
    fs.writeFileSync(path.join(OUT, ord + '-UCS2.bin'), b);
    list.push(ord + '-UCS2');
    total += b.length;
  }
}

fs.writeFileSync(path.join(OUT, 'index.json'), JSON.stringify(list.sort()));
console.log(`CMap ${list.length}개, ${(total / 1024).toFixed(0)}KB → public/cmaps/`);
