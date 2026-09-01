# @ohah/pdf

브라우저에서 PDF 를 읽고, 그리고, 고친다. 엔진은 Zig 로 짜 wasm 하나(288KB)로
굽고 웹 워커에서 돌린다. 화면 갈래는 바닐라·React·Vue·Svelte 를 함께 낸다.

```bash
npm i @ohah/pdf
```

```js
import { PDFDocument } from "@ohah/pdf";

const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
await pdf.render(1, document.querySelector("canvas"), { scale: 1.5 });
const text = await pdf.text(1);
pdf.close();
```

`pdf.wasm` 과 `cmaps/` 는 정적 파일이다. 꾸러미에서 꺼내 웹에서 받을 수 있는
자리에 두고 그 주소를 `wasm`·`cmaps` 로 알려 준다.

주소로 열면 받는 동안 진행률이 온다:

```js
const pdf = await PDFDocument.open("/big.pdf", {
  wasm: "/pdf.wasm",
  onProgress: ({ loaded, total }) => setBar(total ? loaded / total : 0),
  signal: ac.signal,          // 그만두기
});
```

```bash
cp node_modules/@ohah/pdf/dist/pdf.wasm public/
cp -r node_modules/@ohah/pdf/cmaps public/
```

CMap 은 문서가 실제로 쓰는 이름만 그때그때 받아 간다 — 7MB 를 통째로 내려받지
않는다. 한글·일본어·중국어 문서를 안 다룬다면 `cmaps` 는 없어도 된다.

## 무엇을 하나

**읽기** — 쪽 그리기, 글자 뽑기(읽는 차례로 줄 세우기 포함), 링크, 목차,
문서 속성, 레이어(선택 콘텐츠) 켜고 끄기, 딸린 파일 꺼내기, 전자 서명 확인,
암호 걸린 문서(RC4·AES-128·AES-256, 사용자·소유자 암호 모두).

**글꼴** — 박힌 TrueType·CFF·Type1·Type3, CID 글꼴, 세로쓰기, 미리 정의된
CMap. 브라우저가 거절하는 글꼴은 표를 기워서 다시 낸다.

**그림** — DCTDecode(회색·RGB·CMYK·YCCK), JPX(JPEG 2000, 관심 구역·타일·
다중 계층), JBIG2(산술·허프만·정교화·globals), CCITT G3/G4, 1·2·4·8·16 비트,
Indexed·Separation·Lab·ICC 대체, /Mask 스텐실과 색 열쇠 마스킹, SMask,
투명 그룹과 혼합 모드.

**쓰기** — 쪽 고르기·회전·이어붙이기, 워터마크, 주석, 양식 칸 채우기와
새 칸 만들기, 암호 걸기(AES-256/R6).

어디까지 되고 무엇이 안 되는지는 [`docs/support.md`](docs/support.md) 에,
pdf.js 와 하나씩 맞댄 표는 [`docs/compare.md`](docs/compare.md) 에 있다.

## 화면 갈래

### React

```jsx
import { usePdf, PDFPage } from "@ohah/pdf/react";

function Viewer({ file }) {
  const { doc, loading, error, needPassword } = usePdf(file, { wasm: "/pdf.wasm" });
  if (loading) return <p>여는 중…</p>;
  if (needPassword) return <p>암호가 필요합니다</p>;
  if (error) return <p>{String(error)}</p>;
  return doc && <PDFPage doc={doc} page={1} scale={1.5} />;
}
```

### Vue 3

```vue
<script setup>
import { ref } from "vue";
import { usePdf, PDFPage } from "@ohah/pdf/vue";

const file = ref(null);
const { doc } = usePdf(file, { wasm: "/pdf.wasm" });
</script>

<template>
  <PDFPage v-if="doc" :doc="doc" :page="1" :scale="1.5" />
</template>
```

### Svelte

```svelte
<script>
  import { pdfStore, pdfPage } from "@ohah/pdf/svelte";
  const pdf = pdfStore({ wasm: "/pdf.wasm" });
</script>

<input type="file" on:change={(e) => pdf.open(e.target.files[0])} />
{#if $pdf.doc}
  <canvas use:pdfPage={{ doc: $pdf.doc, page: 1, scale: 1.5 }}></canvas>
{/if}
```

### 바닐라

`examples/vanilla.html` 이 번들러 없이 `dist` 를 그대로 물리는 길을 보여 준다.
`examples/node.mjs` 는 Node 에서 뽑고 다시 내는 길이다.

### Node.js

브라우저 밖에서도 돈다. Worker 가 없으면 같은 갈래에서 엔진을 부르고, wasm 과
CMap 표는 주소 대신 꾸러미 안 파일에서 읽는다 — 따로 설정할 것이 없다.

```js
import { PDFDocument } from "@ohah/pdf";

const pdf = await PDFDocument.open("./보고서.pdf");   // 파일 경로 그대로
console.log(pdf.pages, await pdf.text(1));
const items = await pdf.textItems(1);                 // 색인·검색용
const out = await pdf.build({ pick: [0, 2, 4] });     // 쪽만 골라 다시 내기
pdf.close();
```

뽑기(`text`·`textItems`·`annotations`·`structure`·`fields`·`signatures`)와
편집(`build`·`merge`·`encrypt`)은 그대로 된다. **그리려면 캔버스를 만들어 넘긴다.**

```js
import { createCanvas } from "@napi-rs/canvas";   // node-canvas 도 된다

const cv = createCanvas(10, 10);                  // 크기는 render 가 맞춘다
await pdf.render(1, cv, { scale: 1, dpr: 1 });
await writeFile("1쪽.png", cv.toBuffer("image/png"));
```

도형·그림·무늬·투명 무리·소프트 마스크는 브라우저와 같은 그림이 나온다(잉크
양까지 맞다). 다만 문서에 박힌 글꼴은 브라우저에서만 등록되므로(FontFace),
**Node 에서 그린 글자는 시스템 글꼴 모양이다** — 자간과 자리는 맞고 글자 모양만
다르다. 캔버스를 안 넘기면 무슨 일인지 알려 주는 오류가 난다.

문서를 여러 개 한꺼번에 열어도 된다. 문서마다 제 엔진 사례를 들고 다닌다.

## API

| | |
|---|---|
| `PDFDocument.open(src, opts)` | 문서를 연다 — 바이트·`Blob`·`Response`·**주소** 모두. 암호가 필요하면 `PasswordNeeded` |
| `pdf.pages` · `outline` · `info` · `layers` · `attachments` · `isXfa` · `locked` | 문서 정보 |
| `pdf.permissions` | 인쇄·복사·고침 … 문서가 허락한 것들 (`/P`) |
| `pdf.pageLabels` | 쪽 라벨 — 표지가 i, ii 이고 본문이 1부터인 문서 |
| `pdf.pageMode` · `pageLayout` · `lang` · `tagged` · `fingerprint` | 열 때 설정·언어·태그 여부·문서 지문 |
| `pdf.destinations` | 이름 목적지 — 목차·링크가 이름으로 가리키는 자리 |
| `pdf.viewerPreferences` · `pdf.xmp` | 뷰어 설정 · XMP 원문 |
| `pdf.render(page, canvas, opts)` | 쪽을 그린다. 글자 자리(`runs`)를 돌려주므로 투명 글자층을 직접 얹을 수 있다 |
| `pdf.text(page)` | 쪽의 글자 |
| `pdf.textItems(page)` | 덩이째 — 자리·크기·글꼴 이름·쓰는 방향·줄 끝 |
| `pdf.structure(page?)` | 구조 나무(태그 PDF) — 제목·문단·표와 대체 글 |
| `pdf.fields(page)` · `links(page)` | 입력 칸 · 링크 |
| `pdf.annotations(page)` | 쪽에 달린 주석 전부 — 종류·글·쓴이·날짜·색·깃발 |
| `pdf.signatures()` | 전자 서명을 WebCrypto 로 맞춰 본다. 비보안(http) 자리라 못 맞춰 보면 `unchecked` 가 선다 — "틀렸다" 와 구별한다 |
| `pdf.attachment(i)` | 딸린 파일 바이트 |
| `pdf.setLayers(on[])` | 레이어를 켜고 끈다 |
| `pdf.build(spec)` · `encrypt(bytes, pw)` · `merge(bytes)` | 새 PDF 를 만든다 |
| `pdf.renderTask(page, canvas, opts)` | 그만둘 수 있는 렌더 — `.cancel()` · `.promise` |
| `pdf.viewport(page, {scale, rotation})` | 그리지 않고 자리만 계산. `toViewport`·`toPdf`·`rect` |
| `pdf.data()` | 연 문서의 원본 바이트 |
| `safeUrl(link.uri)` | 링크 주소를 걸러 준다 — `javascript:` 같은 것은 null |
| `pdf.close()` | 워커를 닫는다 |

브라우저에서는 워커가 일을 맡고, Node 에서는 같은 갈래에서 돈다 — 부르는 쪽 코드는 같다.

`render()` 는 `scale`·`dpr`·`formLayer` 에 더해 `rotation`(문서 회전에 더할 각) ·
`background`(바탕색) · `signal`(AbortSignal) 을 받는다. 돌려주는 `viewport` 로 얹는
것들의 자리를 잡는다.

```js
const { runs, viewport } = await pdf.render(1, canvas, { scale: 1.5, rotation: 90 });
renderTextLayer(layer, runs);              // 긁어 복사되는 투명 글자층
Object.assign(box.style, viewport.rect([72, 680, 172, 700]));   // PDF 네모 → 화면 자리
const [px, py] = viewport.toPdf(ev.offsetX, ev.offsetY);        // 클릭 → PDF 좌표
```

돌려주는 것들은 이름이 있다 — `TextItem`·`FormField`·`LinkItem`·`Annotation`·
`Signature`·`MergeResult`·`OutlineItem`·`Permissions`·`Layer`·`Attachment`·
`Destination`·`StructNode`·`Viewport`·`TextRun`. 함수 하나를 건너 넘길 때
`Awaited<ReturnType<…>>` 를 쓰지 않아도 된다.

`toLines(runs)` 로 글자 덩이를 읽는 차례의 줄로 묶을 수 있고, `renderTextLayer()` 가
그 줄로 투명 글자층을 지어 준다(폭 맞추기·줄바꿈까지).
`renderAnnotationLayer(container, annots, viewport)` 는 주석을 다룰 수 있게 얹는다 —
링크는 `<a>`(위험한 갈래는 거른다), 문서 안 이동은 단추, 남긴 글은 툴팁이다.

## 소스에서 굽기

```bash
npm i
npm run build:wasm   # zig 0.16 이 필요하다 (mise 를 쓰면 mise.toml 이 잡는다)
npm run build:js
bash tests/run.sh 3  # 적대적 604개 + 단언 343개
npx vite examples    # 예제 넷을 한 서버에 띄운다
```

`c/*.zig` 가 엔진, `src/*.ts` 가 브라우저 쪽이다. 시험은
[`tests/README.md`](tests/README.md) 를 본다.

TS 를 JS 로 옮기는 일은 [zntc](https://github.com/ohah/zntc) 가 한다 — Zig 로
짠 트랜스파일러다. 형 선언(`.d.ts`)만 `tsc` 가 내고, 예제 서버도
`@zntc/vite-plugin` 을 끼워 같은 트랜스파일러를 쓴다. 묶지 않고 파일마다
옮기므로 워커가 `dist/worker.js` 로 따로 남는다. 소스맵은 `dist/*.js.map`
으로 함께 나가고 원본을 안에 담고 있어, 쓰는 쪽에서 소스를 따로 받지
않아도 브라우저가 TS 를 보여 준다.

## 라이선스

MIT (`LICENSE`). 함께 담긴 남의 것은 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)
에 적어 두었다.
