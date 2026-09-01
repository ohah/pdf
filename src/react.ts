// React 에서 쓰는 갈래.
//
//   const { doc, error, needPassword } = usePdf(file, { wasm: "/pdf.wasm" });
//   <PDFPage doc={doc} page={1} scale={1.5} />
import {
  createElement, useCallback, useEffect, useRef, useState, type CSSProperties,
} from "react";
import { PasswordNeeded, PDFDocument, type OpenOpts, type RenderOpts } from "./index.js";

export type UsePdf = {
  doc: PDFDocument | null;
  /** 여는 중인가 */
  loading: boolean;
  /** 암호가 있어야 열린다 — password 를 넣어 다시 부른다 */
  needPassword: boolean;
  error: Error | null;
};

/** 파일(또는 바이트)을 열어 문서를 돌려준다. 바뀌면 앞의 것은 닫는다. */
export function usePdf(
  src: File | Blob | ArrayBuffer | Uint8Array | null | undefined,
  opts: OpenOpts = {},
): UsePdf {
  const [state, setState] = useState<UsePdf>({
    doc: null, loading: false, needPassword: false, error: null,
  });
  const { wasm, cmaps, password } = opts;
  useEffect(() => {
    if (!src) {
      setState({ doc: null, loading: false, needPassword: false, error: null });
      return;
    }
    let alive = true;
    let opened: PDFDocument | null = null;
    setState((s) => ({ ...s, loading: true, error: null, needPassword: false }));
    (async () => {
      try {
        const buf = src instanceof Blob ? new Uint8Array(await src.arrayBuffer())
          : src instanceof Uint8Array ? src
          : new Uint8Array(src);
        const doc = await PDFDocument.open(buf, { wasm, cmaps, password });
        opened = doc;
        if (!alive) { doc.close(); return; }
        setState({ doc, loading: false, needPassword: false, error: null });
      } catch (e) {
        if (!alive) return;
        setState({
          doc: null, loading: false,
          needPassword: e instanceof PasswordNeeded,
          error: e instanceof PasswordNeeded ? null : (e as Error),
        });
      }
    })();
    return () => {
      alive = false;
      opened?.close();
    };
  }, [src, wasm, cmaps, password]);
  return state;
}

export type PDFPageProps = RenderOpts & {
  doc: PDFDocument | null;
  /** 1 부터 */
  page: number;
  className?: string;
  style?: CSSProperties;
  /** 다 그린 뒤 부른다 */
  onRender?: (r: { width: number; height: number }) => void;
};

/** 쪽 하나를 canvas 에 그리는 컴포넌트. */
export function PDFPage({
  doc, page, className, style, onRender, ...opts
}: PDFPageProps) {
  const ref = useRef<HTMLCanvasElement | null>(null);
  // 광고한 옵션은 다 넘긴다. 예전에는 셋만 꺼내 쓰고 rotation·background 는
  // 조용히 버려, <PDFPage rotation={90}/> 이 형은 맞는데 아무 일도 안 했다.
  const { scale, dpr, formLayer, rotation, background } = opts;
  const draw = useCallback(async (signal: AbortSignal) => {
    const cv = ref.current;
    if (!cv || !doc) return;
    const r = await doc.render(page, cv, { scale, dpr, formLayer, rotation, background, signal });
    onRender?.({ width: r.width, height: r.height });
  }, [doc, page, scale, dpr, formLayer, rotation, background, onRender]);
  useEffect(() => {
    // 쪽·배율이 바뀌거나 떠나면 그리던 것을 버린다 — 빠르게 넘길 때
    // 지나간 쪽이 나중에 덮어 그리지 않게.
    const ac = new AbortController();
    draw(ac.signal).catch(() => {});
    return () => ac.abort();
  }, [draw]);
  return createElement("canvas", { ref, className, style });
}
