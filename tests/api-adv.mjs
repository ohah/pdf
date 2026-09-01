// 공개 API 전수 적대적 검증.
//
//   node tests/api-adv.mjs [회차] [fixtures]
//
// 내보내는 것을 하나도 빠짐없이 두들긴다. 통과 기준은 셋이다.
//
//   1. 안 매달린다   — 모든 부름이 정해진 시간 안에 끝난다(값이든 오류든).
//   2. 안 죽는다     — 던지더라도 Error 여야 한다. undefined 를 읽다 죽거나
//                      wasm 이 통째로 트랩나면 실패다.
//   3. 빠진 게 없다  — dist/index.d.ts 가 내보낸다고 적어 둔 이름 중에
//                      여기서 안 건드린 것이 있으면 실패다(전수조사).
//
// 화면(DOM)이 있어야 하는 둘은 브라우저 쪽 검증기가 맡는다 — 여기서는
// 이름만 확인하고 넘긴다. tests/browser-api.mjs 를 보라.
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const round = Number(process.argv[2] ?? 1);
const FX = (process.argv[3] ?? "tests/fixtures").replace(/\/$/, "");
const lib = await import(pathToFileURL("dist/index.js").href);

const touched = new Set();
/** 이 이름을 두들겼다고 적어 둔다. 라벨에서 캐면 괄호가 섞여 헛돈다. */
const hit = (...names) => { for (const n of names) touched.add(n); };
const bad = [];
const note = (what, why) => bad.push(`${what}: ${why}`);

/** 이 부름은 매달리면 안 된다. 값이 오든 오류가 나든 제 시간 안에 끝나야 한다. */
async function bounded(what, fn, ms = 8000) {
  let timer;
  const t0 = Date.now();
  try {
    const r = await Promise.race([
      (async () => fn())(),
      new Promise((_, no) => { timer = setTimeout(() => no(new Error("__매달림__")), ms); }),
    ]);
    return { ok: true, v: r, ms: Date.now() - t0 };
  } catch (e) {
    if (e instanceof Error && e.message === "__매달림__") { note(what, `${ms}ms 안에 안 끝났다`); return { ok: false, hung: true }; }
    // 던지는 것은 괜찮다. 다만 Error 여야 한다.
    if (!(e instanceof Error)) note(what, `Error 가 아닌 것을 던졌다: ${typeof e}`);
    return { ok: false, err: e, ms: Date.now() - t0 };
  } finally {
    clearTimeout(timer);
  }
}

/** 값이 와야 하는 자리 */
async function want(what, fn, check) {
  const r = await bounded(what, fn);
  if (!r.ok) { if (!r.hung) note(what, `오류가 났다: ${String(r.err?.message).slice(0, 60)}`); return; }
  if (check && !check(r.v)) note(what, `모양이 다르다: ${JSON.stringify(r.v)?.slice(0, 80)}`);
  return r.v;
}

/** 던져야 하는 자리 */
async function dies(what, fn) {
  const r = await bounded(what, fn);
  if (r.ok) note(what, "오류가 안 났다");
}

const bytes = (f) => new Uint8Array(fs.readFileSync(`${FX}/${f}`));
const seedy = [
  new Uint8Array(0), new Uint8Array([37, 80, 68, 70]), // %PDF 만
  Uint8Array.from({ length: 512 }, (_, i) => (i * 7 + round) & 255),
];

// ── 1. 문서 열기 ──────────────────────────────────────────────
const DOCS = ["annots.pdf", "korean.pdf", "multi.pdf", "form.pdf", "struct.pdf", "dests.pdf", "labels.pdf"];
const doc = DOCS[(round - 1) % DOCS.length];

hit("PDFDocument");
for (const junk of [null, undefined, 0, "", {}, [], new Uint8Array(0), NaN]) {
  await dies(`open(${JSON.stringify(junk) ?? String(junk)})`, () => lib.PDFDocument.open(junk));
}
for (const b of seedy) await dies("open(쓰레기 바이트)", () => lib.PDFDocument.open(b));
await dies("open(없는 파일)", () => lib.PDFDocument.open(`${FX}/no-such-${round}.pdf`));
await dies("open(디렉터리)", () => lib.PDFDocument.open(FX));
await dies("open(끊긴 signal)", () => lib.PDFDocument.open(`${FX}/${doc}`, { signal: AbortSignal.abort() }));
await want("open(onProgress 가 던져도)", async () => {
  const d = await lib.PDFDocument.open(bytes(doc), { onProgress: () => { throw new Error("일부러"); } });
  d.close();
  return true;
}, (v) => v === true);

const pdf = await lib.PDFDocument.open(`${FX}/${doc}`);

// ── 2. 읽기 전용 속성 전부 ────────────────────────────────────
const props = {
  pages: (v) => Number.isInteger(v) && v > 0,
  truncated: (v) => typeof v === "boolean",
  locked: (v) => typeof v === "boolean",
  isXfa: (v) => typeof v === "boolean",
  tagged: (v) => typeof v === "boolean",
  outline: Array.isArray,
  info: Array.isArray,
  layers: Array.isArray,
  attachments: Array.isArray,
  destinations: Array.isArray,
  pageLabels: Array.isArray,
  permissions: (v) => v && typeof v.print === "boolean" && Object.keys(v).length === 8,
  viewerPreferences: (v) => v && typeof v === "object",
  pageMode: (v) => typeof v === "string",
  pageLayout: (v) => typeof v === "string",
  lang: (v) => typeof v === "string",
  fingerprint: (v) => typeof v === "string",
  xmp: (v) => typeof v === "string",
};
for (const [k, ok] of Object.entries(props)) {
  touched.add(k);
  if (!ok(pdf[k])) note(`속성 ${k}`, `모양이 다르다: ${JSON.stringify(pdf[k])?.slice(0, 60)}`);
}

// ── 3. 쪽을 받는 것들 — 말도 안 되는 번호로 ───────────────────
const pageArgs = [0, -1, 1.5, NaN, Infinity, 1e9, pdf.pages + 1, "1", null, undefined];
for (const m of ["text", "textItems", "fields", "links", "annotations"]) {
  await want(`${m}(정상)`, () => pdf[m](1), (v) => (m === "text" ? typeof v === "string" : Array.isArray(v)));
  for (const a of pageArgs) await bounded(`${m}(이상한 쪽)`, () => pdf[m](a));
}
await want("structure()", () => pdf.structure(), (v) => v === null || (v && Array.isArray(v.children)));
for (const a of pageArgs) await bounded("structure(이상한 쪽)", () => pdf.structure(a));
await want("signatures()", () => pdf.signatures(), Array.isArray);
await want("data()", () => pdf.data(), (v) => v instanceof Uint8Array && v.length > 0);
for (const i of [-1, 0, 1e6, NaN, null]) await bounded("attachment(이상한 번호)", () => pdf.attachment(i));

// ── 4. 그리기 ─────────────────────────────────────────────────
for (const c of [null, undefined, {}, { getContext: 1 }, { getContext: () => null }, "canvas"]) {
  await dies("render(캔버스 아닌 것)", () => pdf.render(1, c));
}
let createCanvas = null;
try { ({ createCanvas } = await import("@napi-rs/canvas")); } catch { /* 없으면 건너뛴다 */ }
if (createCanvas) {
  const cv = createCanvas(8, 8);
  await want("render(정상)", () => pdf.render(1, cv, { scale: 1, dpr: 1 }),
    (v) => v && Array.isArray(v.runs) && v.viewport && v.width > 0);
  for (const o of [{ scale: 0 }, { scale: -3 }, { scale: 1e6 }, { dpr: 0 }, { dpr: -1 },
                   { rotation: 37 }, { rotation: -450 }, { background: "not-a-color" },
                   { background: "transparent" }, { formLayer: false }, { scale: NaN }]) {
    await bounded("render(이상한 옵션)", () => pdf.render(1, createCanvas(8, 8), { dpr: 1, ...o }), 12000);
  }
  await dies("render(끊긴 signal)", () => pdf.render(1, createCanvas(8, 8), { signal: AbortSignal.abort(), dpr: 1 }));
  // 그만두기 — 바로 끊고, 두 번 끊어도 된다
  const task = pdf.renderTask(1, createCanvas(8, 8), { dpr: 1 });
  task.cancel();
  task.cancel();
  await bounded("renderTask(끊기)", () => task.promise);
  touched.add("renderTask");
  // drawOps 를 날것으로
  hit("drawOps");
  await want("drawOps(빈 명령)", () => lib.drawOps(createCanvas(8, 8), {
    ops: new Float32Array(0), text: new Uint8Array(0), read: new Uint8Array(0),
    pageW: 100, pageH: 100, bitmaps: [], stencils: [], originX: 0, originY: 0, rotate: 0,
  }), Array.isArray);
  await bounded("drawOps(어긋난 명령)", () => lib.drawOps(createCanvas(8, 8), {
    ops: Float32Array.from([99, 3, 1, 2, 3, 12, 200]), text: new Uint8Array(0), read: new Uint8Array(0),
    pageW: 0, pageH: 0, bitmaps: [], stencils: [], originX: 0, originY: 0, rotate: 90,
  }));
}

// ── 5. 뷰포트·자리 ────────────────────────────────────────────
const vp = await want("viewport()", () => pdf.viewport(1, { scale: 1.5 }), (v) => v && v.width > 0);
for (const o of [{ scale: 0 }, { scale: -1 }, { scale: 1e9 }, { rotation: 37 }, { rotation: NaN }]) {
  await bounded("viewport(이상한 옵션)", () => pdf.viewport(1, o));
}
if (vp) {
  const [x, y] = vp.toViewport(72, 720);
  const back = vp.toPdf(x, y);
  if (Math.abs(back[0] - 72) > 0.5 || Math.abs(back[1] - 720) > 0.5) {
    note("viewport 왕복", `72,720 → ${x},${y} → ${back}`);
  }
  touched.add("toViewport"); touched.add("toPdf");
  for (const r of [[0, 0, 0, 0], [NaN, 1, 2, 3], [1e9, -1e9, 0, 0]]) await bounded("viewport.rect", () => vp.rect(r));
  await bounded("viewport.clone", () => vp.clone({ scale: 2, rotation: 90 }));
  touched.add("rect"); touched.add("clone");
}
hit("makeViewport");
await want("makeViewport", () => lib.makeViewport({ w: 612, h: 792, x0: 0, y0: 0, rot: 0, scale: 1 }),
  (v) => v && v.width === 612);
for (const bad2 of [{ w: 0, h: 0, x0: 0, y0: 0, rot: 0, scale: 1 },
                    { w: -1, h: NaN, x0: 0, y0: 0, rot: 37, scale: 0 }]) {
  await bounded("makeViewport(이상한 값)", () => lib.makeViewport(bad2));
}
const pgBox = { w: 612, h: 792, x0: 0, y0: 0, rot: 0 };
hit("toScreen", "placeRect");
await want("toScreen", () => lib.toScreen(10, 10, pgBox, 1), (v) => Array.isArray(v) && v.length === 2);
await want("placeRect", () => lib.placeRect([0, 0, 10, 10], pgBox, 1), (v) => v && "left" in v);
for (const r of [[NaN, NaN, NaN, NaN], [1e9, 1e9, -1e9, -1e9]]) {
  await bounded("placeRect(이상한 네모)", () => lib.placeRect(r, { ...pgBox, rot: 270 }, 0));
}

// ── 6. 글자 줄 묶기·주소 거르기·서명 ──────────────────────────
hit("toLines");
await want("toLines(빈 것)", () => lib.toLines([]), Array.isArray);
await bounded("toLines(이상한 것)", () => lib.toLines([{ x: NaN, y: NaN, w: NaN, h: NaN, text: "" }]));
const urls = ["javascript:alert(1)", "JaVaScRiPt:alert(1)", " javascript:alert(1)", "data:text/html,<b>",
  "vbscript:x", "file:///etc/passwd", "https://example.com", "mailto:a@b.c", "#hash", "", "x".repeat(5000)];
hit("safeUrl");
for (const u of urls) {
  const r = await bounded("safeUrl", () => lib.safeUrl(u));
  if (r.ok && r.v && /^(javascript|vbscript|data):/i.test(String(r.v).trim())) note("safeUrl", `위험한 것을 통과시켰다: ${u.slice(0, 30)}`);
}
hit("checkSignature");
for (const g of [new Uint8Array(0), new Uint8Array([1, 2, 3])]) {
  await bounded("checkSignature(쓰레기)", () => lib.checkSignature(g, g, [0, 0, 0, 0], false));
}

// ── 6-2. 양식 계산식·XFA ──────────────────────────────────────
hit("runCalc");
// 문서가 준 코드를 절대 돌리면 안 된다 — 돌면 아래 자국이 남는다
globalThis.__pwned = false;
const evil = [
  'event.value = (globalThis.__pwned = true) ? 1 : 2;',
  'app.alert("x"); event.value = 1;',
  'this.getField("a").value = eval("1+1");',
  'while(1){}',
  'event.value = ' + '('.repeat(500) + '1' + ')'.repeat(500) + ';',
  'event.value = this.getField(' + '"a"'.repeat(50) + ').value;',
  '',
  'event.value = 1/0;',
  'AFSimple_Calculate("SUM", new Array(' + '"a",'.repeat(200) + '"b"));',
];
for (const js of evil) await bounded("runCalc(고약한 것)", () => lib.runCalc(js, () => "1"));
if (globalThis.__pwned) note("runCalc", "문서가 준 코드가 실제로 돌았다");
hit("recalculate");
for (const arg of [[[], {}], [[{ name: "a", calc: "event.value = 1;" }], {}],
                   [[{ name: "a", calc: "event.value = this.getField(\"a\").value + 1;" }], { a: "1" }]]) {
  await bounded("recalculate", () => lib.recalculate(arg[0], arg[1]));
}
hit("toPt");
for (const v of ["", "1in", "25.4mm", "abc", "1e9in", "-5pt", "9".repeat(400) + "mm"]) {
  await bounded("toPt", () => lib.toPt(v));
}
hit("readXfa");
for (const x of ["", "<template>", "<template><subform x=\"1in\"><field/></subform></template>",
                 "<".repeat(2000), "<template>" + "<subform>".repeat(300) + "</template>"]) {
  await bounded("readXfa(이상한 XML)", () => lib.readXfa(x));
}
hit("drawXfa");
await bounded("drawXfa(캔버스 없이)", () => lib.drawXfa({ getContext: () => null, width: 1, height: 1 },
  { width: 10, height: 10, boxes: [] }, 1));

// ── 7. 만들기·잇기·암호 ───────────────────────────────────────
for (const spec of [{}, { pick: [] }, { pick: [0, 0, 0] }, { pick: [1e6] }, { pick: [-1] },
                    { rotate: 450 }, { rotate: NaN }, { watermark: "가".repeat(400) },
                    { shrink: true }, { encryptPw: "" }, { pageRot: [[0, 90]] },
                    { notes: [] }, { labels: [] }, { fields: [] }, { newFields: [] }]) {
  const r = await bounded("build", () => pdf.build(spec), 15000);
  if (r.ok && r.v && r.v.length > 8) {
    const back = await bounded("build 결과 다시 열기", () => lib.PDFDocument.open(r.v.slice()), 15000);
    if (back.ok) back.v.close();
  }
}
for (const b of [new Uint8Array(0), seedy[2], bytes("annots.pdf")]) {
  const r = await bounded("merge", () => pdf.merge(b.slice()), 15000);
  if (r.ok && r.v) {
    if (!(r.v.bytes instanceof Uint8Array) || typeof r.v.added !== "number") note("merge", "모양이 다르다");
  }
}
for (const [b, pw] of [[new Uint8Array(0), ""], [bytes("annots.pdf"), "열쇠"], [bytes("annots.pdf"), "x".repeat(500)]]) {
  await bounded("encrypt", () => pdf.encrypt(b.slice(), pw), 15000);
}
for (const on of [[], [true], [false, false, false, false], [1, 0], [null]]) {
  await bounded("setLayers", () => pdf.setLayers(on));
}

// ── 8. 닫은 뒤 · 낮은 층 ──────────────────────────────────────
pdf.close();
pdf.close();
touched.add("close");
for (const m of ["text", "textItems", "fields", "links", "annotations", "signatures", "build", "merge"]) {
  await dies(`닫은 뒤 ${m}`, () => (m === "build" ? pdf.build({}) : m === "merge" ? pdf.merge(new Uint8Array()) : pdf[m](1)));
}

{
  const cl = new lib.PDFClient();
  touched.add("PDFClient");
  await dies("PDFClient.open(쓰레기)", async () => {
    const r = await cl.open(seedy[2].slice(), "");
    if (!r || r.err || !r.pages) throw new Error(r?.err ?? "못 열었다");
    return r;
  });
  const good = await want("PDFClient.open", () => cl.open(bytes(doc), ""), (v) => v && v.pages > 0);
  if (good) {
    await want("PDFClient.page", () => cl.page(0, true), (v) => v && typeof v.w === "number");
    await bounded("PDFClient.page(이상한 쪽)", () => cl.page(1e6, true, true));
    await bounded("PDFClient.layers", () => cl.layers([true]));
    await bounded("PDFClient.attach", () => cl.attach(999));
    await bounded("PDFClient.seal", () => cl.seal(bytes(doc), "pw"));
  }
  cl.close();
  await dies("닫은 뒤 PDFClient.page", () => cl.page(0, true));
}

// 자리를 엉뚱하게 알려 줬을 때 — 매달리지 말고 오류가 나야 한다
{
  const cl = new lib.PDFClient({ wasm: "/없는곳/pdf.wasm", cmaps: "/없는곳" });
  await dies("wasm 자리가 틀렸을 때", () => cl.open(bytes(doc), ""));
  cl.close();
}

// ── 9. 오류 갈래 ──────────────────────────────────────────────
touched.add("PasswordNeeded"); touched.add("RenderCancelled");
if (!(new lib.PasswordNeeded() instanceof Error)) note("PasswordNeeded", "Error 가 아니다");
if (!(new lib.RenderCancelled() instanceof Error)) note("RenderCancelled", "Error 가 아니다");

// ── 10. 전수조사 — 내보낸다고 적힌 것 중 안 건드린 것 ─────────
const dts = fs.readFileSync("dist/index.d.ts", "utf8");
const declared = new Set();
for (const m of dts.matchAll(/^export (?:declare )?(?:function|class|const) (\w+)/gm)) declared.add(m[1]);
for (const m of dts.matchAll(/^export \{ ([^}]+) \}/gm)) {
  for (const one of m[1].split(",")) {
    const t = one.trim();
    if (t.startsWith("type ")) continue; // 형만 내보낸 것은 런타임에 없다
    const name = t.split(/\s+as\s+/).pop();
    if (name) declared.add(name);
  }
}
// 화면이 있어야 하는 것들은 브라우저 검증기가 맡는다
const byBrowser = new Set(["renderTextLayer", "renderAnnotationLayer"]);
const runtime = new Set(Object.keys(lib).filter((k) => typeof lib[k] === "function"));
const missed = [...runtime].filter((k) => !touched.has(k) && !byBrowser.has(k));
const undeclared = [...declared].filter((k) => !runtime.has(k) && typeof lib[k] === "undefined");
if (missed.length) note("전수조사", `안 건드린 것: ${missed.join(", ")}`);
if (undeclared.length) note("전수조사", `적혀 있는데 안 나가는 것: ${undeclared.join(", ")}`);

const covered = runtime.size - missed.length;
if (bad.length) {
  console.log(`${round}회차 ✗ [${doc}] 내보낸 함수 ${covered}/${runtime.size} · 브라우저 몫 ${byBrowser.size}`);
  for (const b of bad) console.log("   " + b);
} else {
  console.log(`${round}회차 통과 [${doc}] 내보낸 함수 ${covered}/${runtime.size} 다 두들김 · 속성 ${Object.keys(props).length}개 · 브라우저 몫 ${byBrowser.size}`);
}
process.exit(bad.length ? 1 : 0);
