# PDF 엔진 시험

```
bun run test:pdf        # 3회 반복
bash tests/run.sh 5 # 5회
```

두 갈래로 돈다.

**적대적** (`r1.mjs`~`r7.mjs`, 440개) — 망가진 파일과 극단값을 넣고
죽거나 멎지 않는지 본다. 통과 기준은 *예외 0, 3초 넘는 항목 0* 이다.
`r7.mjs` 는 CMap 표·CIDToGIDMap·라벨·주석·서명·암호 걸기를 겨냥한다.
`r8.mjs` 는 무작위 퍼저다 — 붙임감을 마구 헝클어 넣고, 회차마다 씨앗이 달라
돌릴 때마다 다른 파일이 된다. 넘어지면 씨앗을 찍어 두므로 그 값으로 다시
만들어 볼 수 있다(`node tests/r8.mjs tests/fixtures 12345`).

**pdf.js 와 그림 맞대기** (`tests/compare-pdfjs.mjs`) — 같은 쪽을 우리 엔진과
pdf.js 로 각각 그려 화소를 견준다. 우리 판끼리 맞대는 `ab.mjs` 는 "어제와 같은가"
만 볼 수 있어서, 둘 다 처음부터 틀렸으면 잡지 못한다. 바깥 눈이 하나 필요하다.

```
npx vite examples --port 4277 &
node tests/compare-pdfjs.mjs            # 견본 전부
node tests/compare-pdfjs.mjs icc.pdf    # 몇 개만
node tests/sample-px.mjs icc.pdf "60,60;150,110"  # 자리를 짚어 색을 뽑아 본다
```

두 그림이 똑같을 수는 없다 — 글자 뭉개기와 글리프 래스터가 서로 다르다.
그래서 "크게 다른 화소"(채널 하나라도 32 넘게 어긋난 화소)의 비율을 본다.
글자 가장자리 차이로는 잘 안 뛰고, 그림이 빠지거나 색이 뒤집히면 확 뛴다.

한쪽이 아예 안 그린 쪽은 갈라 놓는다. **우리가 못 그린 쪽이 있으면 실패**로
친다. pdf.js 가 못 그린 쪽(JPX·JBIG2 견본 26개)은 세어만 둔다.

**우리가 만든 PDF 를 pdf.js 로 열어 보기** (`tests/roundtrip-pdfjs.mjs`) — 원본에
주석·라벨·워터마크를 얹어 새 PDF 를 만든 뒤, 그것을 pdf.js 로 열어 그린다.

```
npx vite examples --port 4277 &
node tests/roundtrip-pdfjs.mjs
```

여기까지 오기 전의 시험은 모두 **우리가 쓴 것을 우리만 읽어 봤다.** A/B 는 우리
엔진끼리 맞대고, 앱 화면 시험도 우리 뷰어로 다시 연다. `compare-pdfjs.mjs` 는
바깥 눈이지만 **원본 견본만** 본다. 그래서 우리가 내보낸 파일이 규격을 벗어나도
아무도 몰랐다.

pdf.js 가 못 열거나, 쪽 수가 다르거나, 우리가 그린 것의 절반도 못 그리면 실패다.

다만 이 시험이 만능은 아니다. 겉모습 폼의 `/Subtype` 이 규격에 없는 이름으로
나갔을 때 **pdf.js 는 그것을 무시하고 멀쩡히 그렸다** — 저쪽도 `/AP → /N` 만
따라간다. 그런 것은 나온 바이트를 직접 보는 수밖에 없어 `verify.mjs` 에 단언을
따로 뒀다("내보낸 PDF 에 모듈 이름이 안 샌다").

**브라우저** (`tests/e2e.spec.ts` 20개, `tests/worker.spec.ts` 6개) — 화면과
워커 경계를 본다. 워커는 이번에 새로 생긴 자리라 따로 두들긴다 — 답이 오기 전에
다음 파일을 넣기, 망가진 파일 잇달아 넣기, 미리보기가 흐르는 중에 만지기.

    npx playwright test --repeat-each=5

**단언** (`verify.mjs` 204개, `lines.ts` 6개, `place.ts` 12개,
`sig.ts` 32개) — 결과가 실제로 맞는지 본다.
죽지 않는 것만으로는 모자란다. 예전에 CFF 글꼴이 통째로 Type1 로 새고
있었는데 적대적 쪽은 "글꼴 실림" 이라고 답했다. `"/FontFile"` 이
`"/FontFile3"` 의 접두사라 벌어진 일이었고, 단언을 넣고서야 잡혔다.

`dist/pdf.wasm` 과 `cmaps/` 를 읽는다. wasm 을 고쳤으면
`npm run build:wasm` 를 먼저 돌린다.

## fixture

`fixtures/` 에 30개. 두 개는 생성기가 있다.

```
node tests/mkcmap2.mjs tests/fixtures   # cmap2.pdf — ToUnicode 없는 옛 한글
node tests/mkc2g.mjs   tests/fixtures   # c2g.pdf·c2g0.pdf — CIDToGIDMap
```

`fixtures/sub.ttf` 는 `korean.pdf` 에서 꺼낸 트루타입이다. 글리프가
3320개라 번호로 집는 길을 시험할 수 있다.

```
node tests/mksh.mjs    tests/fixtures   # 셰이딩 1·4·5·6·7 형
node tests/mktr.mjs    tests/fixtures   # 글자 그리기 모드 Tr 0~7
node tests/mksmask.mjs tests/fixtures   # ExtGState /SMask
node tests/mkjbig2.mjs tests/fixtures   # JBIG2 (부록 H 시험 흐름)
node tests/mkjbig2h.mjs tests/fixtures  # JBIG2 허프만 판의 빈 자리
node tests/mkjbig2big.mjs tests/fixtures # jb-globals.pdf — 스캔 한 장
node tests/mktype3.mjs tests/fixtures   # type3.pdf — 글리프가 그림인 글꼴
node tests/mkdocs.mjs  tests/fixtures   # 여러 쪽 문서 (pages.pdf·sample.pdf 도 함께)
node tests/mkscan.mjs  tests/fixtures   # 스캔 문서 (scanned.pdf·scan4.pdf)
node tests/mkdest.mjs  tests/fixtures   # 이름으로 가리킨 목적지 셋
node tests/mkatt.mjs   tests/fixtures   # 딸린 파일·XFA

`crop.pdf`·`cmyk.pdf`·`mask-stencil.pdf`·`mask-key.pdf`·`bpc16.pdf`·`vert.pdf`·
`group.pdf` 은 두 번째 전수조사에서 메운 갈래다(CropBox·CMYK JPEG·그림 가리개·
16비트·세로쓰기·투명 그룹). `cmyk.jpg` 는 macOS `sips` 로 만든 CMYK JPEG 이다 —
브라우저가 못 푸는 꼴이라 우리 복호기(c/pdfjpeg.zig)로 푼다.
node tests/mkjpx.mjs   tests/fixtures   # JPEG 2000 (관심 구역 포함)
node tests/mksig.mjs   tests/fixtures   # 전자 서명 (openssl 이 필요하다)
```

`mkjbig2h.mjs` 는 부록 H 에 없는 세 갈래를 **직접 부호화해서** 만든다 —
문서가 제 허프만 표를 실어 오는 꼴, 허프만 사전에서 세밀화로 글자를 만드는 꼴,
허프만 글자 영역에서 다듬는 꼴이다. 세밀화 자료는 산술 부호라 MQ 부호기
(T.88 부록 E)를 같이 담았다. 새 길과 옛 길로 각각 담아 짝지어 내므로,
틀이 한 비트라도 어긋나면 두 그림이 갈린다.

`mksig.mjs` 는 구멍만 뚫린 PDF 를 먼저 쓰고, `/ByteRange` 자리를 잰 다음
그 바이트를 `openssl smime` 으로 서명해 구멍을 메운다. 열쇠와 인증서는
`fixtures/sig/` 에 있다(자체 서명, 100년짜리). 개인 열쇠는 저장소에 담지
않으므로, 없으면 `mksig.mjs` 가 openssl 로 새로 만든다. `signed-tampered.pdf` 는
서명 뒤에 한 글자를 바꾼 것이라 요약값이 어긋나야 한다.

부호기는 `jbig2enc.mjs` 에 모아 두었다 — MQ 산술 부호기, 허프만 표, 세그먼트
틀, PDF 껍데기다. `mkjbig2h.mjs` 와 `mkjbig2big.mjs` 가 같이 쓴다.

`fixtures/` 안의 `.*.pdf` 와 `v-*.pdf` 는 붙임감이 아니라 **시험이 돌면서
만들어 내는 것**이라 저장소에 담지 않는다.

`fixtures/annex-h.jbig2` 는 ITU-T T.88 부록 H 의 시험 흐름이다. 같은 그림을
쪽1 은 허프만·MMR 로, 쪽2 는 산술 부호로 담아 두어 서로 맞대 볼 수 있다.
`fixtures/jpx/` 의 `p0_*.j2k` 는 JPEG2000 적합성 시험 자료(openjpeg-data)이고,
나머지 `.jp2` 는 macOS 인코더로 만든 것이다.
