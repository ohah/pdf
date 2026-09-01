// Vue 3 에서 쓰는 갈래.
//
//   const { doc, needPassword } = usePdf(file, { wasm: "/pdf.wasm" });
//   <PDFPage :doc="doc" :page="1" :scale="1.5" />
import {
  defineComponent, h, onUnmounted, ref, shallowRef, watch, watchEffect,
  type PropType, type Ref,
} from "vue";
import { PasswordNeeded, PDFDocument, type OpenOpts } from "./index.js";

export function usePdf(
  src: Ref<File | Blob | ArrayBuffer | Uint8Array | null | undefined>,
  opts: OpenOpts = {},
) {
  const doc = shallowRef<PDFDocument | null>(null);
  const loading = ref(false);
  const needPassword = ref(false);
  const error = shallowRef<Error | null>(null);
  let opened: PDFDocument | null = null;

  const stop = watch(src, async (v) => {
    opened?.close();
    opened = null;
    doc.value = null;
    needPassword.value = false;
    error.value = null;
    if (!v) return;
    loading.value = true;
    try {
      const buf = v instanceof Blob ? new Uint8Array(await v.arrayBuffer())
        : v instanceof Uint8Array ? v
        : new Uint8Array(v);
      opened = await PDFDocument.open(buf, opts);
      doc.value = opened;
    } catch (e) {
      if (e instanceof PasswordNeeded) needPassword.value = true;
      else error.value = e as Error;
    } finally {
      loading.value = false;
    }
  }, { immediate: true });

  onUnmounted(() => { stop(); opened?.close(); });
  return { doc, loading, needPassword, error };
}

export const PDFPage = defineComponent({
  name: "PDFPage",
  props: {
    doc: { type: Object as PropType<PDFDocument | null>, default: null },
    page: { type: Number, default: 1 },
    scale: { type: Number, default: 1 },
    formLayer: { type: Boolean, default: true },
    // React 갈래와 같은 것을 받는다 — 한쪽만 되는 옵션이 있으면 헷갈린다
    dpr: { type: Number, default: undefined },
    rotation: { type: Number, default: undefined },
    background: { type: String, default: undefined },
  },
  setup(props) {
    const cv = ref<HTMLCanvasElement | null>(null);
    watchEffect(async (onCleanup) => {
      if (!cv.value || !props.doc) return;
      // 쪽·배율이 바뀌면 그리던 것을 버린다
      const ac = new AbortController();
      onCleanup(() => ac.abort());
      await props.doc
        .render(props.page, cv.value, {
          scale: props.scale, formLayer: props.formLayer, dpr: props.dpr,
          rotation: props.rotation, background: props.background, signal: ac.signal,
        })
        .catch(() => {});
    });
    return () => h("canvas", { ref: cv });
  },
});
