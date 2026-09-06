// 쓰는 쪽이 타입을 이름으로 부를 수 있는지.
//
//   npx tsc --noEmit --ignoreConfig --strict --target ES2022 --module ESNext \
//     --moduleResolution bundler --lib ES2022,DOM,DOM.Iterable tests/types.ts
//
// 돌려주는 꼴을 메서드 자리에 적어 두면 밖에서 그걸 가리킬 수가 없다 —
// const items: ??? = await pdf.textItems(1) 에서 막힌다. 이 파일이 컴파일되면
// 이름이 다 나가 있다는 뜻이고, 하나라도 빠지면 여기서 걸린다.
import {
  PDFDocument, type TextItem, type FormField, type LinkItem, type Annotation,
  type Signature, type MergeResult, type OutlineItem, type Permissions,
  type Layer, type Attachment, type Destination, type StructNode, type Viewport,
  type RenderResult, type BuildOpts, type OpenOpts, type Paths, type TextRun,
  type OpenAction, type CalcField, type ValueOf, type XfaForm, type XfaPage, type XfaBox,
  readXfa, drawXfa, toPt, runCalc, recalculate, formCalc, runJs, type Sandbox,
} from "../src/index.js";
// 어댑터 셋은 index 에서 안 딸려 온다. 여기서 부르지 않으면 이 검사의 그물
// 밖이라, .d.ts 를 내는 build-js.sh 만 이들을 본다 — 그쪽은 형 선언을 내는
// 김에 보는 것이라, 차례가 바뀌거나 실패를 삼키면 조용히 열린다.
import { usePdf as useReact, PDFPage as ReactPage, type UsePdf, type PDFPageProps } from "../src/react.js";
import { pdfStore, pdfPage, type PDFPageParams } from "../src/svelte.js";
import { usePdf as useVue, PDFPage as VuePage } from "../src/vue.js";

export async function demo(pdf: PDFDocument) {
  const items: TextItem[] = await pdf.textItems(1);
  const fields: FormField[] = await pdf.fields(1);
  const links: LinkItem[] = await pdf.links(1);
  const annots: Annotation[] = await pdf.annotations(1);
  const sigs: Signature[] = await pdf.signatures();
  const merged: MergeResult | null = await pdf.merge(new Uint8Array());
  const outline: OutlineItem[] = pdf.outline;
  const perm: Permissions = pdf.permissions;
  const layers: Layer[] = pdf.layers;
  const atts: Attachment[] = pdf.attachments;
  const dests: Destination[] = pdf.destinations;
  const tree: StructNode | null = pdf.structure();
  const vp: Viewport = await pdf.viewport(1, { scale: 1.5 });
  const spec: BuildOpts = { pick: [0] };
  const opts: OpenOpts = { wasm: "/pdf.wasm" };
  const paths: Paths = { cmaps: "/cmaps" };
  const runs: TextRun[] = [];
  // 열 때 갈 자리·셈 차례·XFA
  const open: OpenAction | null = pdf.openAction;
  const order: number[] = pdf.calcOrder;
  const xml: string = pdf.xfaXml;
  const form: XfaForm = readXfa(xml);
  const page: XfaPage | undefined = form.pages[0];
  const box: XfaBox | undefined = page?.boxes[0];
  const pt: number = toPt("1in");
  const fc: string | null = formCalc("Sum(a,b)", (n) => n);
  const sbox: Sandbox = { out: {} };
  const js: unknown = runJs("out.v = 1;", sbox, { steps: 1000, ms: 10 });
  const flow: number = form.flowed + form.repeated + form.calculated + form.unreadScripts;
  const calcs: CalcField[] = fields.map((f) => ({ name: f.name, calc: f.calc, format: f.format }));
  const at: ValueOf = (n) => n;
  const one: string | null = runCalc("event.value = 1;", at);
  const many: { values: Record<string, string>; skipped: string[] } = recalculate(calcs, {}, order.map(String));
  const partial: boolean = pdf.partial;
  void drawXfa;
  return {
    open, order, xml, form, page, box, pt, calcs, one, many, partial, fc, flow, js, sbox, items, fields, links, annots, sigs, merged, outline, perm, layers, atts, dests, tree, vp, spec, opts, paths, runs };
}

/** 어댑터의 이름이 다 나갔는지. 부르지는 않고 가리키기만 한다 — React·Vue
 *  훅은 컴포넌트 밖에서 부르면 안 되고, 여기서 필요한 건 타입뿐이다. */
export function adapters() {
  const r: typeof useReact = useReact;
  const v: typeof useVue = useVue;
  const s2: typeof pdfStore = pdfStore;
  const a2: typeof pdfPage = pdfPage;
  const u: UsePdf | null = null;
  const pp: PDFPageProps | null = null;
  const sp: PDFPageParams | null = null;
  return { r, v, s2, a2, u, pp, sp, ReactPage, VuePage };
}
