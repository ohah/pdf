import { loadBytes } from "./bytes.js";


/**
 * 미리 정의된 CMap 을 필요할 때만 받아 온다.
 *
 * KSCms-UHC-H 같은 이름만 적힌 CMap 은 표가 PDF 안에 없다. Adobe 가 이름으로
 * 배포하는 표를 봐야 코드를 몇 바이트씩 끊을지, 그 코드가 몇 번 글자인지
 * 알 수 있다. 전부 다 실으면 7MB 라 통째로 넣지 않는다. 문서를 연 뒤
 * wasm 이 "이 이름들이 필요하다"고 알려 주면 그것만 받는다 — 한글 문서면
 * 보통 4KB 짜리 하나, ToUnicode 까지 없으면 40KB 남짓이다.
 *
 * 받은 표는 브라우저 캐시와 이 표에 남으므로 다음 문서에서는 다시 받지 않는다.
 */
let base = "./cmaps";
/** 표가 어디 있는지 정한다. 워커가 열 때 한 번 부른다. */
export function setCmapBase(url: string) {
  base = url.replace(/\/$/, "");
}
/** 지금 어디를 보고 있나. 워커 없이 여럿이 나눠 쓸 때 되돌리려고 쓴다. */
export function cmapBase() {
  return base;
}

type CmapEx = {
  memory: WebAssembly.Memory;
  needCount?: () => number;
  needOff?: (i: number) => number;
  needLen?: (i: number) => number;
  needPtr?: () => number;
  cmapReset?: () => void;
  cmapPtr?: () => number;
  cmapRoom?: () => number;
  cmapAdd?: (idx: number, len: number) => number;
};

// 곳간은 자리(base)마다 따로 둔다.
//
// 예전에는 이름만 열쇠라, 문서 A 의 표를 받아 두면 자리가 다른 문서 B 도
// 그것을 썼다. 브라우저에서는 문서마다 워커가 따로라 안 겪지만, Node 나
// 워커를 못 만드는 자리에서는 한 모듈을 나눠 쓰므로 B 의 한글이 깨졌다.
const indexes = new Map<string, Promise<Set<string>>>();
const cache = new Map<string, Promise<ArrayBuffer | null>>();

/** 어떤 이름이 실제로 있는지. 없는 이름을 받으러 가면 404 만 쌓인다. */
function known() {
  let got = indexes.get(base);
  if (!got) {
    got = loadBytes(`${base}/index.json`)
      .then((b) => (b ? (JSON.parse(new TextDecoder().decode(b)) as string[]) : []))
      .then((a) => new Set(a))
      .catch(() => new Set<string>());
    indexes.set(base, got);
  }
  return got;
}

function grab(name: string) {
  const key = `${base}\n${name}`;
  let p = cache.get(key);
  if (!p) {
    p = loadBytes(`${base}/${name}.bin`)
      .then((b) => (b ? (b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer) : null))
      .catch(() => null);
    cache.set(key, p);
  }
  return p;
}

/** parse() 뒤, 페이지를 그리기 전에 부른다. 실제로 넣은 이름을 준다. */
export async function loadCmaps(ex: CmapEx): Promise<string[]> {
  if (!ex.needCount || !ex.cmapAdd || !ex.cmapReset) return [];
  ex.cmapReset();
  const n = ex.needCount();
  if (n === 0) return [];

  // 이름은 먼저 다 읽어 둔다 — 목록 자리는 다음 문서를 열면 덮인다.
  const dec = new TextDecoder();
  const want: { i: number; name: string }[] = [];
  for (let i = 0; i < n; i++) {
    want.push({
      i,
      name: dec.decode(
        new Uint8Array(ex.memory.buffer, ex.needPtr!() + ex.needOff!(i), ex.needLen!(i)),
      ),
    });
  }

  const have = await known();
  const use = want.filter((w) => have.has(w.name));
  if (use.length === 0) return [];
  const bodies = await Promise.all(use.map((w) => grab(w.name)));

  const done: string[] = [];
  for (let k = 0; k < use.length; k++) {
    const b = bodies[k];
    if (!b || b.byteLength === 0 || b.byteLength > ex.cmapRoom!()) continue;
    // 자리를 먼저 받는다 — 곳간을 잡느라 메모리가 늘면 앞서 잡은 버퍼가
    // 떨어져 나간다(detached)
    const at = ex.cmapPtr!();
    new Uint8Array(ex.memory.buffer, at, b.byteLength).set(new Uint8Array(b));
    if (ex.cmapAdd(use[k].i, b.byteLength)) done.push(use[k].name);
  }
  return done;
}
