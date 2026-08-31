// 워커에 일을 시키는 창구.
//
// 워커는 메시지로만 이야기하므로 부르는 쪽이 지저분해지기 쉽다. 여기서
// 번호를 붙여 오간 것을 짝지어 두고, 바깥에는 평범한 async 함수로 보인다.
import type { BuildSpec } from "./worker.js";
import { DEFAULTS, type Paths } from "./config.js";

export type { BuildSpec, Mask } from "./worker.js";

/** 워커가 돌려주는 쪽 하나. 화면 쪽이 canvas 에 얹는다. */
export type PageMsg = {
  w: number; h: number; x0: number; y0: number; rot: number;
  items: { x: number; y: number; size: number; text: string }[];
  ops: Float32Array;
  txt: Uint8Array;
  drw: Uint8Array;
  rtx: Uint8Array;
  links: { x0: number; y0: number; x1: number; y1: number; uri: string; page: number }[];
  /** 쪽에 달린 주석 — 종류를 가리지 않는다(링크·위젯도 들어 있다) */
  annots: {
    obj: number;
    /** Highlight·Text·Square·Ink·Link·Widget … (/Subtype) */
    subtype: string;
    rect: [number, number, number, number];
    /** 주석에 적힌 글 (/Contents) */
    contents: string;
    /** 쓴 사람 (/T) */
    author: string;
    /** 적힌 시각 (/M, 예: D:20260901120000+09'00') */
    date: string;
    /** 테두리 색 0~1. 없으면 null */
    color: [number, number, number] | null;
    /** 2=숨김, 4=인쇄됨 … (/F) */
    flags: number;
    /** Link 주석이 가리키는 주소. 문서 안 이동이면 빈 문자열 */
    uri?: string;
    /** Link 주석이 가리키는 쪽(0부터). 모르면 -1 */
    page?: number;
  }[];
  inline: Uint8Array;
  fields: {
    obj: number; kind: number; flags: number; maxLen: number; size: number; align: number;
    rect: [number, number, number, number];
    name: string; value: string; on: string; opts: string; checked: boolean;
  }[];
  fonts: { bytes: Uint8Array | null; pua: boolean; name: string; kind: number; len: number }[];
  bitmaps: (ImageBitmap | undefined)[];
  stencils: ({ w: number; h: number; flip: boolean; bytes: Uint8Array; key: string } | undefined)[];
  bitmap?: ImageBitmap;
  images: number;
  forms: number;
  /** 글자와 자리만 담긴 것인가 */
  light: boolean;
};

export type OpenMsg = {
  err?: string;
  max?: number;
  needPw?: boolean;
  pages?: number;
  locked?: boolean;
  outline?: { depth: number; title: string; page: number }[];
  info?: string[];
  layers?: { name: string; on: boolean }[];
  atts?: { name: string }[];
  /** XFA 양식인가 — 우리도 남들도 제대로 못 그린다 */
  xfa?: boolean;
  /** 암호 사전의 권한 비트(/P). 암호가 없으면 -1 */
  perm?: number;
  /** 열 때 옆판을 어떻게 둘지 (/PageMode) */
  pageMode?: string;
  /** 한 쪽·두 쪽 보기 (/PageLayout) */
  pageLayout?: string;
  /** 파일 지문(/ID 첫 문자열, 16진수) — 문서별 상태 저장 열쇠 */
  fingerprint?: string;
  /** 태그 PDF 인가 (/MarkInfo /Marked) */
  tagged?: boolean;
  /** 문서 언어 (/Lang) */
  lang?: string;
  /** 쪽 라벨(i, ii, A-1 …). 없으면 빈 배열 */
  labels?: string[];
  /** 이름 목적지 — 목차·링크가 이름으로 가리키는 자리 */
  dests?: { name: string; page: number }[];
  /** 뷰어 설정 (/ViewerPreferences) */
  prefs?: Record<string, string>;
  /** XMP 메타데이터 원문 (RDF/XML). 없으면 빈 문자열 */
  xmp?: string;
  sigs?: {
    name: string; date: string; reason: string; sub: string;
    der: Uint8Array; range: number[]; covers: boolean;
  }[];
};

export class PDFClient {
  private w: Worker;
  private seq = 0;
  private waiting = new Map<number, { ok: (v: unknown) => void; no: (e: Error) => void }>();
  private gone = false;

  constructor(paths: Paths = {}) {
    this.w = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
    this.w.onmessage = (ev) => {
      const { id, r, err } = ev.data;
      const slot = this.waiting.get(id);
      if (!slot) return;
      this.waiting.delete(id);
      if (err) slot.no(new Error(err));
      else slot.ok(r);
    };
    this.tellPaths(paths);
    this.w.onerror = (ev) => {
      for (const [, slot] of this.waiting) slot.no(new Error(String(ev.message ?? "worker error")));
      this.waiting.clear();
    };
  }

  /** 파일을 어디에 뒀는지 워커에 알린다. 줄을 서므로 늘 먼저 닿는다. */
  private tellPaths(paths: Paths) {
    void this.call("paths", {
      wasm: paths.wasm ?? DEFAULTS.wasm,
      cmaps: paths.cmaps ?? DEFAULTS.cmaps,
    });
  }

  private call<T>(t: string, a: unknown, move: Transferable[] = []): Promise<T> {
    // 닫힌 뒤에 부르면 워커가 없어 대답이 영영 안 온다. 그대로 두면 부르는
    // 쪽 await 가 매달린다 — 바로 알려 준다.
    if (this.gone) return Promise.reject(new Error("the document is already closed"));
    const id = ++this.seq;
    return new Promise<T>((ok, no) => {
      this.waiting.set(id, { ok: ok as (v: unknown) => void, no });
      this.w.postMessage({ id, t, a }, move);
    });
  }

  close() {
    if (this.gone) return;
    this.gone = true;
    // 답을 기다리던 것들도 함께 끊는다
    for (const [, slot] of this.waiting) slot.no(new Error("the document was closed"));
    this.waiting.clear();
    this.w.terminate();
  }

  /** 문서를 연다. 바이트는 넘겨주고 나면 이쪽에서 못 쓴다 — 부르는 쪽이 사본을 준다. */
  open(bytes: Uint8Array, pw: string) {
    return this.call<OpenMsg>("open", { bytes, pw }, [bytes.buffer as Transferable]);
  }
  /** light 면 글자와 자리만 — 찾기·쪽 크기에 쓴다 */
  /** 딸린 파일 하나를 꺼낸다 */
  attach(i: number) {
    return this.call<Uint8Array | null>("attach", { i });
  }
  /** 레이어를 켜고 끈다. 다음 page() 부터 먹는다. */
  layers(on: boolean[]) {
    return this.call<boolean>("layers", { on });
  }
  /** light 면 글자와 자리만 — 찾기·쪽 크기에 쓴다 */
  page(i: number, formOn: boolean, light = false) {
    return this.call<PageMsg>("page", { i, formOn, light });
  }
  build(spec: BuildSpec) {
    const move: Transferable[] = [];
    const add = (m?: { bits: Uint8Array }) => { if (m) move.push(m.bits.buffer as Transferable); };
    add(spec.wmMask);
    for (const f of spec.fields) add(f.mask);
    for (const L of spec.labels) add(L.mask);
    return this.call<Uint8Array | null>("build", { spec }, move);
  }
  merge(bytes: Uint8Array) {
    return this.call<{ bytes: Uint8Array; added: number } | null>(
      "merge", { bytes }, [bytes.buffer as Transferable]);
  }
  seal(bytes: Uint8Array, pw: string) {
    return this.call<Uint8Array | null>("seal", { bytes, pw }, [bytes.buffer as Transferable]);
  }
}
