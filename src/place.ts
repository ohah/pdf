/**
 * 얹는 것들의 자리 잡기.
 *
 * 캔버스가 /Rotate 만큼 돌려 그리므로 링크·입력 칸처럼 위에 얹는 것도
 * 같이 돌아야 한다. 식은 pdf-draw 의 setTransform 과 같은 것이다.
 */
export type PageBox = { w: number; h: number; x0: number; y0: number; rot: number };
export type Placed = {
  position: "absolute";
  left: number;
  top: number;
  width: number;
  height: number;
  transformOrigin: string;
  transform: string | undefined;
};

/**
 * PDF 좌표 한 점을 화면 좌표로 옮긴다.
 *
 * 캔버스가 /Rotate 만큼 돌려 그리므로 얹는 것들도 같이 돌아야 한다.
 * 식은 pdf-draw 의 setTransform 과 같은 것이다.
 */
export function toScreen(px: number, py: number, pg: PageBox, sc: number): [number, number] {
  const x1 = pg.x0 + pg.w;
  const y1 = pg.y0 + pg.h;
  const rot = ((pg.rot % 360) + 360) % 360;
  if (rot === 90) return [(py - pg.y0) * sc, (px - pg.x0) * sc];
  if (rot === 180) return [(x1 - px) * sc, (py - pg.y0) * sc];
  if (rot === 270) return [(y1 - py) * sc, (x1 - px) * sc];
  return [(px - pg.x0) * sc, (y1 - py) * sc];
}

/**
 * PDF 의 네모 하나를 화면에 얹을 자리와 돌림각으로 바꾼다.
 *
 * 왼쪽 위 모서리를 옮긴 자리에 원래 크기 그대로 두고 쪽만큼 돌린다.
 * 그러면 돌아간 쪽에서도 칸이 글자와 같은 쪽을 본다.
 */
export function placeRect(
  r: [number, number, number, number], pg: PageBox, sc: number,
): Placed {
  const [ax, ay] = toScreen(r[0], r[3], pg, sc);
  const rot = ((pg.rot % 360) + 360) % 360;
  return {
    position: "absolute",
    left: ax,
    top: ay,
    width: Math.max((r[2] - r[0]) * sc, 6),
    height: Math.max((r[3] - r[1]) * sc, 6),
    transformOrigin: "0 0",
    transform: rot ? `rotate(${rot}deg)` : undefined,
  };
}

