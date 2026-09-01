// wasm 이 낸 그리기 명령을 캔버스에 실행한다.
//
// PDF.js 의 CanvasGraphics 와 같은 자리다. 좌표 변환을 미리 곱해 넘기지 않고
// 캔버스의 transform 에 그대로 태우는 것이 요점 — 그래야 선 굵기·클리핑·글자
// 크기가 변환을 함께 받아 원본과 어긋나지 않는다.

export const OP = {
  MOVE: 1, LINE: 2, CURVE: 3, CLOSE: 4, RECT: 5,
  FILL: 6, STROKE: 7, FILLSTROKE: 8, ENDPATH: 9, CLIP: 10,
  FILLCOLOR: 11, STROKECOLOR: 12, LINEWIDTH: 13,
  SAVE: 14, RESTORE: 15, TRANSFORM: 16, TEXT: 17, IMAGE: 18, TEXTCLIP: 29,
  SMASK_BEGIN: 30, SMASK_END: 31, SMASK_OFF: 32,
  GROUP_BEGIN: 33, GROUP_END: 34,
  LINECAP: 19, LINEJOIN: 20, ALPHA: 21, INLINE: 22, SALPHA: 23, DASH: 24,
  MITER: 25, BLEND: 26, SHFILL: 27, SHCOLOR: 28,
} as const;

const BLENDS = [
  "source-over", "multiply", "screen", "overlay", "darken", "lighten",
  "color-dodge", "color-burn", "hard-light", "soft-light", "difference",
  "exclusion", "hue", "saturation", "color", "luminosity",
] as const;

/** 셰이딩 명령에서 캔버스 그라데이션을 만든다. */
function gradientFrom(g: CanvasRenderingContext2D, ops: Float32Array, a: number) {
  const kind = ops[a];
  const c = [ops[a + 1], ops[a + 2], ops[a + 3], ops[a + 4], ops[a + 5], ops[a + 6]];
  const n = Math.max(0, Math.min(8, ops[a + 9]));
  let grad: CanvasGradient;
  try {
    grad = kind === 2
      ? g.createLinearGradient(c[0], c[1], c[2], c[3])
      : g.createRadialGradient(c[0], c[1], Math.max(0, c[2]), c[3], c[4], Math.max(0, c[5]));
  } catch { return null; }
  for (let k = 0; k < n; k++) {
    const t = Math.min(1, Math.max(0, ops[a + 10 + k * 4]));
    try {
      grad.addColorStop(t, rgb(ops[a + 11 + k * 4], ops[a + 12 + k * 4], ops[a + 13 + k * 4]));
    } catch {
      // 마디가 겹치면 건너뛴다
    }
  }
  return grad;
}

const CAPS = ["butt", "round", "square"] as const;
const JOINS = ["miter", "round", "bevel"] as const;

/** 화면에 얹을 글자 한 토막. 좌표는 캔버스 CSS 화소다. */
export type TextRun = {
  x: number; y: number; w: number; h: number; text: string; angle: number;
};

export type DrawInput = {
  ops: Float32Array;
  text: Uint8Array;
  /** 글자층에 얹을, 사람이 읽는 글자. 없으면 text 를 그대로 쓴다. */
  read?: Uint8Array;
  pageW: number;
  pageH: number;
  /** MediaBox 의 왼쪽 아래 모서리 */
  originX?: number;
  originY?: number;
  /** /Rotate — 0·90·180·270 */
  rotate?: number;
  /** 바탕색. 기본은 흰색이다 — 투명하게 두려면 "transparent" 를 준다. */
  background?: string;
  bitmap?: ImageBitmap;
  /** 쪽이 쓰는 그림들. Do 가 번호로 고른다. */
  bitmaps?: (ImageBitmap | undefined)[];
  /** 글꼴 번호 → CSS font-family. 없으면 시스템 글꼴로 그린다. */
  fontFamily?: (idx: number) => string | undefined;
  /** 글꼴 번호 → 글리프를 번호로 집는 글꼴인가.
   *  그런 글꼴은 문서 글꼴을 못 실으면 그리지 않는다 — 시스템 글꼴로
   *  대신 그려 봐야 뜻 없는 네모만 나온다. */
  fontIsPua?: (idx: number) => boolean;
  /** 콘텐츠에 바로 박힌 그림의 바이트 */
  inline?: Uint8Array;
  /** 스텐실 그림(1비트 마스크). 지금 채우기 색으로 칠한다. */
  stencils?: (Stencil | undefined)[];
  /** 글꼴 번호 → 문서에 글꼴 파일이 박혀 있는데 우리가 못 실었는가 */
  fontUnusable?: (idx: number) => boolean;
};

// 인라인 그림은 글리프 하나인 경우가 많아 같은 것이 수백 번 나온다.
// 만든 캔버스를 내용과 색으로 캐시한다.
const inlineCache = new Map<string, HTMLCanvasElement>();

/**
 * 인라인 그림 곳간마다 붙이는 딱지.
 *
 * 캐시 열쇠에 자리(off)와 길이만 넣었더니, 엔진이 쪽마다 그 곳간을 처음부터
 * 다시 쓰기 때문에 2쪽의 첫 그림이 1쪽 것과 길이만 같으면 1쪽 그림이
 * 나왔다. Type3 비트맵 글꼴은 크기가 같아 길이도 같으니 거의 반드시 겹친다.
 * 곳간(버퍼)마다 딴 딱지를 달아 섞이지 않게 한다.
 */
const inlineTags = new WeakMap<Uint8Array, string>();
let inlineSeq = 0;
function tagOf(buf: Uint8Array): string {
    let t = inlineTags.get(buf);
    if (!t) {
      t = `b${inlineSeq++}:`;
      inlineTags.set(buf, t);
    }
    return t;
}

/** 1비트 스텐실 그림 — 색이 그릴 때 정해지므로 미리 만들어 둘 수 없다. */
export type Stencil = { w: number; h: number; flip: boolean; bytes: Uint8Array; key: string };

/** 1비트 마스크나 8비트 그림을 작은 캔버스로 만든다. */
function inlineCanvas(
  src: Uint8Array, off: number, len: number,
  w: number, h: number, bpc: number, isMask: boolean, flip: boolean,
  comps: number, color: string, tag?: string,
  /** 여벌 판을 만들 본보기. Node 에는 document 가 없어 이것이 있어야 만든다 */
  like?: { constructor: unknown } | null,
  /** 화면에 놓일 크기(화소). 원본이 그보다 크면 줄여 만든다 */
  fitW = 0, fitH = 0,
): HTMLCanvasElement | null {
  // 스캔본은 5188x6930(3600만 화소) 같은 그림을 담고 있다. 그걸 원본
  // 해상도로 펼치면 RGBA 로만 137MB 이고, 캔버스 뒷면까지 치면 그 두 배다 —
  // 화면에는 595pt 폭으로 그리면서. 놓일 크기에 맞춰 줄여 만든다.
  const outW = Math.max(1, Math.min(w, fitW > 0 ? Math.ceil(fitW) : w));
  const outH = Math.max(1, Math.min(h, fitH > 0 ? Math.ceil(fitH) : h));
  const key = `${tag ?? ""}${off}:${len}:${outW}x${outH}:${isMask ? color : ""}`;
  const hit = inlineCache.get(key);
  if (hit) return hit;
  if (off + len > src.length) return null;
  const cv = scratch(outW, outH, like ?? null) as HTMLCanvasElement | null;
  if (!cv) return null;
  const c = cv.getContext("2d");
  if (!c) return null;
  const img = c.createImageData(outW, outH);
  const row = Math.ceil((w * bpc * comps) / 8);
  let r = 0, g2 = 0, b2 = 0;
  if (isMask) {
    // rgb(r,g,b) 와 #rrggbb 를 다 받는다
    const m = /rgb\((\d+),\s*(\d+),\s*(\d+)\)/i.exec(color);
    if (m) { r = +m[1]; g2 = +m[2]; b2 = +m[3]; }
    else {
      const h = /^#([0-9a-f]{6})$/i.exec(color);
      if (h) { const v = parseInt(h[1], 16); r = (v >> 16) & 255; g2 = (v >> 8) & 255; b2 = v & 255; }
    }
  }
  const shrink = outW !== w || outH !== h;
  for (let oy = 0; oy < outH; oy++) {
    const y = outH === h ? oy : Math.min(h - 1, Math.floor((oy * h) / outH));
    // 줄일 때 이 출력 화소가 덮는 원본 칸
    const y1 = shrink ? Math.min(h, Math.max(y + 1, Math.ceil(((oy + 1) * h) / outH))) : y + 1;
    for (let ox = 0; ox < outW; ox++) {
      const x = outW === w ? ox : Math.min(w - 1, Math.floor((ox * w) / outW));
      const x1 = shrink ? Math.min(w, Math.max(x + 1, Math.ceil(((ox + 1) * w) / outW))) : x + 1;
      const d = (oy * outW + ox) * 4;
      if (bpc === 1) {
        // 1비트 마스크를 줄일 때는 덮는 칸에서 켜진 비율을 진하기로 삼는다.
        // 한 점만 집으면 스캔본의 가는 획이 사라지고, 하나라도 켜졌으면
        // 켜는 식이면 글자가 뭉개져 새까매진다.
        let lit = 0;
        let seen = 0;
        for (let sy = y; sy < y1; sy++) {
          for (let sx = x; sx < x1; sx++) {
            const bt = src[off + sy * row + (sx >> 3)];
            const b1 = (bt >> (7 - (sx & 7))) & 1;
            if (flip ? b1 === 1 : b1 === 0) lit += 1;
            seen += 1;
          }
        }
        const cover = seen > 0 ? lit / seen : 0;
        const on = cover > 0;
        if (isMask) {
          img.data[d] = r; img.data[d + 1] = g2; img.data[d + 2] = b2;
          img.data[d + 3] = Math.round(cover * 255);
        } else {
          const v = Math.round(255 * (1 - cover));
          img.data[d] = img.data[d + 1] = img.data[d + 2] = v;
          img.data[d + 3] = 255;
        }
        void on;
      } else {
        const s2 = off + y * row + x * comps;
        if (comps >= 3) {
          img.data[d] = src[s2]; img.data[d + 1] = src[s2 + 1]; img.data[d + 2] = src[s2 + 2];
        } else {
          img.data[d] = img.data[d + 1] = img.data[d + 2] = src[s2];
        }
        img.data[d + 3] = 255;
      }
    }
  }
  c.putImageData(img, 0, 0);
  if (inlineCache.size > 4000) inlineCache.clear();
  inlineCache.set(key, cv);
  return cv;
}

/**
 * 명령 목록을 캔버스에 그린다. 캔버스 크기는 미리 맞춰 둔다.
 *
 * 그리면서 글자가 놓인 자리를 모아 돌려준다. 그 위에 투명한 글자층을 얹으면
 * 뷰어에서 긁어 복사할 수 있다 — PDF.js 가 하는 그 방식이다.
 */
/**
 * 여벌 판을 하나 만든다.
 *
 * 투명 무리·오려 내기·소프트 마스크·인라인 그림은 딴 판에 그렸다가 얹는다.
 * 브라우저에서는 document 로 만들면 되지만 워커에는 document 가 없고 Node
 * 에는 둘 다 없다. 있는 것부터 차례로 써 보고, 마지막에는 넘겨받은 판과
 * 같은 것을 하나 더 만든다(node-canvas 처럼 생성자가 (폭, 높이)인 것).
 */
function scratch(
  w: number, h: number, like: { constructor: unknown } | null,
): { width: number; height: number; getContext: (k: "2d") => unknown } | null {
  const W = Math.max(1, Math.round(w));
  const H = Math.max(1, Math.round(h));
  try {
    if (typeof document !== "undefined" && document.createElement) {
      const c = document.createElement("canvas");
      c.width = W;
      c.height = H;
      return c;
    }
  } catch { /* 아래로 */ }
  try {
    if (typeof OffscreenCanvas === "function") {
      return new OffscreenCanvas(W, H) as unknown as {
        width: number; height: number; getContext: (k: "2d") => unknown;
      };
    }
  } catch { /* 아래로 */ }
  try {
    const Ctor = like?.constructor as (new (w: number, h: number) => {
      width: number; height: number; getContext: (k: "2d") => unknown;
    }) | undefined;
    if (Ctor) return new Ctor(W, H);
  } catch { /* 없다 */ }
  return null;
}

export function drawOps(canvas: HTMLCanvasElement, input: DrawInput): TextRun[] {
  const runs: TextRun[] = [];
  const g0 = canvas.getContext("2d");
  // 판을 못 얻는 일이 실제로 있다 — 그 캔버스가 이미 webgl 로 잡혀 있거나,
  // 메모리가 모자랄 때다. 조용히 빈 손으로 돌아오면 "그렸는데 아무것도
  // 안 보인다" 가 되므로 무슨 일인지 말해 준다.
  if (!g0) throw new Error("could not get a 2d context from the canvas");
  // 글자 오려 내기가 걸리면 그리는 판이 바뀐다
  let g: CanvasRenderingContext2D = g0;
  const { ops, text, pageW, pageH } = input;
  const rot = ((input.rotate ?? 0) % 360 + 360) % 360;
  const swap = rot === 90 || rot === 270;
  const scale = canvas.width / (swap ? pageH : pageW);
  const dec = new TextDecoder();
  const x0 = input.originX ?? 0;
  const y0 = input.originY ?? 0;

  g.setTransform(1, 0, 0, 1, 0, 0);
  const bg = input.background ?? "#fff";
  g.clearRect(0, 0, canvas.width, canvas.height);
  if (bg !== "transparent") {
    g.fillStyle = bg;
    g.fillRect(0, 0, canvas.width, canvas.height);
  }

  // PDF 는 좌하단이 원점이고 y 가 위로 자란다. 캔버스는 반대라 뒤집고,
  // /Rotate 가 있으면 그만큼 돌린다 — 뷰어들이 쓰는 그 변환이다.
  const x1 = x0 + pageW;
  const y1 = y0 + pageH;
  if (rot === 90) g.setTransform(0, scale, scale, 0, -y0 * scale, -x0 * scale);
  else if (rot === 180) g.setTransform(-scale, 0, 0, scale, x1 * scale, -y0 * scale);
  else if (rot === 270) g.setTransform(0, -scale, -scale, 0, y1 * scale, x1 * scale);
  else g.setTransform(scale, 0, 0, -scale, -x0 * scale, y1 * scale);
  g.fillStyle = "#000";
  g.strokeStyle = "#000";
  g.lineWidth = 1;

  let i = 0;
  let depth = 0;
  // 마스크 그림은 지금 채우기 색으로 칠한다
  let fillCss = "#000000";
  const fillStack: string[] = [];
  // 글자층에 쓸 자리 모으기
  // 화면 배율. node-canvas 처럼 style 이 없는 판도 있으므로 없으면 1 로 본다.
  const shown = parseFloat((canvas as { style?: { width: string } }).style?.width ?? "");
  const dpr = canvas.width / (shown || canvas.width);
  // 오려 내기가 걸리면 그리는 곳이 바뀐다
  let run: (TextRun & { endX: number }) | null = null;
  const flush = () => {
    if (run && run.text.trim()) runs.push({
      x: run.x, y: run.y, w: Math.max(run.endX - run.x, 1), h: run.h,
      text: run.text, angle: run.angle,
    });
    run = null;
  };
  // 글자 모양으로 오려 내기 (Tr 4~7).
  //
  // 캔버스에는 "글자를 오려 내기 경로에 더한다" 가 없다. 글꼴 파일이 있어도
  // 글리프 외곽선을 얻을 길이 없기 때문이다. 그래서 PDF.js 와 같은 길을
  // 간다 — 글자를 딴 판에 하얗게 찍어 가리개로 삼고, 그 뒤 그림은 또 다른
  // 판에 그렸다가 가리개로 오려 원판에 얹는다.
  let maskG: CanvasRenderingContext2D | null = null;
  /** 투명 그룹을 그리는 딴 판 */
  type GroupLayer = {
    layer: CanvasRenderingContext2D; parent: CanvasRenderingContext2D;
    alpha: number; bm: number; depth: number;
  };
  const groups: GroupLayer[] = [];
  type ClipLayer = { mask: CanvasRenderingContext2D; layer: CanvasRenderingContext2D;
    parent: CanvasRenderingContext2D; depth: number };
  const clips: ClipLayer[] = [];
  const like = () => {
    const c = scratch(canvas.width, canvas.height, canvas);
    return c ? c.getContext("2d") as CanvasRenderingContext2D | null : null;
  };
  /**
   * 새 판에 지금 그리기 상태를 옮긴다.
   *
   * 딴 판(투명 그룹·가리개·글자 오려 내기)은 갓 만든 캔버스라 색이 검정,
   * 선 굵기 1, 점선 없음에서 시작한다. PDF 의 폼 XObject 는 부르는 쪽 상태를
   * 그대로 물려받아야 하므로, 옮기지 않으면 `1 0 0 rg` 로 칠해 둔 빨강이
   * 그룹 안에서 검정으로 나온다. 알파와 혼합 모드는 그룹을 겹칠 때 한 번에
   * 먹이므로 여기서 옮기지 않는다(두 번 먹으면 더 진해진다).
   */
  const carry = (from: CanvasRenderingContext2D, to: CanvasRenderingContext2D) => {
    to.fillStyle = from.fillStyle;
    to.strokeStyle = from.strokeStyle;
    to.lineWidth = from.lineWidth;
    to.lineCap = from.lineCap;
    to.lineJoin = from.lineJoin;
    to.miterLimit = from.miterLimit;
    to.font = from.font;
    try {
      to.setLineDash(from.getLineDash());
      to.lineDashOffset = from.lineDashOffset;
    } catch {
      // 점선을 못 옮겨도 그리는 것은 이어 간다
    }
  };
  const maskCtx = () => {
    if (!maskG) {
      const c = like();
      if (!c) return null;
      c.fillStyle = "#fff";
      maskG = c;
    }
    return maskG;
  };
  /** 모은 글자 모양으로 층을 오려 원판에 얹는다. */
  const closeClip = () => {
    const top = clips.pop();
    if (!top) return;
    top.layer.save();
    top.layer.setTransform(1, 0, 0, 1, 0, 0);
    top.layer.globalCompositeOperation = "destination-in";
    top.layer.drawImage(top.mask.canvas, 0, 0);
    top.layer.restore();
    top.parent.save();
    top.parent.setTransform(1, 0, 0, 1, 0, 0);
    top.parent.drawImage(top.layer.canvas, 0, 0);
    top.parent.restore();
    g = top.parent;
    maskG = null;
  };

  // 부드러운 가리개(/SMask) — 가리개 그림을 그리는 동안 쓰는 자리
  let smask: { ctx: CanvasRenderingContext2D; lum: boolean; parent: CanvasRenderingContext2D;
    tf: DOMMatrix } | null = null;

  const guard = ops.length + 16;
  let steps = 0;

  while (i + 1 < ops.length && steps++ < guard) {
    const code = ops[i];
    const argc = ops[i + 1];
    const a = i + 2;
    i = a + argc;

    switch (code) {
      case OP.SAVE: g.save(); fillStack.push(fillCss); depth++; break;
      case OP.RESTORE:
        // 층(가리개·글자 오려 내기)을 먼저 얹고 부모로 돌아간 다음에 되돌린다.
        // 순서를 바꾸면 층에는 save 가 없어 restore 가 헛돌고, 부모의 q 는
        // 영영 안 닫혀 그 뒤 내용까지 오려진 채 남는다.
        while (clips.length > 0 && clips[clips.length - 1].depth >= depth) closeClip();
        if (depth > 0) { g.restore(); fillCss = fillStack.pop() ?? "#000000"; depth--; }
        break;
      case OP.SMASK_BEGIN: {
        // 가리개 그림을 딴 판에 그린다. 밝기로 가리는 것이면 바탕색을
        // 먼저 깔아야 한다 — 아무것도 안 그린 자리는 그 색의 밝기가 된다.
        const c = like();
        if (!c) break;
        const lum = ops[a] !== 0;
        if (lum) {
          c.fillStyle = rgb(ops[a + 1], ops[a + 2], ops[a + 3]);
          c.fillRect(0, 0, canvas.width, canvas.height);
        }
        c.setTransform(g.getTransform());
        smask = { ctx: c, lum, parent: g, tf: g.getTransform() };
        g = c;
        break;
      }
      case OP.SMASK_END: {
        if (!smask) break;
        const { ctx, lum, parent } = smask;
        smask = null;
        g = parent;
        // 밝기(또는 불투명도)를 알파로 옮긴다 — destination-in 이 알파만 본다
        try {
          const im = ctx.getImageData(0, 0, canvas.width, canvas.height);
          const d = im.data;
          for (let k = 0; k < d.length; k += 4) {
            const v = lum
              ? ((d[k] * 77 + d[k + 1] * 151 + d[k + 2] * 28) >> 8) * (d[k + 3] / 255)
              : d[k + 3];
            d[k] = 255; d[k + 1] = 255; d[k + 2] = 255; d[k + 3] = v;
          }
          ctx.putImageData(im, 0, 0);
        } catch { break; }
        const layer = like();
        if (!layer) break;
        layer.setTransform(g.getTransform());
        carry(g, layer);
        clips.push({ mask: ctx, layer, parent: g, depth });
        g = layer;
        break;
      }
      case OP.GROUP_BEGIN: {
        // 투명 그룹 — 통째로 딴 판에 그렸다가 한 번에 겹친다.
        // 낱낱이 겹치면 겹친 데가 두 번 칠해져 더 진해진다.
        const c = like();
        if (!c) break;
        c.setTransform(g.getTransform());
        carry(g, c);
        groups.push({ layer: c, parent: g, alpha: ops[a], bm: ops[a + 1] | 0, depth });
        g = c;
        break;
      }
      case OP.GROUP_END: {
        const top = groups.pop();
        if (!top) break;
        g = top.parent;
        g.save();
        g.setTransform(1, 0, 0, 1, 0, 0);
        g.globalAlpha = top.alpha;
        g.globalCompositeOperation = (BLENDS[top.bm] ?? "source-over") as GlobalCompositeOperation;
        g.drawImage(top.layer.canvas, 0, 0);
        g.restore();
        break;
      }
      case OP.SMASK_OFF:
        // /SMask /None — 오려 내던 것을 여기서 얹고 끝낸다
        if (clips.length > 0 && clips[clips.length - 1].depth === depth) closeClip();
        break;
      case OP.TEXTCLIP: {
        // 글자 묶음이 끝났다. 모아 둔 글자 모양을 가리개로 삼고, 이제부터는
        // 딴 판에 그린다. 이 판은 q 가 닫힐 때 오려서 얹는다.
        const m = maskG;
        if (!m) break;
        const layer = like();
        if (!layer) { maskG = null; break; }
        layer.setTransform(g.getTransform());
        clips.push({ mask: m, layer, parent: g, depth });
        g = layer;
        maskG = null;
        break;
      }
      case OP.TRANSFORM:
        g.transform(ops[a], ops[a + 1], ops[a + 2], ops[a + 3], ops[a + 4], ops[a + 5]);
        break;
      case OP.MOVE: g.beginPath === undefined ? null : null; g.moveTo(ops[a], ops[a + 1]); break;
      case OP.LINE: g.lineTo(ops[a], ops[a + 1]); break;
      case OP.CURVE:
        g.bezierCurveTo(ops[a], ops[a + 1], ops[a + 2], ops[a + 3], ops[a + 4], ops[a + 5]);
        break;
      case OP.CLOSE: g.closePath(); break;
      case OP.RECT: g.rect(ops[a], ops[a + 1], ops[a + 2], ops[a + 3]); break;
      case OP.FILL:
        g.fill(ops[a] ? "evenodd" : "nonzero");
        g.beginPath();
        break;
      case OP.STROKE: g.stroke(); g.beginPath(); break;
      case OP.FILLSTROKE:
        g.fill(ops[a] ? "evenodd" : "nonzero");
        g.stroke();
        g.beginPath();
        break;
      case OP.ENDPATH: g.beginPath(); break;
      case OP.CLIP:
        g.clip(ops[a] ? "evenodd" : "nonzero");
        g.beginPath();
        break;
      case OP.FILLCOLOR:
        fillCss = rgb(ops[a], ops[a + 1], ops[a + 2]);
        g.fillStyle = fillCss;
        break;
      case OP.STROKECOLOR:
        g.strokeStyle = rgb(ops[a], ops[a + 1], ops[a + 2]);
        break;
      case OP.LINEWIDTH: g.lineWidth = Math.max(ops[a], 0.1); break;
      case OP.LINECAP: g.lineCap = CAPS[Math.min(Math.max(ops[a] | 0, 0), 2)]; break;
      case OP.ALPHA:
        g.globalAlpha = Math.max(0, Math.min(1, ops[a]));
        break;
      case OP.SALPHA:
        // 캔버스는 채우기와 획의 투명도를 따로 두지 못한다. 획 쪽을 따른다.
        g.globalAlpha = Math.max(0, Math.min(1, ops[a]));
        break;
      case OP.DASH: {
        const n = Math.max(0, Math.min(6, ops[a]));
        const arr: number[] = [];
        for (let k = 0; k < n; k++) arr.push(Math.max(0, ops[a + 1 + k]));
        g.setLineDash(arr.some((v) => v > 0) ? arr : []);
        g.lineDashOffset = ops[a + 7] || 0;
        break;
      }
      case OP.BLEND: {
        const k = Math.round(ops[a]);
        g.globalCompositeOperation = (BLENDS[k] ?? "source-over") as GlobalCompositeOperation;
        break;
      }
      case OP.SHFILL: {
        // 지금 자르기 영역을 그라데이션으로 채운다
        const grad = gradientFrom(g, ops, a);
        if (grad) {
          g.save();
          g.fillStyle = grad;
          g.fillRect(-100000, -100000, 200000, 200000);
          g.restore();
        }
        break;
      }
      case OP.SHCOLOR: {
        const grad = gradientFrom(g, ops, a);
        if (grad) { g.fillStyle = grad; fillCss = "rgb(128,128,128)"; }
        break;
      }
      case OP.MITER:
        g.miterLimit = Math.max(1, ops[a]);
        break;
      case OP.LINEJOIN: g.lineJoin = JOINS[Math.min(Math.max(ops[a] | 0, 0), 2)]; break;
      case OP.TEXT: {
        const x = ops[a], y = ops[a + 1], size = ops[a + 2];
        const off = ops[a + 3], len = ops[a + 4], fontIdx = ops[a + 5];
        const ta = ops[a + 6], tb = ops[a + 7], tc = ops[a + 8], td = ops[a + 9];
        const adv = argc > 10 ? ops[a + 10] : 0;
        const mode = argc > 11 ? ops[a + 11] : 0;
        if (len <= 0) break;
        const str = dec.decode(text.subarray(off, off + len));
        // 그리는 글자와 긁는 글자는 다르다. 번호로 집는 글꼴은 사용자 영역
        // 으로 찍어야 그려지지만, 그대로 글자층에 얹으면 붙여넣기가 깨진다.
        const roff = argc > 12 ? ops[a + 12] : off;
        const rlen = argc > 13 ? ops[a + 13] : len;
        const rd = input.read ?? text;
        const shown = rlen > 0 ? dec.decode(rd.subarray(roff, roff + rlen)) : str;
        const emb = input.fontFamily?.(fontIdx);
        // 번호로 집는 글꼴인데 그 글꼴을 못 실었으면, 번호를 그대로 찍어도
        // 아무것도 안 나온다(대체 글꼴에는 그 자리에 글리프가 없다). 예전에는
        // 그럴 때 아예 안 그려서 쪽이 통째로 비었다 — 실제로 name·OS/2 가
        // 빠진 글꼴을 쓴 문서가 백지로 나왔다. PDF.js 처럼 되찾은 글자를
        // 시스템 글꼴로라도 그린다. 모양은 달라도 빈 종이보다는 낫다.
        const lost = !emb && input.fontIsPua?.(fontIdx) === true;
        const paintStr = lost ? shown : str;
        g.save();
        // 텍스트 행렬을 태우고, 글자만 다시 뒤집는다(페이지를 뒤집어 뒀으므로).
        g.transform(ta, tb, tc, td, x, y);
        g.transform(1, 0, 0, -1, 0, 0);
        // 부분집합 글꼴에 없는 글자는 시스템 글꼴로 넘어가게 뒤를 받쳐 둔다.
        const fam = emb ? `"${emb}", system-ui, sans-serif` : "system-ui, sans-serif";
        g.font = `${Math.max(size, 0.01)}px ${fam}`;
        // 대신 그린 글꼴이 제 칸보다 넓으면 가로로 눌러 넣는다.
        // 이렇게 해야 글꼴이 바뀌어도 글자가 서로 겹치지 않는다.
        if (adv > 0) {
          const m = g.measureText(paintStr).width;
          // 글꼴이 아예 안 박힌 문서는 대신 그리는 것이 정상이다. 뷰어들이
          // 다 그렇게 하고, 폭만 맞춰 눌러 넣는다.
          //
          // 문서가 글꼴 파일을 박아 두었는데 우리가 그 형식을 못 읽은 경우는
          // 다르다. 그 자리는 "이 글리프를 그려라"라고 못 박은 자리다.
          // 바코드가 그렇다 — 폭이 글자의 몇 분의 일이라, 대신 그리면 원본과
          // 전혀 다른 그림이 겹쳐 찍힌다. 그럴 때만 비워 둔다.
          if (m > adv * 3 && input.fontUnusable?.(fontIdx)) { g.restore(); break; }
          // 묶음 전체를 제 폭에 맞춘다. 좁으면 늘리기도 한다 — 안 그러면
          // 대신 그린 글꼴에서 좁은 글자마다 틈이 벌어져 "Pri ncess Dai sy"
          // 처럼 보인다.
          if (m > 0) {
            const k = Math.min(4, Math.max(0.25, adv / m));
            if (k > 1.02 || k < 0.98) g.scale(k, 1);
          }
        }
        // Tr 4~7 은 글자 모양으로 오려 낸다. 딴 판에 하얗게 찍어 둔다 —
        // 뒤에 오는 그림을 이 모양으로 오려 낼 가리개다.
        if (mode >= 4) {
          const mk = maskCtx();
          if (mk) {
            mk.save();
            mk.setTransform(g.getTransform());
            mk.font = g.font;
            mk.fillStyle = "#fff";
            mk.fillText(paintStr, 0, 0);
            mk.restore();
          }
        }
        // Tr 1·5 는 획으로만, 2·6 은 채우고 획까지
        if (mode === 1 || mode === 5) g.strokeText(paintStr, 0, 0);
        else {
          // 빈칸도 글자층에는 넣는다 — 안 넣으면 낱말이 다 붙어 검색이 안 된다
        if (!str.trim()) {
          if (run) {
            run.text += str;
            const m3 = g.getTransform();
            run.endX = m3.e / dpr + (adv > 0 ? adv : size * 0.3) * Math.hypot(m3.a, m3.b) / dpr;
          }
          g.restore();
          break;
        }
        // 글자층에 쓸 자리를 잰다 (캔버스 변환을 그대로 반영한다)
        {
          const m2 = g.getTransform();
          const px = m2.e / dpr;
          const py = m2.f / dpr;
          const hh = Math.hypot(m2.b, m2.d) * size / dpr;
          const ang = Math.atan2(m2.b, m2.a);
          const adv2 = (adv > 0 ? adv : size * 0.5) * Math.hypot(m2.a, m2.b) / dpr;
          if (run && Math.abs(run.y - py) < 0.6 && Math.abs(run.endX - px) < hh * 0.9
              && Math.abs(run.angle - ang) < 0.01) {
            // PDF 에는 빈칸 글자가 없는 경우가 많다. 낱말 사이를 자리로만
            // 벌려 놓는다. 그대로 이으면 복사했을 때 "위사람은본교를" 이
            // 된다. 글자 사이 틈이 눈에 띄게 벌어지면 빈칸을 넣는다.
            const gap = px - run.endX;
            if (gap > hh * 0.2 && !/\s$/.test(run.text) && !/^\s/.test(shown)) run.text += " ";
            run.text += shown;
            run.endX = px + adv2;
          } else {
            flush();
            run = { x: px, y: py, w: 0, h: hh, text: shown, angle: ang, endX: px + adv2 };
          }
        }
        // Tr 3 은 안 보이는 글자다. 스캔 문서 위에 얹힌 OCR 결과가 대개
        // 이것이라 그리면 그림 위에 글자가 겹친다. 그래도 글자층에는
        // 넣었으므로 긁어 복사하고 찾을 수 있다.
        // Tr 7 은 오려 내기 전용이라 역시 그리지 않는다.
        if (mode !== 3 && mode !== 7) {
          g.fillText(paintStr, 0, 0);
          if (mode === 2 || mode === 6) g.strokeText(paintStr, 0, 0);
        }
        }
        g.restore();
        break;
      }
      case OP.INLINE: {
        const src = input.inline;
        if (!src) break;
        const w = ops[a], h = ops[a + 1], bpc = ops[a + 2], isMask = ops[a + 3] === 1;
        const off = ops[a + 4], len = ops[a + 5], flip = ops[a + 6] === 1;
        const comps = argc > 7 ? ops[a + 7] : 1;
        // 지금 변환에서 단위 사각형이 화면에 차지할 크기
        const mm = g.getTransform();
        const onW = Math.hypot(mm.a, mm.b);
        const onH = Math.hypot(mm.c, mm.d);
        const cv = inlineCanvas(src, off, len, w, h, bpc, isMask, flip, comps, fillCss,
          `${tagOf(src)}${w}x${h}x${bpc}x${comps}:`, canvas, onW, onH);
        if (!cv) break;
        g.save();
        g.imageSmoothingEnabled = false;
        // 그림 공간은 단위 사각형이고 위아래가 뒤집혀 있다
        g.transform(1, 0, 0, -1, 0, 1);
        g.drawImage(cv, 0, 0, 1, 1);
        g.restore();
        break;
      }
      case OP.IMAGE: {
        const slot = argc > 0 ? ops[a] : 0;
        const st2 = slot > 0 ? input.stencils?.[slot - 1] : undefined;
        if (st2) {
          const mm = g.getTransform();
          const cv = inlineCanvas(st2.bytes, 0, st2.bytes.length, st2.w, st2.h, 1, true, st2.flip, 1,
            fillCss, st2.key, canvas, Math.hypot(mm.a, mm.b), Math.hypot(mm.c, mm.d));
          if (cv) {
            g.save();
            g.imageSmoothingEnabled = false;
            g.transform(1, 0, 0, -1, 0, 1);
            g.drawImage(cv, 0, 0, 1, 1);
            g.restore();
          }
          break;
        }
        const pick = slot > 0 ? input.bitmaps?.[slot - 1] : undefined;
        if (pick) {
          g.save();
          g.transform(1, 0, 0, -1, 0, 1);
          g.drawImage(pick, 0, 0, 1, 1);
          g.restore();
          break;
        }
        if (!input.bitmap) break;
        // 그림은 현재 변환의 단위 정사각형에 놓인다. 위아래를 뒤집어 맞춘다.
        g.save();
        g.transform(1, 0, 0, -1, 0, 1);
        g.drawImage(input.bitmap, 0, 0, 1, 1);
        g.restore();
        break;
      }
      default: break;
    }
  }
  // 닫지 않고 끝난 문서도 있다. 층이 열린 채 끝나면 그 판에 그린 것이
  // 통째로 사라지므로(g 가 보이지 않는 캔버스를 가리킨 채 끝난다) 여기서
  // 그룹·가리개·오려 내기를 모두 마저 얹는다.
  if (smask) {
    g = smask.parent;
    smask = null;
  }
  while (groups.length > 0) {
    const top = groups.pop()!;
    g = top.parent;
    g.save();
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.globalAlpha = top.alpha;
    g.globalCompositeOperation = (BLENDS[top.bm] ?? "source-over") as GlobalCompositeOperation;
    g.drawImage(top.layer.canvas, 0, 0);
    g.restore();
  }
  while (clips.length > 0) closeClip();
  // 짝이 안 맞는 q 가 남아 있어도 상태를 되돌린다
  while (depth-- > 0) g.restore();
  g.setTransform(1, 0, 0, 1, 0, 0);
  flush();
  return runs;
}

function rgb(r: number, g: number, b: number) {
  const c = (v: number) => Math.round(Math.min(Math.max(v, 0), 1) * 255);
  return `rgb(${c(r)},${c(g)},${c(b)})`;
}

/**
 * 글자 토막을 읽는 차례대로 줄로 묶는다.
 *
 * 그린 차례는 대개 읽는 차례지만 늘 그렇지는 않다. 표나 두 단짜리 편집은
 * 뒤죽박죽 나온다. 줄로 묶어 위에서 아래로 세워 두면 긁어 복사한 결과가
 * 눈에 보이는 대로 나온다. 줄마다 따로 담아 두면 복사할 때 줄바꿈도 함께
 * 붙는다 — 한 덩어리로 두면 문서 전체가 한 줄로 붙어 나온다.
 *
 * 기울어진 글자는 따로 묶는다. 도장이나 세로쓰기가 본문 줄에 끼면 순서가
 * 되레 망가진다.
 */
/** 가운데값. 몇 개 안 되는 목록이라 그냥 정렬해 집는다. */
function mid(v: number[]) {
  if (v.length === 0) return 0;
  const s = [...v].sort((a, b) => a - b);
  return s[s.length >> 1];
}

/** 한 묶음을 줄로 나눈다. 기울기가 같은 것만 들어온다. */
function linesOf(list: TextRun[], ang: number): TextRun[][] {
  const cos = Math.cos(ang);
  const sin = Math.sin(ang);
  // 글자가 나아가는 쪽과 그 옆 — 기울어져 있어도 줄을 알아볼 수 있다
  const along = (r: TextRun) => r.x * cos + r.y * sin;
  const across = (r: TextRun) => -r.x * sin + r.y * cos;
  const sorted = [...list].sort((p, q) => across(p) - across(q) || along(p) - along(q));
  const out: TextRun[][] = [];
  let line: TextRun[] = [];
  let base = 0;
  for (const r of sorted) {
    const v = across(r);
    if (line.length > 0 && Math.abs(v - base) > Math.max(r.h, 1) * 0.5) {
      out.push(line);
      line = [];
    }
    if (line.length === 0) base = v;
    line.push(r);
  }
  if (line.length > 0) out.push(line);
  return out;
}

/**
 * 단으로 나눈다. 세로로 뻥 뚫린 빈 띠를 찾는다.
 *
 * 아무 글자도 걸치지 않는 띠여야 하고, 양쪽이 저마다 여러 줄에 걸쳐 있어야
 * 한다. 제목 한 줄이 "차례 ..... 3" 처럼 가운데가 비어 있다고 단으로 보면
 * 안 되기 때문이다.
 */
function byColumn(runs: TextRun[]): TextRun[][] | null {
  if (runs.length < 6) return null;
  const iv = runs.map((r) => [r.x, r.x + Math.max(r.w, 1)] as [number, number])
    .sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const v of iv) {
    const last = merged[merged.length - 1];
    if (last && v[0] <= last[1]) last[1] = Math.max(last[1], v[1]);
    else merged.push([v[0], v[1]]);
  }
  if (merged.length < 2) return null;
  const extent = merged[merged.length - 1][1] - merged[0][0];
  const h = mid(runs.map((r) => r.h));
  const least = Math.max(h * 1.5, extent * 0.025);
  // 띠마다 잘라 보고, 양쪽이 단이라 할 만한지 본다
  const edges: number[] = [];
  for (let i = 1; i < merged.length; i++) {
    if (merged[i][0] - merged[i - 1][1] >= least) edges.push((merged[i][0] + merged[i - 1][1]) / 2);
  }
  if (edges.length === 0) return null;
  const groups: TextRun[][] = Array.from({ length: edges.length + 1 }, () => []);
  for (const r of runs) {
    let k = 0;
    while (k < edges.length && r.x + r.w / 2 > edges[k]) k += 1;
    groups[k].push(r);
  }
  // 한쪽이 몇 줄 안 되면 단이 아니라 그냥 벌어진 한 줄이다
  const okGroup = (g: TextRun[]) => {
    if (g.length < 3) return false;
    const ys = [...new Set(g.map((r) => Math.round(r.y / Math.max(r.h, 1))))];
    return ys.length >= 2;
  };
  if (!groups.every(okGroup)) return null;
  return groups;
}

/**
 * 문단·블록으로 나눈다. 가로로 뻥 뚫린 빈 띠를 찾는다.
 *
 * 줄 간격의 두 배쯤 벌어진 데를 자른다. 보통 줄바꿈은 안 잘린다.
 */
function byBand(runs: TextRun[], ang: number): TextRun[][] | null {
  const lines = linesOf(runs, ang);
  if (lines.length < 3) return null;
  const ys = lines.map((l) => l[0].y);
  const gaps: number[] = [];
  for (let i = 1; i < ys.length; i++) gaps.push(ys[i] - ys[i - 1]);
  const pitch = mid(gaps);
  const h = mid(runs.map((r) => r.h));
  const least = Math.max(pitch * 1.8, h * 1.5);
  const out: TextRun[][] = [];
  let cur: TextRun[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (i > 0 && ys[i] - ys[i - 1] > least && cur.length > 0) {
      out.push(cur);
      cur = [];
    }
    cur.push(...lines[i]);
  }
  if (cur.length > 0) out.push(cur);
  return out.length > 1 ? out : null;
}

/**
 * 읽는 차례로 세운다 (XY 컷).
 *
 * 예전에는 y 로만 줄을 묶었다. 두 단 문서에서 왼쪽 첫 줄과 오른쪽 첫 줄이
 * 같은 높이라 한 줄로 붙어, 긁어 복사하면 "왼1오른1왼2오른2…" 가 됐다.
 * 단을 먼저 가르고, 그 안에서 문단을 가르고, 그 안에서 줄을 묶는다.
 */
function order(runs: TextRun[], ang: number, depth: number): TextRun[][] {
  if (runs.length < 4 || depth > 4) return linesOf(runs, ang);
  const cols = byColumn(runs);
  if (cols) return cols.flatMap((c) => order(c, ang, depth + 1));
  const bands = byBand(runs, ang);
  if (bands) return bands.flatMap((b) => order(b, ang, depth + 1));
  return linesOf(runs, ang);
}

export function toLines(runs: TextRun[]): TextRun[][] {
  const byAngle = new Map<number, TextRun[]>();
  for (const r of runs) {
    const k = Math.round(r.angle * 100) / 100;
    const got = byAngle.get(k);
    if (got) got.push(r);
    else byAngle.set(k, [r]);
  }
  // 똑바른 글자를 먼저, 기운 것(도장·워터마크)은 뒤에 붙인다.
  // 섞어서 y 로 줄 세우면 본문 사이에 도장 글자가 끼어든다.
  const keys = [...byAngle.keys()].sort((a, b) => Math.abs(a) - Math.abs(b));
  const out: TextRun[][] = [];
  for (const k of keys) out.push(...order(byAngle.get(k)!, k, 0));
  return out;
}
