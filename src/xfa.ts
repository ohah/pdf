/**
 * XFA 양식을 그려 본다.
 *
 * XFA 는 쪽 내용이 PDF 가 아니라 XML 로 들어 있는 딴 세상 양식이다. 그래서
 * 우리가 PDF 를 아무리 잘 그려도 "Acrobat 으로 여세요" 한 줄만 나온다.
 * 여기서는 그 XML 에서 **정적인 부분**을 읽어 자리와 글자를 뽑는다 —
 * 서식 스크립트로 모양이 바뀌는 동적 XFA 까지는 하지 않는다. 그런 문서는
 * 여기서 뽑은 것이 실제와 다를 수 있어, 몇 개나 읽었는지 함께 알려 준다.
 *
 * 읽는 것: <pageArea>/<contentArea> 로 쪽 크기, <subform> 을 따라 내려가며
 * 쌓이는 자리, <draw>·<field> 의 x·y·w·h 와 <value><text>, <caption>,
 * <font size>, <border>. 값은 <datasets> 에 따로 있으면 이름으로 찾는다.
 */

/** 그릴 것 하나 — 자리는 쪽 왼쪽 위에서 잰 pt 다. */
export type XfaBox = {
  x: number; y: number; w: number; h: number;
  text: string;
  /** 칸 이름 (<field name>). 없으면 빈 문자열 */
  name: string;
  size: number;
  bold: boolean;
  align: "left" | "center" | "right";
  /** 테두리를 그릴 것인가 */
  border: boolean;
  /** 사람이 채우는 칸인가 (<field>) — 그리는 쪽이 입력칸을 얹을 수 있다 */
  field: boolean;
};

export type XfaPage = { width: number; height: number; boxes: XfaBox[] };

/** 뽑아 본 결과. */
export type XfaForm = {
  pages: XfaPage[];
  /** 못 읽고 지나친 마디 수 — 0 이 아니면 실제와 다를 수 있다 */
  skipped: number;
  /** 서식이 흐르거나 스크립트로 바뀌는 문서인가 */
  dynamic: boolean;
  /** 흐름 배치(layout="tb"·"lr-tb")를 실제로 쓴 마디 수 */
  flowed: number;
  /** 자료만큼 되풀이한 마디 수 (<occur max="-1">) */
  repeated: number;
  /** 셈해서 값을 채운 칸 수 (calculate·initialize 스크립트) */
  calculated: number;
  /** 못 읽은 스크립트 수 — 그 칸은 값이 비어 있을 수 있다 */
  unreadScripts: number;
  /** 스크립트가 감춘 마디 수 (presence = "hidden") */
  hidden: number;
  /** 스크립트가 줄 수를 바꾼 마디 수 (instanceManager) */
  instanced: number;
  /** 스크립트가 띄우려 한 말 (xfa.host.messageBox) */
  said: string[];
};

/** "12.7mm" · "1in" · "36pt" · "0.5cm" · "10px" 를 pt 로 */
import { runCalc, type ValueOf } from "./formjs.js";
import { runJs } from "./jsmini.js";

export function toPt(v: string | undefined, dflt = 0): number {
  if (!v) return dflt;
  const m = /^\s*(-?[\d.]+)\s*(mm|cm|in|pt|px)?\s*$/.exec(v);
  if (!m) return dflt;
  const n = parseFloat(m[1]);
  if (!isFinite(n)) return dflt;
  switch (m[2]) {
    case "mm": return (n / 25.4) * 72;
    case "cm": return (n / 2.54) * 72;
    case "in": return n * 72;
    case "px": return (n / 96) * 72;
    default: return n; // pt
  }
}

type Node = { tag: string; attr: Record<string, string>; kids: Node[]; text: string };

/** XML 을 아주 작은 나무로 읽는다. 우리가 쓰는 만큼만 본다. */
function parseXml(src: string): Node {
  const root: Node = { tag: "#root", attr: {}, kids: [], text: "" };
  const stack: Node[] = [root];
  let i = 0;
  while (i < src.length) {
    const lt = src.indexOf("<", i);
    if (lt < 0) break;
    if (lt > i) {
      const t = src.slice(i, lt);
      if (t.trim()) stack[stack.length - 1].text += unescapeXml(t);
    }
    if (src.startsWith("<!--", lt)) { i = src.indexOf("-->", lt) + 3 || src.length; continue; }
    if (src.startsWith("<?", lt) || src.startsWith("<!", lt)) {
      const gt0 = src.indexOf(">", lt);
      i = gt0 < 0 ? src.length : gt0 + 1;
      continue;
    }
    const gt = src.indexOf(">", lt);
    if (gt < 0) break;
    const raw = src.slice(lt + 1, gt);
    i = gt + 1;
    if (raw.startsWith("/")) {
      if (stack.length > 1) stack.pop();
      continue;
    }
    const selfClose = raw.endsWith("/");
    const body = selfClose ? raw.slice(0, -1) : raw;
    const sp = body.search(/\s/);
    const tagFull = sp < 0 ? body : body.slice(0, sp);
    const tag = tagFull.includes(":") ? tagFull.slice(tagFull.indexOf(":") + 1) : tagFull;
    const attr: Record<string, string> = {};
    if (sp >= 0) {
      const re = /([A-Za-z_:][-\w:.]*)\s*=\s*("([^"]*)"|'([^']*)')/g;
      let m: RegExpExecArray | null;
      while ((m = re.exec(body.slice(sp)))) {
        const k = m[1].includes(":") ? m[1].slice(m[1].indexOf(":") + 1) : m[1];
        attr[k] = unescapeXml(m[3] ?? m[4] ?? "");
      }
    }
    const node: Node = { tag, attr, kids: [], text: "" };
    stack[stack.length - 1].kids.push(node);
    if (!selfClose) stack.push(node);
  }
  return root;
}

function unescapeXml(s: string): string {
  return s.replace(/&(lt|gt|amp|quot|apos|#(\d+)|#x([0-9a-fA-F]+));/g, (_, n, d, h) => {
    if (d) return String.fromCodePoint(Number(d));
    if (h) return String.fromCodePoint(parseInt(h, 16));
    return { lt: "<", gt: ">", amp: "&", quot: '"', apos: "'" }[n as string] ?? _;
  });
}

function find(n: Node, tag: string): Node | undefined {
  for (const k of n.kids) if (k.tag === tag) return k;
  return undefined;
}
function findDeep(n: Node, tag: string): Node | undefined {
  if (n.tag === tag) return n;
  for (const k of n.kids) {
    const r = findDeep(k, tag);
    if (r) return r;
  }
  return undefined;
}

/**
 * <value><text>…</text></value> 에서 글자를 꺼낸다.
 *
 * <value> 가 없으면 빈 것을 준다 — 마디 아래를 통째로 뒤지면 <caption> 의
 * 글자를 값으로 잘못 집는다("금액" 이라는 이름표가 금액 자리에 찍혔다).
 */
function valueText(n: Node): string {
  const v = find(n, "value");
  if (!v) return "";
  const t = findDeep(v, "text") ?? findDeep(v, "exData");
  if (!t) return "";
  // exData 는 HTML 조각일 때가 있다 — 태그를 걷어 낸다
  const raw = t.text || t.kids.map((k) => k.text).join(" ");
  return raw.replace(/<[^>]*>/g, "").trim();
}

/** <datasets> 에서 이름으로 값을 찾는다 */
function datasetValue(ds: Node | undefined, name: string): string {
  if (!ds || !name) return "";
  let hit = "";
  const walk = (n: Node) => {
    if (hit) return;
    if (n.tag === name && n.text.trim()) { hit = n.text.trim(); return; }
    for (const k of n.kids) walk(k);
  };
  walk(ds);
  return hit;
}

/**
 * XFA XML 에서 그릴 것을 뽑는다.
 *
 * 쪽이 여럿이면 <pageArea> 마다 하나씩 준다. 자리를 못 정한 마디는 세어서
 * `skipped` 로 알린다 — 그 수가 크면 화면이 "제대로 못 그렸다" 고 말해야 한다.
 */
/**
 * 스크립트가 서식을 바꾼 것 — 다시 훑을 때 그대로 반영한다.
 *
 * XFA 스크립트는 값만 정하지 않는다. 칸을 감추고(presence) 표의 줄 수를
 * 바꾼다(instanceManager). 그래서 한 번 훑고, 스크립트를 돌리고, 바뀐 것이
 * 있으면 그 값을 얹어 한 번 더 훑는다.
 */
type Twist = { hide: Set<string>; count: Map<string, number> };

export function readXfa(xml: string): XfaForm {
  const first = layoutXfa(xml, { hide: new Set(), count: new Map() });
  const tw = runXfaScripts(xml, first);
  if (tw.hide.size === 0 && tw.count.size === 0) {
    applyValues(first, tw.values);
    first.said = tw.said2;
    return first;
  }
  // 서식이 바뀌었다 — 그 값을 얹어 다시 훑고 스크립트를 한 번 더 돌린다
  const again = layoutXfa(xml, tw);
  const tw2 = runXfaScripts(xml, again);
  applyValues(again, tw2.values);
  again.hidden = tw.hide.size;
  again.instanced = tw.count.size;
  again.said = tw2.said2;
  return again;
}

function layoutXfa(xml: string, twist: Twist): XfaForm {
  const root = parseXml(xml);
  const template = findDeep(root, "template");
  const datasets = findDeep(root, "datasets");
  const out: XfaForm = {
    pages: [], skipped: 0, dynamic: false,
    flowed: 0, repeated: 0, calculated: 0, unreadScripts: 0,
    hidden: 0, instanced: 0, said: [],
  };
  if (!template) return out;

  // 서식이 흐르거나 스크립트로 바뀌는 문서인가
  out.dynamic = /<(script|event)\b/.test(xml) || /layout\s*=\s*"(tb|lr-tb|row|table)"/.test(xml);

  // 쪽 크기 — <pageArea><contentArea> 또는 <medium short long>
  const area = findDeep(template, "contentArea");
  const medium = findDeep(template, "medium");
  const width = toPt(medium?.attr.short, toPt(area?.attr.w, 612));
  const height = toPt(medium?.attr.long, toPt(area?.attr.h, 792));
  /** 종이 안에서 글이 놓이는 자리 — 여기를 넘으면 다음 쪽으로 넘긴다 */
  const areaTop = toPt(area?.attr.y, 0);
  const areaBottom = areaTop + toPt(area?.attr.h, height);
  const page: XfaPage = { width, height, boxes: [] };
  out.pages.push(page);
  /** 지금 담고 있는 쪽 */
  let cur = page;
  /** 흐름 배치가 다음 쪽으로 넘어간 만큼 y 를 되돌린다 */
  let carry = 0;

  const put = (b: XfaBox) => {
    // 자리가 종이 밖으로 나가면 새 쪽을 낸다. 흐름 배치가 있는 문서는
    // 자료가 길어지면 저절로 여러 쪽이 된다 — 그게 동적 XFA 다.
    if (b.y - carry + b.h > areaBottom && b.y - carry > areaTop) {
      carry = b.y - areaTop;
      cur = { width, height, boxes: [] };
      out.pages.push(cur);
    }
    cur.boxes.push({ ...b, y: b.y - carry });
  };

  /** 보이지 않기로 한 마디인가 — 스크립트가 감춘 것도 여기서 걸린다 */
  const gone = (k: Node) =>
    k.attr.presence === "hidden" || k.attr.presence === "invisible" ||
    (!!k.attr.name && twist.hide.has(k.attr.name));

  /** 자료에서 이 이름의 마디들을 찾는다 — 되풀이할 만큼 */
  const records = (name: string): Node[] => {
    if (!datasets || !name) return [];
    const hit: Node[] = [];
    const walk2 = (n: Node) => {
      for (const k of n.kids) {
        if (k.tag === name) hit.push(k);
        else walk2(k);
      }
    };
    walk2(datasets);
    return hit;
  };

  const walk = (n: Node, ox: number, oy: number, bind?: Node) => {
    // 이 마디가 아이를 어떻게 놓는가. position 이면 아이마다 제 x·y 를
    // 쓰고, tb·lr-tb 면 차례로 쌓는다 — 자료가 길어지면 아래로 흐른다.
    const how = n.attr.layout ?? "position";
    const flow = how === "tb" || how === "lr-tb" || how === "row" || how === "table";
    if (flow) out.flowed++;
    let cx = 0;
    let cy = 0;
    let rowH = 0;
    const parentW = toPt(n.attr.w, width);

    /** 흐름 배치에서 이 크기의 마디를 놓을 자리를 정한다 */
    const spot = (w: number, h: number) => {
      if (!flow) return null;
      if ((how === "lr-tb" || how === "row" || how === "table") && cx > 0 && cx + w > parentW) {
        cx = 0;
        cy += rowH;
        rowH = 0;
      }
      const at = { x: cx, y: cy };
      if (how === "tb") { cy += h; }
      else { cx += w; rowH = Math.max(rowH, h); }
      return at;
    };

    for (const k of n.kids) {
      if (gone(k)) continue;
      if (k.tag === "subform" || k.tag === "area" || k.tag === "exclGroup") {
        // <occur max="-1"> 이면 자료에 있는 만큼 되풀이한다
        const oc = find(k, "occur");
        const many = oc && (oc.attr.max === "-1" || Number(oc.attr.max ?? 1) > 1);
        const recs = many ? records(k.attr.name ?? "") : [];
        // 스크립트가 줄 수를 정했으면 그것을 따른다
        const forced = twist.count.get(k.attr.name ?? "");
        const times = forced !== undefined
          ? Math.max(0, Math.min(2000, forced))
          : recs.length > 1 ? recs.length : 1;
        if (times > 1) out.repeated += times - 1;
        for (let t = 0; t < times; t++) {
          const kh = toPt(k.attr.h, 0);
          const at = spot(toPt(k.attr.w, parentW), kh || 0);
          walk(k,
            ox + (at ? at.x : toPt(k.attr.x)),
            oy + (at ? at.y : toPt(k.attr.y)),
            recs[t] ?? bind);
          // 흐름 배치인데 높이를 안 적어 두었으면 담은 만큼 내려간다
          if (at && how === "tb" && !kh) {
            const low = cur.boxes.reduce((m, b) => Math.max(m, b.y + b.h + carry), 0);
            cy = Math.max(cy, low - oy);
          }
        }
        continue;
      }
      if (k.tag !== "draw" && k.tag !== "field") {
        // 쪽 얼개는 위에서 따로 읽었다 — 못 읽은 것으로 세지 않는다
        const frame = k.tag === "pageSet" || k.tag === "pageArea" ||
          k.tag === "contentArea" || k.tag === "medium";
        if (!frame && (k.attr.x !== undefined || k.attr.y !== undefined)) out.skipped++;
        if (!frame) walk(k, ox, oy);
        continue;
      }
      const w = toPt(k.attr.w, 0);
      const h = toPt(k.attr.h, 0);
      const at = spot(w || 100, h || 14);
      const x = ox + (at ? at.x : toPt(k.attr.x));
      const y = oy + (at ? at.y : toPt(k.attr.y));
      const font = findDeep(k, "font");
      const para = findDeep(k, "para");
      const name = k.attr.name ?? "";
      let text = valueText(k);
      // 되풀이하는 마디는 제 자료 조각에서 값을 찾는다 — 표의 줄마다
      // 다른 값이 들어가야 하는데, 문서 전체에서 찾으면 다 같은 값이 된다.
      if (!text && k.tag === "field") text = datasetValue(bind ?? datasets, name);
      if (!text && k.tag === "field" && bind) text = datasetValue(datasets, name);
      const cap = find(k, "caption");
      const capText = cap ? valueText(cap) : "";
      const size = toPt(font?.attr.size, 10);
      const bold = (font?.attr.weight ?? "") === "bold";
      const align = (para?.attr.hAlign as XfaBox["align"]) ?? "left";
      const border = !!findDeep(k, "border") || k.tag === "field";
      if (capText) {
        put({
          x, y, w: w || 100, h: h || size * 1.4, text: capText, name: "",
          size, bold, align, border: false, field: false,
        });
      }
      put({
        x: capText ? x + (w || 100) : x, y,
        w: w || 100, h: h || size * 1.4,
        text, name, size, bold, align, border, field: k.tag === "field",
      });
    }
  };
  walk(template, 0, 0);

  // ── 셈하는 마디 (동적 XFA) ─────────────────────────────────────────────
  //
  // 값이 자료가 아니라 스크립트로 정해지는 칸이 있다. 표의 합계가 대개
  // 그렇다. 스크립트는 자바스크립트이거나 FormCalc 인데, 둘 다 **돌리지
  // 않고 읽어서** 셈한다 — 문서가 준 코드를 실행하지 않는다는 원칙은
  // 여기서도 같다. 못 읽은 것은 세어 둔다.
  {
    const at = new Map<string, string>();
    const many = new Map<string, string[]>();
    for (const pg of out.pages)
      for (const b of pg.boxes) {
        if (!b.name || !b.text) continue;
        at.set(b.name, b.text);
        const list = many.get(b.name) ?? [];
        list.push(b.text);
        many.set(b.name, list);
      }
    const valueOf = (n: string) => at.get(n) ?? "";
    const allOf = (n: string) => many.get(n) ?? [];
    const jobs: { name: string; src: string; kind: "js" | "fc" }[] = [];
    const hunt = (n: Node) => {
      for (const k of n.kids) {
        if (k.tag === "field" && k.attr.name) {
          for (const ev of k.kids) {
            if (ev.tag !== "event") continue;
            const act = ev.attr.activity ?? "";
            if (act !== "calculate" && act !== "initialize") continue;
            const sc = find(ev, "script");
            const src = (sc?.text ?? "").trim();
            if (!src) continue;
            const ct = sc?.attr.contentType ?? "";
            const fc = /formcalc/i.test(ct);
            // XFA 꼴로 쓴 자바스크립트(this.rawValue·presence·instanceManager)는
            // 뒤 단계가 맡는다 — 여기서 못 읽었다고 세면 두 번 세는 셈이다
            if (!fc && /this\.(rawValue|value)|presence|instanceManager|messageBox|xfa\./.test(src)) continue;
            jobs.push({ name: k.attr.name, src, kind: fc ? "fc" : "js" });
          }
        }
        hunt(k);
      }
    };
    hunt(template);
    for (const j of jobs) {
      const got = j.kind === "fc"
        ? formCalc(j.src, valueOf, allOf)
        : runCalc(j.src, valueOf);
      if (got === null) { out.unreadScripts++; continue; }
      at.set(j.name, got);
      out.calculated++;
      for (const pg of out.pages)
        for (const b of pg.boxes) if (b.name === j.name) b.text = got;
    }
  }
  return out;
}

/**
 * 서식을 바꾸는 스크립트를 돌린다.
 *
 * 값만 정하는 것은 위에서 이미 셈했다. 여기서는 **칸을 감추고 줄 수를
 * 바꾸는** 것을 본다 — 동적 XFA 가 실제로 하는 일이다.
 *
 *   this.presence = "hidden"
 *   item.instanceManager.setInstances(3)
 *   xfa.host.messageBox("확인하세요")
 *
 * 문서가 준 코드를 host 자바스크립트로 넘기지 않는다. jsmini 가 한 마디씩
 * 해석하고, 걸음·시간에 한도가 있다. 코드가 볼 수 있는 이름은 우리가
 * 건넨 것뿐이라 fetch·document·globalThis 는 이름조차 없다.
 */
function runXfaScripts(
  xml: string, form: XfaForm,
): Twist & { said2: string[]; values: Map<string, string> } {
  const hide = new Set<string>();
  const count = new Map<string, number>();
  const said: string[] = [];
  const root = parseXml(xml);
  const template = findDeep(root, "template");
  if (!template) return { hide, count, said2: said, values: new Map() };

  // 이름으로 찾을 수 있게 칸을 늘어놓는다
  const at = new Map<string, string>();
  for (const pg of form.pages)
    for (const b of pg.boxes) if (b.name && b.text && !at.has(b.name)) at.set(b.name, b.text);

  /**
   * 스크립트가 실제로 값을 쓴 이름.
   *
   * 쓴 것만 쪽에 얹는다. 안 그러면 되풀이하는 줄(같은 이름이 여럿)이
   * 마지막 값 하나로 뭉개진다 — 표의 모든 줄이 "품목 1" 이 됐다.
   */
  const touched = new Set<string>();

  /** 스크립트가 만지는 마디 하나 */
  const nodeOf = (name: string) => ({
    name,
    get rawValue() { return at.get(name) ?? ""; },
    set rawValue(v: unknown) { at.set(name, String(v)); touched.add(name); },
    get value() { return at.get(name) ?? ""; },
    set value(v: unknown) { at.set(name, String(v)); touched.add(name); },
    get presence() { return hide.has(name) ? "hidden" : "visible"; },
    set presence(v: unknown) {
      if (String(v) === "hidden" || String(v) === "invisible") hide.add(name);
      else hide.delete(name);
    },
    instanceManager: {
      setInstances: (n: unknown) => { count.set(name, Math.max(0, Number(n) || 0)); },
      addInstance: () => { count.set(name, (count.get(name) ?? 1) + 1); },
      removeInstance: () => { count.set(name, Math.max(0, (count.get(name) ?? 1) - 1)); },
      get count() { return count.get(name) ?? 1; },
    },
  });

  const named: Record<string, unknown> = {};
  const seen = new Set<string>();
  const collect = (n: Node) => {
    for (const k of n.kids) {
      const nm = k.attr.name;
      if (nm && !seen.has(nm) && (k.tag === "field" || k.tag === "subform" || k.tag === "draw")) {
        seen.add(nm);
        named[nm] = nodeOf(nm);
      }
      collect(k);
    }
  };
  collect(template);

  const xfa = {
    host: {
      messageBox: (m: unknown) => { said.push(String(m)); return 0; },
      setFocus: () => undefined,
      name: "@ohah/pdf",
    },
    resolveNode: (path: unknown) => {
      const nm = String(path).split(".").pop() ?? "";
      return named[nm];
    },
  };

  // 서식을 바꾸는 스크립트만 돌린다 — 값만 정하는 것은 이미 셈했다
  const runOne = (owner: string, src: string) => {
    const box: Record<string, unknown> = { ...named, xfa, this: named[owner] ?? nodeOf(owner) };
    try {
      runJs(src, box);
    } catch {
      form.unreadScripts++;
    }
  };
  const hunt = (n: Node) => {
    for (const k of n.kids) {
      const nm = k.attr.name ?? "";
      for (const ev of k.kids) {
        if (ev.tag !== "event") continue;
        const act = ev.attr.activity ?? "";
        if (act !== "initialize" && act !== "calculate" && act !== "ready") continue;
        const sc = find(ev, "script");
        const src = (sc?.text ?? "").trim();
        if (!src) continue;
        // FormCalc 는 위에서 셈했다. 여기는 자바스크립트만.
        if (/formcalc/i.test(sc?.attr.contentType ?? "")) continue;
        // XFA 꼴로 쓴 것만 여기서 돌린다 (event.value 꼴은 앞에서 셈했다)
        if (!/this\.(rawValue|value)|presence|instanceManager|messageBox|xfa\./.test(src)) continue;
        runOne(nm, src);
      }
      hunt(k);
    }
  };
  hunt(template);
  // 스크립트가 **고친** 값만 돌려준다
  const values = new Map<string, string>();
  for (const k of touched) values.set(k, at.get(k) ?? "");
  return { hide, count, said2: said, values };
}

/** 스크립트가 정한 값을 쪽에 얹는다. */
function applyValues(form: XfaForm, values: Map<string, string>) {
  for (const pg of form.pages)
    for (const b of pg.boxes) {
      if (!b.name) continue;
      const v = values.get(b.name);
      if (v !== undefined && v !== b.text) { b.text = v; form.calculated++; }
    }
}

/**
 * FormCalc 한 줄을 읽어 셈한다. 못 읽으면 null.
 *
 * XFA 가 쓰는 제 나름의 식 언어다. 자바스크립트와 달리 Sum(a, b) 처럼
 * 함수가 대문자로 시작하고, 마디 이름을 그대로 쓴다. 여기서는 실제 양식이
 * 거의 다 쓰는 것만 읽는다 — Sum·Avg·Min·Max·Count 와 사칙연산.
 */
export function formCalc(
  src: string, valueOf: ValueOf, allOf: (name: string) => string[] = () => [],
): string | null {
  const line = src.replace(/\/\/[^\n]*/g, " ").replace(/\s+/g, " ").trim();
  const num = (v: string) => {
    const n = parseFloat(String(v).replace(/[^0-9.\-]/g, ""));
    return isFinite(n) ? n : 0;
  };
  const fn = /^(Sum|Avg|Min|Max|Count)\s*\(([^()]*)\)$/i.exec(line);
  if (fn) {
    const args = fn[2].split(",").map((t) => t.trim()).filter(Boolean);
    const vals: number[] = [];
    for (const a of args) {
      // 이름[*] 은 "그 이름을 가진 것 전부" 라는 뜻이다. 표의 합계가 바로
      // 이것이라, 하나만 집으면 마지막 줄 값이 합계로 나온다.
      const star = /\[\s*\*\s*\]/.test(a);
      const bare = a.replace(/\[[^\]]*\]/g, "");
      if (/^[-+]?[\d.]+$/.test(bare)) { vals.push(Number(bare)); continue; }
      if (star) {
        const many = allOf(bare);
        if (many.length > 0) { for (const v of many) vals.push(num(v)); continue; }
      }
      vals.push(num(valueOf(bare)));
    }
    if (vals.length === 0) return "";
    switch (fn[1].toLowerCase()) {
      case "sum": return String(vals.reduce((a, b) => a + b, 0));
      case "avg": return String(vals.reduce((a, b) => a + b, 0) / vals.length);
      case "min": return String(Math.min(...vals));
      case "max": return String(Math.max(...vals));
      case "count": return String(vals.length);
      default: return null;
    }
  }
  // 이름과 숫자와 사칙연산만 있는 식이면 셈한다
  if (!/^[\w.\[\]*\s+\-*/()]+$/.test(line)) return null;
  const filled = line.replace(/[A-Za-z_][\w.]*(\[[^\]]*\])?/g, (m) => {
    const bare = m.replace(/\[[^\]]*\]/g, "");
    return String(num(valueOf(bare)));
  });
  if (!/^[\d.\s+\-*/()]+$/.test(filled)) return null;
  try {
    // 숫자와 연산자만 남았으므로 우리 계산기로 셈한다
    const got = runCalc(`event.value = ${filled};`, () => "");
    return got;
  } catch {
    return null;
  }
}

/**
 * 뽑아 둔 것을 캔버스에 그린다. 자리는 쪽 왼쪽 위 기준이라 그대로 찍는다.
 *
 * `scale` 은 pt 를 화면 화소로 옮기는 비율이다(1 이면 72dpi).
 */
export function drawXfa(
  canvas: { getContext(k: "2d"): unknown; width: number; height: number },
  page: XfaPage,
  scale = 1,
): void {
  const g = canvas.getContext("2d") as CanvasRenderingContext2D | null;
  if (!g) throw new Error("could not get a 2d context");
  g.save();
  g.setTransform(scale, 0, 0, scale, 0, 0);
  g.fillStyle = "#fff";
  g.fillRect(0, 0, page.width, page.height);
  g.textBaseline = "top";
  for (const b of page.boxes) {
    if (b.border) {
      g.strokeStyle = "#9ca3af";
      g.lineWidth = 0.5;
      g.strokeRect(b.x, b.y, b.w, b.h);
    }
    if (!b.text) continue;
    g.fillStyle = "#111";
    g.font = `${b.bold ? "bold " : ""}${b.size}px system-ui, sans-serif`;
    const tx = b.align === "center" ? b.x + b.w / 2 : b.align === "right" ? b.x + b.w - 2 : b.x + 2;
    g.textAlign = b.align === "center" ? "center" : b.align === "right" ? "right" : "left";
    g.fillText(b.text, tx, b.y + Math.max(0, (b.h - b.size) / 2));
  }
  g.restore();
}
