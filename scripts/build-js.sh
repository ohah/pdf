#!/bin/bash
# TypeScript 를 브라우저가 읽을 JS 로 옮긴다.
#
#   bash scripts/build-js.sh
#
# 옮기는 일은 zntc(https://github.com/ohah/zntc)가 한다 — Zig 로 짠
# 트랜스파일러다. 형 선언(.d.ts)만 tsc 가 낸다.
#
# 묶지 않고 파일마다 옮긴다. 워커(worker.js)가 따로 남아야 하고, 쓰는 쪽
# 번들러가 필요한 것만 골라 갈 수 있어야 하기 때문이다.
set -e
cd "$(dirname "$0")/.."
mkdir -p dist
# --outdir 로 주면 --sourcemap 이 무시된다(zntc 0.1.4). 파일마다 -o 로 낸다.
for f in src/*.ts; do
  npx zntc "$f" -o "dist/$(basename "$f" .ts).js" --sourcemap
done
npx tsc -p tsconfig.build.json
node scripts/postbuild.mjs
echo "dist/ — JS $(ls dist/*.js | wc -l | tr -d ' ')개, 소스맵 $(ls dist/*.js.map | wc -l | tr -d ' ')개, 형 선언 $(ls dist/*.d.ts | wc -l | tr -d ' ')개"
