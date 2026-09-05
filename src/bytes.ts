import { onNode } from "./config.js";
/**
 * 어디서든 바이트를 읽어 온다.
 *
 * 브라우저에서는 fetch 한 줄이면 되지만 Node 에서는 wasm 도 CMap 도 웹 주소가
 * 아니라 파일 경로로 온다 — fetch 는 그걸 못 읽는다. 그래서 웹 주소 꼴이
 * 아니고 Node 위라면 파일로 본다.
 */
export async function loadBytes(where: string): Promise<Uint8Array<ArrayBuffer> | null> {
  const web = /^(https?|blob|data):/.test(where);
  const node = !web && onNode;
  if (!node) {
    const r = await fetch(where);
    return r.ok ? new Uint8Array(await r.arrayBuffer()) : null;
  }
  try {
    // 문자열을 변수에 담아 부른다. 번들러에 따라 이걸 그대로 두기도 하고
    // (그러면 브라우저 빌드에서 "node:fs/promises 는 외부 모듈" 이라는
    // 안내가 뜬다) 접어 버리기도 한다. 어느 쪽이든 브라우저에서는 이 갈래에
    // 안 들어오므로 동작에는 영향이 없다.
    const fs = "node:fs/promises";
    const { readFile } = (await import(/* @vite-ignore */ fs)) as {
      readFile: (p: string) => Promise<{ buffer: ArrayBuffer; byteOffset: number; byteLength: number }>;
    };
    // file:// 주소는 규칙대로 경로로 바꾼다. 문자열을 잘라 쓰면 윈도에서
    // /C:/... 가 되어 C:\\C:\\... 로 풀린다 — Node 지원이 통째로 죽는다.
    let path = where;
    if (where.startsWith("file:")) {
      const u = "node:url";
      const { fileURLToPath } = (await import(/* @vite-ignore */ u)) as {
        fileURLToPath: (s: string) => string;
      };
      path = fileURLToPath(where);
    }
    const buf = await readFile(path);
    return new Uint8Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  } catch {
    return null;
  }
}

/**
 * 글꼴 바이트에서 캐시 열쇠를 만든다.
 *
 * 예전에는 512바이트만 골라 봤다. 50KB 글꼴이면 99%를 안 보는 셈이라,
 * 길이가 같고 표본 밖만 다른 부분집합 글꼴이 같은 열쇠가 됐다 — 한 바이트만
 * 비켜 바꿔도 열쇠가 같은 것을 확인했다. 이 캐시는 문서를 넘나들므로 남의
 * 문서 글꼴이 그려질 수 있었다(스텐실 캐시에서 실제로 겪은 그 사고다).
 *
 * 전부 본다. 4바이트씩 묶어 5MB 글꼴도 한 자릿수 ms 다. 곱은 Math.imul 로
 * 한다 — `(h * 16777619) >>> 0` 은 2^53 을 넘겨 아랫자리를 잃는다.
 */
export function fontKey(bytes: Uint8Array): string {
  let h = 2166136261;
  const n = bytes.length;
  const words = n >> 2;
  if (words > 0) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, words * 4);
    for (let w = 0; w < words; w++) h = Math.imul(h ^ dv.getUint32(w * 4, true), 16777619) >>> 0;
  }
  for (let i = words * 4; i < n; i++) h = Math.imul(h ^ bytes[i], 16777619) >>> 0;
  return `${n}-${h.toString(36)}`;
}
