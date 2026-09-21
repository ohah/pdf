# pdf.js 와 견주면

pdf.js **6.3.289** 의 공개 API 를 타입 정의에서 그대로 뽑아 하나씩 맞대 본 표다
(`pdf.mjs` 내보내기 · `PDFDocumentProxy` · `PDFPageProxy` · `pdf_viewer.mjs` 부품 ·
`DocumentInitParameters`). "없음"이라고 적은 것은 실제로 코드에서 확인한 것이다.

## 요약

| | pdf.js | @ohah/pdf |
|---|---|---|
| 번들 크기 | 505KB | **220KB** + wasm 301KB |
| 그리기 정확도 | CMYK JPEG·JBIG2 허프만·JPX ROI 문서에서 빈 화면 | **그린다** |
| 표준 14종 | AFM 폭 + 실제 글꼴 | AFM 폭은 정확. 모양은 이름을 보고 갈래를 맞춘 시스템 글꼴이고, `fonts` 로 자리를 주면 진짜 글꼴을 받아 싣는다 |
| 전자 서명 | 데이터만 준다 | **WebCrypto 로 검증까지** |
| 편집 | 없음(뷰어) | 쪽 고르기·회전·병합·워터마크·양식 채우기·AES-256 |
| 뷰어 부품 | `PDFViewer`·검색·링크·썸네일·주석 편집기 한 벌 | **없음** — 화면은 쓰는 쪽이 짠다 |
| 실행 환경 | 브라우저 + Node.js | **브라우저 + Node.js** (Node 에서는 뽑기·편집만, 그리기는 캔버스가 있어야) |

## 문서 열기

| pdf.js | 우리 |
|---|---|
| `data` · `password` | ✅ |
| `cMapUrl` / `cMapPacked` | ✅ 열 때 `cmaps` 로 자리를 준다 |
| `url` + `range`·`disableStream`·`disableAutoFetch` | ⚠️ `range` 는 된다 — 512KB 넘고 서버가 받아 주면 토막만 받아 먼저 열고 `complete()` 로 마저 받는다. 나머지 둘은 없다 |
| `onProgress` | ✅ `open(url, { onProgress, signal })` |
| `standardFontDataUrl` (표준 14종) | ✅ `fonts` 로 자리를 준다 — 문서가 쓰는 한 벌만 받는다. 안 주면 이름을 보고 갈래(세리프·고정폭)를 맞춰 시스템 글꼴로 그린다 |
| `disableFontFace` · `useSystemFonts` · `fontExtraProperties` | ❌ (거절당하면 자동 대체) |
| `maxImageSize` · `canvasMaxAreaInBytes` · `enableHWA` | ❌ 내부 고정 |
| `CanvasFactory` · `FilterFactory` 교체 | ❌ — 대신 Node 에서 워커 없이 그대로 돈다. `render()` 에 캔버스를 넘기면 그것에 그린다 |
| `verbosity` · `docBaseUrl` · `enableXfa` | ❌ |

## 문서 수준

| pdf.js | 우리 |
|---|---|
| `numPages` · `getOutline` · `getAttachments` · `getOptionalContentConfig` | ✅ `pages`·`outline`·`attachments`·`layers`/`setLayers` |
| `getSignatures` · `getSignatureData` | ✅ `signatures()` — 검증까지 |
| `getMetadata` (Info · XMP) | ✅ `info` · `xmp`(원문) |
| `getData` | ✅ `data()` |
| `getPermissions` | ✅ `permissions` — 인쇄·복사·고침 … |
| `getPageLabels` | ✅ `pageLabels` |
| `getDestinations` / `getDestination` | ✅ `destinations` |
| `getPageMode` · `getPageLayout` | ✅ `pageMode` · `pageLayout` (덤으로 `lang`) |
| `getViewerPreferences` | ✅ `viewerPreferences` |
| `getOpenAction` | ✅ `openAction` |
| `fingerprints` | ✅ `fingerprint` |
| `getMarkInfo` | ✅ `tagged` |
| (pdf.js 에 없음) | ✅ `collection` — 파일 묶음(포트폴리오)의 보기·처음 열 파일·목록 칸 |
| `getFieldObjects` (문서 전체) | ⚠️ 쪽 단위 `fields(page)` 만 |
| `getJSActions` · `hasJSActions` · `getCalculationOrderIds` | ⚠️ `calcOrder` 와 양식 계산식(`runCalc`·`recalculate`)은 된다 — 작은 해석기로 푼다. `/OpenAction` 의 자유 스크립트는 일부러 안 돌린다 |
| `getPageIndex(ref)` · `cachedPageNumber(ref)` | ❌ 객체 ref 개념 없음 |
| `annotationStorage` | ⚠️ `build(spec)` 왕복 |
| `saveDocument` · `extractPages` | ✅ `build`·`merge`·`encrypt` |

## 쪽 수준

| pdf.js | 우리 |
|---|---|
| `render()` | ✅ |
| `RenderTask.cancel()` | ✅ `renderTask().cancel()` · `render({ signal })` |
| `getViewport()` + `convertToViewportPoint/PdfPoint` | ✅ `viewport(page, {scale, rotation})` · `toViewport`·`toPdf`·`rect` |
| render 옵션 `rotation` · `background` | ✅ |
| render 옵션 `intent:'print'` · `annotationMode` · `transform` · `pageColors` · `isEditing` | ❌ |
| `getTextContent()` | ✅ `textItems(page)` — `str`·`dir`·`fontName`·`hasEOL` 까지 |
| `streamTextContent()` | ❌ |
| `getAnnotations()` 전체 주석 | ✅ `annotations(page)` — 종류·글·쓴이·날짜·색·깃발 |
| `getOperatorList()` · `recordImages` | ❌ 내부에만 있다 |
| `getStructTree()` | ✅ `structure(page?)` |
| `view`(MediaBox) · `userUnit` · `ref` · `clone()` | ⚠️ `viewport` 가 쪽 크기를 준다 |
| `cleanup(keepLoadedFonts)` | ⚠️ `close()` 만 |

## 화면 층

| pdf.js | 우리 |
|---|---|
| `TextLayer` / `TextLayerBuilder` | ✅ `renderTextLayer(container, runs)` |
| `AnnotationLayer` / `AnnotationLayerBuilder` | ✅ `renderAnnotationLayer()` — 스타일시트 없이 인라인 자리 잡기 |
| `XfaLayer` | ✅ `readXfa()` 로 뜯어 `drawXfa()` 로 그린다 — 서식을 스크립트로 바꾸는 동적 XFA 까지 |
| `StructTreeLayerBuilder` | ⚠️ 나무는 `structure()` 로. DOM 얹기는 아직 |
| `AnnotationEditorLayer` · `DrawLayer` · `ColorPicker` (형광펜·자유글·잉크·도장) | ❌ 편집은 `build(spec)` 로만 |

## 뷰어 부품 (`pdf_viewer.mjs`)

`PDFViewer` · `PDFSinglePageViewer` · `PDFPageView` · `PDFFindController`(문서 검색·
하이라이트) · `PDFLinkService` · `PDFHistory` · `PDFScriptingManager` ·
`DownloadManager` · `EventBus` · `ProgressBar` · `ScrollMode`/`SpreadMode` —
**우리는 없다.** 화면은 쓰는 쪽이 짠다(React·Vue·Svelte 갈래가 그 바탕은 준다).

## 유틸

`PixelsPerInch` · `Util` · `PDFDateString` · `normalizeUnicode` · `getFilenameFromUrl` ·
`isPdfFile` · `OPS` · `AnnotationType/Mode` · `PermissionFlag` · `OutputScale` ·
`TouchManager` — 없다. 우리 쪽은 `toLines`·`makeViewport`·`toScreen`·`placeRect` 넷이다.

## 앞으로

이 표에서 ❌ 인 것 중 뷰어에 먼저 아쉬운 순서:

1. 문서 전체 입력 칸(`getFieldObjects`) — 지금은 쪽 단위만이다
2. 구조 나무를 DOM 으로 얹기(`StructTreeLayerBuilder` 갈래)
3. 주석 편집기 층 — 지금은 `build(spec)` 로만 고친다

앞선 판에 적어 두었던 둘은 됐다. range 요청은 `range` 로, 표준 14종의 글자
모양은 `fonts` 로 자리를 주면 진짜 글꼴을 받아 싣는다.

## PDF → Markdown — docling·pymupdf4llm 과 맞댄 결과

`tests/md-gold.json` 에 사람이 못 박은 정답 102개(제목·제목 아님·이어진 구절·
없어야 할 꼴·표 행·코드·순서)를 세 도구가 같은 잣대로 푼다. 문서는 arXiv
논문 둘(attention·ViT, 두 단·표·수식), 비트코인 백서(코드), IRS W-9(양식),
한글 견본, 한국은행 경제전망보고서(2026-02, 앞 12쪽).

| | 우리(규칙, wasm 323KB) | docling(ML, Python) | pymupdf4llm(Python) |
|---|---|---|---|
| 맞힌 정답 | **111/111** (docling·pymupdf4llm 은 102개 기준 95·51) | 95/102 | 51/102 |
| attention 15쪽 | 150ms | 60s | — |
| 못 하는 것 | 괘선 없는 표·그림 캡션 경계 | 줄 끝 하이픈("Englishto-German"), booktabs 표 | 절 제목 0개, 수식을 제목으로 |

정답 일부는 우리 출력을 보며 적었으니 편향이 있다. 그래서 문서마다 "세
도구가 다 틀리는 것" 을 찾아 정답에 넣는 쪽으로 늘린다 — 한은 보고서의
병합 표(우리는 표를 포기하고 글로, docling 은 열을 섞음)가 그 예다.

    node tests/md-bench.mjs <문서디렉터리> docling=<출력디렉터리> pymupdf4llm=<출력디렉터리> -v
