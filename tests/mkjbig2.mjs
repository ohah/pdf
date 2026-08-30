// JBIG2 시험 파일.
//
// 자료는 ITU-T T.88 부록 H 의 시험 흐름이다(jbig2dec 저장소의 annex-h.jbig2).
// 같은 그림을 여러 방식으로 부호화해 두었기에 서로 맞대 볼 수 있다 —
// 쪽1 의 보통 영역은 MMR(팩스와 같은 부호), 쪽2 의 같은 영역은 산술 부호다.
// 둘을 풀어 비트가 똑같이 나오면 산술 복호기가 맞다는 뜻이다.
import fs from 'node:fs';
const S = process.argv[2];
const d = fs.readFileSync(`${S}/annex-h.jbig2`);

/** 파일에서 세그먼트를 잘라 낸다. */
function segments(buf) {
  let p = 9 + ((buf[8] & 2) ? 0 : 4);
  const out = [];
  while (p + 11 <= buf.length) {
    const start = p;
    const num = buf.readUInt32BE(p);
    const flags = buf[p + 4];
    let q = p + 5;
    const rt = buf[q];
    let nref = rt >> 5;
    if (nref === 7) { nref = buf.readUInt32BE(q) & 0x1fffffff; q += 4 + Math.ceil((nref + 1) / 8); }
    else q += 1;
    q += nref * (num <= 256 ? 1 : num <= 65536 ? 2 : 4);
    q += (flags & 0x40) ? 4 : 1;
    const len = buf.readUInt32BE(q);
    q += 4;
    out.push({ num, kind: flags & 0x3f, bytes: buf.subarray(start, q + len) });
    if (len === 0xffffffff) break;
    p = q + len;
  }
  return out;
}
const segs = segments(d);

function build(objs) {
  const parts = [Buffer.from('%PDF-1.4\n', 'latin1')];
  let len = parts[0].length;
  const off = [];
  for (let i = 0; i < objs.length; i++) {
    off.push(len);
    const head = Buffer.from(`${i + 1} 0 obj\n`, 'latin1');
    const body = Buffer.isBuffer(objs[i]) ? objs[i] : Buffer.from(objs[i], 'latin1');
    const tail = Buffer.from('\nendobj\n', 'latin1');
    parts.push(head, body, tail);
    len += head.length + body.length + tail.length;
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of off) x += `${String(o).padStart(10, '0')} 00000 n \n`;
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${len}\n%%EOF\n`;
  parts.push(Buffer.from(x, 'latin1'));
  return Buffer.concat(parts);
}

/** JBIG2 그림 하나를 얹은 한 쪽짜리 문서. globals 를 주면 따로 실어 준다. */
function doc(name, data, w, h, globals) {
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << /XObject << /I 5 0 R >> >> /Contents 4 0 R >>`,
    (() => { const c = `q ${w} 0 0 ${h} 0 0 cm /I Do Q`; return Buffer.concat([
      Buffer.from(`<< /Length ${c.length} >>\nstream\n`, 'latin1'), Buffer.from(c, 'latin1'),
      Buffer.from('\nendstream', 'latin1')]); })(),
    Buffer.concat([
      Buffer.from(`<< /Type /XObject /Subtype /Image /Width ${w} /Height ${h} /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode${globals ? ' /DecodeParms << /JBIG2Globals 6 0 R >>' : ''} /Length ${data.length} >>\nstream\n`, 'latin1'),
      data, Buffer.from('\nendstream', 'latin1')]),
  ];
  if (globals) objs.push(Buffer.concat([
    Buffer.from(`<< /Length ${globals.length} >>\nstream\n`, 'latin1'),
    globals, Buffer.from('\nendstream', 'latin1')]));
  fs.writeFileSync(`${S}/${name}`, build(objs));
}

const by = (n) => segs.find((s) => s.num === n).bytes;
// 쪽1 의 MMR 보통 영역과 쪽2 의 산술 보통 영역. 같은 그림이어야 한다.
doc('jb-mmr.pdf', Buffer.concat([by(1), by(4)]), 64, 56);
doc('jb-arith.pdf', Buffer.concat([by(8), by(11)]), 64, 56);
// 글자 사전 + 글자 영역은 여기서 만들지 않는다. 부록 H 의 글자 영역은
// 허프만 사전(세그먼트 0)까지 가리키는데 그건 다루지 않기 때문이다.
// 그 길은 실제 문서인 jb-sym.pdf·jb-globals.pdf 로 본다.
// 세밀화 — 쪽3 은 사전을 다듬어 글자를 만들고 글자 영역에서 또 다듬는다
doc('jb-refine.pdf', Buffer.concat([by(15), by(16), by(17), by(18)]), 37, 8);
// 하프톤 — 쪽2 의 무늬 사전과 하프톤 영역
doc('jb-half.pdf', Buffer.concat([by(8), by(12), by(13)]), 64, 56);
doc('jb-halfmmr.pdf', Buffer.concat([by(1), by(5), by(6)]), 64, 56);
// 쪽2 통째 — 글자·보통·하프톤이 다 들어 있다
doc('jb-page2.pdf', Buffer.concat([by(0), by(8), by(9), by(10), by(11), by(12), by(13)]), 64, 56);
// 쪽1 통째 — 같은 그림을 허프만·MMR 로 담았다
doc('jb-page1.pdf', Buffer.concat([by(0), by(1), by(2), by(3), by(4), by(5), by(6)]), 64, 56);
console.log('jb-mmr·jb-arith·jb-refine·jb-half·jb-page1·jb-page2 만듦');
