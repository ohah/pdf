/**
 * 파일을 통째로 받지 않고 필요한 토막만 받아 온다.
 *
 * 100MB 짜리를 열면 100MB 를 다 받은 뒤에야 첫 쪽이 떴다. 규격에는 그러라고
 * 적혀 있지 않다 — 상호참조표는 꼬리에 있고, "선형화(linearized)" 된 파일은
 * 첫 쪽에 필요한 것을 앞머리에 몰아 둔다. 그래서 꼬리와 앞머리만 받아도
 * 첫 쪽은 그릴 수 있다. pdf.js 가 하는 것도 같은 일이다.
 *
 * 받은 토막은 파일 크기만 한 버퍼의 제자리에 놓는다. 나머지는 0 으로 남는다 —
 * 엔진은 객체를 상호참조표의 자리로 집으므로, 안 받은 자리를 건드리지만
 * 않으면 그대로 돈다. 첫 쪽을 그린 뒤 나머지를 마저 받아 다시 읽는다.
 */

/** 서버가 범위 요청을 받아 주는가와, 받아 온 것 */
export type Ranged = {
  /** 파일 크기만 한 버퍼. 안 받은 자리는 0 이다 */
  bytes: Uint8Array;
  /** 파일 전체 크기 */
  total: number;
  /** 지금 버퍼에 실제로 들어 있는 구간들 */
  have: [number, number][];
  /** 아직 다 안 받았는가 */
  partial: boolean;
};

/** 한 번에 받을 토막 크기. 앞머리·꼬리 각각 이만큼 받는다. */
const CHUNK = 256 * 1024;

/** `bytes=a-b` 로 한 토막 받아 온다. 서버가 안 받아 주면 null. */
async function slice(
  url: string, from: number, to: number, signal?: AbortSignal,
): Promise<{ body: Uint8Array; total: number } | null> {
  const res = await fetch(url, { headers: { Range: `bytes=${from}-${to}` }, signal });
  if (res.status !== 206) return null;
  const cr = res.headers.get("content-range") ?? "";
  const m = /bytes\s+(\d+)-(\d+)\/(\d+)/i.exec(cr);
  if (!m) return null;
  const body = new Uint8Array(await res.arrayBuffer());
  return { body, total: Number(m[3]) };
}

/** 선형화 딕셔너리에서 /E(첫 쪽 끝)를 찾는다. 없으면 0. */
function firstPageEnd(head: Uint8Array): number {
  const txt = new TextDecoder("latin1").decode(head.subarray(0, Math.min(head.length, 4096)));
  if (!/\/Linearized/.test(txt)) return 0;
  const m = /\/E\s+(\d+)/.exec(txt);
  return m ? Number(m[1]) : 0;
}

/**
 * 주소에서 토막만 받아 온다. 서버가 범위 요청을 안 받아 주면 null 을 주고,
 * 부르는 쪽이 통째로 받는 길로 되돌아간다.
 */
export async function openRanged(
  url: string,
  opts: { signal?: AbortSignal; onProgress?: (p: { loaded: number; total: number }) => void } = {},
): Promise<Ranged | null> {
  // 앞머리부터 본다 — 선형화 딕셔너리가 거기 있고, 파일 크기도 함께 온다
  const head = await slice(url, 0, CHUNK - 1, opts.signal).catch(() => null);
  if (!head) return null;
  const total = head.total;
  if (total <= CHUNK * 2) return null; // 작은 파일은 통째로 받는 편이 빠르다

  const bytes = new Uint8Array(total);
  const have: [number, number][] = [];
  const put = (at: number, b: Uint8Array) => {
    bytes.set(b, at);
    have.push([at, at + b.length]);
  };
  put(0, head.body);

  // 선형화 파일이면 첫 쪽이 어디서 끝나는지 적혀 있다
  const e = firstPageEnd(head.body);
  const headEnd = e > 0 ? Math.min(total, e + 4096) : head.body.length;
  if (headEnd > head.body.length) {
    const more = await slice(url, head.body.length, headEnd - 1, opts.signal);
    if (more) put(head.body.length, more.body);
  }
  // 꼬리도 받는다 — 선형화가 아니면 상호참조표가 거기 있다
  const from = Math.max(headEnd, total - CHUNK);
  if (from < total) {
    const back = await slice(url, from, total - 1, opts.signal);
    if (back) put(from, back.body);
  }
  const loaded = have.reduce((n, [a, b]) => n + (b - a), 0);
  opts.onProgress?.({ loaded, total });
  return { bytes, total, have, partial: loaded < total };
}

/** 안 받은 구간을 마저 받아 채운다. */
export async function fillRest(
  url: string, r: Ranged,
  opts: { signal?: AbortSignal; onProgress?: (p: { loaded: number; total: number }) => void } = {},
): Promise<Uint8Array> {
  if (!r.partial) return r.bytes;
  const sorted = [...r.have].sort((a, b) => a[0] - b[0]);
  const gaps: [number, number][] = [];
  let at = 0;
  for (const [a, b] of sorted) {
    if (a > at) gaps.push([at, a]);
    at = Math.max(at, b);
  }
  if (at < r.total) gaps.push([at, r.total]);
  let loaded = r.total - gaps.reduce((n, [a, b]) => n + (b - a), 0);
  for (const [a, b] of gaps) {
    const got = await slice(url, a, b - 1, opts.signal);
    if (!got) throw new Error("the server stopped accepting range requests");
    r.bytes.set(got.body, a);
    loaded += got.body.length;
    opts.onProgress?.({ loaded, total: r.total });
  }
  r.have = [[0, r.total]];
  r.partial = false;
  return r.bytes;
}
