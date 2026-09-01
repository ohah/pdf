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

/** 뽑아 본 결과. `dynamic` 이면 서식이 스크립트로 바뀌는 문서다. */
export type XfaForm = {
  pages: XfaPage[];
  /** 못 읽고 지나친 마디 수 — 0 이 아니면 실제와 다를 수 있다 */
  skipped: number;
  dynamic: boolean;
};

/** "12.7mm" · "1in" · "36pt" · "0.5cm" · "10px" 를 pt 로 */
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
export function readXfa(xml: string): XfaForm {
  const root = parseXml(xml);
  const template = findDeep(root, "template");
  const datasets = findDeep(root, "datasets");
  const out: XfaForm = { pages: [], skipped: 0, dynamic: false };
  if (!template) return out;

  // 서식이 스크립트로 바뀌는 문서인가
  out.dynamic = /<(script|event)\b/.test(xml) || /layout\s*=\s*"(tb|row|table)"/.test(xml);

  // 쪽 크기 — <pageArea><contentArea> 또는 <medium short long>
  const area = findDeep(template, "contentArea");
  const medium = findDeep(template, "medium");
  const width = toPt(medium?.attr.short, toPt(area?.attr.w, 612));
  const height = toPt(medium?.attr.long, toPt(area?.attr.h, 792));
  const page: XfaPage = { width, height, boxes: [] };

  const walk = (n: Node, ox: number, oy: number) => {
    for (const k of n.kids) {
      if (k.tag === "subform" || k.tag === "area" || k.tag === "exclGroup") {
        walk(k, ox + toPt(k.attr.x), oy + toPt(k.attr.y));
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
      const x = ox + toPt(k.attr.x);
      const y = oy + toPt(k.attr.y);
      const w = toPt(k.attr.w, 0);
      const h = toPt(k.attr.h, 0);
      const font = findDeep(k, "font");
      const para = findDeep(k, "para");
      const name = k.attr.name ?? "";
      let text = valueText(k);
      if (!text && k.tag === "field") text = datasetValue(datasets, name);
      const cap = find(k, "caption");
      const capText = cap ? valueText(cap) : "";
      const size = toPt(font?.attr.size, 10);
      const bold = (font?.attr.weight ?? "") === "bold";
      const align = (para?.attr.hAlign as XfaBox["align"]) ?? "left";
      const border = !!findDeep(k, "border") || k.tag === "field";
      if (capText) {
        page.boxes.push({
          x, y, w: w || 100, h: h || size * 1.4, text: capText, name: "",
          size, bold, align, border: false, field: false,
        });
      }
      page.boxes.push({
        x: capText ? x + (w || 100) : x, y,
        w: w || 100, h: h || size * 1.4,
        text, name, size, bold, align, border, field: k.tag === "field",
      });
    }
  };
  walk(template, 0, 0);
  out.pages.push(page);
  return out;
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
