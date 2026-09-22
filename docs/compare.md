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

`tests/md-gold.json` 에 사람이 못 박은 정답 115개(제목·제목 아님·이어진 구절·
없어야 할 꼴·표 행·코드·순서)를 세 도구가 같은 잣대로 푼다. 문서는 arXiv
논문 둘(attention·ViT, 두 단·표·수식), 비트코인 백서(코드), IRS W-9(양식),
한글 견본, 한국은행 경제전망보고서(2026-02, 앞 12쪽).

| | 우리(규칙, wasm 327KB) | docling(ML, Python) | pymupdf4llm(Python) |
|---|---|---|---|
| 맞힌 정답 | **115/115** (docling·pymupdf4llm 은 102개 기준 95·51) | 95/102 | 51/102 |
| attention 15쪽 | 150ms | 60s | — |
| 태그 PDF | 구조 나무를 따름(제목·표·목록·읽는 차례, /RoleMap) | 무시(ML 로 다시 봄) | 무시 |
| 못 하는 것 | 병합 칸 표·그림 캡션 경계 | 줄 끝 하이픈("Englishto-German"), booktabs 표 | 절 제목 0개, 수식을 제목으로 |

정답에 없는 arXiv 논문 22편·한국 보고서 5편(각 앞 10쪽)에서 docling 과 절 제목이
일치한 수는 259 → 278, docling 만 잡은 것 160 → 141, 표는 33 → 73 개(docling 54)로
움직였다 — 태그 PDF 를 따르고 괘선 없는 표를 찾은 뒤의 수다.

정답 일부는 우리 출력을 보며 적었으니 편향이 있다. 그래서 문서마다 "세
도구가 다 틀리는 것" 을 찾아 정답에 넣는 쪽으로 늘린다 — 한은 보고서의
병합 표(우리는 표를 포기하고 글로, docling 은 열을 섞음)가 그 예다.

    node tests/md-bench.mjs <문서디렉터리> docling=<출력디렉터리> pymupdf4llm=<출력디렉터리> -v

## 글자 뽑기 — 실문서 100편에서 pymupdf·pdf.js 와 맞댄 결과

정답을 손으로 적지 않고, 무작위로 모은 실문서 100편(arXiv 42편 — 1996~2026년, Type3·
Type1·OpenType 세대별로 —, 한국 정부·지자체·한은·KDI 보고서 20편, IRS 양식·설명서,
RFC·ECMA·NIST 규격, EU 관보 4개 언어, UN 아랍어·중국어, 일본 총무성 백서, CTAN 안내서,
GNU 매뉴얼 등 — `tests/corpus-dump.mjs` 의 SOURCES.txt)에서 앞 5쪽 + 고르게 3쪽을 뽑아
세 엔진의 글자를 맞댔다. 잣대는 빈칸 뺀 글자 다중집합의 재현율·정밀도(빠진 글자·군더더기),
읽는 차례(difflib), 자리(pymupdf 의 글자 상자와 우리 조각을 글자별로 짝지어 3pt·6pt 안).

|  | 재현(mu) | 정밀(mu) | 자리 | 기준끼리(pdf.js↔mupdf) |
|---|---|---|---|---|
| 처음(0.2.0) | 0.951 | 0.949 | 0.926 | 0.963 |
| 고친 뒤 | **0.992** | **0.995** | **0.988** | 1.000 |

여기서 잡아 고친 결함 — 정답 벤치(115개)로는 하나도 안 잡히던 것들이다:
- 객체 스트림이 원본보다 크게 풀리는 문서(IRS 설명서 4.4MB·객체 7만 개, arXiv pikepdf)를
  못 열었다(쪽 나무 없음) — 펼칠 자리가 모자라면 얼마나 필요한지 알리고 다시 잡는다
- 쪽 내용이 4배 넘게 풀리면(arXiv 그림 쪽 236KB→1.5MB) 그 쪽이 글자까지 백지였다
- `/MediaBox 395 0 R`(arXiv GenPDF)을 못 읽어 A4 가 Letter 로 — 글자 자리가 50pt 어긋났다
- 폼 XObject 가 쪽과 같은 이름의 글꼴(C2_0)을 가지면(InDesign) 남의 ToUnicode 로 글자가 깨졌다
- 2MB 넘는 폼(포함된 PDF 그림)이 잘리고 잘린 자리의 q 가 짝을 잃어 배율이 새어 캡션이 밀렸다
- CropBox 밖의 워터마크(한은 보고서 "복사 금지 … 담당자")가 `text()` 에 딸려 나왔다
- 오른쪽 여백의 색인 탭 앞 빈 띠를 두 단의 골로 골라 단이 안 갈렸다(한은 통화신용정책보고서)
- 같은 기준선에 크기 다른 글이 겹쳐 찍힌 쪽(지자체 보고서)에서 글자가 끼어들었다
- 글자 곳간 창(256KB)이 메모리 끝을 넘겨 memoir 안내서 첫 쪽에서 터졌다

남은 차이는 기준 쪽 것이다: HWP 가 굵게 하려고 27번 겹쳐 찍은 글자를 pdf.js 는 27번 내고
mupdf 는 빈칸으로 내는데 우리는 한 번 낸다(gov-yeosu·gov-hampyeong·kr04), attention 논문의
그림 속 낱말 반복도 같다.

    node tests/corpus-dump.mjs <pdf디렉터리> <출력디렉터리> 8
    <venv>/bin/python tests/corpus-compare.py <pdf디렉터리> <출력디렉터리>


## 그리기 — 실문서 100편에서 mupdf·pdf.js 와 화소로 맞댄 결과

같은 100편 752쪽을 세 엔진이 1배(72dpi)로 그려 화소를 맞댔다(`tests/corpus-render.mjs`,
mupdf 그림은 `tests/corpus-mupdf.py`). 잣대는 "어느 채널이든 32 넘게 다른 화소의 비율"
(글자 테두리의 안티앨리어싱 차이는 대개 그 아래라 걸러진다).

|  | 우리↔mupdf | pdf.js↔mupdf | 우리↔pdf.js |
|---|---|---|---|
| 처음(0.2.1) | 7.43% | 3.29% | — |
| 고친 뒤 | **3.12%** | 3.21% | 2.70% |

여기서 잡아 고친 결함(`tests/mkrender.mjs` 의 견본들로 못박았다):
- 폼의 `/Group` 이 딴 객체(Illustrator)면 투명 그룹으로 안 묶여 `ca 0` 으로 숨긴 막대 수백
  개가 그대로 찍혔다(attention 논문 15쪽 30%)
- 폼 `/X1` 안의 그림 이름도 `/X1`(InDesign) — 폼이 제 자신을 여섯 번 다시 불러 배경 사진이
  안 나왔다(총무성 백서 표지). 자기 자신을 부르는 폼도 막았다
- `[/DeviceN[/Cyan/Magenta]/DeviceCMYK …]` 처럼 빈칸 없이 붙은 별색 배열에서 잉크 변환
  함수를 못 찾아 셰이딩·채우기가 회색이 됐다
- Type1 글꼴의 Subrs 를 512 개로 못박아 TeX Gyre(1441 개) 본문이 통째로 대체 글꼴로 나왔다
- `/Widths` 의 소수(LM Roman 555.6)를 잘라 글자마다 0.006pt 씩 밀려 줄 끝에서 0.3pt 어긋났다
- Type1·Type3 글리프의 기준선을 화소 줄에 맞춘다 — 글꼴 엔진들이 다 그렇게 찍어, 안 맞추면
  본문 쪽마다 5~6% 가 달랐다(pdf.js 1.3%). 이것 하나로 arXiv 절반이 pdf.js 수준이 됐다
- 브라우저(OTS)가 거절하던 글꼴 스물일곱: 길이 0 인 name·OS/2·cvt 표, numGlyphs 를 넘는
  cmap, 표 목록의 쓰레기 칸(HWP 의 NanumSquare), 글리프 수와 안 맞는 post, Name INDEX 의
  EUC-KR 글꼴 이름, 부분집합이 비워 둔 박힌 비트맵(Word 의 Cambria — n·m 이 사라졌다).
  `opentype-sanitizer` 로 말뭉치 글꼴 1,274 개를 다 검사해 13 개(Corel 의 4글리프 CFF·빈
  글리프 글꼴)만 남았다
- 맨 CFF(FontFile3) 단순 글꼴이 `/Differences` 의 제 이름(g7267)으로 글리프를 고르지 못해
  HWP 보고서의 글꼴 열다섯이 다 빠졌다; WinAnsi 같은 이름 인코딩이 CFF 제 인코딩보다 세다
- 타일·셰이딩 무늬의 좌표계는 지금 변환이 아니라 쪽(폼)의 기본 변환 기준이다 — pdfTeX 이
  `0.1 0 0 0.1 cm` 아래에서 무늬로 깐 사진이 열 배 작은 칸으로 되풀이됐다
- 예측기 값은 `/DecodeParms` *안*의 것(BitsPerComponent 없으면 8) — 그림의 4 를 써서 4비트
  RGB 천체 사진이 줄무늬가 됐다; 스트림이 잘려 마지막 줄이 모자라면 0 으로 채운다
- 4비트 RGB·팔레트 그림을 회색으로 폈다; `/Indexed /DeviceCMYK` 팔레트를 3바이트 칸으로
  읽어 사진이 잡음이 됐다; 필터 없는 팔레트 그림엔 색 표를 안 먹였다
- `[/Separation /Black]` 흑백 JPEG(IRS 표지)와 AdobeRGB 프로파일의 JPEG(소식지 표지)은
  브라우저가 회색·sRGB 로만 푸니 우리가 풀어 잉크 함수·프로파일을 먹인다
- 순검정(K=1)을 (44,46,53) 으로 냈는데 요즘 pdf.js(qcms)·mupdf 는 (35,31,32) 다 — 맞췄다
- 파일이 안 박힌 Arial-BoldMT 를 대신 그릴 때 굵기·기울기를 안 살렸다(ISO 규격 목차)

남은 차이: JPEG 사진 쪽의 디코더 차이(~2%), Word 문서의 낱말 자리 서브픽셀(pdf.js 도 같다),
Corel 이 낸 4글리프 CFF(OTS 가 FD 사전의 CIDCount 를 거절 — 시스템 Arial 로 대신 그린다).

    <venv>/bin/python tests/corpus-mupdf.py <pdf디렉터리> <png디렉터리>
    CORPUS=<pdf디렉터리> CORPUS_PNG=<png디렉터리> npx vite examples --port 4278 &
    CORPUS=… CORPUS_PNG=… node tests/corpus-render.mjs out.json
    node tests/corpus-png.mjs <출력> <문서> <쪽>   # 셋의 PNG 를 나란히
