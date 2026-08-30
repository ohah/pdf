/**
 * PDF 의 입력 칸(AcroForm).
 *
 * 양식은 쪽의 /Annots 에 /Subtype /Widget 으로 얹혀 있다. 각 칸은 자리와
 * 갈래와 값을 들고 있고, 겉모습(/AP /N)은 그 값을 그려 둔 그림이다.
 * 화면에서는 그 그림 대신 진짜 입력 칸을 얹는다 — 그래야 채울 수 있다.
 */
export type Field = {
  /** 위젯 객체 번호. 값을 다시 써 넣을 때 이걸로 찾는다. */
  obj: number;
  page: number;
  /** PDF 좌표 [x0 y0 x1 y1] */
  rect: [number, number, number, number];
  /** 0 글상자 · 1 확인란 · 2 라디오 · 3 목록 */
  kind: number;
  flags: number;
  maxLen: number;
  size: number;
  align: number;
  name: string;
  value: string;
  /** 확인란이 켜졌을 때의 상태 이름 (/AP /N 의 열쇠) */
  on: string;
  checked: boolean;
  options: string[];
};

export const MULTILINE = 1 << 12;
export const PASSWORD = 1 << 13;
export const READONLY = 1;
export const COMB = 1 << 24;

type FieldEx = {
  memory: WebAssembly.Memory;
  fieldCount?: () => number;
  fieldObj?: (i: number) => number;
  fieldRect?: (i: number, k: number) => number;
  fieldKind?: (i: number) => number;
  fieldFlags?: (i: number) => number;
  fieldMaxLen?: (i: number) => number;
  fieldSize?: (i: number) => number;
  fieldAlign?: (i: number) => number;
  fieldChecked?: (i: number) => number;
  fieldTextPtr?: () => number;
  fieldNameOff?: (i: number) => number;
  fieldNameLen?: (i: number) => number;
  fieldValOff?: (i: number) => number;
  fieldValLen?: (i: number) => number;
  fieldOnOff?: (i: number) => number;
  fieldOnLen?: (i: number) => number;
  fieldOptsOff?: (i: number) => number;
  fieldOptsLen?: (i: number) => number;
};

/** 방금 그린 쪽의 입력 칸을 꺼낸다. renderPage 바로 뒤에 부른다. */
export function readFields(ex: FieldEx, page: number): Field[] {
  if (!ex.fieldCount) return [];
  const n = ex.fieldCount();
  if (n === 0) return [];
  const dec = new TextDecoder();
  const base = ex.fieldTextPtr!();
  const str = (off: number, len: number) =>
    len > 0 ? dec.decode(new Uint8Array(ex.memory.buffer, base + off, len)) : "";
  const out: Field[] = [];
  for (let i = 0; i < n; i++) {
    const opts = str(ex.fieldOptsOff!(i), ex.fieldOptsLen!(i));
    out.push({
      obj: ex.fieldObj!(i),
      page,
      rect: [ex.fieldRect!(i, 0), ex.fieldRect!(i, 1), ex.fieldRect!(i, 2), ex.fieldRect!(i, 3)],
      kind: ex.fieldKind!(i),
      flags: ex.fieldFlags!(i),
      maxLen: ex.fieldMaxLen!(i),
      size: ex.fieldSize!(i),
      align: ex.fieldAlign!(i),
      name: str(ex.fieldNameOff!(i), ex.fieldNameLen!(i)),
      value: str(ex.fieldValOff!(i), ex.fieldValLen!(i)),
      on: str(ex.fieldOnOff!(i), ex.fieldOnLen!(i)) || "Yes",
      checked: ex.fieldChecked!(i) === 1,
      options: opts ? opts.split("\n").filter((v) => v.length > 0) : [],
    });
  }
  return out;
}

/**
 * 표준 글꼴에 없는 글자가 섞였는가.
 *
 * 겉모습은 Helvetica 로 그리므로 라틴-1 밖 글자는 나오지 않는다. 그럴 때는
 * 화면 글꼴로 그린 그림을 대신 심는다.
 */
export function needsImage(v: string): boolean {
  for (const ch of v) if ((ch.codePointAt(0) ?? 0) > 0xff) return true;
  return false;
}

/**
 * 칸 하나를 화면 글꼴로 그려 1비트 마스크로 만든다.
 *
 * PDF 의 ImageMask 는 값이 0 인 자리를 지금 색으로 칠한다. 글자가 있는
 * 자리를 0 으로 둔다. 해상도는 인쇄에도 견디게 네 배로 잡되, 너무 큰 칸은
 * 배율을 낮춰 파일이 부풀지 않게 한다.
 */
export function renderFieldMask(
  f: Field, value: string, multiline: boolean,
): { w: number; h: number; bits: Uint8Array } | null {
  const bw = f.rect[2] - f.rect[0];
  const bh = f.rect[3] - f.rect[1];
  if (bw < 1 || bh < 1) return null;
  let scale = 4;
  while (bw * scale * bh * scale > 4_000_000 && scale > 1) scale -= 1;
  const w = Math.max(1, Math.round(bw * scale));
  const h = Math.max(1, Math.round(bh * scale));
  const cv = document.createElement("canvas");
  cv.width = w;
  cv.height = h;
  const g = cv.getContext("2d", { willReadFrequently: true });
  if (!g) return null;
  g.fillStyle = "#fff";
  g.fillRect(0, 0, w, h);
  const size = (f.size > 0 ? f.size : multiline ? 10 : Math.min(12, Math.max(6, bh * 0.62))) * scale;
  g.fillStyle = "#000";
  g.font = `${size}px system-ui, -apple-system, "Apple SD Gothic Neo", "Malgun Gothic", sans-serif`;
  g.textBaseline = "alphabetic";
  g.textAlign = (["left", "center", "right"] as const)[f.align] ?? "left";
  const x = f.align === 1 ? w / 2 : f.align === 2 ? w - 2 * scale : 2 * scale;
  const lead = size * 1.16;
  const lines = multiline ? value.split(/\r?\n/) : [value.replace(/[\r\n]+/g, " ")];
  let y = multiline ? lead : (h + size * 0.72) / 2;
  for (const ln of lines) {
    if (y > h + lead) break;
    g.fillText(ln, x, y);
    y += lead;
  }
  // 1비트로 줄인다 — 글자가 있는 자리가 0
  const im = g.getImageData(0, 0, w, h).data;
  const stride = (w + 7) >> 3;
  const bits = new Uint8Array(stride * h).fill(0xff);
  for (let yy = 0; yy < h; yy++) {
    for (let xx = 0; xx < w; xx++) {
      // 회색 절반보다 어두우면 잉크로 본다
      if (im[(yy * w + xx) * 4] < 128) bits[yy * stride + (xx >> 3)] &= ~(0x80 >> (xx & 7));
    }
  }
  return { w, h, bits };
}
