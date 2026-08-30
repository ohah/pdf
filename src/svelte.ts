// Svelte 에서 쓰는 갈래.
//
//   const pdf = pdfStore({ wasm: "/pdf.wasm" });
//   pdf.open(file);
//   <canvas use:pdfPage={{ doc: $pdf.doc, page: 1, scale: 1.5 }} />
import { PasswordNeeded, PDFDocument, type OpenOpts, type RenderOpts } from "./index.js";

type State = { doc: PDFDocument | null; loading: boolean; needPassword: boolean; error: Error | null };
type Sub = (v: State) => void;

/** Svelte 스토어 규약(subscribe)을 따르는 작은 상자. */
export function pdfStore(opts: OpenOpts = {}) {
  let state: State = { doc: null, loading: false, needPassword: false, error: null };
  const subs = new Set<Sub>();
  const set = (v: Partial<State>) => {
    state = { ...state, ...v };
    for (const s of subs) s(state);
  };
  return {
    subscribe(run: Sub) {
      subs.add(run);
      run(state);
      return () => subs.delete(run);
    },
    /** 파일을 연다. 암호가 필요하면 needPassword 가 선다. */
    async open(src: File | Blob | ArrayBuffer | Uint8Array, password?: string) {
      state.doc?.close();
      set({ doc: null, loading: true, needPassword: false, error: null });
      try {
        const buf = src instanceof Blob ? new Uint8Array(await src.arrayBuffer())
          : src instanceof Uint8Array ? src
          : new Uint8Array(src);
        const doc = await PDFDocument.open(buf, { ...opts, password });
        set({ doc, loading: false });
      } catch (e) {
        if (e instanceof PasswordNeeded) set({ loading: false, needPassword: true });
        else set({ loading: false, error: e as Error });
      }
    },
    close() {
      state.doc?.close();
      set({ doc: null });
    },
  };
}

export type PDFPageParams = RenderOpts & { doc: PDFDocument | null; page: number };

/** canvas 에 거는 action. 값이 바뀌면 다시 그린다. */
export function pdfPage(node: HTMLCanvasElement, params: PDFPageParams) {
  let cur = params;
  const draw = () => {
    if (!cur.doc) return;
    void cur.doc.render(cur.page, node, cur);
  };
  draw();
  return {
    update(next: PDFPageParams) { cur = next; draw(); },
    destroy() { /* 문서는 스토어가 닫는다 */ },
  };
}
