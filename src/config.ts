// 파일을 어디에 두었는지 알려 주는 자리.
//
// wasm 과 CMap 표는 번들에 못 담는다(각각 290KB·7MB). 쓰는 쪽이 어디에
// 올려 두었는지 여기로 알려 준다. 워커 안에서도 같은 값을 봐야 해서
// 열 때 함께 넘긴다.
export type Paths = {
  /** pdf.wasm 주소. 기본값은 같은 폴더의 ./pdf.wasm */
  wasm?: string;
  /** 미리 정의된 CMap 표가 있는 폴더. 없으면 그 표를 쓰는 옛 문서의 글자가 깨진다. */
  cmaps?: string;
};

/**
 * Node 인가.
 *
 * 브라우저에서는 쓰는 쪽이 올려 둔 자리를 상대 주소로 찾지만, Node 에는
 * 그 기준이 될 페이지가 없다. 꾸러미 안 자리를 바로 가리킨다.
 *
 * window 가 있으면 브라우저로 본다 — jsdom·Electron 처럼 Node 위에서
 * 도는 브라우저 흉내에서는 fetch 가 맞다. 이 판정을 파일 읽는 쪽과 나눠
 * 쓰지 않으면, 한쪽은 상대 주소를 두고 다른 쪽은 파일을 찾아 어긋난다.
 */
export const onNode =
  !!(globalThis as { process?: { versions?: { node?: string } } }).process?.versions?.node &&
  typeof (globalThis as { window?: unknown }).window === "undefined";

export const DEFAULTS: Required<Paths> = {
  wasm: onNode ? new URL("./pdf.wasm", import.meta.url).href : "./pdf.wasm",
  cmaps: onNode ? new URL("../cmaps", import.meta.url).href : "./cmaps",
};
