// 구운 뒤 워커 주소를 .js 로 바꿔 준다.
//
// 소스에는 ./worker.ts 라고 적어 둔다 — 번들러(Vite·webpack)가 그걸 보고 워커를
// 함께 묶기 때문이다. 하지만 dist 를 그대로 쓰는 쪽(바닐라·CDN)은 worker.js 를
// 봐야 한다.
//
// 소스맵은 zntc 0.1.6 부터 알아서 마무리된다 — `//# sourceMappingURL=` 주석과
// dist 기준 sources 를 여기서 기워 넣던 것을 걷어냈다.
import fs from "node:fs";

const f = "dist/client.js";
fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace('"./worker.ts"', '"./worker.js"'));
console.log("dist/client.js — 워커 주소를 ./worker.js 로 맞췄다");
