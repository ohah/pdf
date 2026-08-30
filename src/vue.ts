// Vue 3 에서 쓰는 갈래.
//
//   const { doc, needPassword } = usePdf(file, { wasm: "/pdf.wasm" });
//   <PdfPage :doc="doc" :page="1" :scale="1.5" />
import {
  defineComponent, h, onUnmounted, ref, shallowRef, watch, watchEffect,
  type PropType, type Ref,
} from "vue";
import { PasswordNeeded, PdfDoc, type OpenOpts } from "./index.js";

export function usePdf(
  src: Ref<File | Blob | ArrayBuffer | Uint8Array | null | undefined>,
  opts: OpenOpts = {},
) {
  const doc = shallowRef<PdfDoc | null>(null);
  const loading = ref(false);
  const needPassword = ref(false);
  const error = shallowRef<Error | null>(null);
  let opened: PdfDoc | null = null;

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
      opened = await PdfDoc.open(buf, opts);
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

export const PdfPage = defineComponent({
  name: "PdfPage",
  props: {
    doc: { type: Object as PropType<PdfDoc | null>, default: null },
    page: { type: Number, default: 1 },
    scale: { type: Number, default: 1 },
    formLayer: { type: Boolean, default: true },
  },
  setup(props) {
    const cv = ref<HTMLCanvasElement | null>(null);
    watchEffect(async () => {
      if (!cv.value || !props.doc) return;
      await props.doc.render(props.page, cv.value, {
        scale: props.scale, formLayer: props.formLayer,
      });
    });
    return () => h("canvas", { ref: cv });
  },
});
