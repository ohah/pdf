// 양식 계산식 — 돌리지 않고 읽어서 셈한다.
import { PDFDocument, recalculate, runCalc } from '../dist/index.js';

let fails = 0;
const ok = (n, c, got) => {
  if (c) console.log(`  통과  ${n}`);
  else { console.log(`  ✗    ${n}${got !== undefined ? ' (' + JSON.stringify(got) + ')' : ''}`); fails++; }
};

const d = await PDFDocument.open(new URL('./fixtures/calc.pdf', import.meta.url).pathname);
const fields = await d.fields(1);
const byName = Object.fromEntries(fields.map((f) => [f.name, f]));
ok('계산식이 실려 온다', !!byName.amount?.calc, byName.amount?.calc?.slice(0, 30));
ok('서식도 실려 온다', /AFNumber_Format/.test(byName.amount?.format ?? ''), byName.amount?.format);
ok('셈 차례(/CO)', d.calcOrder.length === 2, d.calcOrder);

// 문서가 정한 차례를 이름으로 옮긴다
const order = d.calcOrder.map((obj) => fields.find((f) => f.obj === obj)?.name ?? '').filter(Boolean);
ok('차례가 이름으로 풀린다', order.join(',') === 'amount,total', order);

const start = Object.fromEntries(fields.map((f) => [f.name, f.value]));
const { values, skipped } = recalculate(
  fields.map((f) => ({ name: f.name, calc: f.calc, format: f.format })), start, order);
ok('수량×단가', values.amount === '4500.00', values.amount);
ok('합계', values.total === '4500', values.total);
ok('못 읽은 계산식 없음', skipped.length === 0, skipped);

// 값을 바꾸면 다시 셈한다
const again = recalculate(
  fields.map((f) => ({ name: f.name, calc: f.calc, format: f.format })),
  { ...values, qty: '10' }, order);
ok('수량을 고치면 따라 바뀐다', again.values.amount === '15000.00' && again.values.total === '15000',
  [again.values.amount, again.values.total]);

// 못 읽는 문법은 조용히 건너뛴다 — 그 칸은 그대로 둔다
ok('모르는 문법은 null', runCalc('app.alert("hi"); event.value = 1;', () => '') === null);
ok('창구를 뒤지려는 것도 null', runCalc('event.value = globalThis.fetch("//x")', () => '') === null);
ok('식은 셈한다', runCalc('event.value = (2 + 3) * 4 - 1;', () => '') === '19');
ok('Math 도', runCalc('event.value = Math.round(3.6);', () => '') === '4');
ok('꾸민 값도 숫자로', runCalc('event.value = this.getField("a").value * 2;',
  (n) => (n === 'a' ? '1,234.50' : '')) === '2469');
ok('0 으로 나눠도 안 죽는다', runCalc('event.value = 1 / 0;', () => '') === '0');

d.close();
console.log(fails === 0 ? '양식 계산 통과' : `양식 계산 실패 ${fails}개`);
process.exit(fails === 0 ? 0 : 1);
