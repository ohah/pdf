// 소비자가 보는 타입이 맞는지 본다. 값이 아니라 *추론*을 시험한다 —
// 여기서 tsc 가 조용하면 쓰는 쪽에서 any 로 새지 않는다는 뜻이다.
//
// 꾸러미 이름("@ohah/pdf")으로 부른다. 상대 경로로 부르면 exports 지도와
// .d.ts 가 제대로 걸렸는지는 못 본다.
import { PDFDocument, PasswordNeeded, type OpenOpts, type RenderOpts } from "@ohah/pdf";
import { usePdf, PDFPage } from "@ohah/pdf/react";
import { usePdf as useVue, PDFPage as VuePage } from "@ohah/pdf/vue";
import { pdfStore, pdfPage } from "@ohah/pdf/svelte";
import { ref } from "vue";

/** 같은 타입인지 컴파일 때 못 박는다 */
type Eq<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const assertEq = <T extends true>(_v?: T) => {};

// ── 뼈대
declare const file: File;
async function core() {
  const doc = await PDFDocument.open(file, { wasm: "/pdf.wasm" } satisfies OpenOpts);
  assertEq<Eq<typeof doc, PDFDocument>>();
  const n = doc.pages;
  assertEq<Eq<typeof n, number>>();
  assertEq<Eq<typeof doc.truncated, boolean>>();
  assertEq<Eq<typeof doc.isXfa, boolean>>();
  const t: string = doc.outline[0].title;
  void t;
  const cv = document.createElement("canvas");
  await doc.render(1, cv, { scale: 1.5, dpr: 2 } satisfies RenderOpts);
  doc.close();
  try { await PDFDocument.open(file); } catch (e) {
    if (e instanceof PasswordNeeded) { const b: boolean = true; void b; }
  }
}

// ── React
function R() {
  const { doc, loading, needPassword, error } = usePdf(file, { wasm: "/pdf.wasm" });
  assertEq<Eq<typeof doc, PDFDocument | null>>();
  assertEq<Eq<typeof loading, boolean>>();
  assertEq<Eq<typeof needPassword, boolean>>();
  assertEq<Eq<typeof error, Error | null>>();
  return <PDFPage doc={doc} page={1} scale={1.5} />;
}

// ── Vue
function V() {
  const src = ref<File | null>(file);
  const { doc, loading, needPassword, error } = useVue(src, { wasm: "/pdf.wasm" });
  assertEq<Eq<typeof doc.value, PDFDocument | null>>();
  assertEq<Eq<typeof loading.value, boolean>>();
  assertEq<Eq<typeof needPassword.value, boolean>>();
  assertEq<Eq<typeof error.value, Error | null>>();
  return VuePage;
}

// ── Svelte
function S() {
  const store = pdfStore({ wasm: "/pdf.wasm" });
  const off = store.subscribe((s) => {
    assertEq<Eq<typeof s.doc, PDFDocument | null>>();
    assertEq<Eq<typeof s.loading, boolean>>();
    assertEq<Eq<typeof s.error, Error | null>>();
  });
  off();
  store.open(file);
  const cv = document.createElement("canvas");
  const act = pdfPage(cv, { doc: null, page: 1, scale: 1 });
  act?.destroy?.();
}

void core; void R; void V; void S;
