import fs from 'fs';
import { run } from './adv.mjs';
const S = process.argv[2];

// 콘텐츠 스트림 하나짜리 최소 PDF
function mk(content, fontExtra = '') {
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /MediaBox [0 0 612 792] /Count 1 /Kids [3 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    null,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' + fontExtra + ' >>',
  ];
  let out = '%PDF-1.4\n';
  objs.forEach((o, i) => {
    const n = i + 1;
    if (o === null) out += `${n} 0 obj\n<< /Length ${content.length} >> stream\n${content}\nendstream\nendobj\n`;
    else out += `${n} 0 obj\n${o}\nendobj\n`;
  });
  out += `trailer\n<< /Size 6 /Root 1 0 R >>\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}
console.log('3회차 — 콘텐츠 스트림과 폭 표');
await run('q 20만 개(Q 없음)', mk('q '.repeat(200000)));
await run('Q 20만 개(q 없음)', mk('Q '.repeat(200000)));
await run('cm 10만 개', mk('1 0 0 1 1 1 cm '.repeat(100000)));
await run('경로 명령 50만 개', mk('1 1 m 2 2 l '.repeat(250000)));
await run('BT/ET 10만 겹침', mk('BT '.repeat(100000) + 'ET '.repeat(100000)));
await run('닫히지 않은 문자열', mk('BT /F1 12 Tf 100 700 Td (' + 'A'.repeat(300000)));
await run('괄호 깊이 5만', mk('BT /F1 12 Tf (' + '('.repeat(50000) + ')'.repeat(50000) + ') Tj ET'));
await run('TJ 배열 10만 항목', mk('BT /F1 12 Tf 10 700 Td [' + '(a) -100 '.repeat(100000) + '] TJ ET'));
await run('글자 100만 자', mk('BT /F1 12 Tf 10 700 Td (' + 'x'.repeat(1000000) + ') Tj ET'));
await run('아주 큰 수', mk('BT /F1 1e30 Tf 1e30 1e30 Td (A) Tj ET'));
await run('아주 작은 수', mk('BT /F1 0.0000001 Tf (A) Tj ET'));
await run('숫자 2000개 스택', mk('1 '.repeat(2000) + 'cm'));
await run('연산자 쓰레기', mk('zzz yyy 1 2 3 qqqq WWWW ~~~ \x00\x01\x02 Tj'));
await run('Tz 0 / Tc 거대', mk('BT /F1 12 Tf 0 Tz 1e9 Tc (AAAA) Tj ET'));
await run('W n 5만 번', mk('0 0 100 100 re W n '.repeat(50000)));
// 폭 표 공격
await run('Widths 5만 항목', mk('BT /F1 12 Tf (AB) Tj ET',
  '/FirstChar 0 /Widths [' + '500 '.repeat(50000) + ']'));
await run('Widths 닫히지 않음', mk('BT /F1 12 Tf (AB) Tj ET',
  '/FirstChar 0 /Widths [' + '500 '.repeat(1000)));
await run('Widths 자기참조', mk('BT /F1 12 Tf (AB) Tj ET', '/FirstChar 0 /Widths 5 0 R'));
await run('W 중첩 배열', mk('BT /F1 12 Tf (AB) Tj ET',
  '/Subtype /Type0 /DescendantFonts [5 0 R] /DW 1000 /W [' + '0 ['.repeat(2000) + ']'.repeat(2000) + ']'));
await run('W 범위 0..65535', mk('BT /F1 12 Tf (AB) Tj ET',
  '/Subtype /Type0 /DescendantFonts [5 0 R] /W [0 65535 800]'));
