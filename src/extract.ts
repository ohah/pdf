// 글자 조각을 사람이 읽는 글로 잇는다.
//
// 엔진은 문자열(Tj) 단위로 조각을 준다 — 자리(x, y)·길이(w)·크기·글꼴.
// 조각 사이는 띄어쓰기일 수도, 자간 조정(TJ)으로 갈라진 한 낱말일 수도
// 있다. 예전 text() 는 조각을 무조건 빈칸으로 이어 "Pro vided" 가 됐다.
// pdf.js 처럼 앞 조각의 끝과 다음 조각의 시작 사이 틈을 재서 가른다.
//
// 줄과 읽는 차례는 draw.ts 의 toLines 가 한다(단 → 띠 → 줄).
import { toLines, type TextRun } from "./draw.js";

export type Piece = {
  x: number; y: number; size: number; w: number; text: string; font: string;
  dir: "ltr" | "rtl" | "ttb";
};

/** 한 줄 — 조각들과 이어 붙인 글 */
export type Line = {
  text: string;
  /** 줄의 자리(pt, 위가 0). 제목·문단 가르기에 쓴다 */
  x: number; y: number; w: number;
  /** 줄에서 가장 흔한 글자 크기와 글꼴 */
  size: number; font: string;
  pieces: Piece[];
};

/**
 * 조각 둘 사이가 띄어쓰기인가.
 *
 * 틈이 글자 크기의 일부(0.12)보다 넓으면 빈칸이다. pdf.js 의 기준과 같은
 * 자리(spacing 어림)다. 앞 조각과 겹치거나(음수) 훨씬 뒤에 있으면 다른
 * 덩이라 빈칸을 둔다.
 */
function spaced(prev: Piece, next: Piece): boolean {
  const end = prev.x + prev.w;
  const gap = next.x - end;
  const size = Math.max(1, Math.min(prev.size, next.size));
  if (gap > 0.12 * size) return true;
  if (gap < -0.5 * size) return true;
  // 앞 조각이 빈칸으로 끝나거나 다음이 빈칸으로 시작하면 이미 띄어 있다
  return /\s$/.test(prev.text) || /^\s/.test(next.text);
}

/** 조각들을 줄로 묶어 글로 잇는다. pageH 는 쪽 높이(pt) — y 를 위 기준으로 뒤집는다 */
export function linesOf(pieces: Piece[], pageH: number): Line[] {
  const runs: TextRun[] = pieces.map((p) => ({
    x: p.x, y: pageH - p.y, w: p.w > 0 ? p.w : p.size * 0.5 * p.text.length, h: p.size,
    text: p.text, angle: p.dir === "ttb" ? Math.PI / 2 : 0,
  }));
  const byRun = new Map<TextRun, Piece>();
  runs.forEach((r, i) => byRun.set(r, pieces[i]));
  const out: Line[] = [];
  for (const L of toLines(runs)) {
    const ps = L.map((r) => byRun.get(r)!);
    let text = "";
    for (let i = 0; i < ps.length; i++) {
      if (i > 0 && spaced(ps[i - 1], ps[i]) && !/\s$/.test(text)) text += " ";
      text += ps[i].text;
    }
    text = text.replace(/\s+/g, " ").trim();
    if (!text) continue;
    // 가장 흔한 크기·글꼴
    const count = new Map<string, number>();
    for (const p of ps) { const k = `${Math.round(p.size * 10)}|${p.font}`; count.set(k, (count.get(k) ?? 0) + p.text.length); }
    const [best] = [...count.entries()].sort((a, b) => b[1] - a[1])[0];
    const [sz, font] = best.split("|");
    const x0 = Math.min(...L.map((r) => r.x));
    const x1 = Math.max(...L.map((r) => r.x + r.w));
    out.push({
      text, x: x0, y: Math.min(...L.map((r) => r.y)), w: x1 - x0,
      size: Number(sz) / 10, font, pieces: ps,
    });
  }
  return out;
}

/** 쪽의 글 — 줄마다 한 줄 */
export function textOf(pieces: Piece[], pageH: number): string {
  return linesOf(pieces, pageH).map((l) => l.text).join("\n");
}
