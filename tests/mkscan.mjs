// 스캔한 것처럼 보이는 문서 — 글자는 없고 큰 그림만 있다.
//
// 예전에는 어디서 온 그림인지 적혀 있지 않은 스캔 파일을 그대로 두었다.
// 남의 문서일 수 있어, 그림도 여기서 그려 짓는다.
//
// 시험이 여기 기대는 것은 세 가지다.
//   · 글자가 없어도 그림을 꺼내 썸네일에 그린다
//   · 워터마크를 얹어도 그림이 그대로 남는다
//   · 쪽을 골라 다시 쓰면 파일이 눈에 띄게 준다 (안 쓰는 그림이 빠지므로)
//
//   node tests/mkscan.mjs tests/fixtures
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));

// 늘 같은 파일이 나오게 씨앗을 박아 둔다
let seed = 20260830;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };

/**
 * 종이를 스캔한 것처럼 보이는 RGB 그림을 그린다.
 *
 * 진짜 스캔처럼 노이즈를 잔뜩 넣으면 압축이 안 돼 붙임감이 수 MB 가 된다.
 * 바탕은 고르게 두고 글줄만 찍는다 — 시험이 보는 것은 "그림이 그려지는가",
 * "다시 쓰면 주는가" 라서 이 정도면 된다.
 */
function scanPage(w, h, n) {
  const px = Buffer.alloc(w * h * 3, 0xf6);
  const put = (x, y, v) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    const o = (y * w + x) * 3;
    px[o] = v; px[o + 1] = v; px[o + 2] = v;
  };
  const box = (x0, y0, x1, y1, v) => {
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) put(x, y, v);
  };
  // 가장자리 그림자 — 스캐너 뚜껑이 덜 닫힌 자리처럼
  box(0, 0, w, 6, 0xd0);
  box(0, h - 6, w, h, 0xd0);
  // 머리글 띠
  box(40, 40, w - 40, 44 + 18, 0x33);
  // 글줄 — 낱말 길이를 들쭉날쭉하게
  let y = 110;
  while (y < h - 80) {
    let x = 46;
    const right = w - 46 - Math.floor(rnd() * 90);
    while (x < right) {
      const wordW = 14 + Math.floor(rnd() * 46);
      const ink = 0x1a + Math.floor(rnd() * 40);
      for (let yy = 0; yy < 9; yy++) {
        for (let xx = 0; xx < wordW; xx++) {
          // 글자처럼 위아래가 성기게
          if (rnd() < (yy === 0 || yy === 8 ? 0.35 : 0.72)) put(x + xx, y + yy, ink);
        }
      }
      x += wordW + 6 + Math.floor(rnd() * 6);
    }
    y += 22;
    // 문단 사이는 한 줄 띈다
    if (rnd() < 0.18) y += 14;
  }
  // 도장 자리 — 쪽마다 다르게 둔다
  const sx = w - 150;
  const sy = h - 150 - n * 8;
  for (let yy = 0; yy < 90; yy++) {
    for (let xx = 0; xx < 90; xx++) {
      const dx = xx - 45;
      const dy = yy - 45;
      const r = Math.sqrt(dx * dx + dy * dy);
      if (r > 38 && r < 44) put(sx + xx, sy + yy, 0x50);
    }
  }
  return px;
}

function build(objs) {
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

/** 쪽마다 그림 한 장씩 있는 문서. 글자는 한 자도 없다.
 *
 * slack 을 주면 아무도 안 쓰는 객체를 뒤에 붙인다. 스캐너나 인쇄 드라이버가
 * 뽑은 문서에는 색 프로파일이나 예전 판의 그림이 남아 있기 마련이라,
 * "쓰는 것만 골라 다시 쓰기" 가 실제로 줄어드는지 보려면 그런 군더더기가
 * 있어야 한다.
 */
function scanDoc(pages, iw, ih, pw, ph, slack = 0) {
  const kids = [];
  const objs = [null, null];   // 카탈로그·Pages 는 나중에 채운다
  for (let i = 0; i < pages; i++) {
    const imgObj = 3 + i * 3;
    const pageObj = imgObj + 1;
    const contObj = imgObj + 2;
    kids.push(`${pageObj} 0 R`);
    const data = zlib.deflateSync(scanPage(iw, ih, i), { level: 9 });
    objs.push(Buffer.concat([
      B(`<< /Type /XObject /Subtype /Image /Width ${iw} /Height ${ih}`
        + ` /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode`
        + ` /Length ${data.length} >>\nstream\n`),
      data, B('\nendstream'),
    ]));
    const c = `q ${pw} 0 0 ${ph} 0 0 cm /I Do Q`;
    objs.push(B(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pw} ${ph}]`
      + ` /Resources << /XObject << /I ${imgObj} 0 R >> >> /Contents ${contObj} 0 R >>`));
    objs.push(B(`<< /Length ${c.length} >>\nstream\n${c}\nendstream`));
  }
  if (slack > 0) {
    // 아무도 가리키지 않는 색 프로파일과 예전 판 그림
    const icc = zlib.deflateSync(Buffer.alloc(slack, 0x5a), { level: 1 });
    objs.push(Buffer.concat([
      B(`<< /N 3 /Alternate /DeviceRGB /Filter /FlateDecode /Length ${icc.length} >>\nstream\n`),
      icc, B('\nendstream'),
    ]));
    const old2 = zlib.deflateSync(scanPage(iw >> 1, ih >> 1, 9), { level: 9 });
    objs.push(Buffer.concat([
      B(`<< /Type /XObject /Subtype /Image /Width ${iw >> 1} /Height ${ih >> 1}`
        + ` /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode`
        + ` /Length ${old2.length} >>\nstream\n`),
      old2, B('\nendstream'),
    ]));
  }
  objs[0] = B('<< /Type /Catalog /Pages 2 0 R >>');
  objs[1] = B(`<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages} >>`);
  return build(objs);
}

const one = scanDoc(1, 600, 800, 596, 843, 400 * 1024);
const four = scanDoc(4, 500, 680, 596, 843);

fs.mkdirSync(`${S}/pdf`, { recursive: true });
fs.writeFileSync(`${S}/pdf/scanned.pdf`, one);
fs.writeFileSync(path.join(S, 'scan4.pdf'), four);
console.log(`scanned.pdf ${(one.length / 1024).toFixed(0)}KB · scan4.pdf ${(four.length / 1024).toFixed(0)}KB`);
