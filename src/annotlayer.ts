/**
 * 주석 층 — 쪽 위에 주석을 얹는다.
 *
 * 그림은 `render()` 가 이미 그린다(문서가 들고 있는 `/AP` 겉모습대로). 이
 * 층이 하는 일은 **다룰 수 있게** 만드는 것이다 — 링크를 누르고, 형광펜에
 * 마우스를 올려 남긴 글을 보고, 메모 자리를 짚는 것.
 *
 * pdf.js 의 AnnotationLayer 와 같은 자리인데, 스타일시트를 따로 불러오지
 * 않아도 되게 자리 잡기는 인라인 style 로 넣는다. 꾸미고 싶으면
 * `[data-annot]` 로 골라 쓰면 된다.
 *
 *   const r = await pdf.render(1, canvas, { scale });
 *   renderAnnotationLayer(layer, await pdf.annotations(1), r.viewport, {
 *     onGoto: (page) => scrollTo(page),
 *   });
 */
import type { PageMsg } from "./client.js";
import type { Viewport } from "./viewport.js";
import { safeUrl } from "./index.js";

export type Annot = PageMsg["annots"][number];

export type AnnotLayerOpts = {
  /** 문서 안 다른 쪽으로 가는 링크를 눌렀을 때. 없으면 그 링크는 안 만든다. */
  onGoto?: (page: number) => void;
  /** 링크를 어디에 열지. 기본은 새 창(`_blank`) */
  target?: string;
  /** 입력 칸(Widget)도 얹을지. 기본은 아니다 — 대개 진짜 입력 칸을 따로 얹는다 */
  includeWidgets?: boolean;
  /** 만든 요소마다 부른다 — 색을 입히거나 클릭을 붙일 자리다 */
  onElement?: (el: HTMLElement, annot: Annot) => void;
};

export type AnnotLayer = {
  /** 만든 요소들. 주석과 같은 차례다 */
  elements: HTMLElement[];
  destroy(): void;
};

/** 숨김(2)·보기 금지(32) 깃발 */
const HIDDEN = 2;
const NOVIEW = 32;

/**
 * 주석 층을 짓는다. container 는 캔버스와 같은 자리·크기에 놓고
 * `position: relative`(또는 absolute) 여야 한다.
 */
export function renderAnnotationLayer(
  container: HTMLElement,
  annots: Annot[],
  viewport: Viewport,
  opts: AnnotLayerOpts = {},
): AnnotLayer {
  container.textContent = "";
  const elements: HTMLElement[] = [];

  for (const a of annots) {
    if ((a.flags & HIDDEN) !== 0 || (a.flags & NOVIEW) !== 0) continue;
    if (a.subtype === "Popup") continue; // 딸린 창은 부모 주석이 대신 보여 준다
    if (a.subtype === "Widget" && !opts.includeWidgets) continue;

    const box = viewport.rect(a.rect);
    const href = a.subtype === "Link" ? safeUrl(linkUri(a)) : null;
    // 링크는 <a>, 문서 안 이동은 <button>, 나머지는 손댈 수 있는 빈 상자다.
    const el: HTMLElement = href
      ? document.createElement("a")
      : a.subtype === "Link" && (a.page ?? -1) >= 0 && opts.onGoto
        ? document.createElement("button")
        : document.createElement("div");

    if (el instanceof HTMLAnchorElement && href) {
      el.href = href;
      el.target = opts.target ?? "_blank";
      el.rel = "noreferrer noopener";
    }
    if (el instanceof HTMLButtonElement) {
      el.type = "button";
      el.addEventListener("click", () => opts.onGoto?.((a.page ?? 0) + 1));
    }

    el.dataset.annot = a.subtype || "Unknown";
    el.dataset.obj = String(a.obj);
    // 남긴 글은 브라우저 기본 툴팁으로 — 스타일시트 없이도 읽힌다
    const tip = [a.contents, a.author ? `— ${a.author}` : ""].filter(Boolean).join("\n");
    if (tip) el.title = tip;

    Object.assign(el.style, {
      position: "absolute",
      left: `${box.left}px`,
      top: `${box.top}px`,
      width: `${box.width}px`,
      height: `${box.height}px`,
      transformOrigin: box.transformOrigin,
      transform: box.transform ?? "",
      // 그림은 캔버스가 그렸다. 여기서는 자리만 잡고 마우스를 받는다.
      background: "transparent",
      border: "none",
      padding: "0",
      cursor: href || el instanceof HTMLButtonElement ? "pointer" : tip ? "help" : "default",
      pointerEvents: href || el instanceof HTMLButtonElement || tip ? "auto" : "none",
    } as Partial<CSSStyleDeclaration>);

    opts.onElement?.(el, a);
    container.appendChild(el);
    elements.push(el);
  }

  return {
    elements,
    destroy() {
      container.textContent = "";
      elements.length = 0;
    },
  };
}

/** 링크 주석이 가리키는 주소. 엔진이 링크만 따로 걷어 둔 것과 짝이 맞는다. */
function linkUri(a: Annot): string {
  return (a as Annot & { uri?: string }).uri ?? "";
}
