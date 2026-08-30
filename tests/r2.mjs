import fs from 'fs';
import { run } from './adv.mjs';
const S = process.argv[2];
const base = fs.readFileSync(S + '/korean.pdf').toString('latin1');

// obj 11 (FontFile2) 을 통째로 갈아 끼운다
function withFont(bytes) {
  const i = base.indexOf('11 0 obj');
  const j = base.indexOf('endobj', i) + 6;
  const s = Buffer.from(bytes).toString('latin1');
  return Buffer.from(base.slice(0, i) +
    `11 0 obj\n<</Length1 ${bytes.length}\n/Length ${bytes.length}>> stream\n` +
    s + '\nendstream\nendobj' + base.slice(j), 'latin1');
}
function sfnt(numTables, recs, body) {
  const head = Buffer.alloc(12 + numTables * 16);
  head.writeUInt32BE(0x00010000, 0); head.writeUInt16BE(numTables, 4);
  recs.forEach((r, i) => {
    const o = 12 + i * 16;
    head.write(r.tag, o, 'latin1');
    head.writeUInt32BE(0, o + 4);
    head.writeUInt32BE(r.off >>> 0, o + 8);
    head.writeUInt32BE(r.len >>> 0, o + 12);
  });
  return Buffer.concat([head, body || Buffer.alloc(0)]);
}
console.log('2회차 — 박힌 글꼴');
await run('12바이트 글꼴', withFont(Buffer.from([0,1,0,0,0,0,0,0,0,0,0,0])));
await run('numTables 65535', withFont(sfnt(65535, [])));
await run('numTables 0', withFont(sfnt(0, [])));
await run('표 오프셋 파일 밖', withFont(sfnt(2, [
  {tag:'head',off:0xFFFFFF0,len:54},{tag:'glyf',off:0,len:100}], Buffer.alloc(200))));
await run('표 길이 4G', withFont(sfnt(1, [{tag:'glyf',off:44,len:0xFFFFFFFF}], Buffer.alloc(200))));
await run('표 길이 음수경계', withFont(sfnt(1, [{tag:'glyf',off:44,len:0x7FFFFFFF}], Buffer.alloc(200))));
await run('head 만 잘림', withFont(sfnt(1, [{tag:'head',off:28,len:4}], Buffer.alloc(8))));
await run('ttcf 모음집', withFont(Buffer.concat([Buffer.from('ttcf'), Buffer.alloc(200)])));
await run('무작위 2KB', withFont(Buffer.from(Array.from({length:2048},()=> (Math.random()*256)|0))));
await run('태그만 맞는 쓰레기', withFont(Buffer.concat([
  Buffer.from([0,1,0,0]), Buffer.from(Array.from({length:2044},()=>(Math.random()*256)|0))])));
await run('표 64개 모두 겹침', withFont(sfnt(64,
  Array.from({length:64},(_,i)=>({tag:'zz'+String(i).padStart(2,'0'),off:1036,len:1000})), Buffer.alloc(4096))));
// ToUnicode 를 부풀려 cmap 구간을 터뜨려 본다
function withCMap(txt) {
  const i = base.indexOf('14 0 obj');
  const j = base.indexOf('endobj', i) + 6;
  return Buffer.from(base.slice(0, i) +
    `14 0 obj\n<</Length ${txt.length}>> stream\n` + txt + '\nendstream\nendobj' + base.slice(j), 'latin1');
}
let big = '/CIDInit /ProcSet findresource begin 1 begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange\n';
for (let k = 0; k < 3000; k++) big += `1 beginbfchar <${(k*2+1).toString(16).padStart(4,'0')}> <${(k*2+1).toString(16).padStart(4,'0')}> endbfchar\n`;
await run('ToUnicode 3000개(띄엄)', withCMap(big));
let rng = '1 begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange\n1 beginbfrange <0000> <FFFF> <0000> endbfrange\n';
await run('bfrange 0..FFFF', withCMap(rng));
let neg = '1 begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange\n1 beginbfrange <FFFF> <0000> <0000> endbfrange\n';
await run('bfrange 역순', withCMap(neg));
await run('ToUnicode 빈 스트림', withCMap(''));
