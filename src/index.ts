// @ohah/pdf — 브라우저에서 PDF 를 읽고 그리고 고친다.
//
// 엔진은 Zig 로 짜 wasm 하나로 굽고, 워커에서 돌린다. 화면 갈래는 그린
// 결과만 받아 canvas 에 얹는다 — 큰 문서를 열어도 화면이 멎지 않는다.
//
//   import { PDFDocument } from "@ohah/pdf";
import { loadBytes } from "./bytes.js";
//
//   const pdf = await PDFDocument.open(bytes, { wasm: "/pdf.wasm", cmaps: "/cmaps" });
//   await pdf.render(1, canvas, { scale: 1.5 });
//   const text = await pdf.text(1);
//   pdf.close();
import { PDFClient, type PageMsg, type OpenMsg, type BuildSpec } from "./client.js";
import { openRanged, fillRest, type Ranged } from "./range.js";
import { drawOps, toLines, type TextRun } from "./draw.js";
import { type Paths } from "./config.js";
import { checkSignature, type SigCheck } from "./sig.js";
import { makeViewport, type Viewport } from "./viewport.js";

export type { Paths } from "./config.js";
export type { BuildSpec, Mask, PageMsg } from "./client.js";
export type { TextRun, Stencil } from "./draw.js";
export type { SigCheck } from "./sig.js";
export { checkSignature } from "./sig.js";
export { runCalc, recalculate, type CalcField, type ValueOf } from "./formjs.js";
export { readXfa, drawXfa, toPt, formCalc, type XfaForm, type XfaPage, type XfaBox } from "./xfa.js";
export { toLines, drawOps } from "./draw.js";
export { renderTextLayer, type TextLayer, type TextLayerOpts } from "./textlayer.js";
export { renderAnnotationLayer, type Annot, type AnnotLayer, type AnnotLayerOpts } from "./annotlayer.js";
export { makeViewport, type Viewport } from "./viewport.js";
export { toScreen, placeRect, type PageBox, type Placed } from "./place.js";
export { PDFClient } from "./client.js";

/**
 * 무엇을 주든 바이트로 바꾼다. 주소면 받아 오면서 진행률을 알린다.
 *
 * pdf.js 는 range 요청으로 앞부분만 받아 첫 쪽을 먼저 그린다. 우리 엔진은
 * 파일 전체로 객체 색인을 만들기 때문에 아직 그렇게 못 한다 — 대신 받는
 * 동안 얼마나 왔는지 알려 주고, 중간에 그만둘 수 있게 한다.
 */
async function toBytes(src: Source, opts: OpenOpts): Promise<Uint8Array> {
  if (src instanceof Uint8Array) return src;
  if (src instanceof ArrayBuffer) return new Uint8Array(src);
  if (typeof Blob !== "undefined" && src instanceof Blob) {
    return new Uint8Array(await src.arrayBuffer());
  }
  if (!(src instanceof Response)) {
    // Node 에서는 주소 대신 파일 경로가 온다 — fetch 로는 못 읽는다
    const where = String(src);
    const proc = (globalThis as { process?: { versions?: { node?: string } } }).process;
    if (proc?.versions?.node && !/^(https?|blob|data):/.test(where)) {
      stopIfAborted(opts.signal);
      const bytes = await loadBytes(where);
      stopIfAborted(opts.signal);
      if (!bytes) throw new Error(`could not read ${where}`);
      opts.onProgress?.({ loaded: bytes.length, total: bytes.length });
      return sniff(bytes, "");
    }
  }
  const res = src instanceof Response
    ? src
    : await fetch(String(src), { signal: opts.signal });
  if (!res.ok) throw new Error(`could not fetch the PDF (HTTP ${res.status})`);
  const total = Number(res.headers.get("content-length") ?? 0);
  const kind = res.headers.get("content-type") ?? "";
  if (!res.body || !opts.onProgress) {
    const buf = new Uint8Array(await res.arrayBuffer());
    opts.onProgress?.({ loaded: buf.length, total: total || buf.length });
    return sniff(buf, kind);
  }
  // 조각을 받을 때마다 알린다
  const reader = res.body.getReader();
  const parts: Uint8Array[] = [];
  let loaded = 0;
  for (;;) {
    if (opts.signal?.aborted) {
      await reader.cancel().catch(() => {});
      throw new Error("loading was cancelled");
    }
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    loaded += value.length;
    opts.onProgress({ loaded, total });
  }
  const out = new Uint8Array(loaded);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return sniff(out, kind);
}

/**
 * 받아 온 것이 PDF 가 맞는지 살짝 본다.
 *
 * 주소를 잘못 적으면 서버가 404 대신 안내 쪽(HTML)을 200 으로 주는 일이
 * 흔하다. 그걸 그대로 엔진에 넘기면 "PDF 를 읽지 못했습니다" 라는 엉뚱한
 * 말이 나온다 — 무엇이 왔는지 알려 준다. 머리글이 없어도 살릴 수 있는
 * 문서가 있으므로, HTML 이 분명할 때만 막는다.
 */
function sniff(buf: Uint8Array, kind: string): Uint8Array {
  const head = new TextDecoder("latin1").decode(buf.subarray(0, 1024));
  if (head.includes("%PDF")) return buf;
  if (/html|xml|json|text\/plain/i.test(kind) || /^\s*<(!doctype|html)/i.test(head)) {
    throw new Error(
      `the server did not return a PDF (content-type: ${kind || "unknown"}). ` +
      "check the URL",
    );
  }
  return buf;
}

/** 구조 나무의 마디 하나 */
export type StructNode = {
  /** Document·H1·P·Table … (/S). 뿌리는 "Root" */
  role: string;
  /** 그림 등에 붙는 대체 글 (/Alt) */
  alt: string;
  /** 놓인 쪽(0부터). 모르면 -1 */
  page: number;
  /** 본문에서 이 마디를 가리키는 표식. 잎이 아니면 -1 */
  mcid: number;
  children: StructNode[];
};

export type OpenOpts = Paths & {
  /** 잠긴 문서의 암호. 틀리면 needPassword 가 선다. */
  password?: string;
  /**
   * 내려받는 동안 얼마나 왔는지 알려 준다. 주소로 열 때만 부른다.
   *
   * `total` 은 서버가 길이를 안 알려 주면 0 이다(그럴 때도 loaded 는 는다).
   */
  onProgress?: (p: { loaded: number; total: number }) => void;
  /** 내려받기를 그만둔다 */
  signal?: AbortSignal;
  /**
   * 주소로 열 때 파일을 통째로 받지 않고 토막만 받아 먼저 연다.
   *
   * 서버가 범위 요청(Range)을 받아 주고 파일이 512KB 를 넘을 때만 쓴다.
   * 그렇지 않으면 저절로 통째로 받는다. 끄려면 false.
   * 토막만 받은 문서는 `partial` 이 true 이고, `complete()` 로 마저 받는다.
   */
  range?: boolean;
};

/** 열 수 있는 것들. 주소를 주면 받아 오면서 진행률을 알려 준다. */
/** build() 에 주는 것. 다 안 적어도 된다 — 안 적으면 그대로 둔다. */
/**
 * 밖에서 부를 수 있게 이름을 붙인 것들.
 *
 * 메서드가 돌려주는 꼴을 그 자리에 적어 두면 쓰는 쪽이 그걸 가리킬 수가 없다 —
 * `const items: ??? = await pdf.textItems(1)` 에서 막힌다. 함수 하나를 건너
 * 넘길 때마다 `Awaited<ReturnType<...>>` 를 쓰게 하지 않으려고 이름을 준다.
 */

/** 목차 한 줄. `page` 는 0부터 */
export type OutlineItem = { depth: number; title: string; page: number };

/** 문서가 밝힌 허락. 암호가 없으면 모두 true 다 */
export type Permissions = {
  print: boolean; modify: boolean; copy: boolean; annotate: boolean;
  fillForms: boolean; accessibility: boolean; assemble: boolean; printHighRes: boolean;
};

/** 레이어(선택 콘텐츠) 하나 */
export type Layer = { name: string; on: boolean };

/** 딸린 파일 하나 */
export type Attachment = { name: string };

/** 이름 목적지 하나. 못 풀면 `page` 는 -1 */
export type Destination = { name: string; page: number };

/**
 * 문서가 적어 둔 "열면 여기부터" (/OpenAction). 쪽은 0부터다.
 *
 * 좌표는 쪽 좌표(pt)이고, null 은 "지금 값을 그대로 두라" 는 뜻이다 —
 * 규격이 그렇게 정한다(12.3.2.2).
 */
export type OpenAction = {
  page: number;
  kind: "XYZ" | "Fit" | "FitH" | "FitV" | "FitR" | "FitB" | "FitBH" | "FitBV";
  x: number | null;
  y: number | null;
  zoom: number | null;
};

/** 글자 덩이 하나 — pdf.js 의 TextItem 자리 */
export type TextItem = {
  str: string; x: number; y: number; size: number;
  /** 이 덩이를 그린 글꼴 이름. 문서가 안 적어 두면 빈 문자열 */
  font: string;
  /** 쓰는 방향 — 세로쓰기면 "ttb", 아랍·히브리면 "rtl", 그 밖은 "ltr" */
  dir: "ltr" | "rtl" | "ttb";
  /** 이 덩이가 줄의 끝인가 */
  hasEOL: boolean;
};

/** 입력 칸 하나 */
export type FormField = PageMsg["fields"][number];

/** 링크 하나 */
export type LinkItem = PageMsg["links"][number];

/** 주석 하나 — 형광펜·메모·네모·잉크·도장·링크·위젯을 가리지 않는다 */
export type Annotation = PageMsg["annots"][number];

/** 서명 하나 — 맞춰 본 결과에 이름·날짜·사유가 붙는다 */
export type Signature = SigCheck & { name: string; date: string; reason: string };

/** 이어 붙인 결과. `added` 는 붙은 쪽 수 */
export type MergeResult = { bytes: Uint8Array; added: number };

export type BuildOpts = Partial<BuildSpec>;

export type Source = Uint8Array | ArrayBuffer | Blob | Response | string | URL;

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
  // FontFace 는 문서에 다는 것이라 브라우저에만 있다. Node 에서는 건너뛴다 —
  // 글자 뽑기에는 필요 없고, 그리기는 어차피 캔버스가 있어야 한다.
  if (typeof FontFace === "undefined" || typeof document === "undefined") return undefined;
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
  /** 닫혔는가 */
  private shut = false;
  private cache = new Map<string, PageMsg>();
  private fams = new Map<string, (string | undefined)[]>();
  private raw: Uint8Array;

  /** 쪽 수 */
  readonly pages!: number;
  /** 쪽이 너무 많아 뒤를 잘라 냈는가. 그렇다면 `pages` 는 문서의 전부가 아니다 */
  readonly truncated!: boolean;
  /** 잠긴 문서였나 */
  readonly locked!: boolean;
  /** 목차 */
  readonly outline!: OutlineItem[];
  /** 문서 속성 (제목·글쓴이 …) */
  readonly info!: string[];
  /** 레이어(선택 콘텐츠) */
  readonly layers!: Layer[];
  /** 딸린 파일 이름 */
  readonly attachments!: Attachment[];
  /** XFA 양식인가 — 그렇다면 쪽이 거의 비어 있는 것이 정상이다 */
  readonly isXfa!: boolean;
  /**
   * 문서가 허락한 것들. 암호가 없으면 모두 true 다.
   *
   * 강제가 아니라 문서가 밝힌 뜻이다 — 뷰어가 인쇄·복사 단추를 흐리게 하는
   * 데 쓴다(pdf.js 의 getPermissions 와 같은 비트다).
   */
  readonly permissions!: Permissions;
  /** 열 때 옆판을 어떻게 둘지 — UseOutlines·UseThumbs·FullScreen … (/PageMode) */
  readonly pageMode!: string;
  /** 한 쪽·두 쪽 보기 — SinglePage·TwoColumnLeft … (/PageLayout) */
  readonly pageLayout!: string;
  /** 파일 지문(/ID). 문서마다 다른 값이라 마지막 쪽·확대율을 저장하는 열쇠로 쓴다 */
  readonly fingerprint!: string;
  /** 태그 PDF 인가 — 읽는 차례 정보가 들어 있다는 뜻 */
  readonly tagged!: boolean;
  /** 문서 언어 (/Lang) */
  readonly lang!: string;
  /** 쪽 라벨(i, ii, A-1 …). 문서가 안 적어 두면 빈 배열 */
  readonly pageLabels!: string[];
  /**
   * 이름 목적지. 목차·링크가 "3쪽" 대신 이름으로 가리키는 문서가 흔하다.
   * `page` 는 0부터이고, 못 풀면 -1 이다.
   */
  readonly destinations!: Destination[];
  /**
   * 문서가 "열면 여기부터 보여라" 고 적어 둔 자리(/OpenAction). 없으면 null.
   *
   * `page` 는 0부터다. `kind` 는 XYZ·Fit·FitH … 이고, 좌표는 쪽 좌표(pt)라
   * null 이면 "지금 값을 그대로 두라" 는 뜻이다. 갈 데가 없는 동작(문서를
   * 열 때 실행하는 자바스크립트 따위)은 null 로 온다.
   */
  readonly openAction!: OpenAction | null;
  /**
   * 값이 바뀌면 다시 셈할 차례 (/AcroForm /CO) — 칸의 객체 번호다.
   * 문서가 안 정해 두면 빈 배열이고, 그때는 나온 차례대로 셈한다.
   */
  readonly calcOrder!: number[];
  /**
   * XFA 양식의 XML 원문. XFA 가 아니면 빈 문자열이다.
   *
   * `readXfa()` 로 뜯어 `drawXfa()` 로 그릴 수 있다 — 정적인 양식만이다.
   */
  readonly xfaXml!: string;
  /** 뷰어 설정 (/ViewerPreferences) — HideToolbar·Direction·PrintScaling … */
  readonly viewerPreferences!: Record<string, string>;
  /** XMP 메타데이터 원문(RDF/XML). 문서에 없으면 빈 문자열 */
  readonly xmp!: string;
  /** 토막만 받아 연 문서인가. `complete()` 로 마저 받는다 */
  partial = false;
  private rest: { url: string; ranged: Ranged; opts: OpenOpts } | null = null;
  private structFlat!: NonNullable<OpenMsg["struct"]>;
  private sigsRaw!: NonNullable<OpenMsg["sigs"]>;

  private constructor(cl: PDFClient, r: OpenMsg, raw: Uint8Array) {
    this.cl = cl;
    this.raw = raw;
    this.take(r);
  }

  /**
   * 엔진이 준 문서 정보를 받아 담는다.
   *
   * 나머지 토막을 마저 받아 다시 읽을 때도 여기로 온다 — 그때는 쪽 수부터
   * 목차까지 다 달라질 수 있다(앞머리만 보고 연 것이었으므로).
   */
  private take(r: OpenMsg) {
    const w = this as unknown as { -readonly [K in keyof PDFDocument]: PDFDocument[K] };
    w.pages = r.pages ?? 0;
    w.locked = r.locked === true;
    w.outline = r.outline ?? [];
    w.info = r.info ?? [];
    w.layers = r.layers ?? [];
    w.attachments = r.atts ?? [];
    w.isXfa = r.xfa === true;
    w.xfaXml = r.xfaXml ?? "";
    // /P 비트. 규격이 정한 자리다(3=인쇄, 4=고침, 5=복사, 6=주석 …).
    //
    // 이 값은 **원래 음수로 적힌다** — 위쪽 비트가 다 켜져 있기 때문이다.
    // 그래서 "음수면 제한 없음" 으로 보면 안 된다. 부호 없는 값으로 바꿔
    // 비트만 본다. 암호가 없으면 -1 이라 모든 비트가 켜져 저절로 전부 허락이 된다.
    const p = r.perm ?? -1;
    const can = (bit: number) => ((p >>> 0) & (1 << (bit - 1))) !== 0;
    w.permissions = {
      print: can(3), modify: can(4), copy: can(5), annotate: can(6),
      fillForms: can(9), accessibility: can(10), assemble: can(11), printHighRes: can(12),
    };
    w.pageMode = r.pageMode ?? "";
    w.pageLayout = r.pageLayout ?? "";
    w.fingerprint = r.fingerprint ?? "";
    w.tagged = r.tagged === true;
    w.lang = r.lang ?? "";
    w.pageLabels = r.labels ?? [];
    w.destinations = r.dests ?? [];
    w.openAction = (r.openAction as OpenAction | null | undefined) ?? null;
    w.calcOrder = r.calcOrder ?? [];
    w.viewerPreferences = r.prefs ?? {};
    w.xmp = r.xmp ?? "";
    this.structFlat = r.struct ?? [];
    w.truncated = r.truncated === true;
    this.sigsRaw = r.sigs ?? [];
  }

  /**
   * 문서를 연다.
   *
   * 암호가 틀리면 PasswordNeeded 를 던진다 — 받아서 다시 부르면 된다.
   */
  static async open(src: Source, opts: OpenOpts = {}) {
    // 주소로 여는 큰 파일은 토막만 받아 먼저 연다. 서버가 안 받아 주면
    // openRanged 가 null 을 주고, 아래에서 통째로 받는 길로 간다.
    const url = typeof src === "string" && /^https?:/i.test(src) ? src : "";
    let ranged: Ranged | null = null;
    if (url && opts.range !== false && typeof fetch === "function") {
      ranged = await openRanged(url, opts).catch(() => null);
    }
    let raw = ranged ? ranged.bytes : await toBytes(src, opts);
    const cl = new PDFClient(opts);
    let r = await cl.open(raw.slice(), opts.password ?? "");
    // 토막만으로는 못 읽는 문서가 있다(선형화가 아니고 앞머리·꼬리 밖에
    // 카탈로그가 있는 경우). 그럴 때는 조용히 다 받아 다시 읽는다.
    if (ranged && (r.err || !r.pages) && !r.needPw) {
      await fillRest(url, ranged, opts);
      ranged = null;
      r = await cl.open(raw.slice(), opts.password ?? "");
    }
    const keep = raw.slice();
    if (r.needPw) {
      cl.close();
      throw new PasswordNeeded();
    }
    if (r.err || !r.pages) {
      cl.close();
      throw new Error(
        r.err === "too-large"
          ? `the file is too large — ${(raw.length / 1048576).toFixed(0)}MB, the engine takes up to ${Math.round((r.max ?? 0) / 1048576)}MB`
        : r.err === "no-memory" ? "could not reserve memory"
        : "could not read the PDF",
      );
    }
    const doc = new PDFDocument(cl, r, keep);
    if (ranged?.partial) {
      doc.partial = true;
      doc.rest = { url, ranged, opts };
    }
    return doc;
  }

  /**
   * 토막만 받아 연 문서의 나머지를 마저 받아 다시 읽는다.
   *
   * 첫 쪽을 그린 뒤 부르면 된다. 다 받은 뒤에는 쪽 수·목차·이름 자리까지
   * 새로 채워지므로, 화면이 들고 있던 값을 다시 읽어야 한다.
   * 이미 다 받았으면 아무 일도 하지 않는다.
   */
  async complete(): Promise<void> {
    const rest = this.rest;
    if (!rest || this.shut) return;
    this.rest = null;
    const bytes = await fillRest(rest.url, rest.ranged, rest.opts);
    if (this.shut) return;
    const r = await this.cl.open(bytes.slice(), rest.opts.password ?? "");
    if (this.shut) return;
    if (r.err || !r.pages) throw new Error("could not read the rest of the PDF");
    this.raw = bytes.slice();
    this.cache.clear();
    this.fams.clear();
    this.take(r);
    this.partial = false;
  }

  /**
   * 쪽 하나를 가져온다. `drawFields` 는 **밖에서 쓰는 뜻**이다 — 입력 칸
   * 겉모습을 그릴 것인가.
   *
   * 엔진이 받는 값은 그 반대다. 거기서 켠다는 것은 "화면이 제 입력 칸을
   * 얹을 테니 겉모습은 그리지 마라" 는 뜻이라, 그대로 넘기면 양식 문서가
   * 통째로 빈 쪽으로 나왔다. 담아 두는 자리도 이 값을 함께 열쇠로 삼는다 —
   * 안 그러면 먼저 부른 쪽의 값이 뒤엣것에 그대로 쓰인다.
   */
  private async get(i: number, drawFields: boolean) {
    const key = `${i}:${drawFields ? 1 : 0}`;
    const hit = this.cache.get(key);
    if (hit) return hit;
    const q = await this.cl.page(i - 1, !drawFields);
    // 기다리는 사이에 닫혔으면 담아 두지 않는다 — 담으면 닫은 뒤에도
    // 그 쪽만 계속 답해 준다.
    if (this.shut) throw new Error("the document is already closed");
    const fams: (string | undefined)[] = [];
    for (const f of q.fonts) fams.push(f.bytes ? await loadFont(f.bytes) : undefined);
    this.cache.set(key, q);
    this.fams.set(key, fams);
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
    // Node 에서 그리려면 node-canvas 같은 것을 만들어 넘겨야 한다. 아무것도
    // 안 넘기면 아래에서 알 수 없는 오류가 나므로 여기서 먼저 알린다.
    if (!canvas || typeof (canvas as { getContext?: unknown }).getContext !== "function") {
      throw new Error(
        "render() needs a canvas with getContext('2d'). "
        + "On Node, pass one from a canvas package, or use text()/textItems() to extract instead.",
      );
    }
    const draw = opts.formLayer !== false;
    const q = await this.get(page, draw);
    stopIfAborted(opts.signal);
    const fams = this.fams.get(`${page}:${draw ? 1 : 0}`) ?? [];
    const scale = opts.scale ?? 1;
    const dpr = opts.dpr ?? Math.min(globalThis.devicePixelRatio || 1, 2);
    const vp = makeViewport({
      w: q.w, h: q.h, x0: q.x0, y0: q.y0, rot: q.rot,
      scale, rotation: opts.rotation ?? 0,
    });
    canvas.width = Math.max(1, Math.round(vp.width * dpr));
    canvas.height = Math.max(1, Math.round(vp.height * dpr));
    // node-canvas 에는 style 이 없다 — 있을 때만 화면 크기를 적어 준다
    const style = (canvas as { style?: { width: string; height: string } }).style;
    if (style) {
      style.width = `${Math.round(vp.width)}px`;
      style.height = `${Math.round(vp.height)}px`;
    }
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

  /**
   * 쪽의 글자를 덩이째 준다 — pdf.js 의 getTextContent 자리다.
   *
   * 그리지 않고도 얻는다(가벼운 뽑기). 각 덩이는 자리·크기와 함께 그린
   * 글꼴 이름, 쓰는 방향, 줄 끝인지를 달고 온다.
   */
  async textItems(page: number): Promise<TextItem[]> {
    const q = await this.get(page, false);
    const out = q.items.map((it) => ({
      str: it.text, x: it.x, y: it.y, size: it.size,
      font: it.font, dir: it.dir, hasEOL: false,
    }));
    // 줄 끝 표시. 같은 줄에 있는 것끼리 묶고 그 줄의 마지막에 표시한다 —
    // 문서가 어디서 줄을 바꿨는지는 자리로만 알 수 있다.
    const byLine = new Map<number, number[]>();
    out.forEach((it, k) => {
      const key = Math.round(it.y / Math.max(1, it.size * 0.6));
      const list = byLine.get(key);
      if (list) list.push(k); else byLine.set(key, [k]);
    });
    for (const list of byLine.values()) {
      let last = list[0];
      for (const k of list) if (out[k].x > out[last].x) last = k;
      out[last].hasEOL = true;
    }
    return out;
  }

  /** 쪽 하나의 글자. 사람이 읽는 차례로 줄을 세워 준다. */
  async text(page: number) {
    const q = await this.get(page, false);
    return q.items.map((it) => it.text).join(" ");
  }

  /** 쪽 하나의 입력 칸 */
  async fields(page: number): Promise<FormField[]> {
    return (await this.get(page, false)).fields;
  }

  /** 쪽 하나의 링크 */
  async links(page: number): Promise<LinkItem[]> {
    return (await this.get(page, false)).links;
  }

  /**
   * 쪽에 달린 주석을 모두 준다 — 형광펜·메모·네모·잉크·도장·링크·위젯까지.
   *
   * 그리는 것은 `render()` 가 /AP 겉모습으로 이미 한다. 이건 목록·툴팁·
   * 뛰어가기처럼 **다루기 위한** 정보다(pdf.js 의 getAnnotations 자리).
   * 숨김 깃발(2)이 선 것도 그대로 준다 — 거르는 것은 쓰는 쪽 몫이다.
   */
  async annotations(page: number): Promise<Annotation[]> {
    return (await this.get(page, false)).annots;
  }

  /** 전자 서명을 확인한다. 브라우저 WebCrypto 로 맞춰 본다. */
  async signatures(): Promise<Signature[]> {
    // 열 때 걷어 둔 것을 쓰지만, 닫은 문서에 물으면 다른 것들처럼 거절한다 —
    // 하나만 대답하면 "닫혔는데 왜 되지" 가 된다.
    if (this.shut) throw new Error("the document is already closed");
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

  /**
   * 구조 나무 — 태그 PDF 가 적어 둔 읽는 차례와 뜻(제목·문단·표…).
   *
   * pdf.js 의 getStructTree 자리다. 쪽 번호를 주면 그 쪽에 놓인 가지만
   * 추린다. 태그가 없는 문서면 null 이다.
   */
  structure(page?: number): StructNode | null {
    if (this.structFlat.length === 0) return null;
    const want = page == null ? null : page - 1;
    const root: StructNode = { role: "Root", alt: "", page: -1, mcid: -1, children: [] };
    const stack: StructNode[] = [root];
    for (const n of this.structFlat) {
      const node: StructNode = {
        role: n.role, alt: n.alt, page: n.page, mcid: n.mcid, children: [],
      };
      stack.length = Math.min(stack.length, n.depth + 1);
      const parent = stack[stack.length - 1] ?? root;
      if (n.depth === 0 && parent === root && n.role === "Root") {
        // 뿌리는 하나로 둔다
        stack[0] = node;
        root.children = node.children;
        root.role = node.role;
        continue;
      }
      parent.children.push(node);
      stack[n.depth + 1] = node;
    }
    if (want == null) return root;
    // 그 쪽에 놓인 것만 남긴다 — 자식이 남으면 부모도 남긴다
    const keep = (n: StructNode): StructNode | null => {
      const kids = n.children.map(keep).filter((k): k is StructNode => k !== null);
      if (kids.length === 0 && n.page !== want && n.mcid < 0) return null;
      if (kids.length === 0 && n.page !== want) return null;
      return { ...n, children: kids };
    };
    return keep(root);
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
  build(spec: BuildOpts) {
    // 안 적은 것은 "손대지 않는다"로 채운다 — 쪽만 골라 새로 내는
    // 흔한 쓰임에서 빈 배열을 열 개씩 적게 하지 않으려는 것이다.
    return this.cl.build({
      pick: spec.pick ?? Array.from({ length: this.pages }, (_, k) => k),
      rotate: spec.rotate ?? 0,
      pageRot: spec.pageRot ?? [],
      watermark: spec.watermark ?? "",
      wmMask: spec.wmMask,
      fields: spec.fields ?? [],
      newFields: spec.newFields ?? [],
      notes: spec.notes ?? [],
      labels: spec.labels ?? [],
      shrink: spec.shrink ?? false,
      encryptPw: spec.encryptPw,
    });
  }

  /** 다 만든 바이트에 암호를 건다 */
  encrypt(bytes: Uint8Array, password: string) {
    return this.cl.seal(bytes, password);
  }

  /** 다른 PDF 를 뒤에 잇는다 */
  merge(bytes: Uint8Array): Promise<MergeResult | null> {
    return this.cl.merge(bytes);
  }

  /** 워커를 닫는다. 두 번 불러도 된다. 닫은 뒤 부르면 바로 오류가 난다. */
  close() {
    this.shut = true;
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
