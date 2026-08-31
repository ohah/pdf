/**
 * 뷰포트 — 쪽 하나를 화면에 얹을 때 쓰는 자리 계산기.
 *
 * 캔버스는 /Rotate 와 배율만큼 돌려 그린다. 그 위에 주석·하이라이트·클릭
 * 위치를 얹으려면 같은 변환을 쓸 수 있어야 한다. 쓰는 쪽이 매번 다시
 * 짜지 않도록 여기서 내어 준다.
 *
 *   const vp = await pdf.viewport(1, { scale: 1.5 });
 *   const [x, y] = vp.toViewport(72, 720);   // PDF 좌표 → 화면 좌표(CSS px)
 *   const [px, py] = vp.toPdf(x, y);         // 되짚기
 *   Object.assign(box.style, vp.rect([100, 100, 200, 140]));
 */
import { placeRect, toScreen, type PageBox, type Placed } from "./place.js";

export type Viewport = {
  /** 화면에 놓일 크기(CSS px) — 회전을 반영한 값이다 */
  width: number;
  height: number;
  scale: number;
  /** 최종 회전각. 문서의 /Rotate 에 사용자 회전을 더한 값(0·90·180·270) */
  rotation: number;
  /** 쪽 크기(pt) */
  pageWidth: number;
  pageHeight: number;
  /** PDF 좌표 → 화면 좌표(CSS px) */
  toViewport(x: number, y: number): [number, number];
  /** 화면 좌표(CSS px) → PDF 좌표 */
  toPdf(x: number, y: number): [number, number];
  /** PDF 의 네모 → 얹을 자리(style 에 그대로 넣는다) */
  rect(r: [number, number, number, number]): Placed;
  /** 배율·회전만 바꾼 새 뷰포트 */
  clone(opts?: { scale?: number; rotation?: number }): Viewport;
};

export type ViewportInput = PageBox & { scale: number; rotation?: number };

/** 쪽 상자와 배율로 뷰포트를 만든다. rotation 은 문서 회전에 **더한다**. */
export function makeViewport(input: ViewportInput): Viewport {
  const scale = input.scale;
  const rot = norm(input.rot + (input.rotation ?? 0));
  const pg: PageBox = { w: input.w, h: input.h, x0: input.x0, y0: input.y0, rot };
  const swap = rot === 90 || rot === 270;
  return {
    width: (swap ? input.h : input.w) * scale,
    height: (swap ? input.w : input.h) * scale,
    scale,
    rotation: rot,
    pageWidth: input.w,
    pageHeight: input.h,
    toViewport: (x, y) => toScreen(x, y, pg, scale),
    toPdf: (x, y) => fromScreen(x, y, pg, scale),
    rect: (r) => placeRect(r, pg, scale),
    clone: (o = {}) =>
      makeViewport({
        ...input,
        // clone 의 rotation 은 문서 회전에 더할 값이라, 원래 준 값을 대신한다
        rotation: o.rotation ?? input.rotation ?? 0,
        scale: o.scale ?? scale,
      }),
  };
}

function norm(deg: number) {
  return ((Math.round(deg / 90) * 90) % 360 + 360) % 360;
}

/** toScreen 의 역함수. 화면에서 집은 점을 PDF 좌표로 되돌린다. */
function fromScreen(sx: number, sy: number, pg: PageBox, sc: number): [number, number] {
  const x = sx / sc;
  const y = sy / sc;
  const x1 = pg.x0 + pg.w;
  const y1 = pg.y0 + pg.h;
  const rot = ((pg.rot % 360) + 360) % 360;
  if (rot === 90) return [y + pg.x0, x + pg.y0];
  if (rot === 180) return [x1 - x, y + pg.y0];
  if (rot === 270) return [x1 - y, y1 - x];
  return [x + pg.x0, y1 - y];
}
