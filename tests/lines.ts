import { toLines, type TextRun } from "../src/draw";
const R = (x: number, y: number, t: string, angle = 0): TextRun => ({ x, y, w: 10, h: 10, text: t, angle });
let ok = 0, bad: string[] = [];
const t = (n: string, c: boolean, g?: unknown) => { if (c) ok++; else bad.push(`${n}${g !== undefined ? ` (${JSON.stringify(g)})` : ""}`); };

// 그린 차례가 뒤죽박죽이어도 읽는 차례로 세운다
{
  const L = toLines([R(50, 30, "나중"), R(10, 10, "가"), R(60, 10, "나"), R(10, 30, "먼저")]);
  t("줄 두 개", L.length === 2, L.length);
  t("위 줄이 먼저", L[0][0].text === "가", L[0].map(r => r.text));
  t("한 줄 안에서 왼쪽부터", L[0].map(r => r.text).join("") === "가나", L[0].map(r => r.text));
  t("아래 줄", L[1].map(r => r.text).join("") === "먼저나중", L[1].map(r => r.text));
}
// 기울어진 글자는 따로 묶는다
{
  const L = toLines([R(10, 10, "본문"), R(60, 10, "본문2"), R(30, 40, "도장", 0.5)]);
  t("기운 글자 분리", L.some(l => l.length === 1 && l[0].text === "도장"), L.map(l => l.map(r => r.text)));
}
// 줄 높이보다 조금 어긋난 것은 같은 줄
{
  const L = toLines([R(10, 10, "가"), R(30, 12, "나")]);
  t("살짝 어긋나도 같은 줄", L.length === 1, L.length);
}

// 두 단 문서 — 왼쪽 단을 다 읽고 오른쪽 단으로 넘어가야 한다
{
  const rs: TextRun[] = [];
  for (let i = 0; i < 12; i++) rs.push({ x: 50, y: 100 + i * 24, w: 90, h: 11, text: `L${i}`, angle: 0 });
  for (let i = 0; i < 12; i++) rs.push({ x: 330, y: 100 + i * 24, w: 90, h: 11, text: `R${i}`, angle: 0 });
  const got = toLines(rs).map((l) => l.map((r) => r.text).join("")).join("|");
  t("두 단: 왼쪽 먼저", got.startsWith("L0|L1|L2"), got.slice(0, 30));
  t("두 단: 오른쪽은 뒤에", got.endsWith("R9|R10|R11"), got.slice(-30));
  t("두 단: 줄이 24개", toLines(rs).length === 24, toLines(rs).length);
}
// 제목이 두 단 위에 걸쳐 있어도 제목 먼저
{
  const rs: TextRun[] = [{ x: 50, y: 60, w: 400, h: 16, text: "제목", angle: 0 }];
  for (let i = 0; i < 8; i++) rs.push({ x: 50, y: 120 + i * 20, w: 90, h: 10, text: `L${i}`, angle: 0 });
  for (let i = 0; i < 8; i++) rs.push({ x: 330, y: 120 + i * 20, w: 90, h: 10, text: `R${i}`, angle: 0 });
  const got = toLines(rs).map((l) => l.map((r) => r.text).join("")).join("|");
  t("제목+두 단: 제목이 맨 앞", got.startsWith("제목|L0"), got.slice(0, 20));
  t("제목+두 단: 단이 안 섞임", !/L\d\|R\d\|L/.test(got), got.slice(0, 40));
}
// 한 줄 안이 넓게 벌어진 것(차례 ..... 3)은 단이 아니다
{
  const rs: TextRun[] = [
    { x: 50, y: 100, w: 60, h: 11, text: "차례", angle: 0 },
    { x: 400, y: 100, w: 20, h: 11, text: "3", angle: 0 },
    { x: 50, y: 124, w: 60, h: 11, text: "머리", angle: 0 },
    { x: 400, y: 124, w: 20, h: 11, text: "4", angle: 0 },
  ];
  const got = toLines(rs).map((l) => l.map((r) => r.text).join("")).join("|");
  t("벌어진 한 줄은 단이 아님", got === "차례3|머리4", got);
}

console.log(`  줄 묶기 ${ok + bad.length}개 중 통과 ${ok}, 실패 ${bad.length}`);
for (const b of bad) console.log("   ✗", b);
