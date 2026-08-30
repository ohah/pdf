// 빌드한 뒤 워커 주소를 .js 로 바꿔 준다.
//
// 소스에는 ./worker.ts 라고 적어 둔다 — 번들러(Vite·webpack)가 그걸 보고
// 워커를 함께 묶기 때문이다. 하지만 dist 를 그대로 쓰는 쪽(바닐라·CDN)은
// worker.js 를 봐야 한다.
import fs from "node:fs";
const f = "dist/client.js";
const s = fs.readFileSync(f, "utf8").replace('"./worker.ts"', '"./worker.js"');
fs.writeFileSync(f, s);
console.log("dist/client.js — 워커 주소를 ./worker.js 로 맞췄다");
