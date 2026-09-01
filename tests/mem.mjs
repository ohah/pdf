// 같은 문서를 열고 1쪽을 그렸을 때 쓰는 메모리를 잰다.
//
//   node --expose-gc tests/mem.mjs <ours|pdfjs> <파일>
//
// 세 값을 함께 낸다 — 어느 하나만 보면 속는다.
//
//   rss   문서를 열기 전후로 프로세스가 쥔 양의 차이.
//   peak  같은 프로세스 안에서 최고점(maxRSS)이 얼마나 올랐나. 실제로
//         손댄 쪽(resident)만 잡히므로 이것이 가장 정직한 값이다.
//   wasm  우리 엔진이 잡아 둔 선형 메모리. 잡아만 두고 안 건드린 자리는
//         실제 메모리를 안 쓰므로, 이 값은 늘 peak 보다 크게 나온다 —
//         "얼마나 예약했나" 이지 "얼마나 썼나" 가 아니다.
//
// pdf.js 는 JS 힙이라 GC 타이밍에 따라 흔들린다 — 그래서 회차를 여러 번
// 돌려 가운데 값을 봐야 한다(tests/mem-cmp.sh 가 그렇게 한다).
// "none" 은 대조군이다 — 라이브러리만 들이고 문서는 안 연다. 노드 자신과
// 캔버스가 쥐는 바닥을 재서, 최고점에서 그만큼 빼야 문서 몫이 보인다.
const which = process.argv[2];
const file = process.argv[3];
const fs = await import("node:fs/promises");
const { createCanvas } = await import("@napi-rs/canvas");

let peak0 = 0;
const settle = async () => {
  for (let i = 0; i < 4; i++) { global.gc?.(); await new Promise((r) => setTimeout(r, 60)); }
  return process.memoryUsage().rss;
};
const peak = () => process.resourceUsage().maxRSS * 1024;

let base;
let wasm = 0;
if (which === "none") {
  await import("../dist/index.js");
  await import("pdfjs-dist/legacy/build/pdf.mjs");
  base = await settle();
  console.log(JSON.stringify({ rss: 0, peak: peak() / 1048576, wasm: 0 }));
} else if (which === "ours") {
  const { PDFDocument } = await import("../dist/index.js");
  base = await settle();
  peak0 = peak();
  const pdf = await PDFDocument.open(file);
  const cv = createCanvas(8, 8);
  await pdf.render(1, cv, { scale: 1, dpr: 1 });
  await pdf.text(1);
  // 워커 없이 도는 길에서는 엔진 사례가 문서(client)에 딸려 있다
  const slot = pdf.cl?.slot;
  wasm = slot?.ex?.memory?.buffer?.byteLength ?? 0;
  const after = await settle();
  console.log(JSON.stringify({ rss: (after - base) / 1048576, peak: (peak() - peak0) / 1048576, wasm: wasm / 1048576 }));
  pdf.close();
} else {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  base = await settle();
  peak0 = peak();
  const data = new Uint8Array(await fs.readFile(file));
  const task = pdfjs.getDocument({ data, cMapUrl: "cmaps/", cMapPacked: true, isEvalSupported: false });
  const doc = await task.promise;
  const page = await doc.getPage(1);
  const vp = page.getViewport({ scale: 1 });
  const cv = createCanvas(Math.ceil(vp.width), Math.ceil(vp.height));
  await page.render({ canvasContext: cv.getContext("2d"), viewport: vp, canvas: cv }).promise;
  await page.getTextContent();
  const after = await settle();
  console.log(JSON.stringify({ rss: (after - base) / 1048576, peak: (peak() - peak0) / 1048576, wasm: 0 }));
  await task.destroy();
}
