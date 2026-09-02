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
  readXfa, drawXfa, toPt, runCalc, recalculate, formCalc,
} from "../src/index.js";

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
  const flow: number = form.flowed + form.repeated + form.calculated + form.unreadScripts;
  const calcs: CalcField[] = fields.map((f) => ({ name: f.name, calc: f.calc, format: f.format }));
  const at: ValueOf = (n) => n;
  const one: string | null = runCalc("event.value = 1;", at);
  const many: { values: Record<string, string>; skipped: string[] } = recalculate(calcs, {}, order.map(String));
  const partial: boolean = pdf.partial;
  void drawXfa;
  return {
    open, order, xml, form, page, box, pt, calcs, one, many, partial, fc, flow, items, fields, links, annots, sigs, merged, outline, perm, layers, atts, dests, tree, vp, spec, opts, paths, runs };
}
