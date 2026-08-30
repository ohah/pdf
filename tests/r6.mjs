import fs from 'fs';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
import { run } from './adv.mjs';
const S = process.argv[2];
console.log('6회차 — 암호·팩스·셰이딩·주석');
const enc = fs.readFileSync(S + '/enc-aes.pdf').toString('latin1');
const rnd = (n) => Buffer.from(Array.from({length:n},()=>(Math.random()*256)|0));

function tweak(src, from, to) { return Buffer.from(src.replace(from, to), 'latin1'); }
await run('암호: O 짧음', tweak(enc, /\/O <[0-9a-f]*>/, '/O <00>'));
await run('암호: U 없음', tweak(enc, /\/U <[0-9a-f]*>/, ''));
await run('암호: R 99', tweak(enc, '/R 4', '/R 99'));
await run('암호: V 99', tweak(enc, '/V 4', '/V 99'));
await run('암호: Length 0', tweak(enc, '/Length 128', '/Length 0'));
await run('암호: Length 100만', tweak(enc, '/Length 128', '/Length 1000000'));
await run('암호: Encrypt 자기참조', tweak(enc, '/Encrypt 6 0 R', '/Encrypt 4 0 R'));
await run('암호: ID 없음', tweak(enc, /\/ID \[<[0-9a-f]*> <[0-9a-f]*>\]/, ''));
await run('암호: P 거대', tweak(enc, '/P -1', '/P 99999999999'));

function mkFax(dict, data, ops) {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, '<< /Type /Page /Parent 2 0 R /Resources << /XObject << /I 5 0 R >> >> /Contents 4 0 R >>');
  push(4, `<< /Length ${ops.length} >>\nstream\n${ops}\nendstream`);
  s2 += `5 0 obj\n<< ${dict} /Length ${data.length} >>\nstream\n` + data.toString('latin1') + '\nendstream\nendobj\n';
  s2 += 'trailer\n<< /Size 6 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
const faxBase = '/Type /XObject /Subtype /Image /ImageMask true /BitsPerComponent 1 /Filter /CCITTFaxDecode';
await run('팩스: 무작위 4KB', mkFax(faxBase + ' /Width 200 /Height 200 /DecodeParms << /K -1 >>', rnd(4096), 'q /I Do Q'));
await run('팩스: 폭 2만', mkFax(faxBase + ' /Width 20000 /Height 20000 /DecodeParms << /K -1 >>', rnd(1000), 'q /I Do Q'));
await run('팩스: 자료 없음', mkFax(faxBase + ' /Width 64 /Height 64 /DecodeParms << /K -1 >>', Buffer.alloc(0), 'q /I Do Q'));
await run('팩스: 0 만 가득', mkFax(faxBase + ' /Width 64 /Height 64 /DecodeParms << /K -1 >>', Buffer.alloc(2000), 'q /I Do Q'));
await run('팩스: 1 만 가득', mkFax(faxBase + ' /Width 64 /Height 64 /DecodeParms << /K -1 >>', Buffer.alloc(2000, 0xff), 'q /I Do Q'));
await run('팩스: K 0(1차원)', mkFax(faxBase + ' /Width 64 /Height 64 /DecodeParms << /K 0 >>', rnd(500), 'q /I Do Q'));
await run('팩스: K 4(섞임)', mkFax(faxBase + ' /Width 64 /Height 64 /DecodeParms << /K 4 >>', rnd(500), 'q /I Do Q'));

function mkSh(sh, ops) {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, `<< /Type /Page /Parent 2 0 R /Resources << /Shading << /S ${sh} >> >> /Contents 4 0 R >>`);
  push(4, `<< /Length ${ops.length} >>\nstream\n${ops}\nendstream`);
  s2 += 'trailer\n<< /Size 5 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
await run('셰이딩: 함수 없음', mkSh('<< /ShadingType 2 /Coords [0 0 1 1] >>', '/S sh'));
await run('셰이딩: 함수 순환', mkSh('<< /ShadingType 3 /Coords [0 0 0 1 1 1] /Function << /FunctionType 3 /Functions [4 0 R] /Bounds [0.5] >> >>', '/S sh'));
await run('셰이딩: 좌표 1e30', mkSh('<< /ShadingType 2 /Coords [-1e30 -1e30 1e30 1e30] /Function << /FunctionType 2 /C0 [0] /C1 [1] >> >>', '/S sh'));
await run('셰이딩: 10만 번', mkSh('<< /ShadingType 2 /Coords [0 0 1 1] /Function << /FunctionType 2 /C0 [0] /C1 [1] >> >>', '/S sh '.repeat(100000)));

function mkAnnot(annot) {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, `<< /Type /Page /Parent 2 0 R /Annots [6 0 R] /Contents 4 0 R >>`);
  const c = '0 0 1 rg 0 0 10 10 re f';
  push(4, `<< /Length ${c.length} >>\nstream\n${c}\nendstream`);
  const ap = '0 g 0 0 50 50 re f q /X Do Q';
  s2 += `5 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 50 50] /Resources << /XObject << /X 5 0 R >> >> /Length ${ap.length} >>\nstream\n${ap}\nendstream\nendobj\n`;
  push(6, annot);
  s2 += 'trailer\n<< /Size 7 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
await run('주석: 자기참조 폼', mkAnnot('<< /Type /Annot /Subtype /Widget /Rect [0 0 100 100] /AP << /N 5 0 R >> >>'));
await run('주석: Rect 뒤집힘', mkAnnot('<< /Type /Annot /Subtype /Widget /Rect [500 500 0 0] /AP << /N 5 0 R >> >>'));
await run('주석: Rect 1e30', mkAnnot('<< /Type /Annot /Subtype /Widget /Rect [-1e30 -1e30 1e30 1e30] /AP << /N 5 0 R >> >>'));
await run('주석: AP 없음', mkAnnot('<< /Type /Annot /Subtype /Widget /Rect [0 0 10 10] >>'));
await run('주석: 숨김 깃발', mkAnnot('<< /Type /Annot /Subtype /Widget /F 2 /Rect [0 0 10 10] /AP << /N 5 0 R >> >>'));

// --- 필터와 레이어
function mkFilt(filter, data, extra = '') {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, '<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>');
  s2 += `4 0 obj\n<< /Filter ${filter} ${extra} /Length ${data.length} >>\nstream\n` + data.toString('latin1') + '\nendstream\nendobj\n';
  s2 += 'trailer\n<< /Size 5 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
const rn2 = (n) => Buffer.from(Array.from({length:n},()=>(Math.random()*256)|0));
await run('LZW 무작위', mkFilt('/LZWDecode', rn2(4096)));
await run('LZW 0만 가득', mkFilt('/LZWDecode', Buffer.alloc(4096)));
await run('LZW 255만 가득', mkFilt('/LZWDecode', Buffer.alloc(4096, 0xff)));
await run('A85 쓰레기', mkFilt('/ASCII85Decode', Buffer.from('!!!!!zzz~~~>>>')));
await run('Hex 홀수 자리', mkFilt('/ASCIIHexDecode', Buffer.from('abc')));
await run('RunLength 잘림', mkFilt('/RunLengthDecode', Buffer.from([0x7f, 1, 2, 3])));
await run('필터 사슬 4개', mkFilt('[/ASCII85Decode /ASCII85Decode /ASCII85Decode /FlateDecode]', rn2(200)));
await run('필터 이름 이상', mkFilt('/NoSuchDecode', rn2(200)));
await run('Predictor 15 자료부족', mkFilt('/FlateDecode', Buffer.from(require('zlib').deflateSync(Buffer.alloc(5))),
  '/DecodeParms << /Predictor 15 /Colors 3 /BitsPerComponent 8 /Columns 1000 >>'));
await run('Predictor 99', mkFilt('/FlateDecode', Buffer.from(require('zlib').deflateSync(Buffer.alloc(100))),
  '/DecodeParms << /Predictor 99 /Columns 4 >>'));

function mkOcg(off, content) {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, `<< /Type /Catalog /Pages 2 0 R /OCProperties << /D << /OFF ${off} >> >> >>`);
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, '<< /Type /Page /Parent 2 0 R /Resources << /Properties << /L 6 0 R >> >> /Contents 4 0 R >>');
  push(4, `<< /Length ${content.length} >>\nstream\n${content}\nendstream`);
  push(6, '<< /Type /OCG >>');
  s2 += 'trailer\n<< /Size 7 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
await run('레이어: EMC 없음', mkOcg('[6 0 R]', '/OC /L BDC 0 0 10 10 re f'));
await run('레이어: EMC 만 10만', mkOcg('[6 0 R]', 'EMC '.repeat(100000) + '0 0 10 10 re f'));
await run('레이어: BDC 10만', mkOcg('[6 0 R]', '/OC /L BDC '.repeat(100000)));
await run('레이어: OFF 자기참조', mkOcg('[1 0 R]', '/OC /L BDC 0 0 10 10 re f EMC'));
await run('레이어: OFF 배열 안 닫힘', mkOcg('[6 0 R', '/OC /L BDC 0 0 10 10 re f EMC'));

// --- 링크·목차
function mkOut(body) {
  let s2 = '%PDF-1.5\n';
  const push = (n, b) => { s2 += `${n} 0 obj\n${b}\nendobj\n`; };
  push(1, '<< /Type /Catalog /Pages 2 0 R /Outlines 20 0 R >>');
  push(2, '<< /Type /Pages /MediaBox [0 0 595 842] /Count 1 /Kids [3 0 R] >>');
  push(3, '<< /Type /Page /Parent 2 0 R /Annots [8 0 R] /Contents 4 0 R >>');
  const c = '0 0 1 rg 0 0 10 10 re f';
  push(4, `<< /Length ${c.length} >>\nstream\n${c}\nendstream`);
  push(8, '<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /A << /S /URI /URI (' + 'x'.repeat(5000) + ') >> >>');
  s2 += body;
  s2 += 'trailer\n<< /Size 30 /Root 1 0 R >>\n%%EOF\n';
  return Buffer.from(s2, 'latin1');
}
await run('목차 자기 순환', mkOut('20 0 obj\n<< /First 21 0 R >>\nendobj\n21 0 obj\n<< /Title (A) /Next 21 0 R >>\nendobj\n'));
await run('목차 깊이 폭발', mkOut('20 0 obj\n<< /First 21 0 R >>\nendobj\n21 0 obj\n<< /Title (A) /First 21 0 R >>\nendobj\n'));
await run('목차 제목 5천자', mkOut('20 0 obj\n<< /First 21 0 R >>\nendobj\n21 0 obj\n<< /Title (' + 'y'.repeat(5000) + ') >>\nendobj\n'));
await run('링크 URI 5천자', mkOut('20 0 obj\n<< >>\nendobj\n'));
await run('목차 Dest 없는 쪽', mkOut('20 0 obj\n<< /First 21 0 R >>\nendobj\n21 0 obj\n<< /Title (A) /Dest [999 0 R /Fit] >>\nendobj\n'));

// --- 미리 정의된 CMap
const cm = fs.readFileSync(S + '/cmap.pdf').toString('latin1');
const tw2 = (from, to) => Buffer.from(cm.replace(from, to), 'latin1');
await run('CMap 이름 이상', tw2('/KSCms-UHC-H', '/NoSuchCMap-H'));
await run('CMap RKSJ', tw2('/KSCms-UHC-H', '/90ms-RKSJ-H'));
await run('CMap UCS2', tw2('/KSCms-UHC-H', '/UniKS-UCS2-H'));
await run('CMap 세로쓰기', tw2('/KSCms-UHC-H', '/KSCms-UHC-V'));
await run('CMap 이름 없음', tw2('/Encoding /KSCms-UHC-H', ''));

// --- 미리 정의된 CMap 표 (망가진 표를 넣어 본다)
const cm2 = fs.readFileSync(S + '/cmap2.pdf');
const feedRaw = (label, bytes) => run(label, cm2, null, (ex) => {
  ex.cmapReset();
  new Uint8Array(ex.memory.buffer, ex.cmapPtr(), bytes.length).set(bytes);
  ex.cmapAdd(0, bytes.length);
});
const good = fs.readFileSync('cmaps/KSCms-UHC-H.bin');
await feedRaw('표 잘림', good.subarray(0, 20));
await feedRaw('표 머리만', good.subarray(0, 9));
await feedRaw('표 빈 것', Buffer.alloc(0));
await feedRaw('표 매직 틀림', Buffer.concat([Buffer.from('XX1'), good.subarray(3)]));
await feedRaw('표 개수 뻥튀기', (() => { const b = Buffer.from(good); b.writeUInt16LE(65535, 7); return b; })());
await feedRaw('표 전부 0', Buffer.alloc(4096));
await feedRaw('표 난수', Buffer.from(Array.from({ length: 4096 }, (_, i) => (i * 7919) & 255)));
await feedRaw('표 폭 4바이트 주장', (() => { const b = Buffer.from(good); b.writeUInt8(1, 4); return b; })());

// --- 라벨
const lab = fs.readFileSync(S + '/cff.pdf');
const stampAdv = (label, fn) => run(label, lab, null, (ex) => {
  ex.clearPick();
  for (let i = 0; i < ex.pageCount(); i++) ex.addPick(i);
  ex.setRotate(0); ex.clearWatermark(); ex.clearLabels();
  fn(ex);
  ex.apply();
});
stampAdv.name;
await stampAdv('라벨 1000개', (ex) => {
  for (let i = 0; i < 1000; i++) { ex.addLabel(0, i, i, 12, 0, 0, 0); ex.addLabelChar(65 + (i % 26)); }
});
await stampAdv('라벨 없이 글자만', (ex) => { for (let i = 0; i < 100; i++) ex.addLabelChar(65); });
await stampAdv('라벨 글자 5만', (ex) => {
  ex.addLabel(0, 10, 10, 12, 0, 0, 0);
  for (let i = 0; i < 50000; i++) ex.addLabelChar(65);
});
await stampAdv('라벨 좌표 NaN', (ex) => { ex.addLabel(0, NaN, NaN, NaN, NaN, NaN, NaN); ex.addLabelChar(65); });
await stampAdv('라벨 좌표 무한', (ex) => { ex.addLabel(0, 1e30, -1e30, 1e30, 2, -2, 9); ex.addLabelChar(66); });
await stampAdv('라벨 쪽 40억', (ex) => { ex.addLabel(4000000000, 10, 10, 12, 0, 0, 0); ex.addLabelChar(67); });
await stampAdv('라벨 크기 0', (ex) => { ex.addLabel(0, 10, 10, 0, 0, 0, 0); ex.addLabelChar(68); });
await stampAdv('라벨 제어문자', (ex) => {
  ex.addLabel(0, 10, 10, 12, 0, 0, 0);
  for (const c of [0, 1, 8, 10, 13, 27, 92, 40, 41, 127, 0x10000]) ex.addLabelChar(c);
});

// --- CIDToGIDMap
const c2gSrc = fs.readFileSync(S + '/c2g.pdf');
const c2gTw = (from, to) => Buffer.from(c2gSrc.toString('latin1').replace(from, to), 'latin1');
await run('C2G 없는 객체 가리킴', c2gTw('/CIDToGIDMap 8 0 R', '/CIDToGIDMap 999 0 R'));
await run('C2G 자기 글꼴 가리킴', c2gTw('/CIDToGIDMap 8 0 R', '/CIDToGIDMap 5 0 R'));
await run('C2G 글꼴 파일 가리킴', c2gTw('/CIDToGIDMap 8 0 R', '/CIDToGIDMap 9 0 R'));
await run('C2G 쪽 가리킴', c2gTw('/CIDToGIDMap 8 0 R', '/CIDToGIDMap 3 0 R'));
await run('C2G 길이 0', c2gTw(/8 0 obj\n<<  \/Length \d+/, '8 0 obj\n<<  /Length 0'));
await run('C2G 길이 거대', c2gTw(/8 0 obj\n<<  \/Length \d+/, '8 0 obj\n<<  /Length 99999999'));
await run('C2G 길이 홀수', c2gTw(/8 0 obj\n<<  \/Length \d+/, '8 0 obj\n<<  /Length 1'));
await run('C2G 이름 이상', c2gTw('/CIDToGIDMap 8 0 R', '/CIDToGIDMap /Nonsense'));
