# 무엇까지 되나

시험으로 확인한 것만 적는다. `bash tests/run.sh` 가 도는 기능 단언 397개가
이 표의 근거다 — 붙임감은 `tests/fixtures/` 에 있다. pdf.js 와 화소를 맞댄
결과는 [`compare.md`](compare.md), 크게 다른 것과 그 까닭은
`tests/pdfjs-known.json` 에 하나씩 적어 두었다.

## 문서 구조

| | |
|---|---|
| xref 표 · xref 스트림 · 객체 스트림 | 된다 |
| 망가진 xref | 객체를 훑어 되살린다 |
| `/Length` 가 딴 객체를 가리키는 꼴 | 된다 (`len-ref.pdf`) |
| `/Length` 가 틀린 문서 | `endstream` 을 찾아 고친다 (`len-big.pdf`·`len-small.pdf`) |
| 쪽 나무 · 상속 속성 · `/Rotate` · `/CropBox` | 된다 |
| 목차 · 링크 · 이름 목적지(나무 포함) | 된다 |
| 딸린 파일(`/EmbeddedFiles`) | 꺼낸다 |
| 레이어(선택 콘텐츠, `/OCProperties`) | 켜고 끈다 |
| 증분 갱신 | 마지막 판을 읽는다 |

## 필터

FlateDecode(Predictor 포함) · LZWDecode · ASCIIHexDecode · ASCII85Decode ·
RunLengthDecode · DCTDecode · JPXDecode · JBIG2Decode · CCITTFaxDecode.

## 글꼴

| | |
|---|---|
| Type1 · CFF · TrueType · Type0(CID) · Type3 | 된다 |
| 표준 14종 | 이름을 보고 갈래(세리프·고정폭)를 맞춰 시스템 글꼴로 그린다. `fonts` 로 자리를 알려 주면 진짜 글꼴(Liberation Sans)을 받아 싣는다 |
| Identity-H · 미리 정의된 CMap(`cmaps/`) | 된다 |
| `/ToUnicode` 없는 옛 문서 | CMap 으로 되짚는다 (`cmap2.pdf`) |
| CIDToGIDMap | 된다 (`c2g.pdf`) |
| 세로쓰기(WMode 1) | 된다 (`vert.pdf`). 글자 자리는 `/W2`·`/DW2`(기본 [880 −1000]) 대로 — 현재 점에서 v 만큼 빼고 w1y 만큼 내려간다 |
| 브라우저가 거절하는 부분집합 글꼴 | `name`·`OS/2`·`post` 를 기워 다시 낸다 |

## 그림

DCTDecode 는 회색·RGB·CMYK·YCCK 를 다룬다 — 브라우저가 못 여는 4성분 JPEG 은
직접 푼다. JPX 는 5/3·9/7 웨이블릿, 타일, 다중 계층, 관심 구역(ROI), MCT,
회색·RGB. JBIG2 는 보통 영역(산술·MMR), 글자 영역, 글자 사전(산술·허프만,
사용자 표 포함), 정교화, 하프톤, globals. CCITT 는 G3 1D·2D 와 G4.

색은 DeviceGray·RGB·CMYK, Indexed, Separation·DeviceN(틴트 변환 함수 0·2·3·4형),
Lab, ICCBased(대체 색공간으로), 1·2·4·8·16 비트.

`/Mask` 는 스텐실과 색 열쇠 두 갈래, `/SMask` 는 ExtGState 쪽까지(가리개의
`/Matte` 미리 곱한 색도 되돌린다), 투명 그룹과 혼합 모드도 그린다. 셰이딩은
1·2·3·4·5·6·7형. `/Interpolate true` 인 그림은 키워 그릴 때도 부드럽게
한다(pdf.js 와 같고, poppler 는 안 한다).

## 양식과 서명

입력 칸(글상자·확인란·라디오·목록·단추)을 읽고, 값을 채우고, 새 칸을 만든다.
라디오는 같은 부모(`parent`)의 위젯끼리 한 묶음이다 — 하나를 켜서 저장하면
부모의 `/V` 와 형제 위젯의 `/AS` 까지 맞춰 쓴다(위젯 하나만 고치면 다른
뷰어는 옛 것이 켜진 채로 보인다).
칸의 틀(`/MK` 바탕·테두리색, `/BS` 굵기와 실선·점선·밑줄·도드라짐·파임)은
겉모습이 없어도 그리고, 채워 저장할 때 새 겉모습에 앞세운다 — 안 그러면
채운 칸의 테두리가 다른 뷰어에서 사라진다. 목록 상자의 첫 보이는 항목
(`/TI`)은 `topIndex` 로 준다.
전자 서명은 PKCS#7 을 뜯어 WebCrypto 로 맞춰 보고, 서명 이후 문서가
바뀌었는지(`/ByteRange` 가 파일 전체를 덮는지)까지 본다.

## 파일 묶음 (포트폴리오)

`/Collection` 이 있으면 그 문서의 쪽은 표지일 뿐이고 알맹이는 딸린 파일이다
(규격 §12.3.5). `collection` 으로 알려 준다 — 보기(자세히·타일·숨김), 처음 열
파일, 목록에 보일 칸(`/Schema` 의 열쇠·이름표·차례·갈래)까지. 파일 자체는
`attachments` 로 꺼낸다.

## XFA 양식

PDF 2.0 에서 폐기됐지만 아직 돌아다닌다. `pdf.isXfa` 로 알아보고, `readXfa()`
로 XML 을 뜯어 `drawXfa()` 로 그린다 — 쪽 크기·자리(단위 옮기기 포함)·이름표와
칸·템플릿과 `datasets` 양쪽의 값을 읽는다. 서식을 스크립트로 바꾸는 동적 XFA 도
편다.

## 문서 안 JavaScript

양식 계산식(`/AA`·`/CO`)을 돌린다. 브라우저의 `eval` 을 쓰지 않고 작은 해석기
(`jsmini`)로 읽어 푼다 — 전역도, `fetch` 도, 프로토타입을 타고 밖으로 빠질 길도
없다. `/OpenAction` 의 자유 스크립트는 돌리지 않는다.

## 암호

읽기: RC4 40·128, AES-128, AES-256(R6). 사용자 암호와 소유자 암호 모두.
쓰기: AES-256(R6).

## 아직 못 하는 것

- **공개키 암호**(`/Adobe.PubSec`) — 다루지 않는다.
- **전달 함수**(`/TR`·`/TR2`) — 색값을 다시 매기는 것인데 안 본다. pdf.js 도
  안 본다. 하프톤(`/HT`)·중복 인쇄(`/OP`)·렌더링 의도(`/RI`) 같은 인쇄용
  지시도 마찬가지다.
- **겉모습 없는 메모 아이콘** — 주석은 `/AP /N` 겉모습 스트림을 그린다(`/AS` 로
  상태를 고르고 숨김 깃발을 지킨다). 겉모습이 없으면 네모·동그라미·선·잉크·
  형광펜·밑줄·취소선·물결·다각형·꺾은선은 규격의 기본 모양으로 대신 그린다
  (pdf.js·poppler 와 1% 안). 글상자 `/FreeText` 도 `/C` 바탕·`/DA` 색의
  테두리와 글로 그린다(poppler 와 1% 안; pdf.js 는 글만). 메모 아이콘
  `/Text` 만 안 그린다 — 아이콘 그림이 뷰어마다 다르다.

`tests/gap.mjs` 는 "아직 안 만든 것" 을 견본으로 못 박는 자리다 — 지금은 비어
있다. 여섯(`/BS`·`/Interpolate`·`/Matte`·라디오 묶음·`/TI`·`/W2`)을 다 만들어
진짜 시험으로 옮겼다. 새 빈틈이 드러나면 거기에 먼저 못 박는다.
