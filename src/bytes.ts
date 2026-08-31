/**
 * 어디서든 바이트를 읽어 온다.
 *
 * 브라우저에서는 fetch 한 줄이면 되지만 Node 에서는 wasm 도 CMap 도 웹 주소가
 * 아니라 파일 경로로 온다 — fetch 는 그걸 못 읽는다. 그래서 웹 주소 꼴이
 * 아니고 Node 위라면 파일로 본다.
 */
export async function loadBytes(where: string): Promise<Uint8Array<ArrayBuffer> | null> {
  const proc = (globalThis as { process?: { versions?: { node?: string } } }).process;
  const web = /^(https?|blob|data):/.test(where);
  const node = !web && !!proc?.versions?.node;
  if (!node) {
    const r = await fetch(where);
    return r.ok ? new Uint8Array(await r.arrayBuffer()) : null;
  }
  try {
    // 문자열을 변수에 담아 부른다 — 번들러가 브라우저 빌드에서 node:fs 를
    // 억지로 끌어들이지 않게 하려는 것이다.
    const fs = "node:fs/promises";
    const { readFile } = (await import(/* @vite-ignore */ fs)) as {
      readFile: (p: string) => Promise<{ buffer: ArrayBuffer; byteOffset: number; byteLength: number }>;
    };
    const path = where.startsWith("file://")
      ? decodeURIComponent(where.slice("file://".length))
      : where;
    const buf = await readFile(path);
    return new Uint8Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
  } catch {
    return null;
  }
}
