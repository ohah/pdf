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
