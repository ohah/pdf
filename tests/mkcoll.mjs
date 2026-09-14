// 포트폴리오(파일 묶음) 문서.
//
// /Collection 이 있으면 뷰어는 쪽을 보여 주는 대신 파일 목록을 낸다.
// 규격(§12.3.5)이 정한 것만 담는다.
//
//   /Schema  칸 정의 — 이름 → << /Subtype /S|/D|/N /N (보일 이름) /O 차례 >>
//   /D       처음 열 파일 이름
//   /View    /D 자세히 · /T 타일 · /H 숨김
//
// 파일마다 /CI 에 칸 값을 둔다. 여기서는 두 파일에 "설명"과 "크기" 를 준다.
import fs from 'fs';

// PDF 글자열에 아스키 밖 글자를 담는 법 — UTF-16BE 에 BOM 을 붙여 16진으로
// 적는다(규격 §7.9.2.2). latin1 로 그냥 쓰면 한 글자가 한 바이트로 잘린다 —
// 처음에 그렇게 써서 "설명" 이 "$\x85" 가 됐다.
const txt = (s) => {
  if (/^[\x20-\x7e]*$/.test(s)) return `(${s.replace(/([()\\])/g, '\\$1')})`;
  let h = 'FEFF';
  for (const c of s) {
    const u = c.codePointAt(0);
    if (u > 0xffff) {
      const v = u - 0x10000;
      h += (0xd800 + (v >> 10)).toString(16).padStart(4, '0').toUpperCase();
      h += (0xdc00 + (v & 0x3ff)).toString(16).padStart(4, '0').toUpperCase();
    } else h += u.toString(16).padStart(4, '0').toUpperCase();
  }
  return `<${h}>`;
};
const S = process.argv[2];
const objs = [];
const add = (s) => { objs.push(s); return objs.length; };

const content = 'BT /F1 14 Tf 40 150 Td (Portfolio cover) Tj ET';
const fileA = 'first file\n';
const fileB = 'second file\n';

const cat = add('');                                    // 1 — 나중에 채운다
const pages = add('');                                  // 2
const page = add('');                                   // 3
const cont = add(`<< /Length ${content.length} >>\nstream\n${content}\nendstream`);  // 4
const font = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');          // 5
const strA = add(`<< /Type /EmbeddedFile /Subtype /text#2Fplain /Length ${fileA.length} >>\nstream\n${fileA}\nendstream`); // 6
const strB = add(`<< /Type /EmbeddedFile /Subtype /text#2Fplain /Length ${fileB.length} >>\nstream\n${fileB}\nendstream`); // 7
// 파일 이름표 — /CI 에 칸 값을 담는다
const specA = add(`<< /Type /Filespec /F (a.txt) /UF (a.txt) /EF << /F ${strA} 0 R >> /Desc ${txt('첫째')} /CI << /desc ${txt('첫째 파일')} /size 11 >> >>`); // 8
const specB = add(`<< /Type /Filespec /F (b.txt) /UF (b.txt) /EF << /F ${strB} 0 R >> /Desc ${txt('둘째')} /CI << /desc ${txt('둘째 파일')} /size 12 >> >>`); // 9
const names = add(`<< /Names [(a.txt) ${specA} 0 R (b.txt) ${specB} 0 R] >>`); // 10
const coll = add(`<< /Type /Collection /View /D /D (b.txt) /Schema << /desc << /Subtype /S /N ${txt('설명')} /O 1 >> /size << /Subtype /N /N ${txt('크기')} /O 2 >> >> >>`); // 11

objs[cat - 1] = `<< /Type /Catalog /Pages ${pages} 0 R /Names << /EmbeddedFiles ${names} 0 R >> /Collection ${coll} 0 R >>`;
objs[pages - 1] = `<< /Type /Pages /Kids [${page} 0 R] /Count 1 >>`;
objs[page - 1] = `<< /Type /Page /Parent ${pages} 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${cont} 0 R >>`;

let out = '%PDF-1.7\n';
const off = [];
for (let i = 0; i < objs.length; i++) { off.push(out.length); out += `${i + 1} 0 obj\n${objs[i]}\nendobj\n`; }
const x = out.length;
out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
for (const o of off) out += `${String(o).padStart(10, '0')} 00000 n \n`;
out += `trailer\n<< /Size ${objs.length + 1} /Root ${cat} 0 R >>\nstartxref\n${x}\n%%EOF\n`;
fs.writeFileSync(`${S}/collection.pdf`, Buffer.from(out, 'latin1'));
console.log('collection.pdf 만듦');
