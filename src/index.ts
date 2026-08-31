// @ohah/pdf — 브라우저에서 PDF 를 읽고 그리고 고친다.
//
// 엔진은 Zig 로 짜 wasm 하나로 굽고, 워커에서 돌린다. 화면 갈래는 그린
// 결과만 받아 canvas 에 얹는다 — 큰 문서를 열어도 화면이 멎지 않는다.
//
//   import { PDFDocument } from "@ohah/pdf";
//
//   const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
//   await pdf.render(1, canvas, { scale: 1.5 });
//   const text = await pdf.text(1);
//   pdf.close();
import { PDFClient, type PageMsg, type OpenMsg, type BuildSpec } from "./client.js";
import { drawOps, toLines, type TextRun } from "./draw.js";
import { type Paths } from "./config.js";
import { checkSignature, type SigCheck } from "./sig.js";
import { makeViewport, type Viewport } from "./viewport.js";

export type { Paths } from "./config.js";
export type { BuildSpec, Mask, PageMsg } from "./client.js";
export type { TextRun } from "./draw.js";
export type { SigCheck } from "./sig.js";
export { toLines } from "./draw.js";
export { renderTextLayer, type TextLayer, type TextLayerOpts } from "./textlayer.js";
export { makeViewport, type Viewport } from "./viewport.js";
export { toScreen, placeRect, type PageBox, type Placed } from "./place.js";
export { PDFClient } from "./client.js";

export type OpenOpts = Paths & {
  /** 잠긴 문서의 암호. 틀리면 needPassword 가 선다. */
  password?: string;
};

export type RenderOpts = {
  /** 1 이면 PDF 자리 그대로(72dpi). 화면 밀도는 알아서 곱한다. */
  scale?: number;
  /** 화면 밀도. 기본은 devicePixelRatio(최대 2). */
  dpr?: number;
  /** 입력 칸 겉모습을 그릴지. 진짜 입력 칸을 얹을 거면 false 로 둔다. */
  formLayer?: boolean;
  /** 문서의 /Rotate 에 **더할** 회전. 90 단위다 — 뷰어의 "돌리기" 단추용. */
  rotation?: number;
  /** 바탕색. 기본은 흰색. "transparent" 면 안 칠한다. */
  background?: string;
  /** 그만두기. 스크롤로 지나간 쪽을 버릴 때 쓴다. */
  signal?: AbortSignal;
};

/** 쪽 하나를 그린 결과. 글자층을 손수 지을 때 쓴다. */
export type RenderResult = {
  /** 글자 한 덩이씩의 자리와 폭. 투명한 글자층을 얹을 때 쓴다. */
  runs: TextRun[];
  /** 쪽 크기(pt) */
  width: number;
  height: number;
  /** 문서의 /Rotate 에 사용자 회전을 더한 최종 각 */
  rotate: number;
  /** 이 렌더에 쓰인 뷰포트 — 얹는 것들의 자리를 여기서 구한다 */
  viewport: Viewport;
};

const fontCache = new Map<string, Promise<string | undefined>>();
let fontSeq = 0;

/** 문서에 박힌 글꼴을 브라우저에 등록한다. 실패하면 undefined 다. */
async function loadFont(bytes: Uint8Array): Promise<string | undefined> {
  let h = 2166136261;
  const step = Math.max(1, Math.floor(bytes.length / 512));
  for (let i = 0; i < bytes.length; i += step) h = ((h ^ bytes[i]) * 16777619) >>> 0;
  const key = `${bytes.length}-${h.toString(36)}`;
  const hit = fontCache.get(key);
  if (hit) return hit;
  const fam = `ohahpdf${fontSeq++}`;
  const buf = bytes.slice().buffer;
  const task = (async () => {
    try {
      const ff = new FontFace(fam, buf as ArrayBuffer);
      await ff.load();
      (document as unknown as { fonts: FontFaceSet }).fonts.add(ff);
      return fam;
    } catch {
      // 브라우저가 거절한 글꼴 — 시스템 글꼴로 대신 그린다
      return undefined;
    }
  })();
  fontCache.set(key, task);
  return task;
}

/** 열어 둔 문서 하나. */
export class PDFDocument {
  private cl: PDFClient;
  private cache = new Map<number, PageMsg>();
  private fams = new Map<number, (string | undefined)[]>();
  private raw: Uint8Array;

  /** 쪽 수 */
  readonly pages: number;
  /** 잠긴 문서였나 */
  readonly locked: boolean;
  /** 목차 */
  readonly outline: { depth: number; title: string; page: number }[];
  /** 문서 속성 (제목·글쓴이 …) */
  readonly info: string[];
  /** 레이어(선택 콘텐츠) */
  readonly layers: { name: string; on: boolean }[];
  /** 딸린 파일 이름 */
  readonly attachments: { name: string }[];
  /** XFA 양식인가 — 그렇다면 쪽이 거의 비어 있는 것이 정상이다 */
  readonly isXfa: boolean;
  private sigsRaw: NonNullable<OpenMsg["sigs"]>;

  private constructor(cl: PDFClient, r: OpenMsg, raw: Uint8Array) {
    this.cl = cl;
    this.raw = raw;
    this.pages = r.pages ?? 0;
    this.locked = r.locked === true;
    this.outline = r.outline ?? [];
    this.info = r.info ?? [];
    this.layers = r.layers ?? [];
    this.attachments = r.atts ?? [];
    this.isXfa = r.xfa === true;
    this.sigsRaw = r.sigs ?? [];
  }

  /**
   * 문서를 연다.
   *
   * 암호가 틀리면 PasswordNeeded 를 던진다 — 받아서 다시 부르면 된다.
   */
  static async open(bytes: Uint8Array | ArrayBuffer, opts: OpenOpts = {}) {
    const raw = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    const keep = raw.slice();
    const cl = new PDFClient(opts);
    const r = await cl.open(raw.slice(), opts.password ?? "");
    if (r.needPw) {
      cl.close();
      throw new PasswordNeeded();
    }
    if (r.err || !r.pages) {
      cl.close();
      throw new Error(
        r.err === "too-large" ? "the file is too large"
        : r.err === "no-memory" ? "could not reserve memory"
        : "could not read the PDF",
      );
    }
    return new PDFDocument(cl, r, keep);
  }

  private async get(i: number, formLayer: boolean) {
    const hit = this.cache.get(i);
    if (hit) return hit;
    const q = await this.cl.page(i - 1, formLayer);
    const fams: (string | undefined)[] = [];
    for (const f of q.fonts) fams.push(f.bytes ? await loadFont(f.bytes) : undefined);
    this.cache.set(i, q);
    this.fams.set(i, fams);
    return q;
  }

  /**
   * 쪽 하나를 canvas 에 그린다. 쪽 번호는 1 부터다.
   *
   * `signal` 로 그만둘 수 있다. 워커가 이미 집어 든 일은 끝까지 가지만,
   * 결과를 버리고 캔버스에는 손대지 않는다 — 빠르게 스크롤할 때 지나간
   * 쪽이 나중에 덮어 그리는 것을 막는다.
   */
  async render(page: number, canvas: HTMLCanvasElement, opts: RenderOpts = {}): Promise<RenderResult> {
    stopIfAborted(opts.signal);
    const q = await this.get(page, opts.formLayer !== false);
    stopIfAborted(opts.signal);
    const fams = this.fams.get(page) ?? [];
    const scale = opts.scale ?? 1;
    const dpr = opts.dpr ?? Math.min(globalThis.devicePixelRatio || 1, 2);
    const vp = makeViewport({
      w: q.w, h: q.h, x0: q.x0, y0: q.y0, rot: q.rot,
      scale, rotation: opts.rotation ?? 0,
    });
    canvas.width = Math.max(1, Math.round(vp.width * dpr));
    canvas.height = Math.max(1, Math.round(vp.height * dpr));
    canvas.style.width = `${Math.round(vp.width)}px`;
    canvas.style.height = `${Math.round(vp.height)}px`;
    const runs = drawOps(canvas, {
      ops: q.ops, text: q.drw, read: q.rtx, pageW: q.w, pageH: q.h,
      bitmap: q.bitmap, bitmaps: q.bitmaps, stencils: q.stencils,
      originX: q.x0, originY: q.y0, rotate: vp.rotation,
      background: opts.background,
      fontFamily: (i) => fams[i - 1],
      fontIsPua: (i) => q.fonts[i - 1]?.pua === true,
      fontUnusable: (i) => {
        const f = q.fonts[i - 1];
        return !!f && (f.kind & 128) === 0 && !fams[i - 1];
      },
      inline: q.inline,
    });
    return { runs, width: q.w, height: q.h, rotate: vp.rotation, viewport: vp };
  }

  /**
   * 그만둘 수 있는 렌더. pdf.js 의 RenderTask 와 같은 모양이다.
   *
   *   const task = pdf.renderTask(1, canvas, { scale });
   *   task.cancel();               // 스크롤로 지나갔을 때
   *   await task.promise;          // RenderCancelled 가 난다
   */
  renderTask(page: number, canvas: HTMLCanvasElement, opts: RenderOpts = {}) {
    const ac = new AbortController();
    if (opts.signal) {
      if (opts.signal.aborted) ac.abort();
      else opts.signal.addEventListener("abort", () => ac.abort(), { once: true });
    }
    return {
      promise: this.render(page, canvas, { ...opts, signal: ac.signal }),
      cancel: () => ac.abort(),
    };
  }

  /**
   * 쪽의 뷰포트. 그리지 않고 자리만 계산할 때 쓴다 — 자리 잡기·클릭 위치·
   * 스크롤 높이 미리 재기 같은 것.
   */
  async viewport(page: number, opts: { scale?: number; rotation?: number } = {}): Promise<Viewport> {
    const q = await this.get(page, false);
    return makeViewport({
      w: q.w, h: q.h, x0: q.x0, y0: q.y0, rot: q.rot,
      scale: opts.scale ?? 1, rotation: opts.rotation ?? 0,
    });
  }

  /** 연 문서의 원본 바이트. 내려받기 단추에 그대로 쓴다. */
  data(): Uint8Array {
    return this.raw.slice();
  }

  /** 쪽 하나의 글자. 사람이 읽는 차례로 줄을 세워 준다. */
  async text(page: number) {
    const q = await this.get(page, false);
    return q.items.map((it) => it.text).join(" ");
  }

  /** 쪽 하나의 입력 칸 */
  async fields(page: number) {
    return (await this.get(page, true)).fields;
  }

  /** 쪽 하나의 링크 */
  async links(page: number) {
    return (await this.get(page, true)).links;
  }

  /** 전자 서명을 확인한다. 브라우저 WebCrypto 로 맞춰 본다. */
  async signatures(): Promise<(SigCheck & { name: string; date: string; reason: string })[]> {
    const out = [];
    for (const g of this.sigsRaw) {
      const one = { name: g.name, date: g.date, reason: g.reason };
      try {
        out.push({ ...one, ...(await checkSignature(this.raw, g.der, g.range, g.covers)) });
      } catch {
        out.push({ ...one, ...({ ok: false, note: "could not be checked" } as SigCheck) });
      }
    }
    return out;
  }

  /** 딸린 파일 하나를 꺼낸다 */
  attachment(i: number) {
    return this.cl.attach(i);
  }

  /** 레이어를 켜고 끈다. 그린 것은 지워지므로 다시 render 한다. */
  async setLayers(on: boolean[]) {
    await this.cl.layers(on);
    this.cache.clear();
    this.fams.clear();
  }

  /** 새 PDF 를 만든다 (쪽 고르기·회전·워터마크·주석·양식·암호). */
  build(spec: BuildSpec) {
    return this.cl.build(spec);
  }

  /** 다 만든 바이트에 암호를 건다 */
  encrypt(bytes: Uint8Array, password: string) {
    return this.cl.seal(bytes, password);
  }

  /** 다른 PDF 를 뒤에 잇는다 */
  merge(bytes: Uint8Array) {
    return this.cl.merge(bytes);
  }

  /** 워커를 닫는다. 두 번 불러도 된다. 닫은 뒤 부르면 바로 오류가 난다. */
  close() {
    this.cl.close();
    this.cache.clear();
    this.fams.clear();
  }
}

/**
 * 링크 주소가 열어도 되는 것인지 본다. 아니면 null 이다.
 *
 * 문서 안의 `/URI` 는 만든 이가 적어 넣은 값이라 `javascript:` 도 올 수 있다.
 * 그걸 그대로 `<a href>` 에 넣으면 문서가 뷰어의 출처에서 스크립트를 돌린다.
 * 링크를 걸기 전에 여기를 지나게 한다.
 *
 *   const href = safeUrl(link.uri);
 *   if (href) a.href = href;
 */
export function safeUrl(uri: string): string | null {
  const t = (uri ?? "").trim();
  if (!t) return null;
  // 스킴 없는 상대 주소는 문서가 열린 곳을 기준으로 도니 그대로 둔다
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(t);
  if (!m) return t;
  const ok = ["http", "https", "mailto", "tel", "ftp", "ftps"];
  return ok.includes(m[1].toLowerCase()) ? t : null;
}

/** 렌더를 그만뒀다. `signal` 로 끊었거나 `renderTask().cancel()` 을 불렀을 때다. */
export class RenderCancelled extends Error {
  constructor() {
    super("rendering was cancelled");
    this.name = "RenderCancelled";
  }
}

function stopIfAborted(signal?: AbortSignal) {
  if (signal?.aborted) throw new RenderCancelled();
}

/** 암호가 있어야 열리는 문서다. 암호를 받아 다시 open 을 부른다. */
export class PasswordNeeded extends Error {
  constructor() {
    super("a password is required");
    this.name = "PasswordNeeded";
  }
}
