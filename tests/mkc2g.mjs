// CIDToGIDMap — CID 와 글리프 번호가 다른 문서.
import fs from 'fs';
const S = process.argv[2];
const ttf = fs.readFileSync(`${S}/sub.ttf`);

// cid 1→300, 2→1000, 3→2 로 뒤섞는다
const MAP = [[1, 300], [2, 1000], [3, 2]];
const c2g = Buffer.alloc(8 * 2);
for (const [cid, gid] of MAP) c2g.writeUInt16BE(gid, cid * 2);

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

const content = 'BT /F1 24 Tf 20 40 Td <000100020003> Tj ET';
const stream = (dict, data) =>
  Buffer.concat([Buffer.from(`<< ${dict} /Length ${data.length} >>\nstream\n`, 'latin1'),
                 data, Buffer.from('\nendstream', 'latin1')]);

for (const [name, c2gVal, extra] of [
  ['c2g.pdf', '8 0 R', c2g],
  ['c2g0.pdf', '/Identity', Buffer.alloc(0)],
]) {
  fs.writeFileSync(`${S}/${name}`, build([
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>',
    '<< /Type /Font /Subtype /Type0 /BaseFont /Sub /Encoding /Identity-H /DescendantFonts [5 0 R] >>',
    `<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Sub /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 1000 /CIDToGIDMap ${c2gVal} >>`,
    stream(`/Length1 ${content.length}`, Buffer.from(content, 'latin1')),
    '<< /Type /FontDescriptor /FontName /Sub /Flags 4 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 /FontFile2 9 0 R >>',
    stream('', extra),
    stream(`/Length1 ${ttf.length}`, ttf),
  ]));
}
console.log('c2g.pdf · c2g0.pdf 만듦');
