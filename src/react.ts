// React 에서 쓰는 갈래.
//
//   const { doc, error, needPassword } = usePdf(file, { wasm: "/pdf.wasm" });
//   <PdfPage doc={doc} page={1} scale={1.5} />
import {
  createElement, useCallback, useEffect, useRef, useState, type CSSProperties,
} from "react";
import { PasswordNeeded, PdfDoc, type OpenOpts, type RenderOpts } from "./index.js";

export type UsePdf = {
  doc: PdfDoc | null;
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
    let opened: PdfDoc | null = null;
    setState((s) => ({ ...s, loading: true, error: null, needPassword: false }));
    (async () => {
      try {
        const buf = src instanceof Blob ? new Uint8Array(await src.arrayBuffer())
          : src instanceof Uint8Array ? src
          : new Uint8Array(src);
        const doc = await PdfDoc.open(buf, { wasm, cmaps, password });
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

export type PdfPageProps = RenderOpts & {
  doc: PdfDoc | null;
  /** 1 부터 */
  page: number;
  className?: string;
  style?: CSSProperties;
  /** 다 그린 뒤 부른다 */
  onRender?: (r: { width: number; height: number }) => void;
};

/** 쪽 하나를 canvas 에 그리는 컴포넌트. */
export function PdfPage({
  doc, page, className, style, onRender, ...opts
}: PdfPageProps) {
  const ref = useRef<HTMLCanvasElement | null>(null);
  const { scale, dpr, formLayer } = opts;
  const draw = useCallback(async () => {
    const cv = ref.current;
    if (!cv || !doc) return;
    const r = await doc.render(page, cv, { scale, dpr, formLayer });
    onRender?.({ width: r.width, height: r.height });
  }, [doc, page, scale, dpr, formLayer, onRender]);
  useEffect(() => { void draw(); }, [draw]);
  return createElement("canvas", { ref, className, style });
}
