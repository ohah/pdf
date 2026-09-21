// 태그 PDF — 구조 나무가 적어 둔 대로 덩이를 만든다.
//
// 태그 PDF 는 "이건 제목(H1), 이건 문단(P), 이건 표의 칸(TD)" 을 문서가
// 스스로 적어 둔다(Word·LibreOffice·InDesign 이 낸 것, 접근성 규격 PDF/UA).
// 본문의 글자 조각마다 /MCID 번호가 붙고, 나무의 잎이 그 번호를 가리킨다.
// 이게 있으면 크기·굵기로 어림하지 않고 나무를 그대로 따른다 — 읽는 차례도
// 나무의 차례다(두 단·상자 글·표도 문서가 정한 대로).
//
// 나무가 있어도 본문의 반도 안 가리키면(겉만 태그한 문서) 어림으로 돌아간다.
import { joinPieces, type Line, type Piece } from "./extract.js";
import type { DocBlock, PageForMd } from "./markdown.js";

/** 구조 나무의 마디 하나 */
export type StructNode = {
  /** Document·H1·P·Table … (/S). 뿌리는 "Root" */
  role: string;
  /** 그림 등에 붙는 대체 글 (/Alt) */
  alt: string;
  /** 놓인 쪽(0부터). 모르면 -1 */
  page: number;
  /** 본문에서 이 마디를 가리키는 표식. 잎이 아니면 -1 */
  mcid: number;
  children: StructNode[];
};

/** 워커가 주는 납작한 마디 — 깊이로 나무를 다시 세운다 */
export type StructRow = { depth: number; role: string; alt: string; page: number; mcid: number };

/**
 * 납작한 마디들(`PDFClient.open()` 이 준 struct)로 나무를 세운다. 쪽 번호(1부터)를
 * 주면 그 쪽에 놓인 가지만 추린다. 마디가 없으면 null — 태그 없는 문서다.
 * 워커 창구를 직접 쓰는 앱이 `markdownOf(pages, nums, structTree(open.struct))` 로 쓴다.
 */
export function structTree(flat: StructRow[], page?: number): StructNode | null {
  if (flat.length === 0) return null;
  const want = page == null ? null : page - 1;
  const root: StructNode = { role: "Root", alt: "", page: -1, mcid: -1, children: [] };
  const stack: StructNode[] = [root];
  for (const n of flat) {
    const node: StructNode = { role: n.role, alt: n.alt, page: n.page, mcid: n.mcid, children: [] };
    stack.length = Math.min(stack.length, n.depth + 1);
    const parent = stack[stack.length - 1] ?? root;
    if (n.depth === 0 && parent === root && n.role === "Root") {
      // 뿌리는 하나로 둔다
      stack[0] = node;
      root.children = node.children;
      root.role = node.role;
      continue;
    }
    parent.children.push(node);
    stack[n.depth + 1] = node;
  }
  if (want == null) return root;
  // 그 쪽에 놓인 것만 남긴다 — 자식이 남으면 부모도 남긴다
  const keep = (n: StructNode): StructNode | null => {
    const kids = n.children.map(keep).filter((k): k is StructNode => k !== null);
    if (kids.length === 0 && n.page !== want) return null;
    return { ...n, children: kids };
  };
  return keep(root);
}

type Frag = { page: number; pageNo: number; bbox: [number, number, number, number]; parts: { line: Line; ps: Piece[] }[]; chars: number };

/** 쪽마다 MCID → 조각들. 줄 차례(읽는 차례)대로 모은다 */
function fragments(pages: PageForMd[]): Map<string, Frag> {
  const out = new Map<string, Frag>();
  pages.forEach((p, i) => {
    const pno = p.page ?? i + 1;
    for (const l of p.lines) {
      const by = new Map<number, Piece[]>();
      for (const q of l.pieces) {
        const m = q.mcid ?? -1;
        if (m < 0) continue;
        const arr = by.get(m); if (arr) arr.push(q); else by.set(m, [q]);
      }
      for (const [m, ps] of by) {
        const key = `${pno - 1}:${m}`;
        const x0 = Math.min(...ps.map((q) => q.x)), x1 = Math.max(...ps.map((q) => q.x + q.w));
        // 줄의 위 기준 y 는 l.y — 조각의 y 는 아래 기준이라 줄 것을 쓴다
        const bb: [number, number, number, number] = [x0, l.y - l.size, x1, l.y + l.size * 0.25];
        const chars = ps.reduce((n, q) => n + q.text.trim().length, 0);
        const f = out.get(key);
        if (f) {
          f.parts.push({ line: l, ps });
          f.bbox = [Math.min(f.bbox[0], bb[0]), Math.min(f.bbox[1], bb[1]), Math.max(f.bbox[2], bb[2]), Math.max(f.bbox[3], bb[3])];
          f.chars += chars;
        } else out.set(key, { page: pno - 1, pageNo: pno, bbox: bb, parts: [{ line: l, ps }], chars });
      }
    }
  });
  return out;
}

type Got = { text: string; page: number; bbox: [number, number, number, number] | null; src: Line[] };

/** 어림 쪽이 빌려주는 제목 판정 — 나무에 제목 역할이 하나도 없을 때(Word 가 다 P 로 낸 문서) 쓴다 */
export type HeadingGuess = (lines: Line[]) => number;

const HEADING = /^H([1-6])$/;
/** 문단처럼 통째로 글이 되는 역할 */
const PARA = new Set(["P", "Caption", "BlockQuote", "Note", "Formula", "Index", "BibEntry", "Form", "Title", "Quote", "Span", "Link", "Reference", "Lbl", "Annot", "Em", "Strong", "Sub", "Sup", "Ruby", "Warichu", "RB", "RT", "RP", "Code"]);
/** 아래를 계속 훑는 역할 */
const CONTAINER = new Set(["Root", "Document", "Part", "Art", "Sect", "Div", "NonStruct", "Private", "Aside", "TOC", "TOCI", "L", "LI", "LBody", "Table", "TR", "TD", "TH", "THead", "TBody", "TFoot", "Figure"]);

/**
 * 구조 나무대로 덩이를 만든다. 나무가 본문을 충분히 가리키지 않으면 null —
 * 그러면 어림(toBlocks)으로 간다.
 */
export function taggedBlocks(pages: PageForMd[], root: StructNode, guess?: HeadingGuess): DocBlock[] | null {
  const frags = fragments(pages);
  if (frags.size === 0) return null;
  const used = new Set<string>();
  let lastPage = -1;
  let blockRoles = 0;

  // 마디 아래의 글을 다 모은다(잎 차례대로)
  const gather = (n: StructNode, acc: { lines: string[]; page: number; bbox: Got["bbox"]; cur: Line | null; buf: Piece[]; src: Line[] }) => {
    if (n.role === "Artifact") return;
    if (n.page >= 0) lastPage = n.page;
    if (n.mcid >= 0) {
      const f = frags.get(`${n.page >= 0 ? n.page : lastPage}:${n.mcid}`);
      if (f) {
        used.add(`${f.page}:${n.mcid}`);
        if (acc.page < 0) acc.page = f.pageNo;
        // 자리는 첫 쪽 것만 — 두 쪽에 걸친 문단의 상자가 쪽을 넘어 늘어나지 않게
        if (f.pageNo === acc.page) acc.bbox = acc.bbox ? [Math.min(acc.bbox[0], f.bbox[0]), Math.min(acc.bbox[1], f.bbox[1]), Math.max(acc.bbox[2], f.bbox[2]), Math.max(acc.bbox[3], f.bbox[3])] : [...f.bbox];
        for (const part of f.parts) {
          // 같은 줄에 이어지는 조각은 한 줄로 잇는다(띄어쓰기는 틈으로) — 줄이 바뀌면 새 줄
          if (acc.cur === part.line) acc.buf.push(...part.ps);
          else { flush(acc); acc.cur = part.line; acc.buf = [...part.ps]; if (!acc.src.includes(part.line)) acc.src.push(part.line); }
        }
      }
    }
    for (const k of n.children) gather(k, acc);
  };
  const flush = (acc: { lines: string[]; cur: Line | null; buf: Piece[] }) => {
    // 같은 줄이라도 x 로 다시 줄 세우지 않는다 — 나무(MCID) 차례가 곧 읽는 차례다.
    // 한은 보고서의 "2.0%" 는 % 가 뒤 낱말보다 왼쪽에 찍혀 x 순으로는 "2.0 성장할 %" 가 됐다
    if (acc.buf.length) { const t = joinPieces(acc.buf); if (t) acc.lines.push(t); }
    acc.buf = []; acc.cur = null;
  };
  const textOf = (n: StructNode): Got => {
    const acc = { lines: [] as string[], page: -1, bbox: null as Got["bbox"], cur: null as Line | null, buf: [] as Piece[], src: [] as Line[] };
    gather(n, acc); flush(acc);
    return { text: joinHyphen(acc.lines), page: acc.page, bbox: acc.bbox, src: acc.src };
  };

  const blocks: DocBlock[] = [];
  const push = (b: DocBlock) => { blocks.push(b); };
  let treeHeads = 0;
  // 문단 — 나무에 제목이 하나도 없으면 어림으로 제목을 가려낸다(뒤에서 다시 본다)
  const paras: { at: number; src: Line[] }[] = [];
  const para = (g: Got) => { paras.push({ at: blocks.length, src: g.src }); push({ kind: "para", text: g.text, ...where(g) }); };
  const where = (g: Got) => ({ page: g.page, bbox: g.bbox ?? [0, 0, 0, 0] as [number, number, number, number] });

  const listItems = (n: StructNode, depth: number, items: string[]) => {
    for (const li of n.children) {
      if (li.role === "L") { listItems(li, depth + 1, items); continue; }
      if (li.role !== "LI") { const g = textOf(li); if (g.text) items.push("\t".repeat(depth) + g.text); continue; }
      let label = "", body = "";
      const nested: StructNode[] = [];
      for (const k of li.children) {
        if (k.role === "Lbl") label = textOf(k).text;
        else if (k.role === "LBody") {
          // 본문 안의 안긴 목록은 따로 — 그 밖의 글은 이 항목의 글
          const inner: StructNode = { ...k, children: k.children.filter((c) => c.role !== "L") };
          body = (body ? body + " " : "") + textOf(inner).text;
          nested.push(...k.children.filter((c) => c.role === "L"));
        } else if (k.role === "L") nested.push(k);
        else body = (body ? body + " " : "") + textOf(k).text;
      }
      // 기호 라벨(•·-)은 Markdown 이 붙인다. 번호·글자 라벨은 뜻이 있어 남긴다
      const keep = label && !/^[•·▪‣◦■□▶►◆◇○●※\-–—*-✀-➿]?$/.test(label.trim());
      // 라벨 없이 본문 첫 글자로 찍은 기호(Word 의 PUA 글머리)도 뗀다
      const text = ((keep ? label.trim() + " " : "") + body).trim().replace(/^[•·▪‣◦■□▶►◆◇○●※\-–—*\uE000-\uF8FF\u2700-\u27BF]\s*/, "");
      if (text.trim()) items.push("\t".repeat(depth) + text.trim());
      for (const nl of nested) listItems(nl, depth + 1, items);
    }
  };
  const tableRows = (n: StructNode): string[][] => {
    const rows: string[][] = [];
    const walkRows = (m: StructNode) => {
      for (const k of m.children) {
        if (k.role === "TR") rows.push(k.children.filter((c) => c.role === "TD" || c.role === "TH").map((c) => textOf(c).text));
        else if (k.role === "THead" || k.role === "TBody" || k.role === "TFoot") walkRows(k);
        else if (k.role === "Caption") { const g = textOf(k); if (g.text) push({ kind: "para", text: g.text, ...where(g) }); }
      }
    };
    walkRows(n);
    return rows.filter((r) => r.some((c) => c.trim()));
  };

  const walk = (n: StructNode, sect: number) => {
    const role = n.role;
    if (role === "Artifact") return;
    if (n.page >= 0) lastPage = n.page;
    const hm = HEADING.exec(role);
    if (hm || role === "H" || role === "Title") {
      const g = textOf(n);
      if (g.text) { blockRoles++; treeHeads++; push({ kind: "heading", level: hm ? Number(hm[1]) : role === "Title" ? 1 : Math.min(6, Math.max(1, sect)), text: g.text, ...where(g) }); }
      return;
    }
    if (role === "Code") {
      const g = textOf(n);
      if (g.text) { blockRoles++; push({ kind: "code", text: g.text, ...where(g) }); }
      return;
    }
    if (role === "L" || role === "TOC") {
      const items: string[] = [];
      if (role === "TOC") for (const k of n.children) { const g = textOf(k); if (g.text) items.push(g.text); }
      else listItems(n, 0, items);
      if (items.length) { blockRoles++; const g = textOf(n); push({ kind: "list", items, ...where(g) }); }
      return;
    }
    if (role === "Table") {
      const rows = tableRows(n);
      if (!rows.length) return;
      blockRoles++;
      // 줄마다 찬 칸이 하나뿐 — Word 가 제목 띠·상자 글을 표로 낸 것이다. 문단으로 푼다
      if (rows.every((r) => r.filter((c) => c.trim()).length <= 1)) {
        const walkCells = (m: StructNode) => {
          for (const k of m.children) {
            if (k.role === "TR") for (const c of k.children) if (c.role === "TD" || c.role === "TH") walk(c, sect);
            if (k.role === "THead" || k.role === "TBody" || k.role === "TFoot") walkCells(k);
          }
        };
        walkCells(n);
        return;
      }
      const g = textOf(n); push({ kind: "table", rows, ...where(g) });
      return;
    }
    if (role === "Figure") {
      const g = textOf(n);
      // 대체 글이 "EMB000043bc27c0" 같은 그림 번호뿐이면 버린다
      const alt = /^[A-Za-z]*\d[A-Za-z0-9_]*$/.test(n.alt.trim()) ? "" : n.alt.trim();
      const t = g.text || alt;
      if (t) push({ kind: "para", text: t, page: g.page >= 0 ? g.page : (n.page >= 0 ? n.page : lastPage) + 1, bbox: g.bbox ?? [0, 0, 0, 0] });
      return;
    }
    const isBlock = (k: StructNode) => HEADING.test(k.role) || ["H", "L", "Table", "Figure", "Code", "TOC", "Sect", "Div", "Art", "Part", "Document"].includes(k.role);
    const hasBlock = n.children.some(isBlock);
    if ((PARA.has(role) || (n.mcid >= 0 && n.children.length === 0)) && !hasBlock) {
      const g = textOf(n);
      if (g.text) { if (role === "P") blockRoles++; para(g); }
      return;
    }
    if (PARA.has(role) && hasBlock) {
      // 문단 안에 표·목록이 안겨 있다(InDesign 은 표를 P 아래 둔다). 글은 글대로 문단,
      // 덩이는 덩이대로 — 덩이 사이의 글 조각들을 한 문단으로 모은다
      let inline: StructNode[] = [];
      const flushInline = () => {
        if (!inline.length) return;
        const g = textOf({ ...n, mcid: -1, children: inline });
        if (g.text) { blockRoles++; para(g); }
        inline = [];
      };
      if (n.mcid >= 0) inline.push({ ...n, children: [] });
      for (const k of n.children) { if (isBlock(k)) { flushInline(); walk(k, sect); } else inline.push(k); }
      flushInline();
      return;
    }
    // 그릇(Sect·Div…)과 모르는 역할 — 아래에 덩이가 있으면 내려가고, 없으면 통째로 문단
    if (CONTAINER.has(role) || hasBlock || n.children.some((k) => k.role === "P")) {
      for (const k of n.children) walk(k, sect + (role === "Sect" ? 1 : 0));
      return;
    }
    const g = textOf(n);
    if (g.text) para(g);
  };
  walk(root, 0);
  if (treeHeads === 0 && guess) for (const { at, src } of paras) {
    const b = blocks[at];
    if (b.kind !== "para" || src.length === 0 || src.length > 2) continue;
    const level = guess(src);
    if (level > 0) blocks[at] = { kind: "heading", level, text: b.text, page: b.page, bbox: b.bbox };
  }

  // 나무가 가리킨 글이 본문의 반도 안 되면 못 믿는다
  let tagged = 0, all = 0;
  for (const p of pages) for (const l of p.lines) for (const q of l.pieces) {
    const m = q.mcid ?? -1;
    if (m === -2) continue;
    const n = q.text.trim().length;
    all += n;
    if (m >= 0 && used.has(`${(p.page ?? 1) - 1}:${m}`)) tagged += n;
  }
  if (blockRoles === 0 || all === 0 || tagged < all * 0.5) return null;

  // 태그가 안 붙은 줄(반쯤 태그한 문서)은 쪽 뒤에 문단으로 덧붙인다
  pages.forEach((p, i) => {
    const pno = p.page ?? i + 1;
    let para: Line[] = [];
    const end = () => {
      if (!para.length) return;
      const text = joinHyphen(para.map((l) => l.text));
      const at = lastIndexOfPage(blocks, pno);
      blocks.splice(at, 0, { kind: "para", text, page: pno, bbox: [Math.min(...para.map((l) => l.x)), para[0].y - para[0].size, Math.max(...para.map((l) => l.x + l.w)), para[para.length - 1].y + para[para.length - 1].size * 0.25] });
      para = [];
    };
    for (const l of p.lines) {
      const free = l.pieces.filter((q) => (q.mcid ?? -1) === -1 || ((q.mcid ?? -1) >= 0 && !used.has(`${pno - 1}:${q.mcid}`)));
      const chars = free.reduce((n, q) => n + q.text.trim().length, 0);
      if (chars * 2 < l.text.length || Math.abs(l.angle) > 0.1) { end(); continue; }
      if (para.length && l.y - para[para.length - 1].y > l.size * 1.8) end();
      para.push(l);
    }
    end();
  });
  return blocks;
}

/** 줄 끝 하이픈은 다음 줄이 소문자로 이어지면 뗀다(어림 쪽 joinLines 와 같은 규칙, 사전 없이) */
function joinHyphen(ls: string[]): string {
  let s = "";
  for (const l of ls) {
    if (!s) { s = l; continue; }
    if (/[a-zA-Z]-$/.test(s) && /^[a-z]/.test(l)) s = s.slice(0, -1) + l;
    else s += " " + l;
  }
  return s.replace(/\s+/g, " ").trim();
}

/** 그 쪽의 덩이가 끝나는 자리(없으면 그 쪽보다 뒤 쪽이 시작하는 자리) */
function lastIndexOfPage(blocks: DocBlock[], pno: number): number {
  let at = blocks.length;
  for (let i = blocks.length - 1; i >= 0; i--) if (blocks[i].page === pno) return i + 1;
  for (let i = 0; i < blocks.length; i++) if (blocks[i].page > pno) { at = i; break; }
  return at;
}
