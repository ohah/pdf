// PDF 엔진을 딴 갈래(워커)에서 돌린다.
//
// 예전에는 모두 화면 갈래에서 했다. 큰 문서를 열면 파싱과 쪽 뽑기가 끝날
// 때까지 화면이 멎었다 — 스크롤도 단추도 안 먹었다. wasm 과 그 둘레를
// 통째로 여기로 옮긴다. 화면 갈래는 그린 결과만 받아 canvas 에 얹는다.
//
// 여기 남길 수 없는 것이 둘 있다.
//   · FontFace 등록 — 글꼴은 문서(document)에 달아야 해서 화면 갈래 몫이다.
//     날바이트만 넘겨 준다.
//   · 화면 글꼴로 글자를 그려 만드는 그림(한글 워터마크·라벨) — 마찬가지다.
//     화면 쪽이 그려서 비트를 넘겨 준다.
//
// 오가는 큰 자료는 transfer 로 넘긴다. 복사가 아니라 소유권만 옮기므로
// 수 MB 짜리 명령 목록도 값이 안 든다.
import { cmapBase, loadCmaps, setCmapBase } from "./cmaps.js";
import { loadBytes } from "./bytes.js";
import { DEFAULTS } from "./config.js";

type Exports = {
  memory: WebAssembly.Memory;
  inputPtr: () => number;
  outputPtr: () => number;
  maxInput: () => number;
  reserve: (wantIn: number, wantOut: number) => number;
  renderPage: (i: number) => number;
  imageCount: () => number;
  imageWidth: () => number;
  imageHeight: () => number;
  imageKind: () => number;
  imagePtr: () => number;
  imageLen: () => number;
  compact: () => number;
  opsPtr: () => number;
  opsLen: () => number;
  fontCount: () => number;
  fontFileOff: (i: number) => number;
  fontFileLen: (i: number) => number;
  fontAreaPtr: () => number;
  itemX: (i: number) => number;
  itemY: (i: number) => number;
  itemSize: (i: number) => number;
  itemOff: (i: number) => number;
  itemLen: (i: number) => number;
  textPtr: () => number;
  textLen: () => number;
  drawPtr: () => number;
  readPtr?: () => number;
  readLen?: () => number;
  drawLen: () => number;
  fontIsPua: (i: number) => number;
  fontKind?: (i: number) => number;
  fontNamePtr?: (i: number) => number;
  fontNameLen?: (i: number) => number;
  formCount?: () => number;
  inlinePtr?: () => number;
  imageAreaPtr?: () => number;
  imageSlots?: () => number;
  slotKind?: (i: number) => number;
  slotWidth?: (i: number) => number;
  slotHeight?: (i: number) => number;
  slotOff?: (i: number) => number;
  slotLen?: (i: number) => number;
  slotFlip?: (i: number) => number;
  slotSMask?: (i: number) => number;
  pageWidth: () => number;
  pageOriginX?: () => number;
  pageOriginY?: () => number;
  pageRotate?: () => number;
  linkCount?: () => number;
  linkRect?: (i: number, k: number) => number;
  linkOff?: (i: number) => number;
  linkLen?: (i: number) => number;
  linkPage?: (i: number) => number;
  linkTextPtr?: () => number;
  outlineCount?: () => number;
  outlineDepth?: (i: number) => number;
  outlineOff?: (i: number) => number;
  outlineLen?: (i: number) => number;
  outlinePage?: (i: number) => number;
  outlineTextPtr?: () => number;
  infoCount?: () => number;
  infoOff?: (i: number) => number;
  infoLen?: (i: number) => number;
  infoTextPtr?: () => number;
  pageHeight: () => number;
  secondPtr: () => number;
  maxSecond: () => number;
  parseSecond: (len: number) => number;
  secondPageCount: () => number;
  outCapacity: () => number;
  inputLen: () => number;
  merge: () => number;
  clearWatermark: () => void;
  addWatermarkChar: (c: number) => void;
  clearLabels?: () => void;
  addLabel?: (page: number, x: number, y: number, size: number, r: number, g: number, b: number) => number;
  addLabelChar?: (c: number) => void;
  outputLen: () => number;
  pageCount: () => number;
  pagesTruncated?: () => number;
  parse: (len: number) => number;
  setFormLayer?: (on: number) => void;
  clearNotes?: () => void;
  addNote?: (kind: number, page: number, x0: number, y0: number, x1: number, y1: number,
    r: number, g: number, b: number) => number;
  addNoteChar?: (c: number) => void;
  addNotePoint?: (x: number, y: number) => void;
  clearPageRotate?: () => void;
  setPageRotate?: (page: number, deg: number) => void;
  clearNewFields?: () => void;
  addNewField?: (page: number, kind: number, x0: number, y0: number, x1: number, y1: number) => number;
  addNewFieldChar?: (c: number) => void;
  clearFieldEdits?: () => void;
  addFieldEdit?: (obj: number, kind: number) => number;
  addFieldEditChar?: (c: number) => void;
  fieldMaskPtr?: () => number;
  fieldMaskRoom?: () => number;
  setFieldEditMask?: (w: number, h: number, len: number) => number;
  setLabelMask?: (w: number, h: number, len: number, pw: number, ph: number) => number;
  setWatermarkMask?: (w: number, h: number, len: number, pw: number, ph: number) => number;
  isXfa?: () => number;
  permissions?: () => number;
  itemFont?: (i: number) => number;
  structCount?: () => number;
  structDepth?: (i: number) => number;
  structPageOf?: (i: number) => number;
  structMcid?: (i: number) => number;
  structRoleOff?: (i: number) => number;
  structRoleLen?: (i: number) => number;
  structAltOff?: (i: number) => number;
  structAltLen?: (i: number) => number;
  structTextPtr?: () => number;
  itemVertical?: (i: number) => number;
  destCount?: () => number;
  destNameOff?: (i: number) => number;
  destNameLen?: (i: number) => number;
  destPageOf?: (i: number) => number;
  destTextPtr?: () => number;
  viewPrefCount?: () => number;
  viewPrefKeyOff?: (i: number) => number;
  viewPrefKeyLen?: (i: number) => number;
  viewPrefValOff?: (i: number) => number;
  viewPrefValLen?: (i: number) => number;
  viewPrefTextPtr?: () => number;
  xmpLen?: () => number;
  xmpPtr?: () => number;
  annCount?: () => number;
  annObj?: (i: number) => number;
  annFlags?: (i: number) => number;
  annRect?: (i: number, k: number) => number;
  annHasColor?: (i: number) => number;
  annColor?: (i: number, k: number) => number;
  annTextPtr?: () => number;
  annSubOff?: (i: number) => number;
  annSubLen?: (i: number) => number;
  annBodyOff?: (i: number) => number;
  annBodyLen?: (i: number) => number;
  annAuthorOff?: (i: number) => number;
  annAuthorLen?: (i: number) => number;
  annDateOff?: (i: number) => number;
  annDateLen?: (i: number) => number;
  metaCount?: () => number;
  metaOff?: (i: number) => number;
  metaLen?: (i: number) => number;
  metaTextPtr?: () => number;
  pageLabelCount?: () => number;
  pageLabelOff?: (i: number) => number;
  pageLabelLen?: (i: number) => number;
  pageLabelPtr?: () => number;
  attCount?: () => number;
  attTextPtr?: () => number;
  attNameOff?: (i: number) => number;
  attNameLen?: (i: number) => number;
  attLoad?: (i: number) => number;
  attPtr?: () => number;
  ocCount?: () => number;
  ocTextPtr?: () => number;
  ocNameOff?: (i: number) => number;
  ocNameLen?: (i: number) => number;
  ocIsOn?: (i: number) => number;
  setOcOn?: (i: number, on: number) => void;
  sigCount?: () => number;
  sigRange?: (i: number, k: number) => number;
  sigTextPtr?: () => number;
  sigDerOff?: (i: number) => number;
  sigDerLen?: (i: number) => number;
  sigNameOff?: (i: number) => number;
  sigNameLen?: (i: number) => number;
  sigDateOff?: (i: number) => number;
  sigDateLen?: (i: number) => number;
  sigReasonOff?: (i: number) => number;
  sigReasonLen?: (i: number) => number;
  sigSubOff?: (i: number) => number;
  sigSubLen?: (i: number) => number;
  sigCovers?: (i: number) => number;
  clearPassword?: () => void;
  addPasswordChar?: (c: number) => void;
  needPassword?: () => number;
  isEncrypted?: () => number;
  setEncrypt?: (on: number) => void;
  addEncryptChar?: (c: number) => void;
  encRandomPtr?: () => number;
  fieldCount?: () => number;
  fieldObj?: (i: number) => number;
  fieldRect?: (i: number, k: number) => number;
  fieldKind?: (i: number) => number;
  fieldFlags?: (i: number) => number;
  fieldMaxLen?: (i: number) => number;
  fieldSize?: (i: number) => number;
  fieldAlign?: (i: number) => number;
  fieldChecked?: (i: number) => number;
  fieldTextPtr?: () => number;
  fieldNameOff?: (i: number) => number;
  fieldNameLen?: (i: number) => number;
  fieldValOff?: (i: number) => number;
  fieldValLen?: (i: number) => number;
  fieldOnOff?: (i: number) => number;
  fieldOnLen?: (i: number) => number;
  fieldOptsOff?: (i: number) => number;
  fieldOptsLen?: (i: number) => number;
  needCount?: () => number;
  needOff?: (i: number) => number;
  needLen?: (i: number) => number;
  needPtr?: () => number;
  cmapReset?: () => void;
  cmapPtr?: () => number;
  cmapRoom?: () => number;
  cmapAdd?: (idx: number, len: number) => number;
  clearPick: () => void;
  addPick: (i: number) => void;
  setRotate: (deg: number) => void;
  apply: () => number;
};

// 워커 전역. tsconfig 의 lib 에 WebWorker 를 넣으면 DOM 타입과 부딪치므로
// 여기서 쓰는 것만 좁게 적는다.
declare const self: {
  onmessage: ((ev: MessageEvent) => void) | null;
  postMessage: (m: unknown, transfer?: Transferable[]) => void;
};

let ex: Exports | null = null;
/**
 * 컴파일한 wasm. 자리(주소)마다 따로 담는다.
 *
 * 하나만 담아 두면, 자리를 잘못 알려 준 문서도 앞서 담아 둔 것으로 열려
 * 버린다 — 설정이 틀렸는데 되는 것처럼 보이고, 판이 다른 wasm 을 가리켜도
 * 조용히 옛것이 쓰인다. 워커가 하나씩 뜨는 브라우저에서는 안 겪지만
 * Node 처럼 한 모듈을 나눠 쓰는 곳에서는 겪는다.
 */
const mods = new Map<string, WebAssembly.Module>();
const dec = new TextDecoder();

const wasi = {
  args_get: () => 0,
  args_sizes_get: () => 0,
  proc_exit: () => { throw new Error("proc_exit"); },
};

let wasmPath = DEFAULTS.wasm;



async function engine() {
  if (ex) return ex;
  if (typeof WebAssembly === "undefined") {
    throw new Error("this browser has no WebAssembly — the PDF engine cannot run here");
  }
  let mod = mods.get(wasmPath);
  if (!mod) {
    const wasmBytes = await loadBytes(wasmPath);
    if (!wasmBytes) throw new Error(`could not load the PDF engine from ${wasmPath}`);
    // 받아 온 것이 wasm 이 맞는지 본다.
    //
    // 자리를 잘못 적으면 서버가 404 대신 안내 쪽(HTML)을 200 으로 준다.
    // 그대로 컴파일하면 "expected magic word 00 61 73 6d" 라는 말만 남아,
    // 무엇을 잘못했는지 알 길이 없다.
    const magic = wasmBytes[0] === 0x00 && wasmBytes[1] === 0x61
      && wasmBytes[2] === 0x73 && wasmBytes[3] === 0x6d;
    if (!magic) {
      const head = new TextDecoder().decode(wasmBytes.slice(0, 16)).replace(/\s+/g, " ").trim();
      const looksHtml = /^<!?[a-z]/i.test(head);
      throw new Error(
        `${wasmPath} is not the PDF engine (wasm)`
        + (looksHtml ? " — the server returned a web page there; check the path" : ` — starts with "${head}"`),
      );
    }
    // 컴파일 결과는 같은 자리를 보는 사례끼리 나눠 쓴다 — 무거운 건 이것뿐이다
    mod = await WebAssembly.compile(wasmBytes);
    mods.set(wasmPath, mod);
  }
  const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi });
  ex = inst.exports as unknown as Exports;
  return ex;
}

/**
 * 워커 없이 돌 때 쓰는 엔진 사례 한 벌.
 *
 * 브라우저에서는 문서마다 워커가 따로라 서로 섞일 일이 없다. Node 에는
 * 워커가 없어 모듈 하나를 여럿이 나눠 쓰는데, 엔진 상태가 모듈에 있으면
 * 문서를 두 개 열었을 때 뒤엣것이 앞엣것을 덮어쓴다 — 앞 문서에 글자를
 * 물으면 뒤 문서의 글자가 나왔다. 문서마다 제 사례를 들고 다니게 한다.
 */
export type Slot = { ex: Exports | null; wasm: string; cmaps: string };

export function newSlot(): Slot {
  return { ex: null, wasm: DEFAULTS.wasm, cmaps: DEFAULTS.cmaps };
}

/** 모듈 상태를 이 사례의 것으로 갈아 끼우고 일을 시킨다. 한 줄로 세운다. */
let gate: Promise<unknown> = Promise.resolve();

export function runWork(slot: Slot, t: string, a: unknown): Promise<{ r: unknown }> {
  const done = gate.then(async () => {
    const keepEx = ex;
    const keepWasm = wasmPath;
    const keepCmaps = cmapBase();
    ex = slot.ex;
    wasmPath = slot.wasm;
    setCmapBase(slot.cmaps);
    try {
      return await doWork(t, a);
    } finally {
      // 이번에 만든 사례와 바뀐 자리를 이 슬롯에 담아 두고 원래대로 돌린다
      slot.ex = ex;
      slot.wasm = wasmPath;
      slot.cmaps = cmapBase();
      ex = keepEx;
      wasmPath = keepWasm;
      setCmapBase(keepCmaps);
    }
  });
  gate = done.then(() => {}, () => {});
  return done;
}

/**
 * 그림을 만들 수 있는 곳인가.
 *
 * Node 에는 createImageBitmap 도 OffscreenCanvas 도 없다. 글자·주석·양식만
 * 뽑는 데는 그림이 필요 없으므로, 없으면 그림 자리를 비워 두고 나머지는
 * 그대로 준다 — 예외를 던져 통째로 못 쓰게 만들지 않는다.
 */
const canImage =
  typeof createImageBitmap === "function" && typeof OffscreenCanvas === "function";

async function decodeImage(
  kind: number, iw: number, ih: number, raw: Uint8Array,
  alpha?: { w: number; h: number; bytes: Uint8Array },
) {
  if (kind === 0 || iw === 0 || ih === 0 || !canImage) return undefined;
  try {
    if (kind === 3) {
      // JPEG 은 브라우저가 푼다
      const bmp = await createImageBitmap(new Blob([raw as BlobPart], { type: "image/jpeg" }), {
        resizeWidth: Math.min(iw, 1600), resizeQuality: "medium",
      });
      if (!alpha) return bmp;
      // 부드러운 마스크를 투명도로 얹는다
      const cv = new OffscreenCanvas(bmp.width, bmp.height);
      const c = cv.getContext("2d");
      if (!c) return bmp;
      c.drawImage(bmp, 0, 0);
      const id = c.getImageData(0, 0, cv.width, cv.height);
      for (let y = 0; y < cv.height; y++) {
        const sy = Math.min(alpha.h - 1, Math.floor((y * alpha.h) / cv.height));
        for (let x = 0; x < cv.width; x++) {
          const sx = Math.min(alpha.w - 1, Math.floor((x * alpha.w) / cv.width));
          id.data[(y * cv.width + x) * 4 + 3] = alpha.bytes[sy * alpha.w + sx] ?? 255;
        }
      }
      c.putImageData(id, 0, 0);
      return await createImageBitmap(cv);
    }
    const rgba = new Uint8ClampedArray(iw * ih * 4);
    const comps = kind === 1 ? 3 : 1;
    for (let k = 0, s2 = 0, d2 = 0; k < iw * ih; k++, s2 += comps, d2 += 4) {
      if (comps === 3) {
        rgba[d2] = raw[s2]; rgba[d2 + 1] = raw[s2 + 1]; rgba[d2 + 2] = raw[s2 + 2];
      } else {
        rgba[d2] = rgba[d2 + 1] = rgba[d2 + 2] = raw[s2];
      }
      rgba[d2 + 3] = alpha
        ? (alpha.bytes[Math.min(alpha.h - 1, Math.floor((Math.floor(k / iw) * alpha.h) / ih)) * alpha.w
            + Math.min(alpha.w - 1, Math.floor(((k % iw) * alpha.w) / iw))] ?? 255)
        : 255;
    }
    return await createImageBitmap(new ImageData(rgba, iw, ih), {
      resizeWidth: Math.min(iw, 1600), resizeQuality: "medium",
    });
  } catch {
    return undefined; // 못 풀면 안내로 넘어간다
  }
}

export type Mask = { w: number; h: number; pw: number; ph: number; bits: Uint8Array };

/** 만들기 한 번에 필요한 것을 전부 담은 꾸러미. 화면 상태를 그대로 옮긴 것이다. */
export type BuildSpec = {
  pick: number[];
  rotate: number;
  pageRot: [number, number][];
  watermark: string;
  wmMask?: Mask;
  fields: { obj: number; kind: number; text: string; mask?: Mask }[];
  newFields: { page: number; kind: number; rect: [number, number, number, number]; name: string }[];
  notes: {
    kind: number; page: number; rect: [number, number, number, number];
    rgb: [number, number, number]; text: string; pts: [number, number][];
  }[];
  labels: {
    page: number; x: number; y: number; size: number;
    rgb: [number, number, number]; text: string; mask?: Mask;
  }[];
  shrink: boolean;
  encryptPw?: string;
};

function putMask(e: Exports, m: Mask) {
  if (!e.fieldMaskPtr || !e.fieldMaskRoom) return false;
  if (m.bits.length > e.fieldMaskRoom()) return false;
  new Uint8Array(e.memory.buffer, e.fieldMaskPtr(), m.bits.length).set(m.bits);
  return true;
}

function chars(e: Exports, s: string, put: (c: number) => void) {
  for (const ch of s) put(ch.codePointAt(0) ?? 0);
}

/** 아랍·히브리처럼 오른쪽에서 왼쪽으로 쓰는 글자가 많은가 */
function rtl(t: string): boolean {
  let r = 0;
  let l = 0;
  for (const ch of t) {
    const c = ch.codePointAt(0)!;
    if ((c >= 0x0590 && c <= 0x08ff) || (c >= 0xfb1d && c <= 0xfdff) || (c >= 0xfe70 && c <= 0xfeff)) r++;
    else if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c > 0x2000) l++;
  }
  return r > l;
}

async function open(bytes: Uint8Array, pw: string) {
  const e = await engine();
  if (bytes.byteLength > e.maxInput()) return { err: "too-large", max: e.maxInput() };
  if (!e.reserve(bytes.byteLength, bytes.byteLength + 1024 * 1024)) return { err: "no-memory" };
  new Uint8Array(e.memory.buffer, e.inputPtr(), bytes.byteLength).set(bytes);
  e.clearPassword?.();
  chars(e, pw, (c) => e.addPasswordChar?.(c));
  const ok = e.parse(bytes.byteLength);
  if (e.needPassword?.()) return { needPw: true };
  if (!ok) return { err: "트리" };
  await loadCmaps(e as unknown as Parameters<typeof loadCmaps>[0]);
  const marks: { depth: number; title: string; page: number }[] = [];
  for (let i = 0; i < (e.outlineCount?.() ?? 0); i++) {
    marks.push({
      depth: e.outlineDepth!(i),
      title: dec.decode(new Uint8Array(e.memory.buffer,
        e.outlineTextPtr!() + e.outlineOff!(i), e.outlineLen!(i))),
      page: e.outlinePage!(i),
    });
  }
  const info: string[] = [];
  for (let i = 0; i < (e.infoCount?.() ?? 0); i++) {
    info.push(dec.decode(new Uint8Array(e.memory.buffer,
      e.infoTextPtr!() + e.infoOff!(i), e.infoLen!(i))));
  }
  // 전자 서명 — 뭉치와 자리만 넘긴다. 맞춰 보는 것은 화면 쪽 WebCrypto 다.
  const sigs = [];
  for (let i = 0; i < (e.sigCount?.() ?? 0); i++) {
    const T = (o: number, l: number) =>
      l > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.sigTextPtr!() + o, l)) : "";
    sigs.push({
      name: T(e.sigNameOff!(i), e.sigNameLen!(i)),
      date: T(e.sigDateOff!(i), e.sigDateLen!(i)),
      reason: T(e.sigReasonOff!(i), e.sigReasonLen!(i)),
      sub: T(e.sigSubOff!(i), e.sigSubLen!(i)),
      der: new Uint8Array(e.memory.buffer, e.sigTextPtr!() + e.sigDerOff!(i), e.sigDerLen!(i)).slice(),
      range: [0, 1, 2, 3].map((k) => e.sigRange!(i, k)),
      covers: e.sigCovers!(i) === 1,
    });
  }
  // 딸린 파일 — 이름만 먼저 준다. 내용은 받겠다고 할 때 꺼낸다.
  const atts = [];
  for (let i = 0; i < (e.attCount?.() ?? 0); i++) {
    atts.push({
      name: dec.decode(new Uint8Array(e.memory.buffer,
        e.attTextPtr!() + e.attNameOff!(i), e.attNameLen!(i))) || `붙임 ${i + 1}`,
    });
  }
  // 레이어(선택 콘텐츠) — 도면·지도 문서가 켜고 끌 거리를 담아 온다
  const layers = [];
  for (let i = 0; i < (e.ocCount?.() ?? 0); i++) {
    layers.push({
      name: dec.decode(new Uint8Array(e.memory.buffer,
        e.ocTextPtr!() + e.ocNameOff!(i), e.ocNameLen!(i))) || `레이어 ${i + 1}`,
      on: e.ocIsOn!(i) === 1,
    });
  }
  // 문서 한 벌 정보 — 뷰어가 처음 열 때 쓰는 것들
  const meta = (i: number) => {
    const n = e.metaLen?.(i) ?? 0;
    return n > 0
      ? dec.decode(new Uint8Array(e.memory.buffer, e.metaTextPtr!() + e.metaOff!(i), n))
      : "";
  };
  // 쪽 라벨(i, ii, A-1 …). 없으면 빈 배열이고 쓰는 쪽이 쪽 번호를 그대로 쓴다.
  const labels: string[] = [];
  for (let i = 0; i < (e.pageLabelCount?.() ?? 0); i++) {
    const n = e.pageLabelLen!(i);
    labels.push(n > 0
      ? dec.decode(new Uint8Array(e.memory.buffer, e.pageLabelPtr!() + e.pageLabelOff!(i), n))
      : "");
  }
  // 이름 목적지 — 목차·링크가 "3쪽" 대신 이름으로 가리키는 문서용
  const dests: { name: string; page: number }[] = [];
  for (let i = 0; i < (e.destCount?.() ?? 0); i++) {
    const n = e.destNameLen!(i);
    dests.push({
      name: n > 0
        ? dec.decode(new Uint8Array(e.memory.buffer, e.destTextPtr!() + e.destNameOff!(i), n))
        : "",
      page: e.destPageOf!(i),
    });
  }
  // 뷰어 설정 — 도구줄을 감출지, 제목을 창에 띄울지 …
  const prefs: Record<string, string> = {};
  for (let i = 0; i < (e.viewPrefCount?.() ?? 0); i++) {
    const T = (off: number, len: number) =>
      len > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.viewPrefTextPtr!() + off, len)) : "";
    const k = T(e.viewPrefKeyOff!(i), e.viewPrefKeyLen!(i));
    if (k) prefs[k] = T(e.viewPrefValOff!(i), e.viewPrefValLen!(i));
  }
  // XMP — 통째로 옮긴다. 뜯는 것은 쓰는 쪽 몫이다.
  const xn = e.xmpLen?.() ?? 0;
  const xmp = xn > 0
    ? dec.decode(new Uint8Array(e.memory.buffer, e.xmpPtr!(), xn))
    : "";

  // 구조 나무 — 태그 PDF 의 읽는 차례·뜻. 깊이를 붙여 납작하게 담는다.
  const struct: { depth: number; role: string; alt: string; page: number; mcid: number }[] = [];
  for (let i = 0; i < (e.structCount?.() ?? 0); i++) {
    const T = (off: number, len: number) =>
      len > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.structTextPtr!() + off, len)) : "";
    struct.push({
      depth: e.structDepth!(i),
      role: T(e.structRoleOff!(i), e.structRoleLen!(i)),
      alt: T(e.structAltOff!(i), e.structAltLen!(i)),
      page: e.structPageOf!(i),
      mcid: e.structMcid!(i),
    });
  }
  return {
    dests, prefs, xmp, struct,
    pages: e.pageCount(), locked: (e.isEncrypted?.() ?? 0) === 1,
    // 쪽이 너무 많아 뒤를 잘랐는가 — 조용히 잘라 놓고 다 보여 주는 척하지 않는다
    truncated: (e.pagesTruncated?.() ?? 0) === 1,
    outline: marks, info, sigs, layers, atts,
    xfa: (e.isXfa?.() ?? 0) === 1,
    perm: e.permissions?.() ?? -1,
    pageMode: meta(0), pageLayout: meta(1), fingerprint: meta(2),
    tagged: meta(3) === "1", lang: meta(4),
    labels: labels.some((t) => t.length > 0) ? labels : [],
  };
}

/**
 * 쪽 하나를 뽑는다.
 *
 * light 면 글자와 자리만 준다 — 찾기와 쪽 크기에 쓸 것이다. 그림과 글꼴은
 * 무거워서(스캔 한 쪽이 수십 MB) 화면에 들어올 때만 제대로 뽑는다.
 */
async function page(i: number, formOn: boolean, light = false) {
  const e = await engine();
  e.setFormLayer?.(formOn ? 1 : 0);
  const cnt = e.renderPage(i);
  const buf = new Uint8Array(e.memory.buffer, e.textPtr(), 256 * 1024);
  const items = [];
  for (let k = 0; k < cnt; k++) {
    const len = e.itemLen(k);
    if (!len) continue;
    const t = dec.decode(buf.subarray(e.itemOff(k), e.itemOff(k) + len)).replace(/\s+$/, "");
    if (!t) continue;
    // 글꼴 이름과 쓰는 방향까지 함께 — pdf.js 의 TextItem 이 주는 것들이다.
    const fi = e.itemFont?.(k) ?? 0;
    items.push({
      x: e.itemX(k), y: e.itemY(k), size: e.itemSize(k), text: t,
      font: fi > 0 && e.fontNamePtr && e.fontNameLen
        ? dec.decode(new Uint8Array(e.memory.buffer, e.fontNamePtr(fi - 1), e.fontNameLen(fi - 1)))
        : "",
      dir: (e.itemVertical?.(k) ?? 0) === 1 ? "ttb" : rtl(t) ? "rtl" : "ltr",
    });
  }
  const rawAt = (si: number) =>
    new Uint8Array(e.memory.buffer, e.imageAreaPtr!() + e.slotOff!(si), e.slotLen!(si)).slice();
  const slots = light ? 0 : (e.imageSlots?.() ?? 0);
  const bitmaps: (ImageBitmap | undefined)[] = [];
  const stencils: ({ w: number; h: number; flip: boolean; bytes: Uint8Array; key: string } | undefined)[] = [];
  for (let si = 0; si < slots; si++) {
    const k = e.slotKind!(si);
    const iw = e.slotWidth!(si);
    const ih = e.slotHeight!(si);
    if (k === 5) {
      // 아직 못 푸는 형식 — 자리만 알린다
      if (!canImage) { stencils.push(undefined); bitmaps.push(undefined); continue; }
      const cv = new OffscreenCanvas(Math.max(8, Math.min(iw, 400)), Math.max(8, Math.min(ih, 400)));
      const c2 = cv.getContext("2d");
      if (c2) {
        c2.fillStyle = "#e5e7eb";
        c2.fillRect(0, 0, cv.width, cv.height);
        c2.strokeStyle = "#9ca3af";
        c2.strokeRect(0.5, 0.5, cv.width - 1, cv.height - 1);
        c2.fillStyle = "#6b7280";
        c2.font = `${Math.max(9, cv.width / 16)}px system-ui, sans-serif`;
        c2.textAlign = "center";
        c2.fillText("지원하지 않는 그림 형식", cv.width / 2, cv.height / 2);
      }
      stencils.push(undefined);
      bitmaps.push(await createImageBitmap(cv).catch(() => undefined));
      continue;
    }
    if (k === 4) {
      stencils.push({ w: iw, h: ih, flip: (e.slotFlip?.(si) ?? 0) === 1, bytes: rawAt(si), key: `s${i}-${si}:` });
      bitmaps.push(undefined);
      continue;
    }
    stencils.push(undefined);
    const ms = e.slotSMask?.(si) ?? 0;
    const alpha = ms > 0
      ? { w: e.slotWidth!(ms - 1), h: e.slotHeight!(ms - 1), bytes: rawAt(ms - 1) }
      : undefined;
    bitmaps.push(await decodeImage(k, iw, ih, rawAt(si), alpha));
  }
  let bitmap = bitmaps[0];
  if (!light && slots === 0 && e.imageKind() !== 0) {
    const raw = new Uint8Array(e.memory.buffer, e.imagePtr(), e.imageLen()).slice();
    bitmap = await decodeImage(e.imageKind(), e.imageWidth(), e.imageHeight(), raw);
    if (bitmap) bitmaps.push(bitmap);
  }
  // 글꼴은 날바이트로 넘긴다 — FontFace 는 화면 갈래에서만 만들 수 있다
  const fonts: { bytes: Uint8Array | null; pua: boolean; name: string; kind: number; len: number }[] = [];
  const area = e.fontAreaPtr();
  for (let fi = 0; !light && fi < e.fontCount(); fi++) {
    const flen = e.fontFileLen(fi);
    fonts.push({
      bytes: flen ? new Uint8Array(e.memory.buffer, area + e.fontFileOff(fi), flen).slice() : null,
      pua: e.fontIsPua(fi) === 1,
      name: e.fontNamePtr && e.fontNameLen
        ? dec.decode(new Uint8Array(e.memory.buffer, e.fontNamePtr(fi), e.fontNameLen(fi)))
        : String(fi),
      kind: e.fontKind?.(fi) ?? 0,
      len: flen,
    });
  }
  const ops = light
    ? new Float32Array(0)
    : new Float32Array(e.memory.buffer, e.opsPtr(), e.opsLen()).slice();
  const txt = new Uint8Array(e.memory.buffer, e.textPtr(), e.textLen()).slice();
  const drw = new Uint8Array(e.memory.buffer, e.drawPtr(), e.drawLen()).slice();
  const rtx = e.readPtr && e.readLen
    ? new Uint8Array(e.memory.buffer, e.readPtr(), e.readLen()).slice()
    : drw;
  const links = [];
  for (let li = 0; li < (e.linkCount?.() ?? 0); li++) {
    const ulen = e.linkLen!(li);
    links.push({
      x0: e.linkRect!(li, 0), y0: e.linkRect!(li, 1),
      x1: e.linkRect!(li, 2), y1: e.linkRect!(li, 3),
      uri: ulen > 0
        ? dec.decode(new Uint8Array(e.memory.buffer, e.linkTextPtr!() + e.linkOff!(li), ulen))
        : "",
      page: e.linkPage!(li),
    });
  }
  // 주석 — 종류 가리지 않고 걷는다. 뷰어가 목록·툴팁을 만들 거리다.
  const annots = [];
  {
    const T = (off: number, len: number) =>
      len > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.annTextPtr!() + off, len)) : "";
    for (let ai = 0; ai < (e.annCount?.() ?? 0); ai++) {
      annots.push({
        obj: e.annObj!(ai),
        subtype: T(e.annSubOff!(ai), e.annSubLen!(ai)),
        rect: [0, 1, 2, 3].map((k) => e.annRect!(ai, k)) as [number, number, number, number],
        contents: T(e.annBodyOff!(ai), e.annBodyLen!(ai)),
        author: T(e.annAuthorOff!(ai), e.annAuthorLen!(ai)),
        date: T(e.annDateOff!(ai), e.annDateLen!(ai)),
        color: e.annHasColor!(ai) === 1
          ? ([0, 1, 2].map((k) => e.annColor!(ai, k)) as [number, number, number])
          : null,
        flags: e.annFlags!(ai),
      });
    }
  }
  // 링크 주석에는 목표(주소·쪽)를 채워 준다. 링크는 따로 걷어 두었으므로
  // 자리로 짝짓는다 — 같은 /Annots 를 두 번 훑지 않는다.
  for (const a of annots) {
    if (a.subtype !== "Link") continue;
    const hit = links.find((L) =>
      Math.abs(L.x0 - a.rect[0]) < 0.5 && Math.abs(L.y0 - a.rect[1]) < 0.5 &&
      Math.abs(L.x1 - a.rect[2]) < 0.5 && Math.abs(L.y1 - a.rect[3]) < 0.5);
    if (hit) {
      (a as typeof a & { uri: string; page: number }).uri = hit.uri;
      (a as typeof a & { uri: string; page: number }).page = hit.page;
    }
  }
  let inlMax = 0;
  for (let k = 0; k + 1 < ops.length;) {
    const argc = ops[k + 1];
    if (ops[k] === 22) inlMax = Math.max(inlMax, ops[k + 2 + 4] + ops[k + 2 + 5]);
    k += 2 + argc;
  }
  const inline = inlMax > 0 && e.inlinePtr
    ? new Uint8Array(e.memory.buffer, e.inlinePtr(), inlMax).slice()
    : new Uint8Array(0);
  // 입력 칸
  const S = (o: number, l: number) =>
    l > 0 ? dec.decode(new Uint8Array(e.memory.buffer, e.fieldTextPtr!() + o, l)) : "";
  const fields = [];
  for (let k = 0; k < (e.fieldCount?.() ?? 0); k++) {
    fields.push({
      obj: e.fieldObj!(k), kind: e.fieldKind!(k), flags: e.fieldFlags!(k),
      maxLen: e.fieldMaxLen!(k), size: e.fieldSize!(k), align: e.fieldAlign!(k),
      rect: [0, 1, 2, 3].map((q) => e.fieldRect!(k, q)) as [number, number, number, number],
      name: S(e.fieldNameOff!(k), e.fieldNameLen!(k)),
      value: S(e.fieldValOff!(k), e.fieldValLen!(k)),
      // 켜짐 이름은 위젯의 /AP /N 에서 읽는다. 겉모습이 없는 확인란은 비어
      // 나오는데, 그대로 두면 켜서 저장해도 /Off 로 적힌다. 규격의 기본값을 쓴다.
      on: S(e.fieldOnOff!(k), e.fieldOnLen!(k)) || "Yes",
      opts: S(e.fieldOptsOff!(k), e.fieldOptsLen!(k)),
      checked: e.fieldChecked!(k) === 1,
    });
  }
  return {
    w: e.pageWidth(), h: e.pageHeight(), x0: e.pageOriginX?.() ?? 0, y0: e.pageOriginY?.() ?? 0,
    rot: e.pageRotate?.() ?? 0, items, ops, txt, drw, rtx, links, annots, inline, fields,
    fonts, bitmaps, stencils, bitmap, images: e.imageCount(), forms: e.formCount?.() ?? 0,
    light,
  };
}

/** 꾸러미대로 다시 만든다. 옛 run() 이 하던 일을 그대로 옮긴 것이다. */
async function build(spec: BuildSpec) {
  const e = await engine();
  e.clearPick();
  for (const i of spec.pick) e.addPick(i);
  e.setRotate(spec.rotate);
  e.clearPageRotate?.();
  for (const [pg, deg] of spec.pageRot) e.setPageRotate?.(pg, deg);
  e.clearWatermark();
  chars(e, spec.watermark, (c) => e.addWatermarkChar(c));
  if (spec.wmMask && e.setWatermarkMask && putMask(e, spec.wmMask)) {
    const m = spec.wmMask;
    e.setWatermarkMask(m.w, m.h, m.bits.length, m.pw, m.ph);
  }
  e.clearFieldEdits?.();
  e.clearNewFields?.();
  let touched = 0;
  for (const f of spec.fields) {
    if (!e.addFieldEdit?.(f.obj, f.kind)) continue;
    chars(e, f.text, (c) => e.addFieldEditChar?.(c));
    if (f.mask && e.setFieldEditMask && putMask(e, f.mask)) {
      e.setFieldEditMask(f.mask.w, f.mask.h, f.mask.bits.length);
    }
    touched++;
  }
  for (const f of spec.newFields) {
    if (!e.addNewField?.(f.page, f.kind, f.rect[0], f.rect[1], f.rect[2], f.rect[3])) continue;
    chars(e, f.name, (c) => e.addNewFieldChar?.(c));
    touched++;
  }
  e.clearNotes?.();
  for (const n of spec.notes) {
    if (!e.addNote?.(n.kind, n.page, n.rect[0], n.rect[1], n.rect[2], n.rect[3],
      n.rgb[0], n.rgb[1], n.rgb[2])) continue;
    if (n.kind === 6) for (const q of n.pts) e.addNotePoint?.(q[0], q[1]);
    else chars(e, n.text, (c) => e.addNoteChar?.(c));
  }
  e.clearLabels?.();
  for (const L of spec.labels) {
    if (!e.addLabel?.(L.page, L.x, L.y, L.size, L.rgb[0], L.rgb[1], L.rgb[2])) continue;
    chars(e, L.text, (c) => e.addLabelChar?.(c));
    if (L.mask && e.setLabelMask && putMask(e, L.mask)) {
      e.setLabelMask(L.mask.w, L.mask.h, L.mask.bits.length, L.mask.pw, L.mask.ph);
    }
  }
  // 줄이기는 원본을 다시 쓰는 길이라 얹거나 채우는 것과 같이 못 간다
  const plain = spec.rotate === 0 && !spec.watermark && spec.labels.length === 0
    && touched === 0 && spec.pageRot.length === 0 && spec.notes.length === 0;
  const n = spec.shrink && plain ? e.compact() : e.apply();
  if (!n) return null;
  let out = new Uint8Array(e.memory.buffer, e.outputPtr(), n).slice();
  if (spec.encryptPw !== undefined) {
    const sealed = await seal(out, spec.encryptPw);
    if (!sealed) return null;
    out = sealed;
  }
  return out;
}

/** 다 만든 바이트에 암호를 건다. 보던 문서를 건드리지 않게 사례를 따로 쓴다. */
async function seal(bytes: Uint8Array, pw: string) {
  await engine();
  const built = mods.get(wasmPath);
  if (!built) return null;
  const inst = await WebAssembly.instantiate(built, { wasi_snapshot_preview1: wasi });
  const e = inst.exports as unknown as Exports;
  if (!e.setEncrypt || !e.encRandomPtr) return null;
  if (!e.reserve(bytes.length, bytes.length * 4 + 32 * 1024 * 1024)) return null;
  new Uint8Array(e.memory.buffer, e.inputPtr(), bytes.length).set(bytes);
  e.clearPassword?.();
  if (!e.parse(bytes.length)) return null;
  e.clearPick();
  for (let i = 0; i < e.pageCount(); i++) e.addPick(i);
  e.setRotate(0);
  e.clearWatermark();
  e.clearLabels?.();
  e.clearFieldEdits?.();
  e.clearNewFields?.();
  e.clearPageRotate?.();
  e.clearNotes?.();
  e.setEncrypt(1);
  chars(e, pw, (c) => e.addEncryptChar?.(c));
  const rnd = new Uint8Array(64);
  crypto.getRandomValues(rnd);
  new Uint8Array(e.memory.buffer, e.encRandomPtr(), 64).set(rnd);
  const n = e.compact();
  return n ? new Uint8Array(e.memory.buffer, e.outputPtr(), n).slice() : null;
}

/** 다른 문서를 뒤에 잇는다. 결과 바이트를 돌려준다. */
async function merge(bytes: Uint8Array) {
  const e = await engine();
  if (bytes.byteLength > e.maxSecond()) return null;
  // 이어 붙인 결과는 두 문서를 합친 크기다. 열 때 잡아 둔 출력 자리는 첫
  // 문서 기준이라 모자랄 수 있다 — 모자라면 자리를 다시 잡고 문서를 다시
  // 읽는다. 원본 바이트는 아직 입력 자리에 그대로 있다.
  const need = e.inputLen() + bytes.byteLength + 1024 * 1024;
  if (e.outCapacity() < need) {
    const src = new Uint8Array(e.memory.buffer, e.inputPtr(), e.inputLen()).slice();
    if (!e.reserve(src.length, need)) return null;
    new Uint8Array(e.memory.buffer, e.inputPtr(), src.length).set(src);
    if (!e.parse(src.length)) return null;
    await loadCmaps(e);
  }
  new Uint8Array(e.memory.buffer, e.secondPtr(), bytes.byteLength).set(bytes);
  if (!e.parseSecond(bytes.byteLength)) return null;
  const n = e.merge();
  if (!n) return null;
  return {
    bytes: new Uint8Array(e.memory.buffer, e.outputPtr(), n).slice(),
    added: e.secondPageCount(),
  };
}

// 한 번에 하나씩만 처리한다.
//
// onmessage 를 async 로 두면 브라우저가 메시지마다 새 실행을 띄운다. await
// 마다 서로 끼어들어, 하나뿐인 wasm 사례 위에서 두 문서가 섞여 파싱된다.
// 실제로 파일을 잇달아 넣으면 마지막이 아니라 엉뚱한 문서가 열렸다.
// 앞의 일이 끝나야 다음이 시작하도록 줄을 세운다.
let queue: Promise<void> = Promise.resolve();

// 워커로 돌 때만 메시지를 받는다. Node 에서는 워커가 없어 doWork 를 바로 부른다.
if (typeof self !== "undefined" && typeof (self as unknown as { postMessage?: unknown }).postMessage === "function") {
  self.onmessage = (ev: MessageEvent) => {
    queue = queue.then(() => handle(ev)).catch(() => {});
  };
}

/**
 * 일 하나를 처리한다. 메시지와 떼어 두어 워커 없이도 부를 수 있다 —
 * Node 에는 Web Worker 가 없어 같은 갈래에서 이 함수를 그대로 쓴다.
 * 줄 세우기는 부르는 쪽 몫이다(엔진 사례가 하나뿐이라 겹치면 섞인다).
 */
export async function doWork(t: string, a: any): Promise<{ r: unknown; move: Transferable[] }> {
  let r: unknown = null;
  const move: Transferable[] = [];
    if (t === "paths") {
    if (a.wasm) wasmPath = a.wasm;
    if (a.cmaps) setCmapBase(a.cmaps);
    r = true;
  }
  else if (t === "open") r = await open(a.bytes, a.pw);
  else if (t === "attach") {
    const e = await engine();
    const n = e.attLoad?.(a.i) ?? 0;
    const q = n ? new Uint8Array(e.memory.buffer, e.attPtr!(), n).slice() : null;
    if (q) move.push(q.buffer as Transferable);
    r = q;
  }
  else if (t === "layers") {
    const e = await engine();
    (a.on as boolean[]).forEach((v, i) => e.setOcOn?.(i, v ? 1 : 0));
    r = true;
  }
  else if (t === "page") {
    const q = await page(a.i, a.formOn, a.light === true);
    for (const b of [q.ops.buffer, q.txt.buffer, q.drw.buffer, q.rtx.buffer, q.inline.buffer]) {
      move.push(b as Transferable);
    }
    for (const b of q.bitmaps) if (b) move.push(b);
    for (const s of q.stencils) if (s) move.push(s.bytes.buffer as Transferable);
    for (const f of q.fonts) if (f.bytes) move.push(f.bytes.buffer as Transferable);
    r = q;
  } else if (t === "build") {
    const q = await build(a.spec);
    if (q) move.push(q.buffer as Transferable);
    r = q;
  } else if (t === "merge") {
    const q = await merge(a.bytes);
    if (q) move.push(q.bytes.buffer as Transferable);
    r = q;
  } else if (t === "seal") {
    const q = await seal(a.bytes, a.pw);
    if (q) move.push(q.buffer as Transferable);
    r = q;
  }
  return { r, move };
}

/** 워커 메시지 한 건. doWork 를 부르고 답을 돌려보낸다. */
async function handle(ev: MessageEvent) {
  const { id, t, a } = ev.data;
  try {
    const { r, move } = await doWork(t, a);
    self.postMessage({ id, r }, move);
  } catch (e) {
    self.postMessage({ id, err: String((e as Error)?.message ?? e) });
  }
}

