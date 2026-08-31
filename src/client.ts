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
      for (const [, slot] of this.waiting) slot.no(new Error(String(ev.message ?? "워커 오류")));
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
    if (this.gone) return Promise.reject(new Error("문서를 이미 닫았습니다"));
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
    for (const [, slot] of this.waiting) slot.no(new Error("문서를 닫았습니다"));
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
