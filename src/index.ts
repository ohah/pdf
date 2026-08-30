// @ohah/pdf — 브라우저에서 PDF 를 읽고 그리고 고친다.
//
// 엔진은 Zig 로 짜 wasm 하나로 굽고, 워커에서 돌린다. 화면 갈래는 그린
// 결과만 받아 canvas 에 얹는다 — 큰 문서를 열어도 화면이 멎지 않는다.
//
//   import { PdfDoc } from "@ohah/pdf";
//
//   const pdf = await PdfDoc.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
//   await pdf.render(1, canvas, { scale: 1.5 });
//   const text = await pdf.text(1);
//   pdf.close();
import { PdfClient, type PageMsg, type OpenMsg, type BuildSpec } from "./client.js";
import { drawOps, toLines, type TextRun } from "./draw.js";
import { type Paths } from "./config.js";
import { checkSignature, type SigCheck } from "./sig.js";

export type { Paths } from "./config.js";
export type { BuildSpec, Mask, PageMsg } from "./client.js";
export type { TextRun } from "./draw.js";
export type { SigCheck } from "./sig.js";
export { toLines } from "./draw.js";
export { PdfClient } from "./client.js";

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
};

/** 쪽 하나를 그린 결과. 글자층을 손수 지을 때 쓴다. */
export type RenderResult = {
  /** 글자 한 덩이씩의 자리와 폭. 투명한 글자층을 얹을 때 쓴다. */
  runs: TextRun[];
  /** 쪽 크기(pt) */
  width: number;
  height: number;
  /** /Rotate */
  rotate: number;
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
export class PdfDoc {
  private cl: PdfClient;
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

  private constructor(cl: PdfClient, r: OpenMsg, raw: Uint8Array) {
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
    const cl = new PdfClient(opts);
    const r = await cl.open(raw.slice(), opts.password ?? "");
    if (r.needPw) {
      cl.close();
      throw new PasswordNeeded();
    }
    if (r.err || !r.pages) {
      cl.close();
      throw new Error(r.err === "큼" ? "파일이 너무 큽니다" : "PDF 를 읽지 못했습니다");
    }
    return new PdfDoc(cl, r, keep);
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

  /** 쪽 하나를 canvas 에 그린다. 쪽 번호는 1 부터다. */
  async render(page: number, canvas: HTMLCanvasElement, opts: RenderOpts = {}): Promise<RenderResult> {
    const q = await this.get(page, opts.formLayer !== false);
    const fams = this.fams.get(page) ?? [];
    const scale = opts.scale ?? 1;
    const dpr = opts.dpr ?? Math.min(globalThis.devicePixelRatio || 1, 2);
    const swap = q.rot === 90 || q.rot === 270;
    const cssW = (swap ? q.h : q.w) * scale;
    const cssH = (swap ? q.w : q.h) * scale;
    canvas.width = Math.max(1, Math.round(cssW * dpr));
    canvas.height = Math.max(1, Math.round(cssH * dpr));
    canvas.style.width = `${Math.round(cssW)}px`;
    canvas.style.height = `${Math.round(cssH)}px`;
    const runs = drawOps(canvas, {
      ops: q.ops, text: q.drw, read: q.rtx, pageW: q.w, pageH: q.h,
      bitmap: q.bitmap, bitmaps: q.bitmaps, stencils: q.stencils,
      originX: q.x0, originY: q.y0, rotate: q.rot,
      fontFamily: (i) => fams[i - 1],
      fontIsPua: (i) => q.fonts[i - 1]?.pua === true,
      fontUnusable: (i) => {
        const f = q.fonts[i - 1];
        return !!f && (f.kind & 128) === 0 && !fams[i - 1];
      },
      inline: q.inline,
    });
    return { runs, width: q.w, height: q.h, rotate: q.rot };
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
        out.push({ ...one, ...({ ok: false, note: "확인하지 못했습니다" } as SigCheck) });
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

  close() {
    this.cl.close();
    this.cache.clear();
  }
}

/** 암호가 있어야 열리는 문서다. 암호를 받아 다시 open 을 부른다. */
export class PasswordNeeded extends Error {
  constructor() {
    super("암호가 필요합니다");
    this.name = "PasswordNeeded";
  }
}
