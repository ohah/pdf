// 환경이 깨진 자리에서 어떻게 되는지 본다.
//
//   npx vite examples --port 4277 &
//   node tests/env.mjs [회차]
//
// 브라우저는 어디서나 같지 않다. 워커가 막힌 iframe, wasm 을 못 받는 망,
// 글꼴 API 가 없는 옛 웹뷰, 비보안(http) 자리라 crypto.subtle 이 없는 곳.
// 그런 데서 "조용히 빈 화면" 이나 "TypeError: undefined 의 …" 가 아니라,
// 되는 것은 되고 안 되는 것은 무슨 일인지 말해 주어야 한다.
import { chromium } from "playwright";

const round = Number(process.argv[2] ?? 1);
const DOCS = ["korean.pdf", "multi.pdf", "form.pdf", "annots.pdf", "modern.pdf"];
const doc = DOCS[(round - 1) % DOCS.length];

const b = await chromium.launch();
const bad = [];

/** 시나리오 하나. before 는 라이브러리를 들이기 전에 창을 손본다. */
async function scene(name, before, check) {
  const p = await b.newPage();
  const errs = [];
  p.on("pageerror", (e) => errs.push(String(e).slice(0, 120)));
  await p.goto("http://localhost:4277/vanilla.html");
  if (before) await p.addInitScript(before);
  // addInitScript 는 다음 이동부터 먹는다
  await p.goto("http://localhost:4277/vanilla.html");
  let out;
  try {
    out = await p.evaluate(check, doc);
  } catch (e) {
    out = { threw: String(e.message ?? e).slice(0, 160) };
  }
  await p.close();
  return { name, out, errs };
}

/** 문서를 열고 그려 본다. 되면 { pages, ink, text }, 안 되면 { fail } */
const tryAll = async (doc) => {
  const { PDFDocument } = await import("/dist/index.js");
  try {
    const bytes = new Uint8Array(await (await fetch("/fixtures/" + doc)).arrayBuffer());
    const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
    const cv = document.createElement("canvas");
    const r = await pdf.render(1, cv, { scale: 1, dpr: 1 });
    const d = cv.getContext("2d").getImageData(0, 0, cv.width, cv.height).data;
    let ink = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 0 && d[i] < 200) ink++;
    const text = (await pdf.text(1)).trim().length;
    const runs = r.runs.length;
    pdf.close();
    return { pages: pdf.pages, ink, text, runs };
  } catch (e) {
    return { fail: String(e?.message ?? e).slice(0, 140), kind: e?.constructor?.name };
  }
};

const rows = [];
const say = (name, out, verdict, why) => {
  rows.push({ name, out, verdict });
  if (!verdict) bad.push(`${name}: ${why} — ${JSON.stringify(out).slice(0, 150)}`);
};

// 1) 워커가 아예 없는 곳 (샌드박스 iframe·옛 웹뷰)
{
  const { out, errs } = await scene("워커 없음", () => { delete window.Worker; },
    tryAll);
  say("워커 없음", out, out.pages > 0 && out.ink > 0 && errs.length === 0,
    "같은 갈래에서라도 열리고 그려져야 한다");
}

// 2) 워커를 못 만드는 곳 (CSP 가 worker-src 를 막음)
{
  const { out } = await scene("워커 생성 막힘",
    () => { window.Worker = function () { throw new Error("Refused by CSP"); }; }, tryAll);
  say("워커 생성 막힘", out, out.pages > 0 && out.ink > 0,
    "워커를 못 만들면 같은 갈래로 물러서야 한다");
}

// 3) wasm 을 못 받는 곳 (404)
{
  const { out } = await scene("wasm 404", null, async (doc) => {
    const { PDFDocument } = await import("/dist/index.js");
    const bytes = new Uint8Array(await (await fetch("/fixtures/" + doc)).arrayBuffer());
    try {
      const pdf = await PDFDocument.open(bytes, { wasm: "/없는곳/pdf.wasm", cmaps: "/cmaps" });
      pdf.close();
      return { opened: true };
    } catch (e) { return { fail: String(e?.message ?? e).slice(0, 140) }; }
  });
  say("wasm 404", out, !!out.fail && /pdf\.wasm/.test(out.fail),
    "어느 자리를 못 읽었는지 말해 줘야 한다");
}

// 4) 그 자리에 wasm 이 아니라 HTML 이 있는 곳 (개발 서버가 index.html 을 준다)
{
  const { out } = await scene("wasm 자리에 HTML", null, async (doc) => {
    const { PDFDocument } = await import("/dist/index.js");
    const bytes = new Uint8Array(await (await fetch("/fixtures/" + doc)).arrayBuffer());
    try {
      const pdf = await PDFDocument.open(bytes, { wasm: "/vanilla.html", cmaps: "/cmaps" });
      pdf.close();
      return { opened: true };
    } catch (e) { return { fail: String(e?.message ?? e).slice(0, 140) }; }
  });
  say("wasm 자리에 HTML", out, !!out.fail && /wasm/i.test(out.fail),
    "wasm 이 아니라고 알아들을 말이 있어야 한다");
}

// 5) CMap 표를 못 받는 곳 — 한글 문서라도 열려야 한다
{
  const { out } = await scene("cmaps 404", null, async (doc) => {
    const { PDFDocument } = await import("/dist/index.js");
    const bytes = new Uint8Array(await (await fetch("/fixtures/" + doc)).arrayBuffer());
    try {
      const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/없는곳" });
      const cv = document.createElement("canvas");
      await pdf.render(1, cv, { scale: 1, dpr: 1 });
      const d = cv.getContext("2d").getImageData(0, 0, cv.width, cv.height).data;
      let ink = 0;
      for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 0 && d[i] < 200) ink++;
      const n = pdf.pages;
      pdf.close();
      return { pages: n, ink };
    } catch (e) { return { fail: String(e?.message ?? e).slice(0, 140) }; }
  });
  say("cmaps 404", out, out.pages > 0 && out.ink > 0, "표가 없어도 열리고 그려져야 한다");
}

// 6) 그림 만드는 API 가 없는 곳 (옛 웹뷰)
{
  const { out, errs } = await scene("createImageBitmap 없음",
    () => { delete window.createImageBitmap; delete window.OffscreenCanvas; }, tryAll);
  say("그림 API 없음", out, out.pages > 0 && errs.length === 0,
    "그림은 빠지더라도 글자는 나와야 한다");
}

// 7) FontFace 가 없는 곳 — 박힌 글꼴을 못 등록해도 그려야 한다
{
  const { out, errs } = await scene("FontFace 없음", () => { delete window.FontFace; }, tryAll);
  say("FontFace 없음", out, out.pages > 0 && out.ink > 0 && errs.length === 0,
    "시스템 글꼴로라도 그려야 한다");
}

// 8) 비보안 자리라 crypto.subtle 이 없는 곳 — 서명 확인만 못 해야 한다
{
  const { out } = await scene("crypto.subtle 없음",
    () => { Object.defineProperty(window, "crypto", { value: {}, configurable: true }); },
    async (doc) => {
      const { PDFDocument } = await import("/dist/index.js");
      const bytes = new Uint8Array(await (await fetch("/fixtures/" + doc)).arrayBuffer());
      const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
      const cv = document.createElement("canvas");
      await pdf.render(1, cv, { scale: 1, dpr: 1 });
      let sig = "안 부름";
      try { sig = `배열 ${(await pdf.signatures()).length}`; }
      catch (e) { sig = `오류 ${String(e?.message ?? e).slice(0, 60)}`; }
      const n = pdf.pages;
      pdf.close();
      return { pages: n, sig };
    });
  say("crypto.subtle 없음", out, out.pages > 0,
    "서명 말고는 다 되어야 한다");
}

// 9) WebAssembly 가 아예 없는 곳
{
  // 워커는 제 전역을 갖고 있어, 창에서 지운 것이 워커 안까지 안 간다.
  // 같은 갈래로 내려온 뒤라야 이 시나리오가 뜻이 있다.
  const { out } = await scene("WebAssembly 없음",
    () => { delete window.Worker; delete window.WebAssembly; }, tryAll);
  say("WebAssembly 없음", out, !!out.fail && /WebAssembly/i.test(out.fail),
    "안 되는 것은 안 된다고 말해야 한다(조용히 빈 화면이 아니라)");
}

// 10) 서명이 있는 문서인데 crypto.subtle 이 없는 자리 (http:// 로 띄운 사내 서버)
{
  const { out } = await scene("서명 문서 · subtle 없음",
    () => { Object.defineProperty(window, "crypto", { value: {}, configurable: true }); },
    async () => {
      const { PDFDocument } = await import("/dist/index.js");
      const bytes = new Uint8Array(await (await fetch("/fixtures/signed.pdf")).arrayBuffer());
      const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
      let sig;
      try {
        const list = await pdf.signatures();
        sig = { n: list.length, first: list[0] ? { ok: list[0].ok, unchecked: list[0].unchecked, note: String(list[0].note ?? "").slice(0, 50) } : null };
      } catch (e) { sig = { threw: String(e?.message ?? e).slice(0, 60) }; }
      const n = pdf.pages;
      pdf.close();
      return { pages: n, sig };
    });
  // 서명은 못 맞춰 보더라도 문서는 열려야 하고, 죽지 말아야 한다
  // 못 맞춰 본 것과 맞춰 봤더니 틀린 것은 다르다 — 멀쩡한 문서를 "틀렸다" 고
  // 하면 안 된다.
  say("서명 문서 · subtle 없음", out,
    out.pages > 0 && out.sig?.first?.unchecked === true && /secure|https|WebCrypto/i.test(out.sig.first.note),
    "확인할 수 없다고 말해야지 틀렸다고 하면 안 된다");
}

// 11) 워커가 밖에서 죽었을 때 — 기다리던 부름이 매달리면 안 된다
{
  const { out } = await scene("워커가 죽었을 때", null, async (doc) => {
    const { PDFClient } = await import("/dist/index.js");
    const bytes = new Uint8Array(await (await fetch("/fixtures/" + doc)).arrayBuffer());
    const cl = new PDFClient({ wasm: "/pdf.wasm", cmaps: "/cmaps" });
    await cl.open(bytes, "");
    // 워커를 끊고 나서 부른다
    cl.close();
    const t0 = performance.now();
    let r;
    try { r = { got: !!(await cl.page(0, true)) }; }
    catch (e) { r = { fail: String(e?.message ?? e).slice(0, 60) }; }
    return { ...r, ms: Math.round(performance.now() - t0) };
  });
  say("워커가 죽었을 때", out, !!out.fail && out.ms < 3000, "매달리지 말고 바로 오류가 나야 한다");
}

// 12) 감당 못 할 만큼 큰 파일 — 무슨 일인지 말해야 한다
{
  const { out } = await scene("너무 큰 파일", null, async () => {
    const { PDFDocument } = await import("/dist/index.js");
    // 헤더만 PDF 이고 뒤는 채워 넣은 것. 엔진 한계를 넘긴다.
    const big = new Uint8Array(700 * 1024 * 1024);
    big.set(new TextEncoder().encode("%PDF-1.7\n"), 0);
    try {
      const pdf = await PDFDocument.open(big, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
      pdf.close();
      return { opened: true };
    } catch (e) { return { fail: String(e?.message ?? e).slice(0, 80) }; }
  });
  say("너무 큰 파일", out, !!out.fail, "열린 척하지 말고 안내해야 한다");
}

// 13) 문서 넷을 한꺼번에 — 서로 섞이면 안 된다
{
  const { out } = await scene("문서 넷 동시에", null, async () => {
    const { PDFDocument } = await import("/dist/index.js");
    const names = ["korean.pdf", "multi.pdf", "annots.pdf", "form.pdf"];
    const docs = await Promise.all(names.map(async (n) => {
      const b2 = new Uint8Array(await (await fetch("/fixtures/" + n)).arrayBuffer());
      return PDFDocument.open(b2, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
    }));
    const pages = docs.map((d) => d.pages);
    const texts = await Promise.all(docs.map((d) => d.text(1)));
    for (const d of docs) d.close();
    return { pages, korean: texts[0].includes("임"), multi: texts[1].includes("PAGE 1"), annots: texts[2].includes("annots") };
  });
  say("문서 넷 동시에", out, out.korean && out.multi && out.annots && out.pages?.[1] === 5,
    "각자 제 문서를 답해야 한다");
}

await b.close();

const w = (s, n) => String(s).padEnd(n);
if (bad.length) {
  console.log(`${round}회차 ✗ [${doc}]`);
  for (const r of rows) console.log(`   ${r.verdict ? "○" : "✗"} ${w(r.name, 22)} ${JSON.stringify(r.out).slice(0, 110)}`);
} else {
  console.log(`${round}회차 통과 [${doc}] 시나리오 ${rows.length}개`);
  for (const r of rows) console.log(`   ○ ${w(r.name, 22)} ${JSON.stringify(r.out).slice(0, 100)}`);
}
process.exit(bad.length ? 1 : 0);
