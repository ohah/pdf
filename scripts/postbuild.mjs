// 구운 뒤 dist 를 다듬는다. 두 가지다.
//
// 1) 워커 주소 — 소스에는 ./worker.ts 라고 적어 둔다. 번들러(Vite·webpack)가
//    그걸 보고 워커를 함께 묶기 때문이다. 하지만 dist 를 그대로 쓰는
//    쪽(바닐라·CDN)은 worker.js 를 봐야 한다.
//
// 2) 소스맵 — zntc 0.1.4 는 .map 을 내주지만 "//# sourceMappingURL=" 주석을
//    붙이지 않는다. 주석이 없으면 브라우저가 맵을 찾지 않으므로 여기서 붙인다.
//    맵 안의 sources 도 CWD 기준("src/x.ts")이라 dist 에서 보면 어긋난다.
//    dist 기준("../src/x.ts")으로 고쳐 둔다.
import fs from "node:fs";
import path from "node:path";

const DIST = "dist";

const client = path.join(DIST, "client.js");
fs.writeFileSync(client, fs.readFileSync(client, "utf8").replace('"./worker.ts"', '"./worker.js"'));

let linked = 0;
for (const f of fs.readdirSync(DIST).filter((n) => n.endsWith(".js"))) {
  const js = path.join(DIST, f);
  const map = `${js}.map`;
  if (!fs.existsSync(map)) continue;

  const m = JSON.parse(fs.readFileSync(map, "utf8"));
  m.sources = m.sources.map((s) => (s.startsWith("../") || path.isAbsolute(s) ? s : `../${s}`));
  m.file = f;
  fs.writeFileSync(map, JSON.stringify(m));

  let code = fs.readFileSync(js, "utf8");
  if (!code.includes("//# sourceMappingURL=")) {
    code = `${code.replace(/\n+$/, "")}\n//# sourceMappingURL=${f}.map\n`;
    fs.writeFileSync(js, code);
  }
  linked++;
}
console.log(`dist/client.js — 워커 주소를 ./worker.js 로 맞췄다`);
console.log(`dist/*.js — 소스맵 ${linked}개를 이었다`);
