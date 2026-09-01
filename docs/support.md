# 무엇까지 되나

시험으로 확인한 것만 적는다. `bash tests/run.sh` 가 도는 단언 330개가
이 표의 근거다 — 붙임감은 `tests/fixtures/` 에 있다.

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
| 표준 14종 | 시스템 글꼴로 대신한다 |
| Identity-H · 미리 정의된 CMap(`cmaps/`) | 된다 |
| `/ToUnicode` 없는 옛 문서 | CMap 으로 되짚는다 (`cmap2.pdf`) |
| CIDToGIDMap | 된다 (`c2g.pdf`) |
| 세로쓰기(WMode 1) | 된다 (`vert.pdf`) |
| 브라우저가 거절하는 부분집합 글꼴 | `name`·`OS/2`·`post` 를 기워 다시 낸다 |

## 그림

DCTDecode 는 회색·RGB·CMYK·YCCK 를 다룬다 — 브라우저가 못 여는 4성분 JPEG 은
직접 푼다. JPX 는 5/3·9/7 웨이블릿, 타일, 다중 계층, 관심 구역(ROI), MCT,
회색·RGB. JBIG2 는 보통 영역(산술·MMR), 글자 영역, 글자 사전(산술·허프만,
사용자 표 포함), 정교화, 하프톤, globals. CCITT 는 G3 1D·2D 와 G4.

색은 DeviceGray·RGB·CMYK, Indexed, Separation·DeviceN(틴트 변환 함수 0·2·3·4형),
Lab, ICCBased(대체 색공간으로), 1·2·4·8·16 비트.

`/Mask` 는 스텐실과 색 열쇠 두 갈래, `/SMask` 는 ExtGState 쪽까지, 투명 그룹과
혼합 모드도 그린다. 셰이딩은 1·2·3·4·5·6·7형.

## 양식과 서명

입력 칸(글상자·확인란·라디오·목록·단추)을 읽고, 값을 채우고, 새 칸을 만든다.
전자 서명은 PKCS#7 을 뜯어 WebCrypto 로 맞춰 보고, 서명 이후 문서가
바뀌었는지(`/ByteRange` 가 파일 전체를 덮는지)까지 본다.

## 암호

읽기: RC4 40·128, AES-128, AES-256(R6). 사용자 암호와 소유자 암호 모두.
쓰기: AES-256(R6).

## 아직 못 하는 것

- **XFA 양식** — 쪽을 그리지 않는다. `pdf.isXfa` 로 알려 주므로 화면에서
  안내를 띄우면 된다. (XFA 는 PDF 2.0 에서 폐기됐다.)
- **공개키 암호**(`/Adobe.PubSec`) — 다루지 않는다.
- **문서 안 JavaScript**(`/AA`·`/OpenAction`) — 실행하지 않는다. 뷰어가
  스크립트를 돌리지 않는 편이 안전하다고 봤다.
- **겉모습 없는 주석** — 주석은 `/AP /N` 겉모습 스트림을 그린다(`/AS` 로 상태를
  고르고 숨김 깃발을 지킨다). 겉모습이 없는 주석을 뷰어가 대신 그려 주지는
  않는다.
