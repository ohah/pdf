// XFA 양식 — XML 을 읽어 자리와 글자를 뽑고, 캔버스에 그린다.
import { PDFDocument, readXfa, drawXfa, toPt, formCalc } from '../dist/index.js';
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

// ── 동적 XFA ──────────────────────────────────────────────────────────
//
// 자료가 길어지면 줄이 흐르고, 넘치면 쪽이 늘고, 합계는 스크립트가 셈한다.
// 그게 "동적" 이다. 스크립트는 여기서도 돌리지 않고 읽어서 셈한다.
{
  const d2 = await PDFDocument.open(new URL('./fixtures/xfa-dyn.pdf', import.meta.url).pathname);
  const f2 = readXfa(d2.xfaXml);
  ok('동적으로 알아본다', f2.dynamic === true);
  ok('자료만큼 되풀이한다', f2.repeated === 29, f2.repeated);
  ok('흐름 배치를 쓴다', f2.flowed > 0, f2.flowed);
  ok('넘치면 쪽이 는다', f2.pages.length === 2, f2.pages.length);
  const all = f2.pages.flatMap((p) => p.boxes);
  ok('줄이 아래로 흐른다',
    all.filter((b) => b.name === 'nm').slice(0, 3).map((b) => Math.round(b.y)).join(',') === '50,70,90',
    all.filter((b) => b.name === 'nm').slice(0, 3).map((b) => Math.round(b.y)));
  ok('줄마다 제 값', all.filter((b) => b.name === 'nm').slice(0, 2).map((b) => b.text).join('|') === '품목 1|품목 2',
    all.filter((b) => b.name === 'nm').slice(0, 2).map((b) => b.text));
  ok('FormCalc 합계', all.find((b) => b.name === 'total')?.text === '465000',
    all.find((b) => b.name === 'total')?.text);
  ok('셈한 칸 수', f2.calculated === 1 && f2.unreadScripts === 0, [f2.calculated, f2.unreadScripts]);
  ok('숨긴 마디는 안 그린다', !all.some((b) => b.text.includes('안 보여야')));
  d2.close();
}
// FormCalc 낱개
{
  const v = { a: '10', b: '4' };
  const at = (n) => v[n] ?? '';
  ok('FormCalc Sum', formCalc('Sum(a, b)', at) === '14', formCalc('Sum(a, b)', at));
  ok('FormCalc 곱', formCalc('a * b', at) === '40', formCalc('a * b', at));
  ok('FormCalc Max', formCalc('Max(a, b, 7)', at) === '10', formCalc('Max(a, b, 7)', at));
  ok('FormCalc 모르는 것은 null', formCalc('xfa.host.messageBox("x")', at) === null);
  ok('돌리지 않는다', formCalc('globalThis.__x = 1', at) === null && globalThis.__x === undefined);
}

console.log(fails === 0 ? 'XFA 통과' : `XFA 실패 ${fails}개`);
process.exit(fails === 0 ? 0 : 1);
