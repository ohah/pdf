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

# 바뀐 것이 없으면 건너뛴다.
#
# 매번 굽는 데는 까닭이 있다 — dist/ 는 git 밖이라 낡은 채로 남기 쉽고, 그러면
# Node 갈래가 옛 JS 를 시험하고도 통과한다(scan4 기대치가 낡은 것을 여섯 달
# 못 봤다). 그 보호는 그대로 두고, *정말 안 바뀌었을 때만* 넘어간다.
#
# 소스·이 스크립트·tsconfig 가운데 하나라도 dist 보다 새로우면 다시 굽는다.
# 헷갈릴 때는 굽는 쪽으로 기운다 — 안 구워서 낡은 것을 시험하는 쪽이 나쁘다.
#
#   bash scripts/build-js.sh --force   로 언제나 다시 구울 수 있다
if [ "${1:-}" != "--force" ] && [ -n "$(ls dist/*.js 2>/dev/null)" ]; then
  newest_src=$(ls -t src/*.ts scripts/build-js.sh scripts/postbuild.mjs tsconfig.build.json tsconfig.json 2>/dev/null | head -1)
  oldest_out=$(ls -tr dist/*.js dist/*.d.ts 2>/dev/null | head -1)
  if [ -n "$newest_src" ] && [ -n "$oldest_out" ] && [ ! "$newest_src" -nt "$oldest_out" ]; then
    echo "dist/ — 바뀐 것이 없어 그대로 쓴다 ($(ls dist/*.js | wc -l | tr -d ' ')개)"
    exit 0
  fi
fi
# --outdir 로 주면 --sourcemap 이 무시된다(zntc 0.1.4). 파일마다 -o 로 낸다.
for f in src/*.ts; do
  npx zntc "$f" -o "dist/$(basename "$f" .ts).js" --sourcemap
done
npx tsc -p tsconfig.build.json
node scripts/postbuild.mjs
echo "dist/ — JS $(ls dist/*.js | wc -l | tr -d ' ')개, 소스맵 $(ls dist/*.js.map | wc -l | tr -d ' ')개, 형 선언 $(ls dist/*.d.ts | wc -l | tr -d ' ')개"
