// 콘텐츠 스트림을 그리기 명령 목록으로 옮긴다.
//
// PDF.js 가 하는 방식과 같은 뼈대다 — 파싱한 결과를 연산자 목록으로 만들어
// 넘기고, 실제 그리기는 캔버스 쪽이 맡는다. 좌표 변환(cm)을 우리가 계산해
// 좌표에 곱하지 않고 캔버스의 transform 에 그대로 넘기는 것이 요점이다.
// 그래야 선 굵기·클리핑·글자 크기가 함께 변환되어 원본과 어긋나지 않는다.
//
// 명령 하나는 [코드, 인자 수, 인자...] 로 f32 배열에 쌓는다.

pub const OP_MOVE: f32 = 1;
pub const OP_LINE: f32 = 2;
pub const OP_CURVE: f32 = 3;
pub const OP_CLOSE: f32 = 4;
pub const OP_RECT: f32 = 5;
pub const OP_FILL: f32 = 6; // arg: evenodd
pub const OP_STROKE: f32 = 7;
pub const OP_FILLSTROKE: f32 = 8; // arg: evenodd
pub const OP_ENDPATH: f32 = 9;
pub const OP_CLIP: f32 = 10; // arg: evenodd
pub const OP_FILLCOLOR: f32 = 11; // r,g,b
pub const OP_STROKECOLOR: f32 = 12; // r,g,b
pub const OP_LINEWIDTH: f32 = 13;
pub const OP_SAVE: f32 = 14;
pub const OP_RESTORE: f32 = 15;
pub const OP_TRANSFORM: f32 = 16; // a,b,c,d,e,f
pub const OP_TEXT: f32 = 17; // x,y,size,off,len,fontIdx,a,b,c,d,adv — 글자 하나
pub const OP_IMAGE: f32 = 18; // 이 페이지의 그림을 현재 변환으로 그린다
pub const OP_LINECAP: f32 = 19;
pub const OP_LINEJOIN: f32 = 20;
pub const OP_ALPHA: f32 = 21; // 채우기 투명도
pub const OP_INLINE: f32 = 22; // 콘텐츠에 바로 박힌 그림
pub const OP_SALPHA: f32 = 23; // 획 투명도
pub const OP_DASH: f32 = 24; // 점선: 개수, 값 6개, 간격
pub const OP_MITER: f32 = 25;
pub const OP_BLEND: f32 = 26; // 섞는 방식
pub const OP_SHFILL: f32 = 27; // 셰이딩으로 영역 채우기
pub const OP_SHCOLOR: f32 = 28; // 셰이딩을 채우기 색으로
pub const OP_TEXTCLIP: f32 = 29; // 글자 묶음이 끝났다 — 모은 글자 모양으로 오려 낸다
pub const OP_SMASK_BEGIN: f32 = 30; // 부드러운 가리개를 그리기 시작한다 (종류, 바탕색)
pub const OP_SMASK_END: f32 = 31; // 가리개 다 그렸다 — 이제부터 이 가리개로 오린다
pub const OP_SMASK_OFF: f32 = 32; // /SMask /None — 오려 내던 것을 얹고 끝낸다
