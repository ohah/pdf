// JBIG2 허프만 판의 빈 자리를 메우는 시험 파일.
//
// 부록 H 의 시험 흐름에는 없는 세 가지를 여기서 만든다.
//
//   · 문서가 제 허프만 표를 실어 오는 꼴 (세그먼트 53)
//   · 허프만 사전에서 세밀화로 글자를 만드는 꼴 (SDHUFF=1, SDREFAGG=1)
//   · 허프만 글자 영역에서 글자를 다듬는 꼴 (SBHUFF=1, SBREFINE=1)
//
// 셋 다 "새 길로 담은 것" 과 "옛 길로 담은 것" 을 짝지어 낸다. 같은 그림이
// 나와야 하므로, 틀이 한 비트라도 어긋나면 짝이 갈린다.
//
// 부호기는 jbig2enc.mjs 에 있다.
import { doc, pageInfo, symDictRaw, symDictRefine, tableDef, tableSeg, textRegion } from './jbig2enc.mjs';

const S = process.argv[2];

// ===== 그림 =====
const REF = [
  [0, 1, 1, 1, 1, 1, 1, 0],
  [1, 0, 0, 0, 0, 0, 0, 1],
  [1, 0, 1, 1, 1, 1, 0, 1],
  [1, 0, 1, 0, 0, 1, 0, 1],
  [1, 0, 1, 0, 0, 1, 0, 1],
  [1, 0, 1, 1, 1, 1, 0, 1],
  [1, 0, 0, 0, 0, 0, 0, 1],
  [0, 1, 1, 1, 1, 1, 1, 0],
];
// 몇 칸만 다른 그림 — 세밀화로 만들어 낼 목표
const TGT = REF.map((r) => r.slice());
TGT[0][0] = 1; TGT[3][3] = 1; TGT[4][4] = 1; TGT[7][7] = 1;

const W = 24, H = 8;
const places2 = [{ id: 0, x: 0 }, { id: 1, ds: 3 }];

// ── 1. 문서가 실어 온 표 vs 규격 표
{
  const std = Buffer.concat([
    pageInfo(0, W, H),
    symDictRaw(1, [REF, TGT]),
    textRegion(2, [1], 2, places2, W, H, false),
  ]);
  doc(S, 'jbh-std.pdf', std, W, H);

  // 같은 값을 담을 수 있는 표를 문서가 직접 싣는다
  const dhDef = tableDef(0, 16, 4, [1, 2, 3], false);
  const dwDef = tableDef(-4, 12, 4, [1, 3, 4, 2], true);
  const tab = Buffer.concat([
    pageInfo(0, W, H),
    tableSeg(1, 0, 16, 4, [1, 2, 3], false),
    tableSeg(2, -4, 12, 4, [1, 3, 4, 2], true),
    symDictRaw(3, [REF, TGT], { dh: dhDef, dw: dwDef, refs: [1, 2] }),
    textRegion(4, [3], 2, places2, W, H, false),
  ]);
  doc(S, 'jbh-tab.pdf', tab, W, H);
}

// ── 2. 허프만 사전에서 세밀화로 글자 만들기
{
  const made = Buffer.concat([
    pageInfo(0, W, H),
    symDictRaw(1, [REF]),
    symDictRefine(2, 1, 1, TGT, REF),
    textRegion(3, [1, 2], 2, places2, W, H, false),
  ]);
  doc(S, 'jbh-refagg.pdf', made, W, H);
  // 같은 두 글자를 날것으로 담은 것
  doc(S, 'jbh-refagg-base.pdf', Buffer.concat([
    pageInfo(0, W, H),
    symDictRaw(1, [REF, TGT]),
    textRegion(2, [1], 2, places2, W, H, false),
  ]), W, H);
}

// ── 3. 허프만 글자 영역에서 다듬기
{
  const tref = Buffer.concat([
    pageInfo(0, W, H),
    symDictRaw(1, [REF]),
    textRegion(2, [1], 1, [
      { id: 0, x: 0 },
      { id: 0, ds: 3, ref: { dst: TGT, src: REF } },
    ], W, H, true),
  ]);
  doc(S, 'jbh-tref.pdf', tref, W, H);
  doc(S, 'jbh-tref-base.pdf', Buffer.concat([
    pageInfo(0, W, H),
    symDictRaw(1, [REF, TGT]),
    textRegion(2, [1], 2, places2, W, H, false),
  ]), W, H);
}

console.log('jbh-std·jbh-tab·jbh-refagg(+base)·jbh-tref(+base) 만듦');
