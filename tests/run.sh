#!/bin/bash
# PDF 엔진 시험.
#
#   bash tests/run.sh [반복횟수]
#
# 두 갈래로 돌린다.
#
#   적대적  — 망가진 파일·극단값을 넣고 죽거나 멎지 않는지 본다.
#             통과 기준은 "예외 0, 3초 넘는 항목 0" 이다.
#   단언    — 결과가 실제로 맞는지 본다. 죽지 않는 것만으로는 모자란다.
#             예전에 CFF 글꼴이 통째로 Type1 로 새는데도 적대적 쪽은
#             "글꼴 실림" 이라고 답한 적이 있다.
#
# dist/pdf.wasm 과 cmaps/ 를 읽으므로 저장소 뿌리에서 돈다. Node 갈래(tests/node.mjs)
# 는 dist/*.js 까지 읽으므로 build:js 를 먼저 돌려 둔다.
set -e
cd "$(dirname "$0")/.."
N=${1:-3}
FX="tests/fixtures"

if [ ! -f dist/pdf.wasm ]; then
  echo "dist/pdf.wasm 이 없다. npm run build:wasm 를 먼저 돌린다."
  exit 1
fi

fail=0
for pass in $(seq 1 "$N"); do
  # r8 은 무작위 퍼저다. 회차마다 씨앗을 바꿔 매번 다른 파일을 만든다 —
  # 정해진 입력만 돌리면 몇 번을 돌려도 같은 길만 밟는다.
  seed=$(( ($(date +%s) + pass * 7919) % 1000000 ))
  adv=$(for i in 1 2 3 4 5 6 7; do node "tests/r$i.mjs" "$FX"; done 2>&1; node tests/r8.mjs "$FX" "$seed" 2>&1)
  # grep -c 는 0건이면 1로 끝난다. set -e 에 걸리므로 받아 준다.
  n=$(echo "$adv" | grep -cE '^  ' || true)
  ex=$(echo "$adv" | grep -cE '예외' || true)
  slow=$(echo "$adv" | grep -cE '⚠' || true)
  fn=$(node tests/verify.mjs "$FX" 2>&1)
  ln=$(bun run tests/lines.ts)
  pl=$(bun run tests/place.ts)
  sg=$(bun run tests/sig.ts)
  nd=$(node tests/node.mjs "$FX" 2>&1 || true)
  printf "%s회차  적대적 %s개 · 예외 %s · 느림 %s | %s | %s\n" \
    "$pass" "$n" "$ex" "$slow" "$(echo "$fn" | head -1 | sed 's/^ *//')" "$(echo "$ln" | head -1 | sed 's/^ *//')"
  echo "        ${pl# } | ${sg# } | ${nd# }"
  if [ "$ex" != 0 ] || [ "$slow" != 0 ]; then echo "$adv" | grep -E '예외|⚠'; fail=1; fi
  if echo "$fn" | grep -qE '실패 [1-9]'; then echo "$fn"; fail=1; fi
  if echo "$ln$pl$sg" | grep -qE '실패 [1-9]'; then echo "$ln"; echo "$pl"; echo "$sg"; fail=1; fi
  if echo "$nd" | grep -qE '실패 [1-9]'; then echo "$nd"; fail=1; fi
done
[ "$fail" = 0 ] || { echo "실패한 항목이 있다."; exit 1; }
echo "모두 통과."
