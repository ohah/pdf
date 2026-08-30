// 여러 쪽짜리 문서 두 개 — 쪽 고르기·회전·병합·썸네일을 시험한다.
//
// 예전에는 맥에서 인쇄해 만든 것을 그대로 두었는데, 그러면 Monaco·
// AppleSDGothicNeo 같은 애플 독점 글꼴이 문서 안에 통째로 박혀 저장소에
// 실린다. 애플 사용권은 글꼴 데이터를 따로 재배포하는 것을 막는다.
//
// 그래서 손으로 짓는다. 라틴은 표준 14종(Helvetica)이라 아무것도 안 박히고,
// 한글은 이름만 적은 Type0 글꼴에 ToUnicode 를 달았다 — 글자는 그대로
// 뽑히고, 화면에서는 브라우저 글꼴로 그려진다. 박힌 글꼴을 시험하는 길은
// korean.pdf(나눔고딕, OFL)와 cff.pdf(STIX, OFL)가 따로 맡는다.
import fs from 'node:fs';
import path from 'node:path';

const S = process.argv[2];
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x, 'latin1'));

/** 한글을 CID 로 적는다. CID 는 그냥 차례 번호이고 뜻은 ToUnicode 가 준다. */
function korean(text, map) {
  let hex = '';
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    let cid = map.get(cp);
    if (cid === undefined) { cid = map.size + 1; map.set(cp, cid); }
    hex += cid.toString(16).padStart(4, '0').toUpperCase();
  }
  return `<${hex}>`;
}

function toUnicode(map) {
  const rows = [...map].map(([cp, cid]) =>
    `<${cid.toString(16).padStart(4, '0').toUpperCase()}> <${cp.toString(16).padStart(4, '0').toUpperCase()}>`);
  let out = '/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n'
    + '/CMapName /Doc-UCS2 def /CMapType 2 def\n'
    + '1 begincodespacerange <0000> <FFFF> endcodespacerange\n';
  for (let i = 0; i < rows.length; i += 100) {
    const part = rows.slice(i, i + 100);
    out += `${part.length} beginbfchar\n${part.join('\n')}\nendbfchar\n`;
  }
  return out + 'endcmap CMapName currentdict /CMap defineresource pop end end';
}

function build(objs) {
  let out = B('%PDF-1.4\n');
  const offs = [];
  for (let i = 0; i < objs.length; i++) {
    offs.push(out.length);
    out = Buffer.concat([out, B(`${i + 1} 0 obj\n`), B(objs[i]), B('\nendobj\n')]);
  }
  let x = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offs) x += String(o).padStart(10, '0') + ' 00000 n \n';
  x += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${out.length}\n%%EOF\n`;
  return Buffer.concat([out, B(x)]);
}

/** 쪽마다 줄 목록을 받아 문서를 만든다. 줄은 문자열이거나 {ko: '한글'} 이다. */
function doc(pages, w, h) {
  const map = new Map();
  const streams = pages.map((lines) => {
    let c = '';
    let y = h - 70;
    for (const ln of lines) {
      if (typeof ln === 'string') {
        const esc = ln.replace(/([()\\])/g, '\\$1');
        c += `BT /F1 ${y === h - 70 ? 22 : 13} Tf 60 ${y} Td (${esc}) Tj ET\n`;
      } else {
        c += `BT /F2 13 Tf 60 ${y} Td ${korean(ln.ko, map)} Tj ET\n`;
      }
      y -= 34;
    }
    return c;
  });
  const nObj = 4 + pages.length * 2;   // 카탈로그·Pages·F1·F2 뒤로 쪽과 스트림
  const kids = pages.map((_, i) => `${5 + i * 2} 0 R`).join(' ');
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${kids}] /Count ${pages.length} >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    `<< /Type /Font /Subtype /Type0 /BaseFont /Gothic /Encoding /Identity-H`
      + ` /DescendantFonts [${nObj + 1} 0 R] /ToUnicode ${nObj + 3} 0 R >>`,
  ];
  pages.forEach((_, i) => {
    objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}]`
      + ` /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${6 + i * 2} 0 R >>`);
    objs.push(`<< /Length ${streams[i].length} >>\nstream\n${streams[i]}\nendstream`);
  });
  const tu = toUnicode(map);
  objs.push('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Gothic'
    + ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>'
    + ` /FontDescriptor ${nObj + 2} 0 R /DW 1000 >>`);
  objs.push('<< /Type /FontDescriptor /FontName /Gothic /Flags 4'
    + ' /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200'
    + ' /CapHeight 700 /StemV 80 >>');
  objs.push(`<< /Length ${tu.length} >>\nstream\n${tu}\nendstream`);
  return build(objs);
}

// 네 쪽 — 쪽마다 한글 제목이 있다 (병합·썸네일 시험이 쓴다)
const modern = doc([1, 2, 3, 4].map((n) => [
  { ko: `페이지 ${n}` },
  { ko: `한글 본문 ${n} — 여러 쪽 문서 시험용입니다.` },
  `Latin body ${n} with digits 0123456789.`,
]), 595, 842);

// 다섯 쪽 — 마지막은 일부러 빈 쪽이다 (쪽 고르기 시험이 쓴다)
const multi = doc([
  ...[1, 2, 3, 4].map((n) => [
    `=== PAGE ${n} ===`,
    `line one of page ${n}`,
    `line two of page ${n}`,
    { ko: `쪽 ${n} 한글 한 줄` },
  ]),
  [],
], 612, 792);

fs.mkdirSync(`${S}/pdf`, { recursive: true });
fs.writeFileSync(`${S}/pdf/modern.pdf`, modern);
fs.writeFileSync(`${S}/pdf/multi.pdf`, multi);
// e2e 는 같은 문서를 tests/fixtures/ 에서 읽는다
const e2e = path.resolve(S, '../../fixtures');
fs.writeFileSync(`${e2e}/pages.pdf`, modern);
fs.writeFileSync(`${e2e}/sample.pdf`, multi);
console.log(`modern.pdf ${modern.length}B · multi.pdf ${multi.length}B (pages.pdf·sample.pdf 로도 씀)`);
