// 문서 하나를 열어 그리는 데 메모리를 얼마나 쓰나 — 세 지점을 다 찍는다.
//
//   node --expose-gc tests/mem.mjs <ours|pdfjs> <파일>
//
// 한 칸만 보면 결론이 뒤집힌다. 실제로 그런 일이 있었다:
//
//   "라이브러리를 들인 직후" 를 0 으로 잡고 재면 우리가 6~12MB 더 쓴다.
//   맨 노드부터 재면 우리가 7~11MB 덜 쓴다.
//
// 둘 다 맞다. pdf.js 는 JS 3MB 를 파싱·컴파일하느라 들이는 데만 20MB 를
// 쓰고, 우리는 JS 가 148KB 라 0.8MB 다 — 대신 wasm 을 여는 시점에 컴파일해
// 그 값이 "열고 그리기" 칸에 들어간다. 그래서 세 칸을 다 찍어 놓는다.
//
//   canvas  캔버스 라이브러리를 들이는 값 (양쪽 공통, 견줄 때 빼고 본다)
//   load    PDF 라이브러리를 들이는 값
//   work    문서를 열고 1쪽을 그리고 글자를 뽑는 값
//   total   맨 노드 위로 쓴 합
//   again   같은 문서를 한 번 더 열고 그리는 값 — "둘째 문서부터" 다.
//           work 에는 한 번만 치르는 값이 통째로 들어 있다. 우리는 wasm 을
//           첫 문서에서 올리고(컴파일·인스턴스·JIT) 그 값이 18MB 쯤인데,
//           pdf.js 는 같은 값을 load 칸에서 이미 치렀다. 한 문서만 재고
//           work 칸만 보면 우리가 큰 것처럼 보인다 — 실제로는 둘째부터
//           1~3MB 다. 그래서 이 칸을 함께 찍는다.
//           그 값이 어디서 오는지도 쪼개 봤다. 250바이트짜리 문서를 열어도
//           parse 가 4.3MB, render 가 2.8MB 를 낸다 — 문서 탓이 아니라
//           wasm 함수가 처음 돌 때 기계어로 번역되는 값이다(V8 tier-up).
//           같은 프로세스에서 두 번째 문서는 parse 0.5MB, render 0.8MB 다.
//   wasm    (우리만) 엔진이 잡아 둔 선형 메모리. 잡아만 두고 안 건드린
//           자리는 실제 메모리를 안 쓰므로 늘 total 보다 크게 나온다 —
//           재 보니 15.4MB 에서 25.2MB 로 늘려도 실제 메모리는 +0.5MB 였다.
//           "얼마나 예약했나" 이지 "얼마나 썼나" 가 아니다.
const which = process.argv[2];
const file = process.argv[3];

const settle = async () => {
  for (let i = 0; i < 4; i++) { global.gc?.(); await new Promise((r) => setTimeout(r, 60)); }
  return process.memoryUsage().rss / 1048576;
};

const bare = await settle();
const { createCanvas } = await import("@napi-rs/canvas");
const fs = await import("node:fs/promises");
const withCanvas = await settle();

let loaded;
let done;
let again = 0;
let wasm = 0;
if (which === "ours") {
  const { PDFDocument } = await import("../dist/index.js");
  loaded = await settle();
  const pdf = await PDFDocument.open(file);
  const cv = createCanvas(8, 8);
  await pdf.render(1, cv, { scale: 1, dpr: 1 });
  await pdf.text(1);
  // 워커 없이 도는 길에서는 엔진 사례가 문서에 딸려 있다
  wasm = (pdf.cl?.slot?.ex?.memory?.buffer?.byteLength ?? 0) / 1048576;
  done = await settle();
  pdf.close();
  // 둘째 문서 — 예열이 끝난 뒤의 값이다
  {
    const p2 = await PDFDocument.open(file);
    const c2 = createCanvas(8, 8);
    await p2.render(1, c2, { scale: 1, dpr: 1 });
    await p2.text(1);
    again = (await settle()) - done;
    p2.close();
  }
} else {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  loaded = await settle();
  const data = new Uint8Array(await fs.readFile(file));
  const task = pdfjs.getDocument({ data, cMapUrl: "cmaps/", cMapPacked: true, isEvalSupported: false });
  const doc = await task.promise;
  const page = await doc.getPage(1);
  const vp = page.getViewport({ scale: 1 });
  const cv = createCanvas(Math.ceil(vp.width), Math.ceil(vp.height));
  await page.render({ canvasContext: cv.getContext("2d"), viewport: vp, canvas: cv }).promise;
  await page.getTextContent();
  done = await settle();
  await task.destroy();
  {
    const data2 = new Uint8Array(await fs.readFile(file));
    const t2 = pdfjs.getDocument({ data: data2, cMapUrl: "cmaps/", cMapPacked: true, isEvalSupported: false });
    const doc2 = await t2.promise;
    const pg2 = await doc2.getPage(1);
    const vp2 = pg2.getViewport({ scale: 1 });
    const cv2 = createCanvas(Math.ceil(vp2.width), Math.ceil(vp2.height));
    await pg2.render({ canvasContext: cv2.getContext("2d"), viewport: vp2, canvas: cv2 }).promise;
    await pg2.getTextContent();
    again = (await settle()) - done;
    await t2.destroy();
  }
}

console.log(JSON.stringify({
  canvas: withCanvas - bare,
  load: loaded - withCanvas,
  work: done - loaded,
  again,
  total: done - bare,
  wasm,
}));
