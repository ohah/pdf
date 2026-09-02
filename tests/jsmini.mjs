// 해석기 — 문서가 준 코드를 host 로 넘기지 않고 우리가 돌린다.
//
// 맞게 도는지와, 밖으로 새지 않는지를 함께 본다. 새는 쪽이 더 중요하다.
import { runJs, JsStop } from '../dist/jsmini.js';

let fails = 0;
const ok = (n, c, got) => {
  if (c) console.log(`  통과  ${n}`);
  else { console.log(`  ✗    ${n}${got !== undefined ? ' (' + JSON.stringify(got) + ')' : ''}`); fails++; }
};
const val = (src, box = {}) => { const b = { out: {}, ...box }; runJs(src, b); return b.out.v; };
const stops = (src, box = {}) => {
  try { runJs(src, { out: {}, ...box }); return false; } catch (e) { return e instanceof JsStop; }
};

// ── 맞게 도는가
ok('셈', val('out.v = (2 + 3) * 4 - 1;') === 19);
ok('문자열 잇기', val('out.v = "가" + 1 + "나";') === '가1나');
ok('비교', val('out.v = (2 < 3) && (3 <= 3) && !(4 == 5);') === true);
ok('삼항', val('out.v = 5 > 3 ? "큼" : "작음";') === '큼');
ok('변수와 블록', val('var a = 1; { var b = 2; out.v = a + b; }') === 3);
ok('반복', val('var s = 0; for (var i = 1; i <= 10; i++) s += i; out.v = s;') === 55);
ok('while·break', val('var i = 0; while (true) { i++; if (i > 4) break; } out.v = i;') === 5);
ok('do-while', val('var i = 0; do { i++; } while (i < 3); out.v = i;') === 3);
ok('함수와 되부름', val('function f(n){ return n <= 1 ? 1 : n * f(n-1); } out.v = f(5);') === 120);
ok('닫힘', val('function mk(a){ return function(b){ return a + b; }; } out.v = mk(3)(4);') === 7);
ok('배열', val('var a = [3,1,2]; a.push(9); out.v = a.length * 10 + a[3];') === 49);
ok('배열 메서드', val('out.v = [1,2,3].join("-");') === '1-2-3');
ok('객체', val('var o = {a: 1, "b": 2}; o.c = 3; out.v = o.a + o.b + o.c;') === 6);
ok('for-in', val('var o = {a:1,b:2}; var s = ""; for (var k in o) s += k; out.v = s;') === 'ab');
ok('문자열 메서드', val('out.v = " 가나다 ".trim().length + "ABC".toLowerCase();') === '3abc');
ok('숫자 서식', val('out.v = (1234.5678).toFixed(2);') === '1234.57');
ok('Math', val('out.v = Math.max(1, 9, 4) + Math.round(2.6);') === 12);
ok('typeof', val('out.v = typeof 1 + "," + typeof "a" + "," + typeof [];') === 'number,string,object');
ok('try·catch', val('try { throw "나쁨"; } catch (e) { out.v = "잡음"; }') === '잡음');
ok('건넨 것 읽고 쓰기', (() => {
  const b = { out: {}, fld: { value: '7' } };
  runJs('out.v = Number(fld.value) * 3; fld.value = "고침";', b);
  return b.out.v === 21 && b.fld.value === '고침';
})());

// ── 밖으로 새는가 (여기가 핵심이다)
ok('전역이 없다', val('out.v = typeof globalThis;') === 'undefined');
ok('window 도 없다', val('out.v = typeof window;') === 'undefined');
ok('fetch 도 없다', val('out.v = typeof fetch;') === 'undefined');
ok('document 도 없다', val('out.v = typeof document;') === 'undefined');
ok('process 도 없다', val('out.v = typeof process;') === 'undefined');
ok('require 도 없다', val('out.v = typeof require;') === 'undefined');
ok('eval 도 없다', val('out.v = typeof eval;') === 'undefined');
ok('Function 도 없다', val('out.v = typeof Function;') === 'undefined');
ok('배열로 프로토타입 못 탄다', val('out.v = typeof [].constructor;') === 'undefined');
ok('문자열로도 못 탄다', val('out.v = typeof "".constructor;') === 'undefined');
ok('숫자로도 못 탄다', val('out.v = typeof (1).constructor;') === 'undefined');
ok('객체로도 못 탄다', val('out.v = typeof ({}).constructor;') === 'undefined');
ok('__proto__ 도 안 준다', val('out.v = typeof ({}).__proto__;') === 'undefined');
ok('건넨 것의 프로토타입도 못 탄다', (() => {
  const b = { out: {}, fld: { value: 1 } };
  runJs('out.v = typeof fld.constructor;', b);
  return b.out.v === 'undefined';
})());
ok('host 함수를 만들 길이 없다', (() => {
  globalThis.__pwn = false;
  const b = { out: {}, f: () => 1 };
  try { runJs('f.constructor("globalThis.__pwn = true")();', b); } catch { /* 막힘 */ }
  return globalThis.__pwn === false;
})());

// ── 한도
ok('무한 반복은 멎는다', stops('while (1) { }'));
ok('무한 되부름도 멎는다', stops('function f(){ return f(); } f();'));
ok('깊은 반복도 멎는다', stops('for (var i = 0; i < 1e9; i++) { }'));
ok('템플릿 글자', val('out.v = `가${1 + 1}나`;') === '가2나');
ok('switch', val('var x = 2; switch (x) { case 1: out.v = "하나"; break; case 2: out.v = "둘"; break; default: out.v = "몰라"; }') === '둘');
ok('switch 기본값', val('switch (9) { case 1: out.v = "하나"; break; default: out.v = "몰라"; }') === '몰라');
ok('화살표 함수', val('var f = (x) => x * 2; out.v = f(4);') === 8);
ok('화살표 한 인자', val('var f = x => x + 1; out.v = f(1);') === 2);
ok('정규식 test', val('out.v = /^[0-9]+$/.test("12345");') === true);
ok('정규식 replace', val('out.v = "1,234,567".replace(/,/g, "");') === '1234567');
ok('정규식 match', val('out.v = ("가2나3".match(/[0-9]/g) || []).length;') === 2);
ok('정규식 split', val('out.v = "a1b2c".split(/[0-9]/).length;') === 3);
ok('날짜', val('out.v = typeof new Date().getFullYear();') === 'number');
ok('JSON', val('out.v = JSON.parse(JSON.stringify({a: 5})).a;') === 5);
ok('되돌이 터질 정규식은 막는다', stops('out.v = /(a+)+b/.test("aaaaaaaaaaaaaaaaaaaaaaaaaa!");'));
ok('풀어 받기(배열)', val('var [a, b] = [1, 2]; out.v = a + b;') === 3);
ok('풀어 받기(객체)', val('var {x, y: z} = {x: 3, y: 4}; out.v = x * z;') === 12);
ok('모르는 문법은 멎는다', stops('out.v = class X {};'));
ok('await 도 멎는다', stops('await x;'));

// 실제 양식에서 흔한 꼴 — 몇이나 도는지 세어 둔다
{
  const real = [
    'var t=0; for (var i=1;i<=3;i++) t+=Number(this.getField("a"+i).value); event.value=t;',
    'if (this.getField("kind").value == "개인") event.value = 0.1; else event.value = 0.2;',
    'AFNumber_Format(2, 0, 0, 0, "원", true);',
    'if (event.value == "") { app.alert("채우세요"); event.rc = false; }',
    'switch (this.getField("t").value) { case "A": event.value=1; break; default: event.value=0; }',
    'event.value = /^[0-9]+$/.test(event.value) ? "맞음" : "틀림";',
    'event.value = event.value.replace(/,/g, "");',
    'event.value = new Date().getFullYear();',
    'event.value = `${1+1}개`;',
    'var f = (x) => x * 2; event.value = f(4);',
    'var [a, b] = [1, 2]; event.value = a + b;',
    'let fs=[]; for (let i=0;i<3;i++) fs.push(function(){return i;}); event.value=fs[0]();',
    'event.value = JSON.stringify({a:1}).length;',
    'event.value = util.printf("%.2f", 3.14159);',
    'event.value = 1 ? 2 ? "a" : "b" : "c";',
  ];
  let ran = 0;
  for (const src of real) {
    const box = { event: { value: '5', rc: true }, this: { getField: () => ({ value: '1' }) },
      app: { alert: () => 1 }, util: { printf: () => '3.14' }, AFNumber_Format: () => {} };
    try { runJs(src, box); ran++; } catch { /* 못 읽음 */ }
  }
  ok(`실제 양식 꼴 ${ran}/${real.length}`, ran === real.length, ran);
}

console.log(fails === 0 ? '해석기 통과' : `해석기 실패 ${fails}개`);
process.exit(fails === 0 ? 0 : 1);
