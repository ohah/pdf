// XFA 양식 — XML 을 읽어 자리와 글자를 뽑고, 캔버스에 그린다.
import { PDFDocument, readXfa, drawXfa, toPt } from '../dist/index.js';
import { createCanvas } from '@napi-rs/canvas';

let fails = 0;
const ok = (n, c, got) => {
  if (c) console.log(`  통과  ${n}`);
  else { console.log(`  ✗    ${n}${got !== undefined ? ' (' + JSON.stringify(got) + ')' : ''}`); fails++; }
};

ok('단위 옮기기', toPt('25.4mm') === 72 && toPt('1in') === 72 && toPt('36pt') === 36
  && Math.abs(toPt('2.54cm') - 72) < 1e-9, [toPt('25.4mm'), toPt('1in'), toPt('2.54cm')]);
ok('모르는 단위는 그대로', toPt('') === 0 && toPt('abc', 5) === 5);

const d = await PDFDocument.open(new URL('./fixtures/xfa.pdf', import.meta.url).pathname);
ok('XFA 로 알아본다', d.isXfa === true);
ok('XML 이 실려 온다', d.xfaXml.includes('<template') && d.xfaXml.includes('datasets'), d.xfaXml.length);

const f = readXfa(d.xfaXml);
const p = f.pages[0];
ok('쪽 크기 (A4)', Math.round(p.width) === 595 && Math.round(p.height) === 842, [p.width, p.height]);
ok('못 읽은 마디 없음', f.skipped === 0, f.skipped);
ok('정적 양식으로 본다', f.dynamic === false);
ok('제목', p.boxes.some((b) => b.text === '거래 명세서' && b.size === 16 && b.bold), p.boxes[0]);
ok('이름표와 칸이 따로', p.boxes.filter((b) => b.field).length === 2, p.boxes.filter((b) => b.field).length);
ok('템플릿에 든 값', p.boxes.some((b) => b.name === 'company' && b.text === '보기 주식회사'));
ok('datasets 에 든 값', p.boxes.some((b) => b.name === 'amount' && b.text === '1,250,000'));
ok('자리 (20mm = 56.7pt)', Math.abs(p.boxes[0].x - 56.69) < 0.1, p.boxes[0].x);

// 그려 본다 — 빈 종이가 아니어야 한다
const c = createCanvas(Math.round(p.width), Math.round(p.height));
drawXfa(c, p, 1);
const px = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
let ink = 0;
for (let i = 0; i < px.length; i += 4) if (px[i] < 200) ink++;
ok('그리면 잉크가 남는다', ink > 500, ink);

// PDF 쪽 자체는 "Acrobat 으로 여세요" 한 줄뿐이다 — 그것도 확인
const t = await d.text(1);
ok('PDF 쪽에는 안내 한 줄뿐', /Acrobat/.test(t), t.slice(0, 40));
d.close();

console.log(fails === 0 ? 'XFA 통과' : `XFA 실패 ${fails}개`);
process.exit(fails === 0 ? 0 : 1);
