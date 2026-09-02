/**
 * 문서가 준 자바스크립트를 **우리가 해석해서** 돌린다.
 *
 * PDF·XFA 양식은 스크립트로 굴러간다. 값을 셈할 뿐 아니라 칸을 감추고,
 * 표의 줄을 늘리고, 모양을 바꾼다. 그걸 안 하면 관공서·보험 양식이
 * 반쪽으로 보인다.
 *
 * 그렇다고 host 의 eval 이나 new Function 으로 돌리면, 문서가 준 코드가
 * 이 페이지의 쿠키·DOM·네트워크에 손댈 수 있다. pdf.js 는 그래서 quickjs
 * (458KB)를 따로 실어 딴 세계에 가둔다.
 *
 * 우리는 세 번째 길을 간다. 코드를 host 자바스크립트로 **넘기지 않고**
 * 여기서 한 마디씩 해석한다. 그래서:
 *
 *   - 전역이라는 것이 아예 없다. 우리가 건네준 것 말고는 이름조차 없다.
 *     globalThis·fetch·document 를 적으면 "그런 이름 없음" 이다.
 *   - 프로토타입을 타고 올라갈 길이 없다. `[].constructor` 는 undefined 다.
 *   - 걸음 수와 시간에 한도가 있다. while(1) 은 한도에서 멎는다.
 *   - 실을 것이 늘지 않는다. 이 파일이 전부다.
 *
 * 다루는 것은 ES5 의 실용 범위다 — var·let·const, if·else, for(;;)·for-in,
 * while·do, break·continue, function(이름 있는 것과 없는 것, 닫힘 포함),
 * return, 삼항, 논리·비교·산술, ++·--, typeof, 객체·배열 리터럴, 속성 접근,
 * 호출, new(우리가 준 것만), throw·try·catch.
 */

/** 밖에서 건네는 것들. 여기 없는 이름은 문서 코드가 볼 수 없다. */
export type Sandbox = Record<string, unknown>;

export type RunOpts = {
  /** 걸음 한도. 넘으면 멎는다 (기본 200,000) */
  steps?: number;
  /** 시간 한도(ms). 넘으면 멎는다 (기본 200) */
  ms?: number;
};

/** 한도에 걸리거나 문법을 못 읽으면 이걸 던진다. */
export class JsStop extends Error {}

// ── 토막내기 ──────────────────────────────────────────────────────────────

type Tok = { k: "num" | "str" | "name" | "punc" | "regex" | "tpl"; v: string; nl: boolean };

const PUNCS = [
  ">>>=", "===", "!==", "**=", "...", "<<=", ">>=", ">>>",
  "==", "!=", "<=", ">=", "&&", "||", "??", "++", "--", "+=", "-=", "*=", "/=",
  "%=", "&=", "|=", "^=", "=>", "**", "<<", ">>",
  "{", "}", "(", ")", "[", "]", ";", ",", "<", ">", "+", "-", "*", "/", "%",
  "&", "|", "^", "!", "~", "?", ":", "=", ".",
];

function lex(src: string): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  let nl = false;
  while (i < src.length) {
    const c = src[i];
    if (c === "\n") { nl = true; i++; continue; }
    if (/\s/.test(c)) { i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") {
      const e = src.indexOf("*/", i + 2);
      i = e < 0 ? src.length : e + 2;
      continue;
    }
    // 정규식 — 식이 시작되는 자리의 / 만 정규식으로 본다. 나눗셈과 갈린다.
    if (c === "/") {
      const prev = out[out.length - 1];
      const canRe = !prev || (prev.k === "punc" && !")]}".includes(prev.v)) ||
        (prev.k === "name" && ["return", "typeof", "case", "in", "of", "new", "delete"].includes(prev.v));
      if (canRe) {
        let j = i + 1;
        let cls = false;
        let body = "";
        while (j < src.length) {
          const ch = src[j];
          if (ch === "\\") { body += ch + (src[j + 1] ?? ""); j += 2; continue; }
          if (ch === "[") cls = true;
          else if (ch === "]") cls = false;
          else if (ch === "/" && !cls) break;
          else if (ch === "\n") { j = src.length; break; }
          body += ch;
          j++;
        }
        if (j < src.length && src[j] === "/") {
          j++;
          let flags = "";
          while (j < src.length && /[a-z]/.test(src[j])) { flags += src[j]; j++; }
          out.push({ k: "regex", v: body + "\u0000" + flags, nl });
          nl = false;
          i = j;
          continue;
        }
      }
    }
    // 템플릿 글자 — `가${1 + 2}나`
    if (c === "`") {
      let j = i + 1;
      let raw = "";
      let depth = 0;
      while (j < src.length) {
        if (src[j] === "\\") { raw += src[j] + (src[j + 1] ?? ""); j += 2; continue; }
        if (src[j] === "$" && src[j + 1] === "{") depth++;
        if (src[j] === "}" && depth > 0) depth--;
        if (src[j] === "`" && depth === 0) break;
        raw += src[j];
        j++;
      }
      out.push({ k: "tpl", v: raw, nl });
      nl = false;
      i = j + 1;
      continue;
    }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(src[i + 1] ?? ""))) {
      let j = i;
      if (c === "0" && /[xX]/.test(src[i + 1] ?? "")) {
        j = i + 2;
        while (j < src.length && /[0-9a-fA-F]/.test(src[j])) j++;
      } else {
        while (j < src.length && /[0-9.eE]/.test(src[j])) {
          if (/[eE]/.test(src[j]) && /[-+]/.test(src[j + 1] ?? "")) j++;
          j++;
        }
      }
      out.push({ k: "num", v: src.slice(i, j), nl });
      nl = false;
      i = j;
      continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      let s = "";
      while (j < src.length && src[j] !== c) {
        if (src[j] === "\\") {
          const e = src[j + 1] ?? "";
          s += e === "n" ? "\n" : e === "t" ? "\t" : e === "r" ? "\r" : e;
          j += 2;
          continue;
        }
        s += src[j];
        j++;
      }
      out.push({ k: "str", v: s, nl });
      nl = false;
      i = j + 1;
      continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      let j = i;
      while (j < src.length && /[A-Za-z0-9_$]/.test(src[j])) j++;
      out.push({ k: "name", v: src.slice(i, j), nl });
      nl = false;
      i = j;
      continue;
    }
    const hit = PUNCS.find((p) => src.startsWith(p, i));
    if (!hit) throw new JsStop(`모르는 글자 ${c}`);
    out.push({ k: "punc", v: hit, nl });
    nl = false;
    i += hit.length;
  }
  return out;
}

// ── 나무 짓기 ─────────────────────────────────────────────────────────────

type Node2 = { t: string; [k: string]: unknown };

/** 풀어 받기 꼴 */
type Pat =
  | { kind: "arr"; items: (string | null)[] }
  | { kind: "obj"; pairs: { key: string; name: string }[] };

class Parser {
  private at = 0;
  constructor(private t: Tok[]) {}

  private peek(n = 0) { return this.t[this.at + n]; }
  private next() {
    const t = this.t[this.at++];
    if (!t) throw new JsStop("끝났는데 더 읽으려 한다");
    return t;
  }
  private is(v: string, n = 0) { const t = this.peek(n); return !!t && t.v === v && t.k !== "str"; }
  private eat(v: string) { if (this.is(v)) { this.at++; return true; } return false; }
  private want(v: string) { if (!this.eat(v)) throw new JsStop(`${v} 가 있어야 한다`); }
  private done() { return this.at >= this.t.length; }

  program(): Node2 {
    const body: Node2[] = [];
    while (!this.done()) body.push(this.statement());
    return { t: "Block", body };
  }

  statement(): Node2 {
    if (this.eat(";")) return { t: "Empty" };
    if (this.is("{")) return this.block();
    const w = this.peek();
    if (w?.k === "name") {
      switch (w.v) {
        case "var": case "let": case "const": return this.decl();
        case "if": return this.ifStmt();
        case "for": return this.forStmt();
        case "while": {
          this.next(); this.want("(");
          const test = this.expr(); this.want(")");
          return { t: "While", test, body: this.statement() };
        }
        case "do": {
          this.next();
          const body = this.statement();
          if (!this.eat("while")) throw new JsStop("do 에는 while 이 따라야 한다");
          this.want("("); const test = this.expr(); this.want(")"); this.eat(";");
          return { t: "DoWhile", test, body };
        }
        case "function": return this.fnDecl();
        case "return": {
          this.next();
          const has = !this.is(";") && !this.is("}") && !this.done() && !this.peek()!.nl;
          const arg = has ? this.expr() : null;
          this.eat(";");
          return { t: "Return", arg };
        }
        case "break": this.next(); this.eat(";"); return { t: "Break" };
        case "continue": this.next(); this.eat(";"); return { t: "Continue" };
        case "switch": {
          this.next(); this.want("(");
          const disc = this.expr(); this.want(")"); this.want("{");
          const cases: { test: Node2 | null; body: Node2[] }[] = [];
          while (!this.is("}")) {
            if (this.done()) throw new JsStop("} 가 없다");
            let test: Node2 | null = null;
            if (this.eat("case")) { test = this.expr(); this.want(":"); }
            else if (this.eat("default")) { this.want(":"); }
            else throw new JsStop("case 가 있어야 한다");
            const body: Node2[] = [];
            while (!this.is("case") && !this.is("default") && !this.is("}")) {
              if (this.done()) throw new JsStop("} 가 없다");
              body.push(this.statement());
            }
            cases.push({ test, body });
          }
          this.want("}");
          return { t: "Switch", disc, cases };
        }
        case "throw": {
          this.next();
          const arg = this.expr();
          this.eat(";");
          return { t: "Throw", arg };
        }
        case "try": {
          this.next();
          const block = this.block();
          let param: string | null = null;
          let handler: Node2 | null = null;
          if (this.eat("catch")) {
            if (this.eat("(")) { param = this.next().v; this.want(")"); }
            handler = this.block();
          }
          const fin = this.eat("finally") ? this.block() : null;
          return { t: "Try", block, param, handler, fin };
        }
        default: break;
      }
    }
    const e = this.expr();
    this.eat(";");
    return { t: "ExprStmt", expr: e };
  }

  private block(): Node2 {
    this.want("{");
    const body: Node2[] = [];
    while (!this.is("}")) {
      if (this.done()) throw new JsStop("} 가 없다");
      body.push(this.statement());
    }
    this.want("}");
    return { t: "Block", body };
  }

  private decl(): Node2 {
    this.next();
    const list: { name: string; init: Node2 | null; pat?: Pat }[] = [];
    do {
      // 풀어 받기 — var [a, b] = … · var {a, b: c} = …
      if (this.is("[") || this.is("{")) {
        const pat = this.pattern();
        this.want("=");
        list.push({ name: "", init: this.assign(), pat });
        continue;
      }
      const name = this.next().v;
      const init = this.eat("=") ? this.assign() : null;
      list.push({ name, init });
    } while (this.eat(","));
    this.eat(";");
    return { t: "Decl", list };
  }

  /** [a, b] 또는 {a, b: c} 를 읽는다 */
  private pattern(): Pat {
    if (this.eat("[")) {
      const items: (string | null)[] = [];
      while (!this.eat("]")) {
        if (this.eat(",")) { items.push(null); continue; }
        const t = this.next();
        if (t.k !== "name") throw new JsStop("이름이 있어야 한다");
        items.push(t.v);
        if (!this.is("]")) this.want(",");
      }
      return { kind: "arr", items };
    }
    this.want("{");
    const pairs: { key: string; name: string }[] = [];
    while (!this.eat("}")) {
      const k = this.next();
      if (k.k !== "name" && k.k !== "str") throw new JsStop("이름이 있어야 한다");
      let nm = k.v;
      if (this.eat(":")) {
        const v = this.next();
        if (v.k !== "name") throw new JsStop("이름이 있어야 한다");
        nm = v.v;
      }
      pairs.push({ key: k.v, name: nm });
      if (!this.is("}")) this.want(",");
    }
    return { kind: "obj", pairs };
  }

  private ifStmt(): Node2 {
    this.next(); this.want("(");
    const test = this.expr(); this.want(")");
    const then = this.statement();
    const alt = this.eat("else") ? this.statement() : null;
    return { t: "If", test, then, alt };
  }

  private forStmt(): Node2 {
    this.next(); this.want("(");
    // for (x in y)
    const save = this.at;
    if (this.is("var") || this.is("let") || this.is("const")) {
      this.next();
      const name = this.peek()?.v ?? "";
      if (this.peek(1)?.v === "in") {
        this.next(); this.next();
        const obj = this.expr();
        this.want(")");
        return { t: "ForIn", name, obj, body: this.statement() };
      }
      this.at = save;
    }
    const init = this.is(";") ? null : (this.is("var") || this.is("let") || this.is("const")) ? this.decl() : { t: "ExprStmt", expr: this.expr() };
    if (!this.t[this.at - 1] || this.t[this.at - 1].v !== ";") this.eat(";");
    const test = this.is(";") ? null : this.expr();
    this.want(";");
    const step = this.is(")") ? null : this.expr();
    this.want(")");
    return { t: "For", init, test, step, body: this.statement() };
  }

  private fnDecl(): Node2 {
    this.next();
    const name = this.peek()?.k === "name" ? this.next().v : "";
    const params = this.params();
    const body = this.block();
    return { t: "FnDecl", name, params, body };
  }

  private params(): string[] {
    this.want("(");
    const out: string[] = [];
    while (!this.eat(")")) {
      const t = this.next();
      if (t.k === "name") out.push(t.v);
      else if (t.v !== ",") throw new JsStop("이름이 있어야 한다");
    }
    return out;
  }

  expr(): Node2 {
    let e = this.assign();
    while (this.eat(",")) e = { t: "Seq", a: e, b: this.assign() };
    return e;
  }

  assign(): Node2 {
    // 화살표 함수 — x => …  또는  (a, b) => …
    const arrow = this.tryArrow();
    if (arrow) return arrow;
    const left = this.ternary();
    for (const op of ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="]) {
      if (this.is(op)) {
        this.next();
        return { t: "Assign", op, left, right: this.assign() };
      }
    }
    return left;
  }

  /** 화살표 함수면 읽어 준다. 아니면 자리를 되돌리고 null. */
  private tryArrow(): Node2 | null {
    const save = this.at;
    const t = this.peek();
    if (t?.k === "name" && this.peek(1)?.v === "=>" && this.peek(1)?.k === "punc") {
      this.next(); this.next();
      return this.arrowBody([t.v]);
    }
    if (t?.k === "punc" && t.v === "(") {
      // 짝이 맞는 ) 를 찾아 그 뒤가 => 인지 본다
      let d = 0;
      let i = this.at;
      while (i < this.t.length) {
        const x = this.t[i];
        if (x.k === "punc" && x.v === "(") d++;
        else if (x.k === "punc" && x.v === ")") { d--; if (d === 0) break; }
        i++;
      }
      const after = this.t[i + 1];
      if (after && after.k === "punc" && after.v === "=>") {
        const params: string[] = [];
        this.next();
        while (!this.eat(")")) {
          const n2 = this.next();
          if (n2.k === "name") params.push(n2.v);
          else if (n2.v !== ",") { this.at = save; return null; }
        }
        this.want("=>");
        return this.arrowBody(params);
      }
    }
    return null;
  }

  private arrowBody(params: string[]): Node2 {
    if (this.is("{")) {
      const body = this.block();
      return { t: "FnExpr", name: "", params, body };
    }
    const e = this.assign();
    return { t: "FnExpr", name: "", params, body: { t: "Block", body: [{ t: "Return", arg: e }] } };
  }

  private ternary(): Node2 {
    const test = this.binary(0);
    if (!this.eat("?")) return test;
    const yes = this.assign();
    this.want(":");
    return { t: "Cond", test, yes, no: this.assign() };
  }

  private binary(min: number): Node2 {
    let left = this.unary();
    for (;;) {
      const t = this.peek();
      if (!t || t.k === "str" || t.k === "num") break;
      const p = PREC[t.v];
      if (p === undefined || p < min) break;
      this.next();
      const right = this.binary(p + 1);
      left = { t: "Bin", op: t.v, left, right };
    }
    return left;
  }

  private unary(): Node2 {
    const t = this.peek();
    // 글자값을 연산자로 잘못 보면 안 된다 — join("-") 의 "-" 가 빼기가 됐다
    const sign = t && (t.k === "punc" || (t.k === "name" && t.v === "typeof"));
    if (sign && (t.v === "!" || t.v === "-" || t.v === "+" || t.v === "~" || t.v === "typeof")) {
      this.next();
      return { t: "Un", op: t.v, arg: this.unary() };
    }
    if (sign && (t.v === "++" || t.v === "--")) {
      this.next();
      return { t: "Update", op: t.v, pre: true, arg: this.unary() };
    }
    return this.postfix();
  }

  private postfix(): Node2 {
    let e = this.callee();
    const t = this.peek();
    if (t && t.k === "punc" && (t.v === "++" || t.v === "--") && !t.nl) {
      this.next();
      e = { t: "Update", op: t.v, pre: false, arg: e };
    }
    return e;
  }

  private callee(): Node2 {
    let e: Node2;
    if (this.is("new")) {
      this.next();
      const target = this.primary();
      const args = this.is("(") ? this.args() : [];
      e = { t: "New", target, args };
    } else {
      e = this.primary();
    }
    for (;;) {
      if (this.eat(".")) {
        e = { t: "Member", obj: e, name: this.next().v, computed: false };
      } else if (this.eat("[")) {
        const k = this.expr();
        this.want("]");
        e = { t: "Member", obj: e, key: k, computed: true };
      } else if (this.is("(")) {
        e = { t: "Call", fn: e, args: this.args() };
      } else break;
    }
    return e;
  }

  private args(): Node2[] {
    this.want("(");
    const out: Node2[] = [];
    while (!this.eat(")")) {
      out.push(this.assign());
      if (!this.is(")")) this.want(",");
    }
    return out;
  }

  private primary(): Node2 {
    const t = this.next();
    if (t.k === "num") return { t: "Num", v: Number(t.v) };
    if (t.k === "str") return { t: "Str", v: t.v };
    if (t.k === "regex") {
      const cut = t.v.indexOf("\u0000");
      return { t: "Regex", src: t.v.slice(0, cut), flags: t.v.slice(cut + 1) };
    }
    if (t.k === "tpl") return { t: "Tpl", parts: tplParts(t.v) };
    if (t.k === "name") {
      // 못 다루는 낱말은 조용히 undefined 로 넘기지 않는다 — 틀린 값을
      // 내놓느니 "못 읽었다" 고 말하는 편이 낫다
      if (["class", "import", "export", "async", "await", "yield", "with", "debugger", "super"]
        .includes(t.v)) throw new JsStop(`${t.v} 는 못 읽는다`);
      switch (t.v) {
        case "true": return { t: "Bool", v: true };
        case "false": return { t: "Bool", v: false };
        case "null": return { t: "Null" };
        case "undefined": return { t: "Undef" };
        case "function": {
          this.at--;
          const f = this.fnDecl();
          return { t: "FnExpr", name: f.name, params: f.params, body: f.body };
        }
        default: return { t: "Name", name: t.v };
      }
    }
    if (t.v === "(") { const e = this.expr(); this.want(")"); return e; }
    if (t.v === "[") {
      const items: Node2[] = [];
      while (!this.eat("]")) {
        items.push(this.assign());
        if (!this.is("]")) this.want(",");
      }
      return { t: "Arr", items };
    }
    if (t.v === "{") {
      const props: { key: string; val: Node2 }[] = [];
      while (!this.eat("}")) {
        const k = this.next();
        const key = k.k === "str" || k.k === "num" ? k.v : k.v;
        this.want(":");
        props.push({ key, val: this.assign() });
        if (!this.is("}")) this.want(",");
      }
      return { t: "Obj", props };
    }
    throw new JsStop(`못 읽는 자리 ${t.v}`);
  }
}

/** `가${1+2}나` 를 [글자, 식, 글자…] 로 나눈다. 식은 다시 읽는다. */
function tplParts(raw: string): { s?: string; e?: Node2 }[] {
  const out: { s?: string; e?: Node2 }[] = [];
  let i = 0;
  let lit = "";
  while (i < raw.length) {
    if (raw[i] === "\\") { lit += raw[i + 1] ?? ""; i += 2; continue; }
    if (raw[i] === "$" && raw[i + 1] === "{") {
      let d = 1;
      let j = i + 2;
      let src = "";
      while (j < raw.length && d > 0) {
        if (raw[j] === "{") d++;
        else if (raw[j] === "}") { d--; if (d === 0) break; }
        src += raw[j];
        j++;
      }
      if (lit) { out.push({ s: lit }); lit = ""; }
      out.push({ e: new Parser(lex(src)).expr() });
      i = j + 1;
      continue;
    }
    lit += raw[i];
    i++;
  }
  if (lit) out.push({ s: lit });
  return out;
}

const PREC: Record<string, number> = {
  "||": 1, "??": 1, "&&": 2, "|": 3, "^": 4, "&": 5,
  "==": 6, "!=": 6, "===": 6, "!==": 6,
  "<": 7, ">": 7, "<=": 7, ">=": 7, "instanceof": 7,
  "<<": 8, ">>": 8, ">>>": 8,
  "+": 9, "-": 9,
  "*": 10, "/": 10, "%": 10,
  "**": 11,
};

// ── 돌리기 ────────────────────────────────────────────────────────────────

type Scope = { vars: Map<string, unknown>; up: Scope | null };

/** 우리가 만든 함수. host 함수와 구별한다. */
type Fn = { params: string[]; body: Node2; scope: Scope; name: string; self?: unknown };

const BREAK = { s: "break" } as const;
const CONT = { s: "continue" } as const;
type Flow = typeof BREAK | typeof CONT | { s: "return"; v: unknown } | null;

class Machine {
  private steps = 0;
  private depth = 0;
  private until: number;
  constructor(private cap: number, ms: number) { this.until = Date.now() + ms; }

  tick() {
    this.steps++;
    if (this.steps > this.cap) throw new JsStop("걸음 한도를 넘었다");
    if ((this.steps & 1023) === 0 && Date.now() > this.until) throw new JsStop("시간이 다 됐다");
  }

  look(sc: Scope | null, name: string): { sc: Scope } | null {
    let s = sc;
    while (s) {
      if (s.vars.has(name)) return { sc: s };
      s = s.up;
    }
    return null;
  }

  get(sc: Scope, name: string): unknown {
    const hit = this.look(sc, name);
    if (!hit) return undefined;
    return hit.sc.vars.get(name);
  }

  set(sc: Scope, name: string, v: unknown) {
    const hit = this.look(sc, name);
    if (hit) hit.sc.vars.set(name, v);
    else {
      // 못 찾으면 가장 안쪽에 만든다 — 전역이라는 것이 따로 없다
      let s = sc;
      while (s.up) s = s.up;
      s.vars.set(name, v);
    }
  }

  /**
   * 속성을 읽는다.
   *
   * 프로토타입을 타고 올라가지 않는다. 문자열·배열·숫자에는 우리가 정한
   * 것만 있다 — `[].constructor` 같은 길로 host 로 빠져나갈 수 없다.
   */
  member(obj: unknown, key: string): unknown {
    if (obj === null || obj === undefined) throw new JsStop(`${key} 를 없는 것에서 읽으려 한다`);
    if (typeof obj === "string") return strMember(obj, key);
    if (typeof obj === "number") return numMember(obj, key);
    if (Array.isArray(obj)) return arrMember(obj, key);
    if (isRe(obj)) return reMember(obj, key);
    if (typeof obj === "object") {
      const o = obj as Record<string, unknown>;
      // 우리가 건넨 host 객체는 제 것만 준다
      if (Object.prototype.hasOwnProperty.call(o, key)) return o[key];
      // getter 를 단 host 객체도 있다
      const d = Object.getOwnPropertyDescriptor(o, key);
      if (d) return d.get ? d.get.call(o) : d.value;
      return undefined;
    }
    if (typeof obj === "function") return undefined;
    return undefined;
  }

  put(obj: unknown, key: string, v: unknown) {
    if (obj === null || obj === undefined) throw new JsStop("없는 것에 넣으려 한다");
    if (Array.isArray(obj)) {
      const i = Number(key);
      if (Number.isInteger(i) && i >= 0) obj[i] = v;
      return;
    }
    if (typeof obj === "object") {
      (obj as Record<string, unknown>)[key] = v;
    }
  }

  call(fn: unknown, self: unknown, args: unknown[]): unknown {
    this.tick();
    if (typeof fn === "function") {
      // host 가 건넨 함수 — 우리가 준 것만 여기 있다
      return (fn as (...a: unknown[]) => unknown).apply(self, args);
    }
    const f = fn as Fn | undefined;
    if (!f || !f.body) throw new JsStop("부를 수 없는 것을 불렀다");
    // 되부름이 깊어지면 host 의 스택이 먼저 넘친다 — 우리가 먼저 멈춘다
    if (++this.depth > 200) { this.depth--; throw new JsStop("너무 깊이 들어갔다"); }
    const sc: Scope = { vars: new Map(), up: f.scope };
    f.params.forEach((p, i) => sc.vars.set(p, args[i]));
    sc.vars.set("arguments", args);
    if (self !== undefined) sc.vars.set("this", self);
    try {
      const flow = this.run(f.body, sc);
      return flow && flow.s === "return" ? flow.v : undefined;
    } finally {
      this.depth--;
    }
  }

  run(n: Node2, sc: Scope): Flow {
    this.tick();
    switch (n.t) {
      case "Block": {
        const inner: Scope = { vars: new Map(), up: sc };
        for (const st of n.body as Node2[]) {
          const f = this.run(st, inner);
          if (f) return f;
        }
        return null;
      }
      case "Empty": return null;
      case "ExprStmt": this.eval(n.expr as Node2, sc); return null;
      case "Decl": {
        for (const d of n.list as { name: string; init: Node2 | null; pat?: Pat }[]) {
          const v = d.init ? this.eval(d.init, sc) : undefined;
          if (d.pat) {
            if (d.pat.kind === "arr") {
              const arr = Array.isArray(v) ? v : [];
              d.pat.items.forEach((nm, i) => { if (nm) sc.vars.set(nm, arr[i]); });
            } else {
              for (const pr of d.pat.pairs) sc.vars.set(pr.name, this.member(v, pr.key));
            }
            continue;
          }
          sc.vars.set(d.name, v);
        }
        return null;
      }
      case "If":
        if (truthy(this.eval(n.test as Node2, sc))) return this.run(n.then as Node2, sc);
        return n.alt ? this.run(n.alt as Node2, sc) : null;
      case "While": {
        while (truthy(this.eval(n.test as Node2, sc))) {
          this.tick();
          const f = this.run(n.body as Node2, sc);
          if (f === BREAK) break;
          if (f && f !== CONT) return f;
        }
        return null;
      }
      case "DoWhile": {
        do {
          this.tick();
          const f = this.run(n.body as Node2, sc);
          if (f === BREAK) break;
          if (f && f !== CONT) return f;
        } while (truthy(this.eval(n.test as Node2, sc)));
        return null;
      }
      case "For": {
        const inner: Scope = { vars: new Map(), up: sc };
        if (n.init) this.run(n.init as Node2, inner);
        while (n.test === null || truthy(this.eval(n.test as Node2, inner))) {
          this.tick();
          const f = this.run(n.body as Node2, inner);
          if (f === BREAK) break;
          if (f && f !== CONT) return f;
          if (n.step) this.eval(n.step as Node2, inner);
        }
        return null;
      }
      case "ForIn": {
        const obj = this.eval(n.obj as Node2, sc);
        const keys = Array.isArray(obj)
          ? obj.map((_, i) => String(i))
          : obj && typeof obj === "object" ? Object.keys(obj as object) : [];
        const inner: Scope = { vars: new Map(), up: sc };
        for (const k of keys) {
          this.tick();
          inner.vars.set(n.name as string, k);
          const f = this.run(n.body as Node2, inner);
          if (f === BREAK) break;
          if (f && f !== CONT) return f;
        }
        return null;
      }
      case "FnDecl": {
        sc.vars.set(n.name as string, {
          params: n.params as string[], body: n.body as Node2, scope: sc, name: n.name as string,
        } as Fn);
        return null;
      }
      case "Switch": {
        const d = this.eval(n.disc as Node2, sc);
        const cases = n.cases as { test: Node2 | null; body: Node2[] }[];
        let on = false;
        const inner: Scope = { vars: new Map(), up: sc };
        for (const c of cases) {
          if (!on && c.test !== null && d === this.eval(c.test, inner)) on = true;
          if (!on) continue;
          for (const st of c.body) {
            const f = this.run(st, inner);
            if (f === BREAK) return null;
            if (f) return f;
          }
        }
        if (!on) {
          // 맞는 것이 없으면 default 부터 흐른다
          let seen = false;
          for (const c of cases) {
            if (!seen && c.test !== null) continue;
            seen = true;
            for (const st of c.body) {
              const f = this.run(st, inner);
              if (f === BREAK) return null;
              if (f) return f;
            }
          }
        }
        return null;
      }
      case "Return": return { s: "return", v: n.arg ? this.eval(n.arg as Node2, sc) : undefined };
      case "Break": return BREAK;
      case "Continue": return CONT;
      case "Throw": throw new JsStop(`문서가 던졌다: ${str(this.eval(n.arg as Node2, sc))}`);
      case "Try": {
        try {
          const f = this.run(n.block as Node2, sc);
          if (f) return f;
        } catch (e) {
          if (e instanceof JsStop && /한도|시간/.test(e.message)) throw e;
          if (n.handler) {
            const inner: Scope = { vars: new Map(), up: sc };
            if (n.param) inner.vars.set(n.param as string, { message: String(e) });
            const f = this.run(n.handler as Node2, inner);
            if (f) return f;
          }
        } finally {
          if (n.fin) this.run(n.fin as Node2, sc);
        }
        return null;
      }
      default:
        this.eval(n, sc);
        return null;
    }
  }

  eval(n: Node2, sc: Scope): unknown {
    this.tick();
    switch (n.t) {
      case "Num": case "Str": case "Bool": return n.v;
      case "Null": return null;
      case "Undef": return undefined;
      case "Name": {
        if (n.name === "this") return this.get(sc, "this");
        const hit = this.look(sc, n.name as string);
        if (!hit) return undefined;
        return hit.sc.vars.get(n.name as string);
      }
      case "Regex": return makeRe(n.src as string, n.flags as string);
      case "Tpl": {
        let out = "";
        for (const p of n.parts as { s?: string; e?: Node2 }[]) {
          out += p.s !== undefined ? p.s : str(this.eval(p.e as Node2, sc));
        }
        return out;
      }
      case "Arr": return (n.items as Node2[]).map((i) => this.eval(i, sc));
      case "Obj": {
        const o: Record<string, unknown> = {};
        for (const p of n.props as { key: string; val: Node2 }[]) o[p.key] = this.eval(p.val, sc);
        return o;
      }
      case "FnExpr": return {
        params: n.params as string[], body: n.body as Node2, scope: sc, name: (n.name as string) || "",
      } as Fn;
      case "Seq": { this.eval(n.a as Node2, sc); return this.eval(n.b as Node2, sc); }
      case "Cond":
        return truthy(this.eval(n.test as Node2, sc))
          ? this.eval(n.yes as Node2, sc) : this.eval(n.no as Node2, sc);
      case "Un": {
        if (n.op === "typeof") {
          const t = n.arg as Node2;
          if (t.t === "Name" && !this.look(sc, t.name as string)) return "undefined";
          return typeOf(this.eval(t, sc));
        }
        const v = this.eval(n.arg as Node2, sc);
        switch (n.op) {
          case "!": return !truthy(v);
          case "-": return -num(v);
          case "+": return num(v);
          case "~": return ~(num(v) | 0);
          default: throw new JsStop(`모르는 ${n.op}`);
        }
      }
      case "Bin": return this.bin(n.op as string, n, sc);
      case "Member": {
        const obj = this.eval(n.obj as Node2, sc);
        const key = n.computed ? str(this.eval(n.key as Node2, sc)) : (n.name as string);
        return this.member(obj, key);
      }
      case "Assign": {
        const left = n.left as Node2;
        let v = this.eval(n.right as Node2, sc);
        if (n.op !== "=") {
          const cur = this.eval(left, sc);
          const o = (n.op as string).slice(0, -1);
          v = binOp(o, cur, v);
        }
        if (left.t === "Name") this.set(sc, left.name as string, v);
        else if (left.t === "Member") {
          const obj = this.eval(left.obj as Node2, sc);
          const key = left.computed ? str(this.eval(left.key as Node2, sc)) : (left.name as string);
          this.put(obj, key, v);
        } else throw new JsStop("넣을 수 없는 자리다");
        return v;
      }
      case "Update": {
        const arg = n.arg as Node2;
        const cur = num(this.eval(arg, sc));
        const nv = n.op === "++" ? cur + 1 : cur - 1;
        if (arg.t === "Name") this.set(sc, arg.name as string, nv);
        else if (arg.t === "Member") {
          const obj = this.eval(arg.obj as Node2, sc);
          const key = arg.computed ? str(this.eval(arg.key as Node2, sc)) : (arg.name as string);
          this.put(obj, key, nv);
        }
        return n.pre ? nv : cur;
      }
      case "Call": {
        const fnNode = n.fn as Node2;
        const args = (n.args as Node2[]).map((a) => this.eval(a, sc));
        if (fnNode.t === "Member") {
          const obj = this.eval(fnNode.obj as Node2, sc);
          const key = fnNode.computed ? str(this.eval(fnNode.key as Node2, sc)) : (fnNode.name as string);
          const fn = this.member(obj, key);
          return this.call(fn, obj, args);
        }
        return this.call(this.eval(fnNode, sc), undefined, args);
      }
      case "New": {
        const target = this.eval(n.target as Node2, sc);
        const args = (n.args as Node2[]).map((a) => this.eval(a, sc));
        // new 는 우리가 건넨 만드는 함수에만 쓴다
        if (typeof target === "function") return (target as (...a: unknown[]) => unknown)(...args);
        throw new JsStop("new 로 만들 수 없는 것이다");
      }
      default: throw new JsStop(`모르는 마디 ${n.t}`);
    }
  }

  private bin(op: string, n: Node2, sc: Scope): unknown {
    if (op === "&&") {
      const a = this.eval(n.left as Node2, sc);
      return truthy(a) ? this.eval(n.right as Node2, sc) : a;
    }
    if (op === "||") {
      const a = this.eval(n.left as Node2, sc);
      return truthy(a) ? a : this.eval(n.right as Node2, sc);
    }
    if (op === "??") {
      const a = this.eval(n.left as Node2, sc);
      return a === null || a === undefined ? this.eval(n.right as Node2, sc) : a;
    }
    return binOp(op, this.eval(n.left as Node2, sc), this.eval(n.right as Node2, sc));
  }
}

function truthy(v: unknown): boolean {
  if (typeof v === "string") return v.length > 0;
  if (typeof v === "number") return v !== 0 && !Number.isNaN(v);
  return !!v;
}
function num(v: unknown): number {
  if (typeof v === "number") return v;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (v === null) return 0;
  if (v === undefined) return NaN;
  const n = parseFloat(String(v));
  return Number.isNaN(n) ? (String(v).trim() === "" ? 0 : NaN) : n;
}
function str(v: unknown): string {
  if (v === null) return "null";
  if (v === undefined) return "undefined";
  if (typeof v === "number") return String(v);
  if (Array.isArray(v)) return v.map(str).join(",");
  if (typeof v === "object") return "[object]";
  return String(v);
}
function typeOf(v: unknown): string {
  if (v === null) return "object";
  if (Array.isArray(v)) return "object";
  if (v && typeof v === "object" && "body" in (v as object)) return "function";
  return typeof v;
}
function binOp(op: string, a: unknown, b: unknown): unknown {
  switch (op) {
    case "+":
      if (typeof a === "string" || typeof b === "string") return str(a) + str(b);
      return num(a) + num(b);
    case "-": return num(a) - num(b);
    case "*": return num(a) * num(b);
    case "/": { const d = num(b); return d === 0 ? (num(a) === 0 ? NaN : Infinity * Math.sign(num(a))) : num(a) / d; }
    case "%": { const d = num(b); return d === 0 ? NaN : num(a) % d; }
    case "**": return num(a) ** num(b);
    case "==": return looseEq(a, b);
    case "!=": return !looseEq(a, b);
    case "===": return a === b;
    case "!==": return a !== b;
    case "<": return cmp(a, b) < 0;
    case ">": return cmp(a, b) > 0;
    case "<=": return cmp(a, b) <= 0;
    case ">=": return cmp(a, b) >= 0;
    case "&": return (num(a) | 0) & (num(b) | 0);
    case "|": return (num(a) | 0) | (num(b) | 0);
    case "^": return (num(a) | 0) ^ (num(b) | 0);
    case "<<": return (num(a) | 0) << (num(b) | 0);
    case ">>": return (num(a) | 0) >> (num(b) | 0);
    case ">>>": return (num(a) >>> 0) >>> (num(b) | 0);
    default: throw new JsStop(`모르는 ${op}`);
  }
}
function looseEq(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || a === undefined) return b === null || b === undefined;
  if (b === null || b === undefined) return false;
  if (typeof a === typeof b) return a === b;
  return num(a) === num(b);
}
function cmp(a: unknown, b: unknown): number {
  if (typeof a === "string" && typeof b === "string") return a < b ? -1 : a > b ? 1 : 0;
  const x = num(a);
  const y = num(b);
  return x < y ? -1 : x > y ? 1 : 0;
}

// ── 문자열·배열·숫자에 붙은 것들 ─────────────────────────────────────────
//
// 프로토타입을 그대로 열어 주면 `"".constructor("코드")` 로 host 함수를
// 만들 수 있다. 그래서 쓰는 것만 손으로 적어 준다.

/**
 * 정규식을 만든다.
 *
 * 문서가 준 무늬를 host 의 정규식 엔진에 그대로 넘기면, `(a+)+b` 같은
 * 무늬 하나로 몇 초씩 잡아먹을 수 있다(되돌이 폭발). 그건 우리 걸음
 * 한도로 못 막는다 — host 안에서 도는 일이라서다. 그래서 무늬 길이를
 * 재고, 겹친 반복이 보이면 아예 안 만든다.
 */
export type Re = { __re: RegExp; source: string; flags: string };
function makeRe(src: string, flags: string): Re {
  if (src.length > 200) throw new JsStop("정규식이 너무 길다");
  // (…+)+ · (…*)* 처럼 반복 안에 반복이 겹친 것
  if (/\([^)]*[+*][^)]*\)\s*[+*]/.test(src)) throw new JsStop("되돌이가 터질 수 있는 정규식이다");
  const f = flags.replace(/[^gimsuy]/g, "");
  try {
    return { __re: new RegExp(src, f), source: src, flags: f };
  } catch {
    throw new JsStop("읽을 수 없는 정규식이다");
  }
}
function isRe(v: unknown): v is Re {
  return !!v && typeof v === "object" && "__re" in (v as object);
}
/** 정규식에 넣을 글자는 길이를 재 둔다 — 긴 글에 무거운 무늬면 오래 끈다 */
function safeSubject(s: string): string {
  return s.length > 20000 ? s.slice(0, 20000) : s;
}

function reMember(r: Re, k: string): unknown {
  switch (k) {
    case "test": return (v: unknown) => r.__re.test(safeSubject(str(v)));
    case "exec": return (v: unknown) => {
      const m = r.__re.exec(safeSubject(str(v)));
      return m ? Array.from(m) : null;
    };
    case "source": return r.source;
    case "flags": return r.flags;
    case "toString": return () => `/${r.source}/${r.flags}`;
    default: return undefined;
  }
}

function strMember(s: string, k: string): unknown {
  switch (k) {
    case "length": return s.length;
    case "toString": return () => s;
    case "toUpperCase": return () => s.toUpperCase();
    case "toLowerCase": return () => s.toLowerCase();
    case "trim": return () => s.trim();
    case "charAt": return (i: unknown) => s.charAt(num(i));
    case "charCodeAt": return (i: unknown) => s.charCodeAt(num(i));
    case "indexOf": return (t: unknown, f?: unknown) => s.indexOf(str(t), f === undefined ? 0 : num(f));
    case "lastIndexOf": return (t: unknown) => s.lastIndexOf(str(t));
    case "slice": return (a: unknown, b?: unknown) => s.slice(num(a), b === undefined ? undefined : num(b));
    case "substring": return (a: unknown, b?: unknown) => s.substring(num(a), b === undefined ? undefined : num(b));
    case "substr": return (a: unknown, b?: unknown) => s.substr(num(a), b === undefined ? undefined : num(b));
    case "split": return (t: unknown) => (isRe(t) ? s.split(t.__re) : s.split(str(t)));
    case "replace": return (a: unknown, b: unknown) => {
      if (isRe(a)) return safeSubject(s).replace(a.__re, str(b));
      return s.split(str(a)).join(str(b));
    };
    case "match": return (t: unknown) => {
      if (!isRe(t)) return null;
      const m = safeSubject(s).match(t.__re);
      return m ? Array.from(m) : null;
    };
    case "search": return (t: unknown) => (isRe(t) ? safeSubject(s).search(t.__re) : s.indexOf(str(t)));
    case "concat": return (...a: unknown[]) => s + a.map(str).join("");
    case "startsWith": return (t: unknown) => s.startsWith(str(t));
    case "endsWith": return (t: unknown) => s.endsWith(str(t));
    case "includes": return (t: unknown) => s.includes(str(t));
    case "padStart": return (n2: unknown, c: unknown) => s.padStart(num(n2), c === undefined ? " " : str(c));
    default:
      if (/^\d+$/.test(k)) return s[Number(k)];
      return undefined;
  }
}

function numMember(v: number, k: string): unknown {
  switch (k) {
    case "toFixed": return (d: unknown) => v.toFixed(Math.max(0, Math.min(20, num(d) || 0)));
    case "toString": return () => String(v);
    case "toPrecision": return (d: unknown) => v.toPrecision(Math.max(1, Math.min(21, num(d) || 6)));
    default: return undefined;
  }
}

function arrMember(a: unknown[], k: string): unknown {
  switch (k) {
    case "length": return a.length;
    case "push": return (...v: unknown[]) => a.push(...v);
    case "pop": return () => a.pop();
    case "shift": return () => a.shift();
    case "unshift": return (...v: unknown[]) => a.unshift(...v);
    case "join": return (t: unknown) => a.map(str).join(t === undefined ? "," : str(t));
    case "slice": return (x: unknown, y?: unknown) => a.slice(num(x), y === undefined ? undefined : num(y));
    case "indexOf": return (t: unknown) => a.indexOf(t);
    case "concat": return (...v: unknown[]) => a.concat(...(v as unknown[][]));
    case "reverse": return () => a.reverse();
    case "toString": return () => a.map(str).join(",");
    default:
      if (/^\d+$/.test(k)) return a[Number(k)];
      return undefined;
  }
}

/** 어디서나 쓰는 것들. 문서가 볼 수 있는 전부다. */
function baseScope(): Map<string, unknown> {
  const m = new Map<string, unknown>();
  m.set("Math", {
    round: (v: unknown) => Math.round(num(v)),
    floor: (v: unknown) => Math.floor(num(v)),
    ceil: (v: unknown) => Math.ceil(num(v)),
    abs: (v: unknown) => Math.abs(num(v)),
    min: (...v: unknown[]) => Math.min(...v.map(num)),
    max: (...v: unknown[]) => Math.max(...v.map(num)),
    pow: (a: unknown, b: unknown) => num(a) ** num(b),
    sqrt: (v: unknown) => Math.sqrt(num(v)),
    PI: Math.PI,
  });
  m.set("parseFloat", (v: unknown) => parseFloat(str(v)));
  m.set("parseInt", (v: unknown, r?: unknown) => parseInt(str(v), r === undefined ? 10 : num(r)));
  m.set("isNaN", (v: unknown) => Number.isNaN(num(v)));
  m.set("Number", (v: unknown) => num(v));
  m.set("String", (v: unknown) => str(v));
  m.set("Boolean", (v: unknown) => truthy(v));
  m.set("Array", (...v: unknown[]) =>
    (v.length === 1 && typeof v[0] === "number" ? new Array(v[0]).fill(undefined) : v));
  m.set("NaN", NaN);
  m.set("Infinity", Infinity);
  // 날짜 — 양식이 오늘 날짜를 찍는 일이 흔하다
  const dateOf = (ms: number) => {
    const d = new Date(ms);
    return {
      getFullYear: () => d.getFullYear(),
      getMonth: () => d.getMonth(),
      getDate: () => d.getDate(),
      getDay: () => d.getDay(),
      getHours: () => d.getHours(),
      getMinutes: () => d.getMinutes(),
      getSeconds: () => d.getSeconds(),
      getTime: () => d.getTime(),
      toISOString: () => d.toISOString(),
      toString: () => d.toString(),
    };
  };
  const DateFn = (...a: unknown[]) => (a.length === 0 ? dateOf(Date.now()) : dateOf(num(a[0])));
  (DateFn as unknown as Record<string, unknown>).now = () => Date.now();
  m.set("Date", DateFn);
  m.set("RegExp", (src2: unknown, f: unknown) => makeRe(str(src2), f === undefined ? "" : str(f)));
  m.set("JSON", {
    stringify: (v: unknown) => {
      try { return JSON.stringify(v) ?? "undefined"; } catch { return "null"; }
    },
    parse: (v: unknown) => {
      const t = str(v);
      if (t.length > 100000) throw new JsStop("JSON 이 너무 길다");
      try { return JSON.parse(t); } catch { throw new JsStop("JSON 을 못 읽는다"); }
    },
  });
  return m;
}

/**
 * 문서가 준 코드를 돌린다.
 *
 * `box` 에 담아 건넨 것만 코드가 볼 수 있다. 한도에 걸리거나 못 읽는
 * 문법이면 JsStop 을 던진다 — 부르는 쪽은 그 칸을 그냥 두면 된다.
 */
export function runJs(src: string, box: Sandbox = {}, opts: RunOpts = {}): unknown {
  const m = new Machine(opts.steps ?? 200000, opts.ms ?? 200);
  const root: Scope = { vars: baseScope(), up: null };
  for (const [k, v] of Object.entries(box)) root.vars.set(k, v);
  const ast = new Parser(lex(src)).program();
  const flow = m.run(ast, root);
  if (flow && flow.s === "return") return flow.v;
  return undefined;
}
