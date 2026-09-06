#!/bin/bash
# PDF 엔진 시험.
#
#   bash tests/run.sh [반복횟수]
#
# 두 갈래로 돌린다.
#
#   API     — 내보낸 것을 하나도 빠짐없이 이상한 값으로 두들긴다. 매달리지
#             않고, Error 만 던지고, 안 건드린 이름이 없어야 한다.
#   환경    — 워커가 막힌 자리, wasm 을 못 받는 자리, 글꼴·그림 API 가 없는
#             옛 웹뷰 … 에서 되는 것은 되고 안 되는 것은 말해 주는지 본다.
#             브라우저가 있어야 해서 여기 말고 tests/env.mjs 로 따로 돌린다:
#               npx vite examples --port 4277 & node tests/env.mjs
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

# 시험 하나를 돌리고 마지막 줄과 종료 코드를 함께 받는다.
#
# 예전에는 `node tests/x.mjs | tail -1 || true` 였다. 파이프를 타면 종료
# 코드가 tail 의 것이라 늘 0 이고, 시험이 터져도 마지막 줄(스택 트레이스)에
# "실패" 글자가 없어 통과로 셌다 — fontkey 를 일부러 터뜨렸더니 결과 자리에
# "Node.js v26.8.1" 이 찍히고 "모두 통과" 가 나왔다.
# 시험이 *몇 개나* 돌았는지 본다.
#
# 여태 "실패 [1-9]" 만 봤다. 그러면 시험이 조용히 적게 돌아도 통과다 —
# 견본 디렉터리가 바뀌거나 앞에서 return 하면 "3개 중 통과 3, 실패 0" 이
# 되고 run.sh 는 모두 통과라고 한다(실제로 383 → 3 으로 줄여 확인했다).
# 앱 화면 시험은 예전에 같은 이유로 56 과 맞대게 고쳤는데, 엔진 쪽은
# 그대로였다.
#
#   atleast <이름> <실제 수> <있어야 할 최소>
atleast() {
  if [ -z "$2" ] || [ "$2" -lt "$3" ] 2>/dev/null; then
    echo "  $1 이 $3 개는 돌아야 하는데 ${2:-0} 개만 돌았다"
    fail=1
  fi
}

one() {
  if ONE_OUT=$("$@" 2>&1); then ONE_RC=0; else ONE_RC=$?; fi
  ONE_LAST=$(printf '%s' "$ONE_OUT" | tail -1)
}

if [ ! -f dist/pdf.wasm ]; then
  echo "dist/pdf.wasm 이 없다. npm run build:wasm 를 먼저 돌린다."
  exit 1
fi

# dist/ 는 git 밖이라 낡은 채로 남아 있기 쉽다. 그러면 Node 갈래가 옛 JS 를
# 시험하고도 통과한다 — scan4 기대치가 낡은 것을 여섯 달 못 봤다. 매번 굽는다.
bash scripts/build-js.sh >/dev/null

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
  one node tests/api-adv.mjs "$pass" "$FX"
  ap="$ONE_OUT"
  ap_rc="$ONE_RC"
  one node tests/range.mjs
  rg="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  range.mjs 이 터졌다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -5; fail=1
  fi
  one node tests/formjs.mjs
  fj="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  formjs.mjs 이 터졌다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -5; fail=1
  fi
  one node tests/xfa.mjs
  xf="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  xfa.mjs 이 터졌다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -5; fail=1
  fi
  one node tests/jsmini.mjs
  jm="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  jsmini.mjs 이 터졌다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -5; fail=1
  fi
  one node tests/fontkey.mjs
  fk="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  fontkey.mjs 이 터졌다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -5; fail=1
  fi
  # 견본마다 뽑아낸 값이 조용히 달라지지 않게 못 박는다.
  # A/B 는 wasm 두 개를 맞대야 해서 상시로 못 돌린다 — 그 자리를 메운다.
  one node tests/snap.mjs "$FX"
  sn="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  snap.mjs 가 걸렸다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -8; fail=1
  fi
  # 아직 없는 기능이 조용히 달라지지 않게 못 박는다 (일부러 변경 감지기다)
  one node tests/gap.mjs "$FX"
  gp="$ONE_LAST"
  if [ "$ONE_RC" != 0 ]; then
    echo "  gap.mjs 이 터졌다 (exit $ONE_RC)"; printf '%s\n' "$ONE_OUT" | tail -5; fail=1
  fi
  ty=$(npx tsc --noEmit --ignoreConfig --strict --target ES2022 --module ESNext \
        --moduleResolution bundler --lib ES2022,DOM,DOM.Iterable tests/types.ts 2>&1 \
        && echo "타입 이름 다 나감" || echo "타입 실패 1")
  # 위는 src 를 직접 부른다. 아래는 소비자처럼 꾸러미 이름으로 부르고
  # React·Vue·Svelte 어댑터의 *추론*까지 못 박는다 — exports 지도와 .d.ts 가
  # 제대로 걸렸는지는 이쪽에서만 걸린다.
  tc=$(npx tsc -p tests/types/tsconfig.json 2>&1 \
        && echo "쓰는 쪽 추론 통과" || echo "쓰는 쪽 추론 실패 1")
  printf "%s회차  적대적 %s개 · 예외 %s · 느림 %s | %s | %s\n" \
    "$pass" "$n" "$ex" "$slow" "$(echo "$fn" | head -1 | sed 's/^ *//')" "$(echo "$ln" | head -1 | sed 's/^ *//')"
  echo "        ${pl# } | ${sg# } | ${nd# } | ${ty# } | ${tc# }"
  echo "        API ${ap# } | ${rg# } | ${fj# } | ${xf# } | ${jm# } | ${fk# } | ${gp# } | ${sn# }"
  if [ "$ex" != 0 ] || [ "$slow" != 0 ]; then echo "$adv" | grep -E '예외|⚠'; fail=1; fi
  # 개수를 못 박는다 — 줄어들면 잡는다. 늘어나는 것은 막지 않는다.
  atleast "기능 단언" "$(printf '%s' "$fn" | grep -oE '기능 단언 [0-9]+' | grep -oE '[0-9]+')" 385
  atleast "적대적" "$n" 600
  atleast "Node" "$(printf '%s' "$nd" | grep -oE '통과 [0-9]+' | tail -1 | grep -oE '[0-9]+')" 55
  atleast "빈틈" "$(printf '%s' "$gp" | grep -oE '빈틈 [0-9]+' | grep -oE '[0-9]+')" 18
  atleast "손자국" "$(printf '%s' "$sn" | grep -oE '손자국 [0-9]+' | grep -oE '[0-9]+')" 160
  atleast "글꼴 열쇠" "$(printf '%s' "$fk" | grep -oE '글꼴 열쇠 [0-9]+' | grep -oE '[0-9]+')" 5
  atleast "서명" "$(printf '%s' "$sg" | grep -oE '서명 [0-9]+' | grep -oE '[0-9]+')" 30
  if echo "$fn" | grep -qE '실패 [1-9]'; then echo "$fn"; fail=1; fi
  if echo "$ln$pl$sg" | grep -qE '실패 [1-9]'; then echo "$ln"; echo "$pl"; echo "$sg"; fail=1; fi
  if echo "$nd" | grep -qE '실패 [1-9]'; then echo "$nd"; fail=1; fi
  if echo "$tc" | grep -qE '실패 [1-9]'; then npx tsc -p tests/types/tsconfig.json 2>&1 | head -5; fail=1; fi
  if echo "$fk" | grep -qE '실패 [1-9]'; then node tests/fontkey.mjs 2>&1 | head -4; fail=1; fi
  if echo "$gp" | grep -qE '실패 [1-9]'; then node tests/gap.mjs "$FX" 2>&1 | tail -5; fail=1; fi
  if echo "$ty" | grep -qE '실패 [1-9]'; then echo "$ty"; fail=1; fi
  # 성공한 흔적이 *있는지* 부터 본다.
  #
  # 예전에는 '✗ 가 없으면 통과' 였다. 터지면 ✗ 도 없으니 그대로 통과였다 —
  # 같은 꼴이 내 검증 실행기에도 있어, vite 가 안 떠 compare 가 죽었는데
  # "pdfjs OK" 로 적힌 일이 있다.
  if [ "$ap_rc" != 0 ] || ! echo "$ap" | grep -q '내보낸 함수'; then
    echo "  api-adv.mjs 가 제대로 안 돌았다 (exit $ap_rc)"; printf '%s\n' "$ap" | tail -5; fail=1
  elif echo "$ap" | grep -q '✗'; then echo "$ap"; fail=1; fi
done
[ "$fail" = 0 ] || { echo "실패한 항목이 있다."; exit 1; }
echo "모두 통과."
