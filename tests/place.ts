// 돌아간 쪽에서도 얹는 것들이 제자리에 오나.
//
// 네 방향 모두, PDF 네모의 네 모서리를 옮긴 화면 상자가 캔버스가 그린
// 자리와 같아야 한다. 캔버스 변환(pdf-draw 의 setTransform)을 그대로
// 흉내 내어 맞대 본다.
import { placeRect, toScreen, type PageBox } from "../src/place";

let ok = 0;
const bad: string[] = [];
const t = (n: string, c: boolean, g?: unknown) => {
  if (c) ok++;
  else bad.push(`${n}${g !== undefined ? ` (${JSON.stringify(g)})` : ""}`);
};

/** 캔버스가 쓰는 변환 그대로 */
function canvasPoint(px: number, py: number, pg: PageBox, sc: number) {
  const x1 = pg.x0 + pg.w, y1 = pg.y0 + pg.h;
  const rot = ((pg.rot % 360) + 360) % 360;
  if (rot === 90) return [sc * (py - pg.y0), sc * (px - pg.x0)];
  if (rot === 180) return [sc * (x1 - px), sc * (py - pg.y0)];
  if (rot === 270) return [sc * (y1 - py), sc * (x1 - px)];
  return [sc * (px - pg.x0), sc * (y1 - py)];
}

/** 얹은 상자를 돌린 뒤 실제로 차지하는 화면 범위 */
function occupied(p: ReturnType<typeof placeRect>) {
  const rot = p.transform ? Number(/rotate\((-?\d+)deg\)/.exec(p.transform)![1]) : 0;
  const pts: [number, number][] = [[0, 0], [p.width, 0], [p.width, p.height], [0, p.height]];
  const rad = (rot * Math.PI) / 180;
  const cos = Math.round(Math.cos(rad)), sin = Math.round(Math.sin(rad));
  const xs: number[] = [], ys: number[] = [];
  for (const [a, b] of pts) {
    xs.push(p.left + a * cos - b * sin);
    ys.push(p.top + a * sin + b * cos);
  }
  return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
}

const rect: [number, number, number, number] = [50, 100, 170, 140];
for (const rot of [0, 90, 180, 270]) {
  const pg: PageBox = { w: 600, h: 800, x0: 10, y0: 20, rot };
  const sc = 0.5;
  const p = placeRect(rect, pg, sc);
  // 캔버스가 옮긴 네 모서리의 범위
  const cs = [
    canvasPoint(rect[0], rect[1], pg, sc), canvasPoint(rect[2], rect[1], pg, sc),
    canvasPoint(rect[2], rect[3], pg, sc), canvasPoint(rect[0], rect[3], pg, sc),
  ];
  const want = [
    Math.min(...cs.map((c) => c[0])), Math.min(...cs.map((c) => c[1])),
    Math.max(...cs.map((c) => c[0])), Math.max(...cs.map((c) => c[1])),
  ];
  const got = occupied(p);
  const near = want.every((v, i) => Math.abs(v - got[i]) < 0.01);
  t(`회전 ${rot}: 자리가 맞음`, near, { want, got });
  // 왼쪽 위 모서리는 옮긴 자리와 같아야 한다
  const tl = toScreen(rect[0], rect[3], pg, sc);
  t(`회전 ${rot}: 기준점`, Math.abs(p.left - tl[0]) < 0.01 && Math.abs(p.top - tl[1]) < 0.01,
    { left: p.left, top: p.top, tl });
  // 돌아간 쪽이면 화면에서 가로세로가 바뀐다
  const swap = rot === 90 || rot === 270;
  const w = got[2] - got[0], h = got[3] - got[1];
  t(`회전 ${rot}: 가로세로`, swap ? Math.abs(w - 40 * sc) < 0.01 : Math.abs(w - 120 * sc) < 0.01, { w, h });
}
console.log(`  자리 잡기 ${ok + bad.length}개 중 통과 ${ok}, 실패 ${bad.length}`);
for (const b of bad) console.log("   ✗", b);
