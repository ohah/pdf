/**
 * 양식에 붙은 자바스크립트를 **돌리지 않고** 읽어 셈한다.
 *
 * PDF 양식은 "수량 × 단가 = 금액", "합계 = 항목들의 합" 같은 셈을 칸에 붙은
 * 자바스크립트로 적어 둔다(/AA /C). 그걸 안 돌리면 값을 넣어도 다른 칸이
 * 그대로라, 계산서·견적서가 빈 채로 남는다.
 *
 * 그렇다고 eval 이나 new Function 으로 돌리면 문서가 준 코드가 이 페이지의
 * 모든 것에 손댈 수 있다. pdf.js 는 그래서 quickjs 를 따로 실어 가둔다.
 * 우리는 코드를 아예 실행하지 않는다 — 양식이 실제로 쓰는 좁은 문법만
 * 읽어 셈한다. 여기 없는 것은 건너뛰고, 무엇을 건너뛰었는지 알려 준다.
 *
 * 읽는 것:
 *   event.value = <식>;
 *   AFSimple_Calculate("SUM"|"AVG"|"PRD"|"MIN"|"MAX", ["가", "나"]);
 *   AFNumber_Format(자릿수, …) · AFPercent_Format(자릿수, …)   — 보이는 꼴만
 *   식: 숫자 · 문자열 · this.getField("이름").value · + - * / % · 괄호 ·
 *       Math.round|abs|min|max|floor|ceil · Number() · parseFloat()
 */

import { runJs, JsStop } from "./jsmini.js";

/** 칸 하나의 지금 값을 찾아 주는 이. 이름은 양식이 쓰는 그 이름이다. */
export type ValueOf = (name: string) => string;

type Tok = { k: "num" | "str" | "name" | "op"; v: string };

function lex(src: string): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (/\s/.test(c)) { i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { i = src.indexOf("*/", i + 2); if (i < 0) break; i += 2; continue; }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(src[i + 1] ?? ""))) {
      let j = i;
      while (j < src.length && /[0-9.]/.test(src[j])) j++;
      out.push({ k: "num", v: src.slice(i, j) });
      i = j;
      continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      let s = "";
      while (j < src.length && src[j] !== c) {
        if (src[j] === "\\" && j + 1 < src.length) { s += src[j + 1]; j += 2; continue; }
        s += src[j];
        j++;
      }
      out.push({ k: "str", v: s });
      i = j + 1;
      continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      let j = i;
      while (j < src.length && /[A-Za-z0-9_$]/.test(src[j])) j++;
      out.push({ k: "name", v: src.slice(i, j) });
      i = j;
      continue;
    }
    out.push({ k: "op", v: c });
    i++;
  }
  return out;
}

/** 못 읽는 문법을 만나면 이걸 던진다 — 그 칸만 건너뛴다. */
class Unsupported extends Error {}

class Reader {
  private at = 0;
  constructor(private t: Tok[], private val: ValueOf) {}

  done() { return this.at >= this.t.length; }
  peek(n = 0) { return this.t[this.at + n]; }
  next() { return this.t[this.at++]; }
  eat(v: string) {
    const t = this.t[this.at];
    if (t && t.v === v) { this.at++; return true; }
    return false;
  }
  want(v: string) { if (!this.eat(v)) throw new Unsupported(v); }

  /** 이름 하나: getField("x").value 를 읽어 값을 준다 */
  private field(): number | string {
    // this.getField("x") | getField("x")
    if (this.peek()?.v === "this") { this.next(); this.want("."); }
    const g = this.next();
    if (!g || g.v !== "getField") throw new Unsupported("getField");
    this.want("(");
    const nm = this.next();
    if (!nm || nm.k !== "str") throw new Unsupported("이름");
    this.want(")");
    this.want(".");
    const p = this.next();
    if (!p || (p.v !== "value" && p.v !== "valueAsString")) throw new Unsupported(p?.v ?? "");
    return this.val(nm.v);
  }

  primary(): number | string {
    const t = this.peek();
    if (!t) throw new Unsupported("끝");
    if (t.k === "num") { this.next(); return Number(t.v); }
    if (t.k === "str") { this.next(); return t.v; }
    if (t.v === "(") { this.next(); const v = this.expr(); this.want(")"); return v; }
    if (t.v === "-") { this.next(); return -num(this.primary()); }
    if (t.v === "+") { this.next(); return num(this.primary()); }
    if (t.k === "name") {
      if (t.v === "this" || t.v === "getField") return this.field();
      if (t.v === "Number" || t.v === "parseFloat" || t.v === "parseInt") {
        this.next(); this.want("(");
        const v = num(this.expr());
        this.want(")");
        return t.v === "parseInt" ? Math.trunc(v) : v;
      }
      if (t.v === "Math") {
        this.next(); this.want(".");
        const fn = this.next()?.v ?? "";
        this.want("(");
        const args: number[] = [num(this.expr())];
        while (this.eat(",")) args.push(num(this.expr()));
        this.want(")");
        switch (fn) {
          case "round": return Math.round(args[0]);
          case "floor": return Math.floor(args[0]);
          case "ceil": return Math.ceil(args[0]);
          case "abs": return Math.abs(args[0]);
          case "min": return Math.min(...args);
          case "max": return Math.max(...args);
          default: throw new Unsupported("Math." + fn);
        }
      }
      throw new Unsupported(t.v);
    }
    throw new Unsupported(t.v);
  }

  mul(): number | string {
    let v = this.primary();
    for (;;) {
      if (this.eat("*")) v = num(v) * num(this.primary());
      else if (this.eat("/")) { const d = num(this.primary()); v = d === 0 ? 0 : num(v) / d; }
      else if (this.eat("%")) { const d = num(this.primary()); v = d === 0 ? 0 : num(v) % d; }
      else return v;
    }
  }

  expr(): number | string {
    let v = this.mul();
    for (;;) {
      if (this.eat("+")) {
        const r = this.mul();
        // 규격이 그렇듯 둘 다 숫자로 읽히면 더하고, 아니면 잇는다
        v = typeof v === "string" && isNaN(Number(v)) ? String(v) + String(r) : num(v) + num(r);
      } else if (this.eat("-")) v = num(v) - num(this.mul());
      else return v;
    }
  }

  /** 이름 배열: ["가","나"] 또는 new Array("가","나") */
  names(): string[] {
    const out: string[] = [];
    if (this.eat("new")) {
      const a = this.next();
      if (!a || a.v !== "Array") throw new Unsupported("new " + (a?.v ?? ""));
      this.want("(");
      while (!this.eat(")")) {
        const t = this.next();
        if (!t) throw new Unsupported("배열");
        if (t.k === "str") out.push(t.v);
        else if (t.v !== ",") throw new Unsupported(t.v);
      }
      return out;
    }
    this.want("[");
    while (!this.eat("]")) {
      const t = this.next();
      if (!t) throw new Unsupported("배열");
      if (t.k === "str") out.push(t.v);
      else if (t.v !== ",") throw new Unsupported(t.v);
    }
    return out;
  }
}

function num(v: number | string): number {
  if (typeof v === "number") return v;
  // "1,234.50" · "₩1,234" 처럼 꾸며 둔 값도 숫자로 읽는다
  const n = parseFloat(String(v).replace(/[^0-9.\-]/g, ""));
  return isFinite(n) ? n : 0;
}

/** 셈한 결과를 문자열로. 자릿수를 주면 그만큼 반올림한다. */
function show(v: number | string, dec?: number): string {
  if (typeof v === "string") return v;
  if (!isFinite(v)) return "";
  return dec === undefined ? String(v) : v.toFixed(dec);
}

/**
 * 계산식 하나를 셈한다. 못 읽는 문법이면 null 을 준다 — 그 칸은 그대로 둔다.
 *
 * `format` 을 함께 주면 AFNumber_Format 의 자릿수만 본다(돈 기호·구분점은
 * 화면이 붙일 몫이라 값에는 넣지 않는다 — 그 값이 다시 계산식에 들어간다).
 */
/**
 * 좁은 읽기로 못 읽은 계산식을 해석기로 돌린다.
 *
 * 문서가 준 코드를 host 자바스크립트로 넘기지 않는다 — jsmini 가 한 마디씩
 * 해석한다. 그래서 전역도, fetch 도, 프로토타입을 타고 host 로 빠질 길도
 * 없다. 걸음과 시간에 한도가 있어 while(1) 도 멎는다.
 *
 * 양식이 실제로 쓰는 것들을 건넨다 — event, this.getField(), AF* 도우미,
 * app.alert(말만 모은다), util.printf.
 */
function runWithJs(calc: string, valueOf: ValueOf, dec?: number): string | null {
  const fields = new Map<string, { value: unknown }>();
  const field = (name: string) => {
    let f = fields.get(name);
    if (!f) { f = { value: valueOf(name) }; fields.set(name, f); }
    return f;
  };
  const ev = { value: "" as unknown, target: null as unknown, willCommit: true, rc: true };
  const said: string[] = [];
  const numOf = (v: unknown) => {
    const n = parseFloat(String(v ?? "").replace(/[^0-9.\-]/g, ""));
    return isFinite(n) ? n : 0;
  };
  const box = {
    event: ev,
    this: {
      getField: (n: unknown) => field(String(n)),
      resetForm: () => undefined,
      calculateNow: () => undefined,
      getPrintParams: () => ({}),
    },
    app: {
      alert: (m: unknown) => { said.push(String(m)); return 1; },
      beep: () => undefined,
    },
    util: {
      printf: (fmt: unknown, ...a: unknown[]) => {
        let i = 0;
        return String(fmt).replace(/%[0-9.]*[dfs]/g, () => String(a[i++] ?? ""));
      },
      printd: (_f: unknown, d: unknown) => String(d ?? ""),
    },
    AFNumber_Format: (d: unknown) => { ev.value = numOf(ev.value).toFixed(numOf(d)); },
    AFPercent_Format: (d: unknown) => { ev.value = numOf(ev.value).toFixed(numOf(d)); },
    AFDate_FormatEx: () => undefined,
    AFSpecial_Format: () => undefined,
    AFMakeNumber: (v: unknown) => numOf(v),
    AFSimple_Calculate: (how: unknown, names: unknown) => {
      const list = Array.isArray(names) ? names.map(String) : String(names).split(",");
      const vals = list.map((n) => numOf(valueOf(n.trim())));
      if (vals.length === 0) { ev.value = ""; return; }
      const k = String(how).toUpperCase();
      const v = k === "SUM" ? vals.reduce((a, b) => a + b, 0)
        : k === "AVG" ? vals.reduce((a, b) => a + b, 0) / vals.length
        : k === "PRD" ? vals.reduce((a, b) => a * b, 1)
        : k === "MIN" ? Math.min(...vals)
        : k === "MAX" ? Math.max(...vals) : NaN;
      ev.value = Number.isNaN(v) ? "" : String(v);
    },
  };
  try {
    runJs(calc, box as Record<string, unknown>);
  } catch (e) {
    if (e instanceof JsStop) return null;
    return null;
  }
  if (ev.value === "" || ev.value === undefined || ev.value === null) return null;
  const out = String(ev.value);
  if (dec === undefined) return out;
  const n = parseFloat(out.replace(/[^0-9.\-]/g, ""));
  return isFinite(n) ? n.toFixed(dec) : out;
}

export function runCalc(calc: string, valueOf: ValueOf, format = ""): string | null {
  let dec: number | undefined;
  if (format) {
    const m = /AF(?:Number|Percent)_Format\s*\(\s*(\d+)/.exec(format);
    if (m) dec = Number(m[1]);
  }
  try {
    const r = new Reader(lex(calc), valueOf);
    // AFSimple_Calculate("SUM", [...])
    if (r.peek()?.v === "AFSimple_Calculate") {
      r.next();
      r.want("(");
      const how = r.next();
      if (!how || how.k !== "str") throw new Unsupported("셈 갈래");
      r.want(",");
      const names = r.names();
      r.want(")");
      const nums = names.map((n) => num(valueOf(n)));
      if (nums.length === 0) return "";
      let v: number;
      switch (how.v.toUpperCase()) {
        case "SUM": v = nums.reduce((a, b) => a + b, 0); break;
        case "AVG": v = nums.reduce((a, b) => a + b, 0) / nums.length; break;
        case "PRD": v = nums.reduce((a, b) => a * b, 1); break;
        case "MIN": v = Math.min(...nums); break;
        case "MAX": v = Math.max(...nums); break;
        default: return null;
      }
      return show(v, dec);
    }
    // event.value = <식>;
    if (r.peek()?.v === "event") {
      r.next();
      r.want(".");
      const p = r.next();
      if (!p || p.v !== "value") throw new Unsupported(p?.v ?? "");
      r.want("=");
      const v = r.expr();
      return show(v, dec);
    }
    // 좁은 읽기로는 못 읽었다 — 해석기에 넘긴다
    return runWithJs(calc, valueOf, dec);
  } catch (e) {
    if (e instanceof Unsupported) return runWithJs(calc, valueOf, dec);
    return null;
  }
}

/** 셈할 칸 하나 — 이름과 계산식·서식만 있으면 된다. */
export type CalcField = { name: string; calc: string; format?: string };

/**
 * 값 하나를 고친 뒤 양식 전체를 다시 셈한다.
 *
 * `order` 는 문서가 정한 차례(/CO)다. 없으면 나온 차례대로 두 번 돈다 —
 * 앞 칸이 뒤 칸을 쓰는 양식도 한 번 더 돌면 맞아떨어진다.
 * 못 읽은 계산식은 `skipped` 에 이름으로 남는다.
 */
export function recalculate(
  fields: CalcField[], values: Record<string, string>, order?: string[],
): { values: Record<string, string>; skipped: string[] } {
  const out: Record<string, string> = { ...values };
  const skipped: string[] = [];
  const byName = new Map(fields.map((f) => [f.name, f]));
  const seq = order && order.length
    ? order.map((n) => byName.get(n)).filter((f): f is CalcField => !!f)
    : [...fields, ...fields];
  const valueOf: ValueOf = (n) => out[n] ?? "";
  for (const f of seq) {
    if (!f.calc) continue;
    const got = runCalc(f.calc, valueOf, f.format ?? "");
    if (got === null) {
      if (!skipped.includes(f.name)) skipped.push(f.name);
      continue;
    }
    out[f.name] = got;
  }
  return { values: out, skipped };
}
