// 프로그레시브 JPEG 이 든 문서. 같은 그림을 베이스라인으로도 넣어 견준다.
//
//   python3 로 미리 만들어 둔 /tmp/{base,prog,proggray}.jpg 를 담는다.
import fs from 'node:fs';
const mk = (jpg, out, w, h) => {
  const img = fs.readFileSync(jpg);
  const objs = [];
  objs.push('<</Type/Catalog/Pages 2 0 R>>');
  objs.push('<</Type/Pages/Count 1/Kids[3 0 R]>>');
  objs.push(`<</Type/Page/Parent 2 0 R/MediaBox[0 0 ${w} ${h}]/Resources<</XObject<</Im0 5 0 R>>>>/Contents 4 0 R>>`);
  const c = `q ${w} 0 0 ${h} 0 0 cm /Im0 Do Q\n`;
  objs.push(`<</Length ${c.length}>>stream\n${c}endstream `);
  const gray = /gray/.test(jpg);
  objs.push(`<</Type/XObject/Subtype/Image/Width ${w}/Height ${h}/ColorSpace/Device${gray ? 'Gray' : 'RGB'}/BitsPerComponent 8/Filter/DCTDecode/Length ${img.length}>>stream\n@@IMG@@\nendstream `);
  const parts = [Buffer.from('%PDF-1.7\n', 'latin1')];
  const off = []; let at = parts[0].length;
  objs.forEach((o, i) => {
    off.push(at);
    const [a, b] = o.split('@@IMG@@');
    if (b === undefined) {
      const buf = Buffer.from(`${i + 1} 0 obj${o}endobj\n`, 'latin1');
      parts.push(buf); at += buf.length;
    } else {
      const h1 = Buffer.from(`${i + 1} 0 obj${a}`, 'latin1');
      const h2 = Buffer.from(`${b}endobj\n`, 'latin1');
      parts.push(h1, img, h2); at += h1.length + img.length + h2.length;
    }
  });
  let tail = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
    + off.map((x) => String(x).padStart(10, '0') + ' 00000 n \n').join('');
  tail += `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${at}\n%%EOF\n`;
  parts.push(Buffer.from(tail, 'latin1'));
  fs.writeFileSync(new URL(`./fixtures/${out}`, import.meta.url), Buffer.concat(parts));
};
mk('/tmp/base.jpg', 'jpg-base.pdf', 160, 120);
mk('/tmp/prog.jpg', 'jpg-prog.pdf', 160, 120);
mk('/tmp/proggray.jpg', 'jpg-prog-gray.pdf', 160, 120);
console.log('jpg-base / jpg-prog / jpg-prog-gray 만듦');
