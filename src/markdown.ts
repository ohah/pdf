// 쪽의 줄들을 Markdown 으로 — 제목·문단·목록·코드·표.
//
// LLM 에 먹이려면 "글자 좌표" 가 아니라 "이건 제목, 이건 문단, 이건 표" 가
// 있어야 한다. 그 일을 하는 도구는 다 Python(docling·marker·pymupdf4llm)이고
// 무겁다. 여기서는 글자층이 이미 아는 것(크기·글꼴·자리)과 그리기 명령의
// 괘선만으로 규칙으로 가른다. ML 없이 되는 데까지 — 규칙이 틀리는 자리는
// tests/md-bench.mjs 가 기준과 맞대 드러낸다.
//
// 가르는 규칙:
//   본문 크기   글자 수로 가중한 최빈 크기
//   제목        본문보다 크거나 굵고 짧은 줄. 크기 순으로 #·##·###. "3.1 …"
//               처럼 번호가 있으면 번호 깊이가 우선
//   문단        같은 단에서 줄 간격이 촘촘한 줄들. 끝의 "-" 는 다음 줄이
//               소문자로 시작하면 이어 붙인다
//   목록        •·-·–·1.·(a) 로 시작하는 줄
//   코드        고정폭 글꼴(Courier·Mono·SFTT·Consolas)인 줄들
//   머리말·꼬리말 쪽마다 같은 자리에 같은 꼴로 반복되는 줄 — 버린다
//   표          가는 선·네모(괘선)가 격자를 이루면 그 안의 글을 칸에 넣는다
import { joinPieces, type Line } from "./extract.js";

export type PageForMd = {
  /** 쪽 번호(1부터). 없으면 넘긴 차례 */
  page?: number;
  lines: Line[];
  /** 쪽 크기(pt) */
  w: number; h: number;
  /** 괘선 — 위 기준 좌표. 가로선은 y 가 같고 세로선은 x 가 같다 */
  rules: Rule[];
  /** 칠해진 도형·그림의 상자(위 기준). 그 안의 글자는 그림 라벨이지 제목이 아니다 */
  boxes: Rule[];
  /** 칠한 경로 하나하나의 상자 — 도표는 수십 개, 제목 띠는 한두 개 */
  marks: Rule[];
};

export type Rule = { x0: number; y0: number; x1: number; y1: number };

const MONO = /courier|mono|sftt|consolas|menlo|typewriter|cmtt|lucidacon/i;
const BOLD = /bold|black|heavy|semibold|demibold|-bd\b|medi\b|cmbx|\bbd\b/i;
const NUMBERED = /^(\d+(\.\d+)*)\.?\s+\S/;
// 글머리: 기호, 번호, 그리고 Wingdings·Symbol 글꼴의 사용자 영역(PUA) 글자 —
// 한국어 보고서의 요약 문장이 그 꼴이다
// 글자 글머리는 소문자만 — "Y. Bengio" 처럼 이름 머리글자로 시작하는 줄(참고문헌)은 목록이 아니다
const BULLET = /^([•·▪‣◦■□▶►◆◇○●※\-–—*]|[\uE000-\uF8FF]|[\u2700-\u27BF]|\d+[.)]|\(?[a-z][.)]|\(?[ivx]+[.)])\s*/;
// 기호 글머리 — 굵거나 커도 제목이 아니라 목록이다(보고서의 요약 문장)
const SYMBOL_BULLET = /^([•·▪‣◦■□▶►◆◇○●※\-–—*]|[\uE000-\uF8FF]|[\u2700-\u27BF])\s*/;

/** 어느 쪽, 어느 자리(pt, 왼쪽 위 기준 [x0 y0 x1 y1])에서 왔는지 */
type Where = { page: number; bbox: [number, number, number, number] };

/** 문서를 가른 덩이 하나 — JSON 으로 그대로 낼 수 있다 */
export type DocBlock = Where & (
  | { kind: "heading"; level: number; text: string }
  | { kind: "para"; text: string }
  | { kind: "list"; items: string[] }
  | { kind: "code"; text: string }
  | { kind: "table"; rows: string[][] }
);
type Block = DocBlock;

/** 그리기 명령에서 괘선(가늘고 긴 채움 네모와 획 선)과 도형·그림 상자를 뽑는다. */
export function rulesOf(ops: Float32Array, pageH: number, y0page = 0): { rules: Rule[]; boxes: Rule[]; marks: Rule[] } {
  const out: Rule[] = [];
  const boxes: Rule[] = [];
  const marks: Rule[] = [];
  // CTM 을 따라간다 — 표 괘선은 대개 변환 아래에 있다
  let m: [number, number, number, number, number, number] = [1, 0, 0, 1, 0, 0];
  const stack: typeof m[] = [];
  const mul = (a: typeof m, b: typeof m): typeof m => [
    a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
    a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
    a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5],
  ];
  const pt = (x: number, y: number) => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
  let path: number[][] = [];
  let sub: number[][] = [];
  const top = (y: number) => y0page + pageH - y;
  const flush = (paint: boolean) => {
    if (sub.length) path.push(...sub);
    if (paint && path.length >= 2) {
      const xs = path.map((p) => p[0]), ys = path.map((p) => p[1]);
      const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
      const w = x1 - x0, h = y1 - y0;
      // 가늘고(2pt 이하) 길면(8pt 이상) 괘선
      if (h <= 2.5 && w >= 8) out.push({ x0, y0: top((y0 + y1) / 2), x1, y1: top((y0 + y1) / 2) });
      else if (w <= 2.5 && h >= 8) out.push({ x0: (x0 + x1) / 2, y0: top(y1), x1: (x0 + x1) / 2, y1: top(y0) });
      else if (w >= 8 && h >= 8 && path.length <= 6) {
        // 네모 테두리(획)는 네 변이 다 괘선이다
        out.push({ x0, y0: top(y1), x1, y1: top(y1) }, { x0, y0: top(y0), x1, y1: top(y0) },
          { x0, y0: top(y1), x1: x0, y1: top(y0) }, { x0: x1, y0: top(y1), x1, y1: top(y0) });
      }
      // 쪽 바탕만 한 채움(배경)은 도형이 아니다
      if (w >= 8 && h >= 8 && !(w > 400 && h > 500)) boxes.push({ x0, y0: top(y1), x1, y1: top(y0) });
      if (!(w > 400 && h > 500)) marks.push({ x0, y0: top(y1), x1, y1: top(y0) });
    }
    path = []; sub = [];
  };
  let strokeRect = false;
  for (let i = 0; i < ops.length;) {
    const k = ops[i], n = ops[i + 1], a = i + 2;
    switch (k) {
      case 14: stack.push(m); break;
      case 15: m = stack.pop() ?? m; break;
      case 16: m = mul([ops[a], ops[a + 1], ops[a + 2], ops[a + 3], ops[a + 4], ops[a + 5]], m); break;
      case 1: if (sub.length) path.push(...sub); sub = [pt(ops[a], ops[a + 1])]; break;
      case 2: sub.push(pt(ops[a], ops[a + 1])); break;
      case 3: sub.push(pt(ops[a + 4], ops[a + 5])); break;
      case 5: {
        const [x, y, w, h] = [ops[a], ops[a + 1], ops[a + 2], ops[a + 3]];
        if (sub.length) path.push(...sub);
        sub = [pt(x, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h)];
        strokeRect = true;
        break;
      }
      case 6: flush(true); strokeRect = false; break;
      case 7: flush(strokeRect || path.length + sub.length <= 2 || true); strokeRect = false; break;
      case 8: flush(true); strokeRect = false; break;
      case 9: case 10: flush(false); strokeRect = false; break;
      case 18: {
        // 그림은 지금 변환의 단위 정사각형에 놓인다
        const c = [pt(0, 0), pt(1, 0), pt(1, 1), pt(0, 1)];
        const xs = c.map((p) => p[0]), ys = c.map((p) => p[1]);
        const bw = Math.max(...xs) - Math.min(...xs), bh = Math.max(...ys) - Math.min(...ys);
        if (bw >= 8 && bh >= 8 && !(bw > 400 && bh > 500)) boxes.push({ x0: Math.min(...xs), y0: top(Math.max(...ys)), x1: Math.max(...xs), y1: top(Math.min(...ys)) });
        break;
      }
      default: break;
    }
    i += 2 + n;
  }
  return { rules: out, boxes, marks };
}

/** 글자 수로 가중한 최빈 크기 */
function bodySize(pages: PageForMd[]): number {
  const count = new Map<number, number>();
  for (const p of pages) for (const l of p.lines) {
    const k = Math.round(l.size * 2) / 2;
    count.set(k, (count.get(k) ?? 0) + l.text.length);
  }
  let best = 10, bn = -1;
  for (const [k, n] of count) if (n > bn) { bn = n; best = k; }
  return best;
}

/** 쪽마다 같은 자리에 같은 꼴로 나오는 줄 — 머리말·꼬리말·쪽 번호 */
function runningLines(pages: PageForMd[]): Set<Line> {
  const drop = new Set<Line>();
  if (pages.length < 3) return drop;
  const key = (l: Line, p: PageForMd) => `${Math.round(l.y / p.h * 40)}|${l.text.replace(/\d+/g, "#").slice(0, 40)}`;
  const seen = new Map<string, Line[]>();
  for (const p of pages) {
    for (const l of p.lines) {
      if (l.y > p.h * 0.12 && l.y < p.h * 0.88) continue;
      const k = key(l, p);
      (seen.get(k) ?? seen.set(k, []).get(k)!).push(l);
    }
  }
  for (const ls of seen.values()) if (ls.length >= Math.max(2, Math.floor(pages.length * 0.4))) ls.forEach((l) => drop.add(l));
  // 쪽 번호 홀로 있는 줄
  for (const p of pages) for (const l of p.lines) {
    if ((l.y < p.h * 0.1 || l.y > p.h * 0.9) && /^\d{1,4}$/.test(l.text)) drop.add(l);
  }
  return drop;
}

function isBoldLine(l: Line): boolean {
  let bold = 0, all = 0;
  for (const p of l.pieces) { all += p.text.length; if (p.bold || BOLD.test(p.base)) bold += p.text.length; }
  return all > 0 && bold / all > 0.6;
}

function isMono(l: Line): boolean {
  let mono = 0, all = 0;
  for (const p of l.pieces) { all += p.text.length; if (MONO.test(p.base)) mono += p.text.length; }
  return all > 0 && mono / all > 0.6;
}

/** 같은 줄 위에서 맞닿는 괘선 조각을 잇는다. horiz 면 y 가 같고 x 로 잇는다 */
function merge(rs: Rule[], horiz: boolean): Rule[] {
  const k = horiz ? ((r: Rule) => r.y0) : ((r: Rule) => r.x0);
  const a = horiz ? ((r: Rule) => r.x0) : ((r: Rule) => r.y0);
  const b = horiz ? ((r: Rule) => r.x1) : ((r: Rule) => r.y1);
  const sorted = [...rs].sort((p, q) => k(p) - k(q) || a(p) - a(q));
  const out: Rule[] = [];
  for (const r of sorted) {
    const last = out[out.length - 1];
    if (last && Math.abs(k(last) - k(r)) < 1.5 && a(r) <= b(last) + 2) {
      if (horiz) last.x1 = Math.max(last.x1, r.x1); else last.y1 = Math.max(last.y1, r.y1);
    } else out.push({ ...r });
  }
  return out.filter((r) => (horiz ? r.x1 - r.x0 : r.y1 - r.y0) >= 8);
}

/** 괘선 격자에서 표를 찾아 줄들을 칸에 넣는다. 표에 든 줄은 used 에 표시. */
function tablesOf(page: PageForMd, used: Set<Line>): { top: number; rows: string[][]; bbox: [number, number, number, number] }[] {
  // 같은 y 에서 맞닿는 조각(칸마다 끊어 그린 괘선)은 한 선으로 잇는다
  const hs = merge(page.rules.filter((r) => Math.abs(r.y0 - r.y1) < 1 && r.x1 - r.x0 >= 4), true);
  const vs = merge(page.rules.filter((r) => Math.abs(r.x0 - r.x1) < 1 && r.y1 - r.y0 >= 4), false);
  const out: { top: number; rows: string[][]; bbox: [number, number, number, number] }[] = [];
  if (hs.length < 2) return out;
  // 가로선을 겹치는 x 범위로 묶어 표 후보를 만든다
  const groups: typeof hs[] = [];
  const sorted = [...hs].sort((a, b) => a.y0 - b.y0);
  for (const h of sorted) {
    const g = groups.find((G) => G.some((o) => Math.min(o.x1, h.x1) - Math.max(o.x0, h.x0) > 20 && Math.abs(o.y0 - h.y0) < 400));
    if (g) g.push(h); else groups.push([h]);
  }
  for (const g of groups) {
    if (g.length < 2) continue;
    const ys = [...new Set(g.map((h) => Math.round(h.y0)))].sort((a, b) => a - b);
    if (ys.length < 2) continue;
    const x0 = Math.min(...g.map((h) => h.x0)), x1 = Math.max(...g.map((h) => h.x1));
    const yTop = ys[0], yBot = ys[ys.length - 1];
    // 표 안의 줄들
    const inside = page.lines.filter((l) => !used.has(l) && l.y - l.size * 0.8 >= yTop - 2 && l.y <= yBot + 4 && l.x >= x0 - 4 && l.x + l.w <= x1 + 4);
    if (inside.length < 2) continue;
    // 세로 경계: 표 높이의 대부분(60%)을 지나는 세로 괘선. 병합 칸의 짧은
    // 경계까지 열로 보면 14칸짜리 표가 된다. 없으면 조각 사이 빈 골로 짐작
    const span = yBot - yTop;
    const gapCols = (): number[] => {
      const spans: [number, number][] = [];
      for (const l of inside) for (const p of l.pieces) spans.push([p.x, p.x + p.w]);
      spans.sort((a, b) => a[0] - b[0]);
      const gaps: number[] = [];
      let reach = spans[0]?.[1] ?? 0;
      for (const s of spans.slice(1)) {
        if (s[0] - reach > 6) gaps.push((reach + s[0]) / 2);
        reach = Math.max(reach, s[1]);
      }
      return [x0, ...gaps, x1];
    };
    let xs: number[] = [];
    for (const v of vs.filter((v) => v.x0 >= x0 - 2 && v.x0 <= x1 + 2 && Math.min(v.y1, yBot) - Math.max(v.y0, yTop) >= span * 0.6).map((v) => v.x0).sort((a, b) => a - b)) {
      if (!xs.length || v - xs[xs.length - 1] > 4) xs.push(v);
    }
    if (xs.length < 2) xs = gapCols();
    if (xs.length < 3) continue;
    // 행: 가로선 사이 띠 안의 글 줄 하나가 한 행이다(booktabs 처럼 괘선이
    // 위·중간·아래에만 있어도 된다). 칸 글은 조각 틈으로 띄어쓰기를 정한다.
    const build = (cols: number[]): { rows: string[][]; lines: Line[]; empty: number } => {
      const rows: string[][] = [];
      const lines: Line[] = [];
      const cellOf = (p: { x: number; w: number }) => {
        const cx = p.x + p.w / 2;
        const c = cols.findIndex((x, i) => i + 1 < cols.length && cx >= x && cx < cols[i + 1]);
        return c < 0 ? (cx < cols[0] ? 0 : cols.length - 2) : c;
      };
      for (let r = 0; r + 1 < ys.length; r++) {
        // l.y 는 기준선이라 글자 가운데는 그보다 0.35·size 위다
        const band = inside.filter((l) => l.y - l.size * 0.35 > ys[r] && l.y - l.size * 0.35 < ys[r + 1]);
        for (const l of band.sort((a, b) => a.y - b.y)) {
          const cells: string[] = new Array(cols.length - 1).fill("");
          const per: Line["pieces"][] = Array.from({ length: cols.length - 1 }, () => []);
          for (const p of l.pieces) per[cellOf(p)].push(p);
          per.forEach((ps, c) => { cells[c] = joinPieces(ps); });
          lines.push(l);
          // 왼쪽 칸이 비고 한 칸만 찬 줄은 앞 행의 칸이 줄바꿈된 것
          const filled = cells.filter((c) => c).length;
          if (rows.length && filled === 1 && !cells[0] && rows[rows.length - 1].some((c) => c)) {
            const k = cells.findIndex((c) => c);
            rows[rows.length - 1][k] = (rows[rows.length - 1][k] + " " + cells[k]).trim();
            continue;
          }
          rows.push(cells);
        }
      }
      let empty = 0, all = 0;
      for (const r of rows) for (const c of r) { all++; if (!c) empty++; }
      return { rows, lines, empty: all ? empty / all : 1 };
    };
    let got = build(xs);
    // 빈 칸이 60% 넘으면 열을 잘못 갈랐다 — 골 기준으로 다시. 그래도 나쁘면 표가 아니다
    if (got.empty > 0.6) { const alt = gapCols(); if (alt.length >= 3) got = build(alt); }
    if (got.empty > 0.6 || got.rows.length < 2) continue;
    got.lines.forEach((l) => used.add(l));
    out.push({ top: yTop, rows: got.rows, bbox: [x0, yTop, x1, yBot] });
  }
  return out;
}

function headingLevel(l: Line, body: number, ranks: number[]): number {
  const m = NUMBERED.exec(l.text);
  if (m) return Math.min(4, m[1].split(".").length);
  const idx = ranks.findIndex((s) => Math.abs(s - l.size) < 0.26);
  if (idx >= 0) return Math.min(4, idx + 1);
  return isBoldLine(l) ? Math.min(4, ranks.length + 1) : 0;
}

/** 같은 크기·같은 단의 줄이 셋 이상 촘촘히 이어지면 제목이 아니라 문단이다 — 저작권 고지 같은 것 */
function inBlock(lines: Line[], l: Line, drop: Set<Line>): boolean {
  const i = lines.indexOf(l);
  // 같은 크기, 가로로 겹치고(가운데 맞춤도 됨), 줄 간격이 촘촘한 이웃
  // 굵기가 다르면 다른 묶음 — 본문 크기의 굵은 제목이 뒤따르는 본문에 묻히지 않게.
  // 다만 긴 줄(40자 초과)은 굵기를 안 본다 — 굵은 초록 문단에 수식(이탤릭)이 섞인
  // 줄이 이웃과 갈려 제목이 됐다. 긴 줄은 이웃이 있으면 문단이다
  const short = l.text.length <= 40;
  const same = (a: Line, b: Line) => Math.abs(a.size - b.size) < 0.3 && (!short || isBoldLine(a) === isBoldLine(b)) &&
    Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > 0 &&
    Math.abs(b.y - a.y) < b.size * 1.8 && Math.abs(b.y - a.y) > b.size * 0.3;
  let n = 1, chars = l.text.length;
  for (let j = i - 1; j >= 0 && !drop.has(lines[j]) && same(lines[j], lines[j + 1]); j--) { n++; chars += lines[j].text.length; }
  for (let j = i + 1; j < lines.length && !drop.has(lines[j]) && same(lines[j - 1], lines[j]); j++) { n++; chars += lines[j].text.length; }
  // 묶음 전체로 판단한다 — 마지막 짧은 줄("scholarly works.")도 같은 문단이다.
  // 제목은 한 줄이거나, 두 줄이어도 합쳐 100자를 안 넘는다.
  return n >= 3 || (n >= 2 && chars > 100);
}

/**
 * 그림·도표의 글자인가 — 칠해진 도형·그림 상자와 겹치는 짧은 줄.
 * 축 눈금·상자 라벨은 크거나 굵어도 제목이 아니다. 저자 목록처럼 짧은 줄이
 * 흩어져 있어도 도형이 없으면 그림이 아니다.
 */
function inFigure(page: PageForMd, l: Line): boolean {
  if (l.text.length > 40) return false;
  const lx0 = l.x, lx1 = l.x + l.w, ly0 = l.y - l.size, ly1 = l.y + l.size * 0.3;
  const hit = page.boxes.filter((b) => lx1 > b.x0 - 2 && lx0 < b.x1 + 2 && ly1 > b.y0 - 2 && ly0 < b.y1 + 2);
  if (!hit.length) return false;
  // 줄 하나 높이의 띠(제목 뒤 색 바탕)는 그림이 아니다. 큰 상자(그림)거나
  // 둘레에 칠한 경로가 많아야(도표의 마디·축·선) 그림이다
  const big = hit.some((b) => b.y1 - b.y0 >= l.size * 3);
  // 가는 선(표 괘선)은 안 센다 — 도형(폭·높이 3pt 이상)만
  const crowd = page.marks.filter((b) => Math.min(b.x1 - b.x0, b.y1 - b.y0) >= 3 && Math.abs((b.y0 + b.y1) / 2 - l.y) < 160 && Math.abs((b.x0 + b.x1) / 2 - l.x) < 260).length >= 8;
  return big || crowd;
}

const CAPTION = /^(fig(ure)?|table|tab|scheme|chart|그림|표|사진)\.?\s*\d+[.:]?\s/i;

function isHeading(l: Line, body: number): boolean {
  if (l.text.length > 120) return false;
  // 캡션("FIG. 2. …", "Table 1:", "그림 3")은 굵어도 제목이 아니다
  if (CAPTION.test(l.text)) return false;
  if (l.size > body * 1.15) return true;
  // 작은 대문자(첫 글자만 크고 나머지는 본문 크기) — "1 INTRODUCTION". 대문자뿐이고 짧으면 제목
  if (l.text.length <= 60 && /[A-Z]{3}/.test(l.text) && !/[a-z]/.test(l.text) && /^(\d+(\.\d+)*\s+)?[A-Z]/.test(l.text)) return true;
  if (l.size >= body * 0.85 && isBoldLine(l) && l.text.length < 80 && !/[.,;:]$/.test(l.text)) return true;
  return false;
}

/** 쪽들을 Markdown 으로. 한 문서를 통째로 넘겨야 본문 크기와 머리말·꼬리말을 안다. */
export function toMarkdown(pages: PageForMd[]): string {
  return render(toBlocks(pages), hyphenatedWords(pages));
}

/** 쪽들을 덩이(제목·문단·목록·코드·표)로 가른다 — 쪽 번호·자리까지. JSON 으로 내는 쪽이 쓴다 */
export function toBlocks(pages: PageForMd[]): DocBlock[] {
  const body = bodySize(pages);
  const drop = runningLines(pages);
  const hyph = hyphenatedWords(pages);
  // 그림 글자는 쪽마다 미리 표시해 둔다 — 크기 순위에도 안 넣는다(그림 라벨 20pt 가 1위가 되어 제목이 밀린다)
  const figOf = new Map<PageForMd, Set<Line>>();
  for (const p of pages) { const f = new Set<Line>(); for (const l of p.lines) if (!drop.has(l) && inFigure(p, l)) f.add(l); figOf.set(p, f); }
  // 제목 크기 순위 — 본문보다 큰 크기들
  const sizes = new Map<number, number>();
  for (const p of pages) for (const l of p.lines) if (!drop.has(l) && !figOf.get(p)!.has(l) && Math.abs(l.angle) <= 0.1 && l.size > body * 1.15 && l.text.length <= 120) {
    const k = Math.round(l.size * 2) / 2; sizes.set(k, (sizes.get(k) ?? 0) + 1);
  }
  const ranks = [...sizes.keys()].sort((a, b) => b - a).slice(0, 3);

  const blocks: Block[] = [];
  pages.forEach((page, pi) => {
    const pno = page.page ?? pi + 1;
    const used = new Set<Line>(drop);
    const tables = tablesOf(page, used);
    const rotatedChars = page.lines.reduce((a, l) => a + (Math.abs(l.angle) > 0.1 ? l.text.length : 0), 0);
    const allChars = page.lines.reduce((a, l) => a + l.text.length, 0);
    const mostlyRotated = allChars > 0 && rotatedChars > allChars * 0.5;
    const fig = figOf.get(page)!;
    let para: string[] = [];
    let paraX = 0;
    let lastBottom = -1;
    let code: string[] = [];
    let codeX = 0;
    let list: string[] = [];
    // 덩이가 차지한 자리 — 줄 상자를 합친다
    let box: [number, number, number, number] | null = null;
    const grow = (l: Line) => {
      const b: [number, number, number, number] = [l.x, l.y - l.size, l.x + l.w, l.y + l.size * 0.25];
      box = box ? [Math.min(box[0], b[0]), Math.min(box[1], b[1]), Math.max(box[2], b[2]), Math.max(box[3], b[3])] : b;
    };
    const where = (): Where => { const w: Where = { page: pno, bbox: box ?? [0, 0, 0, 0] }; box = null; return w; };
    const endPara = () => { if (para.length) blocks.push({ kind: "para", text: joinLines(para, hyph), ...where() }); para = []; };
    const endCode = () => { if (code.length) blocks.push({ kind: "code", text: code.join("\n"), ...where() }); code = []; };
    const endList = () => { if (list.length) blocks.push({ kind: "list", items: list, ...where() }); list = []; };
    const endAll = () => { endPara(); endCode(); endList(); };
    let ti = 0;
    for (const l0 of page.lines) {
      if (drop.has(l0)) continue;
      // 옆으로 누운 줄(arXiv 스탬프·워터마크)은 본문이 아니다 — 쪽 대부분이 누웠으면 그 쪽이 가로 쪽인 것이라 둔다
      if (Math.abs(l0.angle) > 0.1 && !mostlyRotated) continue;
      // 각주 표시(작고 기호뿐인 조각 ∗ † ‡)는 뺀다 — "∗ ∗ Ashish" 가 아니라 "Ashish".
      // 숫자·글자 윗첨자는 joinPieces 가 ^ 로 붙인다.
      const mark = (p: { size: number; text: string }) => p.size < l0.size * 0.75 && !/[\p{L}\p{N}]/u.test(p.text);
      const small = l0.pieces.some(mark);
      const l: Line = small ? { ...l0, text: joinPieces(l0.pieces.filter((p) => !mark(p))) } : l0;
      if (!l.text) continue;
      // 이 줄보다 위에 있는 표를 먼저 낸다
      while (ti < tables.length && tables[ti].top <= l.y) { endAll(); blocks.push({ kind: "table", rows: tables[ti].rows, page: pno, bbox: tables[ti].bbox }); ti++; }
      if (used.has(l0)) continue;
      // 고정폭 글꼴은 코드 — 기호뿐인 줄("}")도 살리고 들여쓰기는 x 로 되살린다
      if (isMono(l)) {
        endPara(); endList();
        if (!code.length) codeX = l.x;
        // 문자열 앞 빈칸(줄 글에서는 잘린다) + x 차이로 들여쓰기
        const lead = (/^\s*/.exec(l0.pieces[0]?.text ?? "") ?? [""])[0].length;
        const indent = Math.max(lead, Math.round((l.x - codeX) / (l.size * 0.6)));
        code.push(" ".repeat(indent) + l.text);
        grow(l0);
        lastBottom = l.y + l.size;
        continue;
      }
      // 기호만 있는 줄(각주 표시 ∗ † 줄 등)은 버린다
      if (!/[\p{L}\p{N}]/u.test(l.text)) continue;
      // 그림 구역: 숫자·기호뿐인 짧은 줄(축 눈금)은 버리고, 라벨은 제목이 아니라 글로만 둔다
      const inFig = fig.has(l0);
      if (inFig && !/\p{L}/u.test(l.text)) continue;
      endCode();
      const symbolBullet = SYMBOL_BULLET.test(l.text) && l.text.length > 2;
      if (!symbolBullet && !inFig && isHeading(l, body) && !inBlock(page.lines, l0, drop)) {
        endAll();
        blocks.push({ kind: "heading", level: headingLevel(l, body, ranks) || 2, text: l.text, page: pno, bbox: [l.x, l.y - l.size, l.x + l.w, l.y + l.size * 0.25] });
        lastBottom = l.y + l.size;
        continue;
      }
      const bm = BULLET.exec(l.text);
      const gap = lastBottom < 0 ? 0 : l.y - lastBottom;
      if (bm && l.text.length > bm[0].length) {
        endPara();
        list.push(l.text.slice(bm[0].length).trim());
        grow(l0);
        lastBottom = l.y + l.size; paraX = l.x;
        continue;
      }
      if (list.length && gap < l.size * 0.9 && l.x > paraX + l.size * 0.5) {
        // 목록 항목의 이어지는 줄
        list[list.length - 1] += " " + l.text;
        grow(l0);
        lastBottom = l.y + l.size;
        continue;
      }
      endList();
      // 문단 나누기: 줄 간격이 벌어졌거나 들여쓰기가 새로 시작됐거나 단이 바뀌었을 때
      const newPara = para.length > 0 && (gap > l.size * 0.9 || l.x > paraX + l.size * 1.2 || l.x < paraX - l.size * 3);
      if (newPara) endPara();
      if (!para.length) paraX = l.x;
      para.push(l.text);
      grow(l0);
      lastBottom = l.y + l.size;
    }
    while (ti < tables.length) { endAll(); blocks.push({ kind: "table", rows: tables[ti].rows, page: pno, bbox: tables[ti].bbox }); ti++; }
    endAll();
  });
  // 같은 문단이 쪽을 넘어 갈라진 것을 잇는다: 앞 문단이 마침표 없이 끝나고 다음이 소문자로 시작.
  // 이은 덩이의 자리는 앞쪽 것이다.
  for (let i = 0; i + 1 < blocks.length; i++) {
    const a = blocks[i], b = blocks[i + 1];
    if (a.kind === "para" && b.kind === "para" && a.page !== b.page && !/[.!?:"”)\]]$/.test(a.text) && /^[a-z]/.test(b.text)) {
      a.text = joinLines([a.text, b.text], hyph);
      blocks.splice(i + 1, 1); i--;
    }
  }
  // 같은 단계·같은 크기의 제목이 촘촘히 이어지면 한 제목이 두 줄로 갈린 것
  // ("1. Introduction: The Case for Pragmatic" + "Research")
  for (let i = 0; i + 1 < blocks.length; i++) {
    const a = blocks[i], b = blocks[i + 1];
    if (a.kind === "heading" && b.kind === "heading" && b.level >= a.level && a.page === b.page &&
        !NUMBERED.test(b.text) && b.bbox[1] - a.bbox[3] < (a.bbox[3] - a.bbox[1]) * 0.6 && Math.abs(b.bbox[0] - a.bbox[0]) < 30) {
      a.text += " " + b.text; a.bbox = [Math.min(a.bbox[0], b.bbox[0]), a.bbox[1], Math.max(a.bbox[2], b.bbox[2]), b.bbox[3]];
      blocks.splice(i + 1, 1); i--;
    }
  }
  // 1쪽 제목과 첫 절(Abstract·Contents·"1 …") 사이의 짧은 제목 후보들은 저자·소속·날짜다 — 문단으로
  const first = blocks.findIndex((b) => b.page === blocks[0]?.page && b.kind === "heading" &&
    (/^(abstract|contents|introduction|keywords?)\b/i.test(b.text.trim()) || NUMBERED.test(b.text) || /^[IVX]+\.\s/.test(b.text)));
  const titleAt = blocks.findIndex((b) => b.kind === "heading");
  if (first > 1) {
    for (let i = titleAt + 1; i < first; i++) {
      const b = blocks[i];
      if (b.kind === "heading" && b.text.length <= 60 && !NUMBERED.test(b.text) && b.level >= 2) blocks[i] = { kind: "para", text: b.text, page: b.page, bbox: b.bbox };
    }
  }
  // 차례(목차): "Contents"·"차례" 제목 뒤 두 쪽 안의 제목 후보는 목차 항목이다.
  // 그 제목이 없어도 쪽 번호로 끝나는 제목 후보가 넷 이상 이어지면 목록이다
  const tocAt = blocks.findIndex((b) => b.kind === "heading" && /^(table of contents|contents|차\s*례|목\s*차)$/i.test(b.text.trim()));
  if (tocAt >= 0) {
    // 차례 쪽(과 이어지는 다음 쪽)의 제목 후보는 다 항목이다 — 긴 항목은 줄이 갈려 문단으로 왔다
    const tocPage = blocks[tocAt].page;
    const cont = blocks.some((b) => b.page === tocPage + 1 && b.kind === "heading" && /\s\d{1,4}$/.test(b.text));
    let j = tocAt + 1;
    while (j < blocks.length && (blocks[j].page === tocPage || (cont && blocks[j].page === tocPage + 1))) j++;
    if (j - tocAt > 2) {
      const items = blocks.slice(tocAt + 1, j).flatMap((b) => b.kind === "list" ? b.items : b.kind === "table" ? b.rows.map((r) => r.join(" ")) : [b.text]);
      const bb = blocks.slice(tocAt + 1, j).map((b) => b.bbox);
      blocks.splice(tocAt + 1, j - tocAt - 1, { kind: "list", items, page: tocPage, bbox: [Math.min(...bb.map((b) => b[0])), bb[0][1], Math.max(...bb.map((b) => b[2])), bb[bb.length - 1][3]] });
    }
  }
  for (let i = 0; i < blocks.length; i++) {
    let j = i;
    while (j < blocks.length && blocks[j].page === blocks[i].page) {
      const b = blocks[j];
      if (b.kind !== "heading" || !/\s\d{1,4}$/.test(b.text)) break;
      j++;
    }
    if (j - i >= 4) {
      const items = blocks.slice(i, j).map((b) => (b as { text: string }).text);
      const bb = blocks.slice(i, j).map((b) => b.bbox);
      blocks.splice(i, j - i, { kind: "list", items, page: blocks[i].page, bbox: [Math.min(...bb.map((b) => b[0])), bb[0][1], Math.max(...bb.map((b) => b[2])), bb[bb.length - 1][3]] });
    }
  }
  return blocks;
}

/**
 * 줄들을 한 문단으로. 줄 끝 "-" 는 다음 줄이 소문자면 잇는다.
 *
 * 하이픈이 낱말의 일부인지("position-wise")는 줄 끝만 봐서는 모른다.
 * 문서 안 줄 가운데에 하이픈 붙은 채 나온 낱말(hyphenated)이면 남기고, 뒤
 * 조각이 또 하이픈을 품으면("to-German") 사슬이라 남긴다. 나머지는 뗀다.
 */
function joinLines(ls: string[], hyphenated: Set<string> = new Set()): string {
  let s = "";
  for (const l of ls) {
    if (!s) { s = l; continue; }
    const m = /([a-zA-Z]+)-$/.exec(s);
    const n = /^([a-z]+(?:-[a-zA-Z]+)*)/.exec(l);
    if (m && n) {
      const keep = n[1].includes("-") || hyphenated.has((m[1] + "-" + n[1].split("-")[0]).toLowerCase());
      s = keep ? s + l : s.slice(0, -1) + l;
    } else s += " " + l;
  }
  return s;
}

/** 줄 가운데에 하이픈 붙은 채 나온 낱말들 — 줄 끝 하이픈을 뗄지 정하는 사전 */
function hyphenatedWords(pages: PageForMd[]): Set<string> {
  const out = new Set<string>();
  for (const p of pages) for (const l of p.lines) {
    for (const m of l.text.matchAll(/\b([a-zA-Z]+)-([a-zA-Z]+)\b(?!$)/g)) out.add(`${m[1]}-${m[2]}`.toLowerCase());
  }
  return out;
}

function esc(s: string): string { return s.replace(/\|/g, "\\|"); }

function render(blocks: Block[], _hyph: Set<string>): string {
  const out: string[] = [];
  for (const b of blocks) {
    switch (b.kind) {
      case "heading": out.push(`${"#".repeat(b.level)} ${b.text}`); break;
      // 문단 첫머리의 #·> 는 Markdown 문법으로 읽힌다("#x #y" 같은 수식) — 피한다
      case "para": out.push(b.text.replace(/^([#>])/, "\\$1")); break;
      case "list": out.push(b.items.map((t) => `- ${t}`).join("\n")); break;
      case "code": out.push("```\n" + b.text + "\n```"); break;
      case "table": {
        const n = Math.max(...b.rows.map((r) => r.length));
        const row = (r: string[]) => "| " + Array.from({ length: n }, (_, i) => esc(r[i] ?? "")).join(" | ") + " |";
        out.push([row(b.rows[0]), "|" + " --- |".repeat(n), ...b.rows.slice(1).map(row)].join("\n"));
        break;
      }
    }
  }
  return out.join("\n\n") + "\n";
}
