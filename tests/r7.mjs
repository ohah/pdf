// 이번에 만든 것만 겨냥한다 — CMap 표, CIDToGIDMap, 라벨, 줄 묶기.
import fs from 'fs';
import { run } from './adv.mjs';
const S = process.argv[2];
console.log('7회차 — CMap 표·CIDToGIDMap·라벨·줄 묶기');

const cm2 = fs.readFileSync(S + '/cmap2.pdf');
const c2g = fs.readFileSync(S + '/c2g.pdf');
const cff = fs.readFileSync(S + '/cff.pdf');
const good = fs.readFileSync('cmaps/KSCms-UHC-H.bin');
const ucs2 = fs.readFileSync('cmaps/Korea1-UCS2.bin');
const feed = (ex, idx, bytes) => {
  const room = ex.cmapRoom();
  if (bytes.length > room) return 0;
  new Uint8Array(ex.memory.buffer, ex.cmapPtr(), bytes.length).set(bytes);
  return ex.cmapAdd(idx, bytes.length);
};

// --- 표를 넣는 쪽을 괴롭힌다
await run('표 자리 넘게 넣기', cm2, null, (ex) => {
  ex.cmapReset();
  // 2MB 자리에 크게 여러 번 — 넘치면 거절해야 한다
  const big = Buffer.alloc(900 * 1024);
  big.write('CM1', 0, 'latin1');
  for (let i = 0; i < 10; i++) feed(ex, 0, big);
});
await run('표 개수 넘게 넣기', cm2, null, (ex) => {
  ex.cmapReset();
  for (let i = 0; i < 50; i++) feed(ex, i % 2, good);
});
await run('표 목록 밖 번호로 등록', cm2, null, (ex) => {
  ex.cmapReset();
  for (const i of [2, 15, 16, 100, 4294967295]) feed(ex, i, good);
});
await run('표 두 번 같은 이름', cm2, null, (ex) => {
  ex.cmapReset();
  feed(ex, 0, good); feed(ex, 0, good); feed(ex, 1, ucs2); feed(ex, 1, ucs2);
});
await run('UCS2 표를 CMap 자리에', cm2, null, (ex) => {
  ex.cmapReset(); feed(ex, 0, ucs2); feed(ex, 1, good);
});
await run('CMap 표를 UCS2 자리에', cm2, null, (ex) => {
  ex.cmapReset(); feed(ex, 0, good); feed(ex, 1, good);
});
await run('표 범위 뒤집힘', cm2, null, (ex) => {
  const b = Buffer.from(good);
  // 첫 cidrange 의 시작을 끝보다 크게
  const ns = b.readUInt16LE(5);
  const cr = 9 + ns * 5;
  b.writeUInt16LE(0xffff, cr); b.writeUInt16LE(0, cr + 2);
  ex.cmapReset(); feed(ex, 0, b);
});
await run('표 codespace 0바이트', cm2, null, (ex) => {
  const b = Buffer.from(good);
  b.writeUInt8(0, 9); b.writeUInt8(9, 14);
  ex.cmapReset(); feed(ex, 0, b);
});
await run('표 reset 없이 계속', cm2, null, (ex) => {
  for (let i = 0; i < 30; i++) feed(ex, 0, good);
});
await run('cmapReset 만 반복', cm2, null, (ex) => {
  for (let i = 0; i < 1000; i++) ex.cmapReset();
});

// --- 이름을 모으는 쪽
const many = (n, key, val) => {
  let s = '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  s += '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n';
  s += '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] >>\nendobj\n';
  s += '4 0 obj\n<< ';
  for (let i = 0; i < n; i++) s += `${key} ${val(i)} `;
  s += '>>\nendobj\ntrailer\n<< /Size 5 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s, 'latin1');
};
await run('/Encoding 이름 5만개', many(50000, '/Encoding', (i) => `/Name${i}`));
await run('/Ordering 5만개', many(50000, '/Ordering', (i) => `(Ord${i})`));
await run('/Encoding 이름 초장문', many(200, '/Encoding', () => '/' + 'X'.repeat(300)));
await run('/Ordering 안 닫힘', Buffer.from(
  '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n' +
  '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n' +
  '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] >>\nendobj\n' +
  '4 0 obj\n<< /Ordering (' + 'A'.repeat(5000) + '\ntrailer\n<< /Size 5 /Root 1 0 R >>\n%%EOF\n', 'latin1'));

// --- CIDToGIDMap
const c2gTw = (from, to) => Buffer.from(c2g.toString('latin1').replace(from, to), 'latin1');
await run('C2G 표가 2MB', (() => {
  const s = c2g.toString('latin1');
  const i = s.indexOf('8 0 obj');
  const j = s.indexOf('endobj', i) + 6;
  const big = 'A'.repeat(2 * 1024 * 1024);
  return Buffer.from(s.slice(0, i) + `8 0 obj\n<< /Length ${big.length} >>\nstream\n${big}\nendstream\nendobj` + s.slice(j), 'latin1');
})());
await run('C2G 표가 CID 하나만', c2gTw(/8 0 obj\n<<  \/Length \d+/, '8 0 obj\n<<  /Length 2'));
await run('C2G 여러 글꼴이 각자 표', (() => {
  // 같은 표를 가리키는 글꼴을 여러 개 둔다
  let s = c2g.toString('latin1');
  s = s.replace('/Font << /F1 4 0 R >>', '/Font << /F1 4 0 R /F2 4 0 R /F3 4 0 R /F4 4 0 R >>');
  s = s.replace('<000100020003> Tj ET', '<000100020003> Tj ET BT /F2 9 Tf <0001> Tj ET BT /F3 9 Tf <0001> Tj ET BT /F4 9 Tf <0001> Tj ET');
  return Buffer.from(s, 'latin1');
})());
await run('C2G 이름 Identity 아님', c2gTw('/CIDToGIDMap 8 0 R', '/CIDToGIDMap /Identity-Weird'));

// --- 라벨
const stamp = (label, src, fn) => run(label, src, null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels();
  fn(ex);
  ex.apply();
});
await stamp('라벨 모든 쪽에 가득', fs.readFileSync(S + '/korean.pdf'), (ex) => {
  for (let p = 0; p < 64; p++) {
    ex.addLabel(p % Math.max(1, ex.pageCount()), 10 + p, 700 - p, 12, 0, 0, 0);
    for (const ch of '글꼴') ex.addLabelChar(ch.codePointAt(0));
  }
});
await stamp('라벨 + 워터마크 같이', fs.readFileSync(S + '/korean.pdf'), (ex) => {
  ex.clearWatermark();
  for (const ch of '대외비') ex.addWatermarkChar(ch.codePointAt(0));
  ex.addLabel(0, 60, 700, 20, 1, 0, 0);
  for (const ch of '글꼴') ex.addLabelChar(ch.codePointAt(0));
});
await stamp('라벨 + 회전 같이', cff, (ex) => {
  ex.setRotate(90);
  ex.addLabel(0, 60, 700, 20, 0, 0, 1);
  for (const ch of 'ROT') ex.addLabelChar(ch.codePointAt(0));
});
await stamp('라벨 대리쌍 글자', cff, (ex) => {
  ex.addLabel(0, 10, 10, 12, 0, 0, 0);
  for (const c of [0x1f600, 0x10ffff, 0x110000, 0xd800, 0xdfff]) ex.addLabelChar(c);
});
await stamp('라벨 클리어 반복', cff, (ex) => {
  for (let i = 0; i < 1000; i++) { ex.clearLabels(); ex.addLabel(0, 10, 10, 12, 0, 0, 0); ex.addLabelChar(65); }
});
await stamp('라벨 색이 범위 밖', cff, (ex) => {
  ex.addLabel(0, 10, 10, 12, -5, 99, 0.5);
  for (const ch of 'CLR') ex.addLabelChar(ch.codePointAt(0));
});

// --- 셰이딩
const rnd = (n, seed = 7) => Buffer.from(Array.from({ length: n }, (_, i) => (i * seed * 2654435761) & 255));
const shTw = (file, from, to) =>
  Buffer.from(fs.readFileSync(S + '/' + file).toString('latin1').replace(from, to), 'latin1');
for (const f of ['sh4.pdf', 'sh5.pdf', 'sh6.pdf', 'sh7.pdf']) {
  const tag = f.slice(0, 3) + f[3];
  await run(`${tag} 좌표비트 0`, shTw(f, '/BitsPerCoordinate 16', '/BitsPerCoordinate 0'));
  await run(`${tag} 좌표비트 33`, shTw(f, '/BitsPerCoordinate 16', '/BitsPerCoordinate 33'));
  await run(`${tag} 성분비트 0`, shTw(f, '/BitsPerComponent 8', '/BitsPerComponent 0'));
  await run(`${tag} Decode 없음`, shTw(f, /\/Decode \[[^\]]*\]/, ''));
  await run(`${tag} Decode 짧음`, shTw(f, /\/Decode \[[^\]]*\]/, '/Decode [0 300]'));
  await run(`${tag} 형 8`, shTw(f, /\/ShadingType \d/, '/ShadingType 8'));
}
await run('sh5 줄 길이 0', shTw('sh5.pdf', '/VerticesPerRow 2', '/VerticesPerRow 0'));
await run('sh5 줄 길이 1', shTw('sh5.pdf', '/VerticesPerRow 2', '/VerticesPerRow 1'));
await run('sh5 줄 길이 10만', shTw('sh5.pdf', '/VerticesPerRow 2', '/VerticesPerRow 100000'));
await run('sh4 깃발 5', shTw('sh4.pdf', /stream\n\x00/, 'stream\n\x05'));
await run('sh6 깃발 9', shTw('sh6.pdf', /stream\n\x00/, 'stream\n\x09'));

// 그물 자리에 난수를 통째로
function meshRnd(type, extra, n) {
  const data = rnd(n);
  let s2 = '%PDF-1.4\n';
  const push = (i, b) => { s2 += `${i} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  push(3, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Shading << /Sh1 5 0 R >> >> /Contents 4 0 R >>');
  push(4, '<< /Length 30 >>\nstream\nq 0 0 300 200 re W n /Sh1 sh Q\nendstream');
  s2 += `5 0 obj\n<< /ShadingType ${type} /ColorSpace /DeviceRGB /BitsPerCoordinate 16 /BitsPerComponent 8 /BitsPerFlag 8 ${extra} /Decode [0 300 0 200 0 1 0 1 0 1] /Length ${data.length} >>\nstream\n`;
  return Buffer.concat([Buffer.from(s2, 'latin1'), data,
    Buffer.from('\nendstream\nendobj\ntrailer\n<< /Size 6 /Root 1 0 R >>\n%%EOF\n', 'latin1')]);
}
for (const [t, extra] of [[4, ''], [5, '/VerticesPerRow 8'], [6, ''], [7, '']]) {
  await run(`${t}형 난수 64KB`, meshRnd(t, extra, 65536));
  await run(`${t}형 자료 없음`, meshRnd(t, extra, 0));
  await run(`${t}형 자료 3바이트`, meshRnd(t, extra, 3));
}

// 표본 함수
const fnTw = (from, to) => shTw('fn0.pdf', from, to);
await run('표본 Size 0', fnTw('/Size [2]', '/Size [0]'));
await run('표본 Size 10만', fnTw('/Size [2]', '/Size [100000]'));
await run('표본 비트 0', fnTw('/BitsPerSample 8', '/BitsPerSample 0'));
await run('표본 비트 33', fnTw('/BitsPerSample 8', '/BitsPerSample 33'));
await run('표본 Range 없음', fnTw(/\/Range \[[^\]]*\]/, ''));
await run('표본 Range 홀수', fnTw(/\/Range \[[^\]]*\]/, '/Range [0 1 0]'));
await run('표본 자료 없음', fnTw(/\/Length \d+ >>\nstream\n[\s\S]{6}/, '/Length 0 >>\nstream\n'));

// --- JBIG2
const jbBase = fs.readFileSync(S + '/jb-sym.pdf');
const jbTw = (from, to) => Buffer.from(jbBase.toString('latin1').replace(from, to), 'latin1');
await run('JBIG2 크기 2만', jbTw(/\/Width \d+ \/Height \d+/, '/Width 20000 /Height 20000'));
await run('JBIG2 크기 0', jbTw(/\/Width \d+ \/Height \d+/, '/Width 0 /Height 0'));
await run('JBIG2 크기 어긋남', jbTw(/\/Width \d+ \/Height \d+/, '/Width 7 /Height 9999'));
await run('JBIG2 globals 없는 객체', jbTw('/JBIG2Decode', '/JBIG2Decode /DecodeParms << /JBIG2Globals 99 0 R >>'));
await run('JBIG2 globals 가 자기 자신', jbTw('/JBIG2Decode', '/JBIG2Decode /DecodeParms << /JBIG2Globals 5 0 R >>'));

// 흐름을 통째로 갈아 끼운다
function jbDoc(data, w = 64, h = 56) {
  const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
  const st = (d, x) => Buffer.concat([B(`<< ${x} /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
  const objs = [
    B('<< /Type /Catalog /Pages 2 0 R >>'),
    B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    B('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] /Resources << /XObject << /I 5 0 R >> >> /Contents 4 0 R >>'),
    st(B('q 99 0 0 99 0 0 cm /I Do Q'), ''),
    st(data, `/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode`),
  ];
  let out = B('%PDF-1.4\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), objs[i], B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}
const jbRnd = (n, seed) => Buffer.from(Array.from({ length: n }, (_, i) => ((i + 1) * seed * 2654435761) >>> 8 & 255));
await run('JBIG2 난수 1KB', jbDoc(jbRnd(1024, 3)));
await run('JBIG2 난수 64KB', jbDoc(jbRnd(65536, 5)));
await run('JBIG2 자료 없음', jbDoc(Buffer.alloc(0)));
await run('JBIG2 0 만 가득', jbDoc(Buffer.alloc(4096)));
await run('JBIG2 FF 만 가득', jbDoc(Buffer.alloc(4096, 0xff)));

/** 세그먼트 하나를 직접 짓는다 */
function seg(num, kind, body, page = 1) {
  const h = Buffer.alloc(11);
  h.writeUInt32BE(num, 0);
  h[4] = kind;
  h[5] = 0; // 참조 없음
  h[6] = page;
  h.writeUInt32BE(body.length, 7);
  return Buffer.concat([h, body]);
}
const regionInfo = (w, h, x, y, op = 0) => {
  const b = Buffer.alloc(17);
  b.writeUInt32BE(w, 0); b.writeUInt32BE(h, 4); b.writeUInt32BE(x, 8); b.writeUInt32BE(y, 12); b[16] = op;
  return b;
};
// 거대한 영역을 여러 개 — 예산이 막아야 한다
await run('JBIG2 거대 영역 200개', jbDoc(Buffer.concat(
  Array.from({ length: 200 }, (_, i) => seg(i, 38, Buffer.concat([
    regionInfo(4000, 4000, 0, 0), Buffer.from([0]), Buffer.alloc(8), jbRnd(64, i + 1)]))))));
await run('JBIG2 영역 크기 40억', jbDoc(seg(0, 38, Buffer.concat([
  regionInfo(0xffffffff, 0xffffffff, 0, 0), Buffer.from([0]), Buffer.alloc(8), jbRnd(64, 9)]))));
await run('JBIG2 영역 자리 음수쪽', jbDoc(seg(0, 38, Buffer.concat([
  regionInfo(40, 40, 0xfffffff0, 0xfffffff0), Buffer.from([0]), Buffer.alloc(8), jbRnd(64, 9)]))));
await run('JBIG2 길이 모름', jbDoc((() => {
  const b = seg(0, 38, Buffer.concat([regionInfo(40, 40, 0, 0), Buffer.from([0]), Buffer.alloc(8), jbRnd(64, 2)]));
  b.writeUInt32BE(0xffffffff, 7); return b; })()));
await run('JBIG2 참조 긴 꼴', jbDoc((() => {
  const h = Buffer.alloc(16);
  h.writeUInt32BE(0, 0); h[4] = 38; h.writeUInt32BE((0xe0000000 | 100000) >>> 0, 5);
  return Buffer.concat([h, jbRnd(64, 4)]); })()));
await run('JBIG2 MMR 난수', jbDoc(seg(0, 38, Buffer.concat([
  regionInfo(64, 56, 0, 0), Buffer.from([1]), jbRnd(512, 6)]))));
for (const t of [0, 1, 2, 3]) {
  await run(`JBIG2 틀 ${t} 난수`, jbDoc(seg(0, 38, Buffer.concat([
    regionInfo(64, 56, 0, 0), Buffer.from([(t << 1) | 8]),
    Buffer.alloc(t === 0 ? 8 : 2, 0x7f), jbRnd(512, t + 1)]))));
}
await run('JBIG2 사전 글자 40억', jbDoc(seg(0, 0, Buffer.concat([
  Buffer.from([0, 0]), Buffer.alloc(8),
  (() => { const b = Buffer.alloc(8); b.writeUInt32BE(0xffffffff, 0); b.writeUInt32BE(0xffffffff, 4); return b; })(),
  jbRnd(256, 7)]))));
await run('JBIG2 글자영역 인스턴스 40억', jbDoc(seg(0, 6, Buffer.concat([
  regionInfo(64, 56, 0, 0), Buffer.from([0, 0]),
  (() => { const b = Buffer.alloc(4); b.writeUInt32BE(0xffffffff, 0); return b; })(),
  jbRnd(256, 8)]))));
// 쪽만 한 영역을 여러 개 — 예산이 막아야 한다
await run('JBIG2 쪽만 한 영역 40개', jbDoc(Buffer.concat(
  Array.from({ length: 40 }, (_, i) => seg(i, 38, Buffer.concat([
    regionInfo(2000, 2000, 0, 0), Buffer.from([0]), Buffer.alloc(8), jbRnd(4096, i + 1)])))),
  2000, 2000));
await run('JBIG2 글자 사전 난수 64KB', jbDoc(seg(0, 0, Buffer.concat([
  Buffer.from([0, 0]), Buffer.alloc(8),
  (() => { const b = Buffer.alloc(8); b.writeUInt32BE(4000, 0); b.writeUInt32BE(4000, 4); return b; })(),
  jbRnd(65536, 11)]))));

// --- 부드러운 가리개·글자 오려 내기
const smTw = (from, to) => Buffer.from(fs.readFileSync(S + '/smask.pdf').toString('latin1').replace(from, to), 'latin1');
await run('SMask 없는 객체', smTw('/G 6 0 R', '/G 999 0 R'));
await run('SMask 자기 자신', smTw('/G 6 0 R', '/G 5 0 R'));
await run('SMask 가 쪽을 가리킴', smTw('/G 6 0 R', '/G 3 0 R'));
await run('SMask /G 없음', smTw('/G 6 0 R', ''));
await run('SMask /S /Alpha', smTw('/S /Luminosity', '/S /Alpha'));
await run('SMask BC 이상', smTw('/BC [0]', '/BC [9 -9 1e30 0 0 0 0 0]'));
await run('SMask BBox 거대', smTw('/BBox [0 0 300 200]', '/BBox [-1e9 -1e9 1e9 1e9]'));
await run('SMask Matrix 이상', smTw('/BBox [0 0 300 200]', '/BBox [0 0 300 200] /Matrix [1e20 0 0 1e20 0 0]'));
const trTw = (from, to) => Buffer.from(fs.readFileSync(S + '/trclip.pdf').toString('latin1').replace(from, to), 'latin1');
for (const m of [4, 5, 6, 7, 8, 99, -1]) await run(`Tr ${m}`, trTw('7 Tr', `${m} Tr`));
await run('Tr 오려 내고 ET 없음', trTw(/ET 1 0 0 rg/, '1 0 0 rg'));
await run('Tr BT 만 잔뜩', Buffer.from(
  fs.readFileSync(S + '/trclip.pdf').toString('latin1').replace('q BT 7 Tr', 'q ' + 'BT 7 Tr ET '.repeat(200) + 'BT 7 Tr'), 'latin1'));

// --- JBIG2 나머지 갈래
for (const f of ['jb-page1.pdf', 'jb-page2.pdf', 'jb-refine.pdf', 'jb-half.pdf', 'jb-halfmmr.pdf']) {
  const src = fs.readFileSync(S + '/' + f);
  await run(`${f} 그대로`, src);
  // 그림 자료를 조금씩 망가뜨린다
  for (const [nm, mk] of [
    ['앞 자름', (b) => b.subarray(0, Math.floor(b.length * 0.6))],
    ['뒤 자름', (b) => Buffer.concat([b.subarray(0, 200), b.subarray(Math.floor(b.length * 0.9))])],
    ['비트 뒤집기', (b) => { const c = Buffer.from(b); for (let i = 300; i < c.length; i += 37) c[i] ^= 0x5a; return c; }],
  ]) await run(`${f} ${nm}`, mk(src));
}
// 허프만 표를 고른 값을 이상하게
const p1 = fs.readFileSync(S + '/jb-page1.pdf');
await run('JBIG2 허프만 사전 표 3', (() => {
  const c = Buffer.from(p1); // 사전 flags 의 표 고르기 비트를 들쑤신다
  for (let i = 0; i < c.length - 1; i++) if (c[i] === 0 && c[i + 1] === 1) { c[i + 1] = 0x3f; break; }
  return c; })());
await run('JBIG2 무늬 사전 gmax 40억', (() => {
  const c = Buffer.from(fs.readFileSync(S + '/jb-half.pdf'));
  return c; })());

// --- JPEG 2000
const jpxNames = ['jpx-rgb', 'jpx-gray', 'jpx-53', 'jpx-tiny', 'jpx-tiles', 'jpx-prec', 'jpx-mct', 'jpx-layers'];
for (const nm of jpxNames) {
  const src = fs.readFileSync(`${S}/${nm}.pdf`);
  await run(`${nm} 그대로`, src);
  await run(`${nm} 앞 자름`, src.subarray(0, Math.floor(src.length * 0.7)));
  await run(`${nm} 비트 뒤집기`, (() => {
    const c = Buffer.from(src);
    for (let i = 400; i < c.length - 40; i += 29) c[i] ^= 0x33;
    return c; })());
}
// 표식을 망가뜨린다
const jr = fs.readFileSync(`${S}/jpx-rgb.pdf`).toString('latin1');
const jTw = (from, to) => Buffer.from(jr.replace(from, to), 'latin1');
await run('JPX 크기 어긋남', jTw('/Width 64 /Height 48', '/Width 4000 /Height 4000'));
await run('JPX 크기 0', jTw('/Width 64 /Height 48', '/Width 0 /Height 0'));
// 코드스트림 표식 자체를 흔든다
function jpxRaw(bytes, w = 64, h = 48) {
  const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));
  const st = (d, x) => Buffer.concat([B(`<< ${x} /Length ${d.length} >>\nstream\n`), d, B('\nendstream')]);
  const objs = [B('<< /Type /Catalog /Pages 2 0 R >>'), B('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    B(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << /XObject << /I 5 0 R >> >> /Contents 4 0 R >>`),
    st(B(`q ${w} 0 0 ${h} 0 0 cm /I Do Q`), ''),
    st(bytes, `/Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode`)];
  let out = B('%PDF-1.5\n'); const offs = [];
  for (let i = 0; i < objs.length; i++) { offs.push(out.length); out = Buffer.concat([out, B(`${i+1} 0 obj\n`), objs[i], B('\nendobj\n')]); }
  let x = `xref\n0 ${objs.length+1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10,'0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length+1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}
const rnd2 = (n, seed) => Buffer.from(Array.from({ length: n }, (_, i) => ((i + 3) * seed * 2654435761) >>> 11 & 255));
await run('JPX 난수 4KB', jpxRaw(rnd2(4096, 3)));
await run('JPX 자료 없음', jpxRaw(Buffer.alloc(0)));
await run('JPX SOC 만', jpxRaw(Buffer.from([0xff, 0x4f])));
await run('JPX SIZ 거대', jpxRaw((() => {
  const b = Buffer.alloc(2 + 2 + 45);
  b.writeUInt16BE(0xff4f, 0); b.writeUInt16BE(0xff51, 2); b.writeUInt16BE(47, 4);
  b.writeUInt32BE(0x7fffffff, 8); b.writeUInt32BE(0x7fffffff, 12);
  b.writeUInt16BE(3, 40);
  return b; })()));
await run('JPX 성분 300개', jpxRaw((() => {
  const b = Buffer.alloc(2 + 2 + 45);
  b.writeUInt16BE(0xff4f, 0); b.writeUInt16BE(0xff51, 2); b.writeUInt16BE(47, 4);
  b.writeUInt32BE(64, 8); b.writeUInt32BE(48, 12);
  b.writeUInt16BE(300, 40);
  return b; })()));

// --- 계산기 함수
const f4 = fs.readFileSync(S + '/fn4.pdf').toString('latin1');
const f4Tw = (to) => Buffer.from(f4.replace('{ dup 1 exch sub 0.5 }', to), 'latin1');
for (const [nm, prog] of [
  ['빈 프로그램', '{ }'],
  ['괄호 안 닫힘', '{ dup 1 exch sub'],
  ['괄호만 잔뜩', '{'.repeat(200) + '}'.repeat(200)],
  ['스택 비우기', '{ pop pop pop pop pop }'],
  ['0 으로 나누기', '{ 1 0 div 0 0 div 0.5 }'],
  ['음수 제곱근', '{ -1 sqrt -1 ln 0.5 }'],
  ['거대한 지수', '{ 10 300 exp 2 -300 exp 0.5 }'],
  ['깊은 ifelse', '{ 1 { 1 { 1 { 1 { 0.5 0.5 0.5 } if } if } if } if }'],
  ['roll 이상', '{ dup dup 99 -99 roll 0.5 }'],
  ['index 이상', '{ 999 index 0 0 }'],
  ['copy 이상', '{ 999 copy }'],
  ['알 수 없는 낱말', '{ frobnicate 0.5 0.5 0.5 }'],
  ['숫자만 잔뜩', '{ ' + Array.from({ length: 500 }, (_, i) => i / 500).join(' ') + ' }'],
]) await run(`계산기 ${nm}`, f4Tw(prog));
const fa = fs.readFileSync(S + '/fnarr.pdf').toString('latin1');
await run('함수 배열 하나만', Buffer.from(fa.replace('[6 0 R 7 0 R 8 0 R]', '[6 0 R]'), 'latin1'));
await run('함수 배열 열 개', Buffer.from(fa.replace('[6 0 R 7 0 R 8 0 R]', '[6 0 R '.repeat(10) + ']'), 'latin1'));
await run('함수 배열 없는 객체', Buffer.from(fa.replace('[6 0 R 7 0 R 8 0 R]', '[99 0 R 98 0 R]'), 'latin1'));
await run('함수 배열 빈 것', Buffer.from(fa.replace('[6 0 R 7 0 R 8 0 R]', '[]'), 'latin1'));

// --- 표시 내용(BDC)과 인코딩
const mc = fs.readFileSync(S + '/mcid.pdf').toString('latin1');
const mcTw = (from, to) => Buffer.from(mc.replace(from, to), 'latin1');
await run('BDC 딕셔너리 깊게', mcTw('<</MCID 299 >>', '<<'.repeat(60) + '/MCID 299' + '>>'.repeat(60)));
await run('BDC 딕셔너리 안 닫힘', mcTw('<</MCID 299 >>', '<</MCID 299'));
await run('BDC 홑 꺾쇠', mcTw('<</MCID 299 >>', '< /MCID 299 >'));
await run('BDC 16진 문자열', mcTw('<</MCID 299 >>', '<48454C4C4F>'));
await run('Differences 이름 이상', mcTw('[68 /A /B /C]', '[68 /uni0041 /uniZZZZ /g5 /notdef /Aacute /zzz]'));
await run('Differences 코드 40억', mcTw('[68 /A /B /C]', '[4294967295 /A /B /C]'));
await run('Differences 빈 것', mcTw('[68 /A /B /C]', '[]'));
await run('Differences 이름만', mcTw('[68 /A /B /C]', '[/A /B /C]'));
await run('Encoding 이상한 이름', mcTw('/BaseEncoding /WinAnsiEncoding', '/BaseEncoding /NoSuchEncoding'));

// --- 입력 칸
const fm = fs.readFileSync(S + '/form.pdf');
const fmS = fm.toString('latin1');
const fmTw = (from, to) => Buffer.from(fmS.replace(from, to), 'latin1');
await run('양식 그대로', fm);
await run('양식 Rect 없음', fmTw('/Rect [20 160 200 180]', ''));
await run('양식 Rect 뒤집힘', fmTw('/Rect [20 160 200 180]', '/Rect [200 180 20 160]'));
await run('양식 Rect 거대', fmTw('/Rect [20 160 200 180]', '/Rect [-1e9 -1e9 1e9 1e9]'));
await run('양식 FT 없음', fmTw('/FT /Tx /T (name)', '/T (name)'));
await run('양식 FT 이상', fmTw('/FT /Tx /T (name)', '/FT /Zz /T (name)'));
await run('양식 Ff 40억', fmTw('/Ff 4096', '/Ff 4294967295'));
await run('양식 MaxLen 40억', fmTw('/MaxLen 40', '/MaxLen 4294967295'));
await run('양식 Opt 200개', fmTw('/Opt [(a) (b) (c)]', '/Opt [' + '(x)'.repeat(400) + ']'));
await run('양식 값 아주 김', fmTw('/V (Mario)', '/V (' + 'A'.repeat(9000) + ')'));
await run('양식 값 UTF-16', fmTw('/V (Mario)', '/V <FEFF0041AC00D55CAE00>'));
await run('양식 Parent 고리', fmTw('/FT /Tx /T (name)', '/FT /Tx /T (name) /Parent 5 0 R'));
await run('양식 Annots 자기참조', fmTw('/Annots [5 0 R 6 0 R 7 0 R 8 0 R]', '/Annots [3 0 R 3 0 R]'));

// 채워 넣는 쪽
const fill = (label, fn) => run(label, fm, null, (ex) => {
  ex.setFormLayer(1);
  ex.renderPage(0);
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  fn(ex);
  ex.apply();
});
await fill('채우기 1000칸', (ex) => {
  for (let i = 0; i < 1000; i++) { ex.addFieldEdit(5, 0); ex.addFieldEditChar(65 + (i % 26)); }
});
await fill('채우기 없는 객체', (ex) => {
  ex.addFieldEdit(9999, 0);
  for (const ch of 'ghost') ex.addFieldEditChar(ch.codePointAt(0));
});
await fill('채우기 쪽을 가리킴', (ex) => {
  ex.addFieldEdit(3, 0);
  for (const ch of 'oops') ex.addFieldEditChar(ch.codePointAt(0));
});
await fill('채우기 10만 글자', (ex) => {
  ex.addFieldEdit(5, 0);
  for (let i = 0; i < 100000; i++) ex.addFieldEditChar(66);
});
await fill('채우기 제어문자', (ex) => {
  ex.addFieldEdit(5, 0);
  for (const c of [0, 9, 10, 13, 27, 40, 41, 92, 127, 0xac00, 0x1f600]) ex.addFieldEditChar(c);
});
await fill('채우기 갈래 이상', (ex) => {
  ex.addFieldEdit(5, 99);
  ex.addFieldEditChar(65);
});
await fill('채우기 값 없이', (ex) => { ex.addFieldEdit(5, 0); });

// --- 겉모습 그림
const maskFill = (label, w, h, len, fn) => run(label, fm, null, (ex) => {
  ex.setFormLayer(1);
  ex.renderPage(0);
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.addFieldEdit(5, 0);
  for (const ch of '한글값') ex.addFieldEditChar(ch.codePointAt(0));
  if (fn) fn(ex);
  ex.setFieldEditMask(w, h, len);
  ex.apply();
});
await maskFill('마스크 크기 0', 0, 0, 16);
await maskFill('마스크 길이 0', 64, 16, 0);
await maskFill('마스크 4만×4만', 40000, 40000, 128);
await maskFill('마스크 길이 40억', 64, 16, 4294967295);
await maskFill('마스크 길이가 크기와 안 맞음', 64, 16, 4);
await maskFill('마스크 1000개', 64, 16, 128, (ex) => {
  for (let i = 0; i < 1000; i++) {
    ex.addFieldEdit(5, 0);
    ex.addFieldEditChar(0xac00);
    ex.setFieldEditMask(64, 16, 128);
  }
});

// --- 쪽마다 회전
const rotFill = (label, fn) => run(label, fs.readFileSync(S + '/pdf/multi.pdf'), null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.clearPageRotate();
  fn(ex);
  ex.apply();
});
await rotFill('쪽 회전 40억쪽', (ex) => ex.setPageRotate(4000000000, 90));
await rotFill('쪽 회전 각도 이상', (ex) => { ex.setPageRotate(0, 47); ex.setPageRotate(1, -3600); ex.setPageRotate(2, 2147483647); });
await rotFill('쪽 회전 다 걸기', (ex) => { for (let i = 0; i < 4096; i++) ex.setPageRotate(i, 90); });
await rotFill('쪽 회전 지우고 다시', (ex) => {
  for (let i = 0; i < 100; i++) { ex.setPageRotate(i % 5, 90); ex.clearPageRotate(); }
  ex.setPageRotate(0, 180);
});

// --- 한글 라벨·워터마크 그림
const koFill = (label, fn) => run(label, fs.readFileSync(S + '/cff.pdf'), null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  fn(ex);
  ex.apply();
});
const kbits = (n) => new Uint8Array(n).fill(0x5a);
await koFill('라벨 그림 크기 0', (ex) => {
  ex.addLabel(0, 10, 10, 12, 0, 0, 0);
  ex.addLabelChar(0xac00);
  const b = kbits(16);
  const maskAt5 = ex.fieldMaskPtr();
  new Uint8Array(ex.memory.buffer, maskAt5, b.length).set(b);
  ex.setLabelMask(0, 0, b.length, 10, 10);
});
await koFill('라벨 그림 4만×4만', (ex) => {
  ex.addLabel(0, 10, 10, 12, 0, 0, 0);
  ex.addLabelChar(0xac00);
  const b = kbits(16);
  const maskAt6 = ex.fieldMaskPtr();
  new Uint8Array(ex.memory.buffer, maskAt6, b.length).set(b);
  ex.setLabelMask(40000, 40000, b.length, 10, 10);
});
await koFill('라벨 그림 64개', (ex) => {
  for (let i = 0; i < 64; i++) {
    ex.addLabel(0, 10 + i, 10 + i, 12, 0, 0, 0);
    ex.addLabelChar(0xac00);
    const b = kbits(64);
    const maskAt7 = ex.fieldMaskPtr();
    new Uint8Array(ex.memory.buffer, maskAt7, b.length).set(b);
    ex.setLabelMask(16, 16, b.length, 10, 10);
  }
});
await koFill('라벨 없이 그림만', (ex) => {
  const b = kbits(64);
  const maskAt8 = ex.fieldMaskPtr();
  new Uint8Array(ex.memory.buffer, maskAt8, b.length).set(b);
  ex.setLabelMask(16, 16, b.length, 10, 10);
});
await koFill('워터마크 그림 크기 0', (ex) => {
  ex.addWatermarkChar(0xac00);
  const b = kbits(16);
  const maskAt9 = ex.fieldMaskPtr();
  new Uint8Array(ex.memory.buffer, maskAt9, b.length).set(b);
  ex.setWatermarkMask(16, 16, b.length, 0, 0);
});
await koFill('워터마크 그림 놓을 크기 무한', (ex) => {
  ex.addWatermarkChar(0xac00);
  const b = kbits(16);
  const maskAt10 = ex.fieldMaskPtr();
  new Uint8Array(ex.memory.buffer, maskAt10, b.length).set(b);
  ex.setWatermarkMask(16, 16, b.length, 1e30, -1e30);
});

// --- 새로 다는 주석
const noteFill = (label, fn) => run(label, fs.readFileSync(S + '/cff.pdf'), null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.clearPageRotate(); ex.clearNotes();
  fn(ex);
  ex.apply();
});
await noteFill('주석 갈래 이상', (ex) => { for (const k of [7, 99, 4294967295]) ex.addNote(k, 0, 10, 10, 50, 50, 0, 0, 0); });
await noteFill('주석 자리 뒤집힘', (ex) => ex.addNote(3, 0, 200, 200, 10, 10, 0, 0, 0));
await noteFill('주석 자리 무한', (ex) => ex.addNote(3, 0, -1e30, -1e30, 1e30, 1e30, 0, 0, 0));
await noteFill('주석 색 범위 밖', (ex) => ex.addNote(0, 0, 10, 10, 50, 50, -5, 99, 0.5));
await noteFill('주석 없는 쪽', (ex) => ex.addNote(0, 4000000000, 10, 10, 50, 50, 0, 0, 0));
await noteFill('주석 1000개', (ex) => { for (let i = 0; i < 1000; i++) ex.addNote(i % 7, 0, 10, 10 + i, 50, 50 + i, 0, 0, 0); });
await noteFill('메모 글 10만자', (ex) => {
  ex.addNote(5, 0, 10, 10, 30, 30, 1, 1, 0);
  for (let i = 0; i < 100000; i++) ex.addNoteChar(0xac00);
});
await noteFill('자유선 점 10만', (ex) => {
  ex.addNote(6, 0, 10, 10, 300, 300, 0, 0, 1);
  for (let i = 0; i < 100000; i++) ex.addNotePoint(i % 300, (i * 7) % 300);
});
await noteFill('자유선 점 없이', (ex) => ex.addNote(6, 0, 10, 10, 300, 300, 0, 0, 1));
await noteFill('주석 없이 글자만', (ex) => { for (let i = 0; i < 100; i++) ex.addNoteChar(65); });
await noteFill('점만 넣기', (ex) => { for (let i = 0; i < 100; i++) ex.addNotePoint(1, 2); });

// --- 허프만 판 JBIG2 (문서가 실은 표 · 세밀화)
for (const f of ['jbh-tab.pdf', 'jbh-refagg.pdf', 'jbh-tref.pdf']) {
  const src = fs.readFileSync(S + '/' + f);
  await run(`${f} 그대로`, src);
  for (const [nm, mk] of [
    ['앞 자름', (b) => b.subarray(0, Math.floor(b.length * 0.7))],
    ['비트 뒤집기', (b) => { const c = Buffer.from(b); for (let i = 200; i < c.length; i += 13) c[i] ^= 0x5a; return c; }],
    ['표 길이 거대', (b) => {
      // 실어 온 표의 high 를 40억으로
      const c = Buffer.from(b);
      for (let i = 0; i < c.length - 9; i++) {
        if (c[i] === 53 && c[i + 5] === 0) { c.writeUInt32BE(0xfffffff0, i + 6); break; }
      }
      return c;
    }],
  ]) await run(`${f} ${nm}`, mk(src));
}

// --- 관심 구역이 걸린 JPEG 2000
for (const f of ['jpx-roi-high.pdf', 'jpx-roi-low.pdf']) {
  const src = fs.readFileSync(S + '/' + f);
  await run(`${f} 그대로`, src);
  await run(`${f} 올림값 255`, (() => {
    const c = Buffer.from(src);
    const at = c.indexOf(Buffer.from([0xff, 0x5e]));
    if (at > 0) c[at + 6] = 255;
    return c;
  })());
  await run(`${f} 성분 번호 이상`, (() => {
    const c = Buffer.from(src);
    const at = c.indexOf(Buffer.from([0xff, 0x5e]));
    if (at > 0) c[at + 4] = 200;
    return c;
  })());
}

// --- 전자 서명
for (const f of ['signed.pdf', 'signed-tampered.pdf']) {
  const src = fs.readFileSync(S + '/' + f);
  await run(`${f} 그대로`, src, (ex) => `서명${ex.sigCount()}`);
}
{
  const src = fs.readFileSync(S + '/signed.pdf').toString('latin1');
  const tw = (from, to) => run(`서명 ${to.slice(0, 20)}`, Buffer.from(src.replace(from, to), 'latin1'),
    (ex) => `서명${ex.sigCount()} 덮음${ex.sigCount() ? ex.sigCovers(0) : '-'}`);
  await tw(/\/ByteRange \[[^\]]*\]/, '/ByteRange [4294967295 4294967295 4294967295 4294967295]');
  await tw(/\/ByteRange \[[^\]]*\]/, '/ByteRange [0 0 0 0]');
  await tw(/\/ByteRange \[[^\]]*\]/, '/ByteRange []');
  await tw(/\/ByteRange \[[^\]]*\]/, '/ByteRange 3 0 R');
  await tw(/\/Contents <[0-9a-fA-F]*>/, '/Contents <>');
  await tw(/\/Contents <[0-9a-fA-F]*>/, '/Contents (날글자열)');
  await tw('/SubFilter /adbe.pkcs7.detached', '/SubFilter /' + 'x'.repeat(5000));
  await tw('/Name', '/Name'.repeat(300));
}

// --- 암호 걸기
const sealTry = (label, file, fn) => run(label, fs.readFileSync(S + '/' + file), null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels(); ex.clearFieldEdits();
  ex.clearPageRotate(); ex.clearNotes();
  ex.setEncrypt(1);
  fn(ex);
  ex.compact();
});
await sealTry('암호 없이 잠그기', 'cff.pdf', () => {});
await sealTry('암호 10만 자', 'cff.pdf', (ex) => {
  for (let i = 0; i < 100000; i++) ex.addEncryptChar(0xac00);
});
await sealTry('암호에 0 넣기', 'cff.pdf', (ex) => { for (let i = 0; i < 8; i++) ex.addEncryptChar(0); });
await sealTry('난수 안 채우고 잠그기', 'korean.pdf', () => {});
await sealTry('이미 잠긴 것 다시 잠그기', 'enc-aes256.pdf', (ex) => ex.addEncryptChar(65));
await sealTry('큰 문서 잠그기', 'pdf/scanned.pdf', (ex) => ex.addEncryptChar(65));
// 틀린 암호로 열어 보기
const pwTry = (label, file, pw) => run(label, fs.readFileSync(S + '/' + file), null, null);
await pwTry('암호 걸린 것 그냥 열기', 'enc-aes256.pdf');

// --- 입력 칸 이름 바꾸기·지우기·새로 만들기
const fldTry = (label, file, fn) => run(label, fs.readFileSync(S + '/' + file), null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels();
  ex.clearFieldEdits(); ex.clearNewFields(); ex.clearPageRotate(); ex.clearNotes();
  fn(ex);
  ex.apply();
});
await fldTry('칸 이름 10만 자', 'form.pdf', (ex) => {
  ex.addFieldEdit(5, 3);
  for (let i = 0; i < 100000; i++) ex.addFieldEditChar(0xac00);
});
await fldTry('칸 이름 빈 값', 'form.pdf', (ex) => ex.addFieldEdit(5, 3));
await fldTry('없는 칸 이름 바꾸기', 'form.pdf', (ex) => {
  ex.addFieldEdit(4294967295, 3);
  ex.addFieldEditChar(65);
});
await fldTry('모든 칸 지우기', 'form.pdf', (ex) => {
  for (const o of [5, 6, 7, 8]) ex.addFieldEdit(o, 4);
});
await fldTry('없는 칸 지우기', 'form.pdf', (ex) => ex.addFieldEdit(999999, 4));
await fldTry('같은 칸 여러 번 지우기', 'form.pdf', (ex) => {
  for (let i = 0; i < 100; i++) ex.addFieldEdit(5, 4);
});
await fldTry('지우고 이름도 바꾸기', 'form.pdf', (ex) => {
  ex.addFieldEdit(5, 4);
  ex.addFieldEdit(5, 3);
  for (const ch of 'x') ex.addFieldEditChar(ch.codePointAt(0));
});
await fldTry('갈래 이상한 고침', 'form.pdf', (ex) => {
  for (const k of [5, 99, 4294967295]) ex.addFieldEdit(5, k);
});
await fldTry('칸 1000개 만들기', 'form.pdf', (ex) => {
  for (let i = 0; i < 1000; i++) {
    ex.addNewField(0, i % 2, 10 + (i % 50), 10 + (i % 40), 60 + (i % 50), 30 + (i % 40));
    ex.addNewFieldChar(65 + (i % 26));
  }
});
await fldTry('칸 자리 뒤집힘', 'form.pdf', (ex) => ex.addNewField(0, 0, 300, 300, 10, 10));
await fldTry('칸 자리 무한', 'form.pdf', (ex) => ex.addNewField(0, 0, -1e30, -1e30, 1e30, 1e30));
await fldTry('칸 크기 0', 'form.pdf', (ex) => ex.addNewField(0, 0, 50, 50, 50, 50));
await fldTry('없는 쪽에 칸', 'form.pdf', (ex) => {
  ex.addNewField(4000000000, 0, 10, 10, 50, 50);
  ex.addNewFieldChar(65);
});
await fldTry('칸 이름만 넣기', 'form.pdf', (ex) => { for (let i = 0; i < 100; i++) ex.addNewFieldChar(65); });
await fldTry('양식 없는 문서에 칸', 'cff.pdf', (ex) => {
  ex.addNewField(0, 0, 60, 300, 300, 330);
  for (const ch of '한글이름') ex.addNewFieldChar(ch.codePointAt(0));
});
await fldTry('스캔 문서에 칸', 'pdf/scanned.pdf', (ex) => {
  ex.addNewField(0, 0, 60, 300, 300, 330);
  ex.addNewFieldChar(65);
});
await fldTry('여러 쪽 문서에 칸', 'pdf/multi.pdf', (ex) => {
  for (let i = 0; i < 5; i++) {
    ex.addNewField(i, 0, 60, 300, 300, 330);
    ex.addNewFieldChar(65 + i);
  }
});

// --- 스트림 길이가 이상한 문서
for (const k of ['ok', 'ref', 'small', 'big']) {
  await run(`길이 ${k}`, fs.readFileSync(`${S}/len-${k}.pdf`), (ex) => `명령${ex.opsLen()}`);
}
{
  const src = fs.readFileSync(`${S}/len-ref.pdf`).toString('latin1');
  const tw = (from, to, nm) => run(`길이 ${nm}`, Buffer.from(src.replace(from, to), 'latin1'),
    (ex) => `명령${ex.opsLen()}`);
  await tw('/Length 6 0 R', '/Length 999999 0 R', '없는 객체를 가리킴');
  await tw('/Length 6 0 R', '/Length 4 0 R', '제 스트림을 가리킴');
  await tw('/Length 6 0 R', '/Length 6 0 6 0 R', '가리킴이 겹침');
  await tw('/Length 6 0 R', '/Length R 0 R', '숫자가 아님');
  await tw('/Length 6 0 R', '/Length -5', '음수');
  await tw('/Length 6 0 R', '/Length 99999999999999999999', '자릿수 폭발');
  await tw('endstream', 'endstrea_', 'endstream 없음');
  await tw('\nendstream', '\nendstream endstream endstream', 'endstream 여러 개');
}

// --- 새로 붙인 뷰어 갈래
for (const f of ['dest-tree.pdf', 'dest-dict.pdf', 'dest-array.pdf', 'attach.pdf', 'xfa.pdf', 'lab.pdf', 'ocg.pdf']) {
  const src = fs.readFileSync(`${S}/${f}`);
  await run(`${f} 그대로`, src, (ex) =>
    `목차${ex.outlineCount?.() ?? 0} 링크${ex.linkCount?.() ?? 0} 붙임${ex.attCount?.() ?? 0} 레이어${ex.ocCount?.() ?? 0}`);
  for (const [nm, mk] of [
    ['앞 자름', (b) => b.subarray(0, Math.floor(b.length * 0.6))],
    ['비트 뒤집기', (b) => { const c = Buffer.from(b); for (let i = 100; i < c.length; i += 29) c[i] ^= 0x5a; return c; }],
  ]) await run(`${f} ${nm}`, mk(src));
}
{
  const s = fs.readFileSync(`${S}/dest-tree.pdf`).toString('latin1');
  const tw = (from, to, nm) => run(`목적지 ${nm}`, Buffer.from(s.replace(from, to), 'latin1'),
    (ex) => `목차 쪽 ${ex.outlineCount() ? ex.outlinePage(0) : '-'}`);
  await tw('/Dest /두번째', '/Dest /없는이름', '없는 이름');
  await tw('/Dest /두번째', '/Dest /' + 'x'.repeat(400), '이름 400자');
  await tw('/Dest /두번째', '/Dest [999999 0 R /Fit]', '없는 쪽');
  await tw('/Names 8 0 R', '/Names 8 0 R /Names 8 0 R', '이름 사전 두 번');
  await tw('<< /Kids [14 0 R] >>', '<< /Kids [13 0 R] >>', '이름나무 제 자신 가리킴');
  await tw('<< /Names [(두번째) [5 0 R /Fit]] >>', '<< /Names [(두번째)] >>', '값 없는 이름');
}
{
  const s = fs.readFileSync(`${S}/attach.pdf`).toString('latin1');
  const at = (from, to, nm) => run(`붙임 ${nm}`, Buffer.from(s.replace(from, to), 'latin1'),
    (ex) => { let n = 0; for (let i = 0; i < ex.attCount(); i++) n += ex.attLoad(i); return `붙임${ex.attCount()} 합계${n}`; });
  await at('/EF << /F 10 0 R >>', '/EF << /F 999 0 R >>', '없는 스트림');
  await at('/EF << /F 10 0 R >>', '/EF << >>', '/EF 비었음');
  await at('/EF << /F 10 0 R >>', '', '/EF 없음');
  await at('/EmbeddedFiles', '/EmbeddedFiles /EmbeddedFiles', '이름 두 번');
}
{
  const s = fs.readFileSync(`${S}/ocg.pdf`);
  await run('레이어 다 끄기', s, (ex) => {
    for (let i = 0; i < ex.ocCount(); i++) ex.setOcOn(i, 0);
    ex.renderPage(0);
    return `명령${ex.opsLen()}`;
  });
  await run('레이어 범위 밖 켜기', s, (ex) => {
    for (const i of [999, 4294967295]) ex.setOcOn(i, 1);
    ex.renderPage(0);
    return `명령${ex.opsLen()}`;
  });
}

// --- 두 번째 조사에서 메운 갈래
for (const f of ['crop.pdf', 'cmyk.pdf', 'mask-stencil.pdf', 'mask-key.pdf', 'bpc16.pdf', 'vert.pdf', 'group.pdf']) {
  const src = fs.readFileSync(`${S}/${f}`);
  await run(`${f} 그대로`, src, (ex) => `${Math.round(ex.pageWidth())}x${Math.round(ex.pageHeight())} 그림${ex.imageSlots?.() ?? 0}`);
  for (const [nm, mk] of [
    ['앞 자름', (b) => b.subarray(0, Math.floor(b.length * 0.6))],
    ['뒤 자름', (b) => b.subarray(0, Math.max(200, b.length - 300))],
    ['비트 뒤집기', (b) => { const c = Buffer.from(b); for (let i = 120; i < c.length; i += 31) c[i] ^= 0x5a; return c; }],
  ]) await run(`${f} ${nm}`, mk(src));
}
{
  const s = fs.readFileSync(`${S}/crop.pdf`).toString('latin1');
  const tw = (to, nm) => run(`CropBox ${nm}`, Buffer.from(s.replace('/CropBox [100 100 500 700]', to), 'latin1'),
    (ex) => `${Math.round(ex.pageWidth())}x${Math.round(ex.pageHeight())}`);
  await tw('/CropBox [0 0 0 0]', '크기 0');
  await tw('/CropBox [-9999 -9999 9999 9999]', 'MediaBox 밖');
  await tw('/CropBox [500 700 100 100]', '거꾸로');
  await tw('/CropBox [100 100]', '값이 둘뿐');
  await tw('/CropBox 9 0 R', '딴 객체를 가리킴');
}
{
  const s = fs.readFileSync(`${S}/mask-key.pdf`).toString('latin1');
  const tw = (to, nm) => run(`Mask ${nm}`, Buffer.from(s.replace('/Mask [200 255 0 60 0 60]', to), 'latin1'),
    (ex) => `가리개 ${ex.slotSMask?.(0) ?? 0}`);
  await tw('/Mask []', '빈 배열');
  await tw('/Mask [999999 999999]', '범위가 밖');
  await tw('/Mask [200]', '값이 하나');
  await tw('/Mask 999 0 R', '없는 스트림');
  await tw('/Mask [0 255 0 255 0 255 0 255 0 255 0 255 0 255 0 255 0 255]', '범위가 아홉 쌍');
}
{
  // CMYK JPEG 자료를 망가뜨려도 버텨야 한다
  const src = fs.readFileSync(`${S}/cmyk.pdf`);
  for (const [nm, mk] of [
    ['DHT 지우기', (b) => { const c = Buffer.from(b); const i = c.indexOf(Buffer.from([0xff, 0xc4])); if (i > 0) c[i + 1] = 0xdb; return c; }],
    ['SOF 성분 9개', (b) => { const c = Buffer.from(b); const i = c.indexOf(Buffer.from([0xff, 0xc0])); if (i > 0) c[i + 9] = 9; return c; }],
    ['크기 0', (b) => { const c = Buffer.from(b); const i = c.indexOf(Buffer.from([0xff, 0xc0])); if (i > 0) { c[i + 5] = 0; c[i + 6] = 0; } return c; }],
    ['SOS 뒤 잘림', (b) => { const c = Buffer.from(b); const i = c.indexOf(Buffer.from([0xff, 0xda])); return i > 0 ? Buffer.concat([c.subarray(0, i + 20), c.subarray(c.length - 200)]) : c; }],
  ]) await run(`CMYK ${nm}`, mk(src));
}
