# pdf.js 와 견주면

pdf.js **6.3.289** 의 공개 API 를 타입 정의에서 그대로 뽑아 하나씩 맞대 본 표다
(`pdf.mjs` 내보내기 · `PDFDocumentProxy` · `PDFPageProxy` · `pdf_viewer.mjs` 부품 ·
`DocumentInitParameters`). "없음"이라고 적은 것은 실제로 코드에서 확인한 것이다.

## 요약

| | pdf.js | @ohah/pdf |
|---|---|---|
| 번들 크기 | 505KB | **150KB** + wasm 288KB |
| 그리기 정확도 | CMYK JPEG·JBIG2 허프만·JPX ROI 문서에서 빈 화면 | **그린다** |
| 전자 서명 | 데이터만 준다 | **WebCrypto 로 검증까지** |
| 편집 | 없음(뷰어) | 쪽 고르기·회전·병합·워터마크·양식 채우기·AES-256 |
| 뷰어 부품 | `PDFViewer`·검색·링크·썸네일·주석 편집기 한 벌 | **없음** — 화면은 쓰는 쪽이 짠다 |
| 실행 환경 | 브라우저 + Node.js | **브라우저만** |

## 문서 열기

| pdf.js | 우리 |
|---|---|
| `data` · `password` | ✅ |
| `cMapUrl` / `cMapPacked` | ✅ `paths.cmaps` |
| `url` + `range`·`disableStream`·`disableAutoFetch` | ❌ 전체 바이트를 받아야 시작 |
| `onProgress` | ❌ |
| `standardFontDataUrl` (표준 14종 실제 글꼴) | ❌ 시스템 글꼴로 대체 — 자간이 원본과 다르다 |
| `disableFontFace` · `useSystemFonts` · `fontExtraProperties` | ❌ (거절당하면 자동 대체) |
| `maxImageSize` · `canvasMaxAreaInBytes` · `enableHWA` | ❌ 내부 고정 |
| `CanvasFactory` · `FilterFactory` 교체 | ❌ → Node.js 실행 불가 |
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
| `getOpenAction` | ❌ |
| `fingerprints` | ✅ `fingerprint` |
| `getMarkInfo` | ✅ `tagged` |
| `getFieldObjects` (문서 전체) | ⚠️ 쪽 단위 `fields(page)` 만 |
| `getJSActions` · `hasJSActions` · `getCalculationOrderIds` | ❌ 의도적 미지원 (뷰어가 스크립트를 안 돌린다) |
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
| `XfaLayer` | ❌ XFA 미지원 (`isXfa` 로 알려만 준다) |
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

1. 스트리밍/진행률 (큰 파일 첫 쪽을 빨리)
2. 표준 14종 실제 글꼴 데이터 (자간 정확도)
3. Node.js 실행 (캔버스 팩토리 교체)
