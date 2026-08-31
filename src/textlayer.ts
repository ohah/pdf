/**
 * 글자층 — 캔버스 위에 투명한 글자를 얹어 긁고 복사할 수 있게 한다.
 *
 * 캔버스에 그린 글자는 그림이라 긁히지 않는다. 뷰어들이 다 그렇듯 같은
 * 자리에 투명한 글자를 겹쳐 둔다. 두 가지가 까다로워 여기 담아 둔다.
 *
 *  - **폭 맞추기.** 얹는 글자는 시스템 글꼴로 놓이므로 PDF 가 좁게 그린 줄이
 *    훨씬 넓게 퍼진다. 그대로 두면 긁었을 때 파란 칠이 글자 너머 여백까지
 *    뻗는다. 재서 `scaleX` 로 눌러 맞춘다.
 *  - **줄바꿈.** 줄마다 감싼 상자에 `<br>` 을 넣어야 여러 줄을 복사할 때
 *    줄이 살아 있다. 높이 0 인 상자는 브라우저가 줄로 안 쳐서, 없으면 문서가
 *    한 줄로 쏟아진다(pdf.js 도 같은 방법을 쓴다).
 *
 *   const r = await pdf.render(1, canvas, { scale });
 *   renderTextLayer(layerDiv, r.runs);
 */
import { toLines, type TextRun } from "./draw.js";

export type TextLayerOpts = {
  /** 이미 줄로 묶은 것을 주면 그대로 쓴다. 없으면 toLines 로 묶는다. */
  lines?: TextRun[][];
  /** 글자를 재는 데 쓸 글꼴. 캔버스에 그린 것과 가까울수록 폭이 잘 맞는다. */
  fontFamily?: string;
  /** 만든 span 마다 부른다 — 검색 하이라이트 같은 것을 붙일 자리다. */
  onSpan?: (span: HTMLSpanElement, run: TextRun) => void;
};

export type TextLayer = {
  /** 만든 글자 span 들. 순서는 읽는 차례다. */
  spans: HTMLSpanElement[];
  /** 층을 비운다 */
  destroy(): void;
};

let ruler: CanvasRenderingContext2D | null = null;

/** 시스템 글꼴로 놓았을 때의 글자 폭. scaleX 를 정하는 데 쓴다. */
function measure(text: string, px: number, family: string) {
  if (!ruler) ruler = document.createElement("canvas").getContext("2d");
  if (!ruler) return 0;
  ruler.font = `${Math.max(px, 0.01)}px ${family}`;
  return ruler.measureText(text).width;
}

/**
 * 글자층을 짓는다. container 는 캔버스와 같은 자리·크기에 놓고
 * `position: relative`(또는 absolute) 여야 한다.
 */
export function renderTextLayer(
  container: HTMLElement,
  runs: TextRun[],
  opts: TextLayerOpts = {},
): TextLayer {
  const family = opts.fontFamily ?? "system-ui, sans-serif";
  const lines = opts.lines ?? toLines(runs);
  container.textContent = "";
  const spans: HTMLSpanElement[] = [];

  for (const line of lines) {
    // 줄 하나를 감싸는 상자. 높이를 0 으로 두어 마우스를 가로채지 않게 하되
    // 폭은 남긴다 — 폭까지 0 이면 브라우저가 줄로 치지 않는다.
    const row = document.createElement("div");
    row.style.cssText = "position:absolute;left:0;top:0;width:100%;height:0;pointer-events:none";
    for (const r of line) {
      const s = document.createElement("span");
      const t: string[] = [];
      if (Math.abs(r.angle) > 0.001) t.push(`rotate(${r.angle}rad)`);
      const m = measure(r.text, r.h, family);
      if (m > 0 && r.w > 0) {
        const k = Math.min(20, Math.max(0.05, r.w / m));
        if (k > 1.02 || k < 0.98) t.push(`scaleX(${k})`);
      }
      s.textContent = r.text;
      s.style.cssText =
        `position:absolute;left:${r.x}px;top:${r.y - r.h * 0.82}px;height:${r.h * 1.15}px;` +
        `font-size:${r.h}px;font-family:${family};line-height:1;white-space:pre;` +
        `color:transparent;transform-origin:0 0;cursor:text;pointer-events:auto`;
      if (t.length) s.style.transform = t.join(" ");
      opts.onSpan?.(s, r);
      row.appendChild(s);
      spans.push(s);
    }
    // 복사할 때 줄바꿈이 함께 붙게 한다
    row.appendChild(document.createElement("br"));
    container.appendChild(row);
  }

  return {
    spans,
    destroy() {
      container.textContent = "";
      spans.length = 0;
    },
  };
}
