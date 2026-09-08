#!/bin/bash
# 같은 검사를 여러 바퀴 돌려, 한 번 통과한 것이 늘 통과하는지 본다.
#
#   bash tests/adversarial.sh [바퀴수] [로그파일]
#
# 한 바퀴로는 흔들리는 것을 못 가른다. 실제로 이 얼개가 잡아낸 것들이다 —
# 빌드가 판마다 달라지던 것(wasm-opt 제자리 덮어쓰기), 기계가 바쁠 때만
# 느리다고 찍히던 것, 열 바퀴 중 한 번만 터지던 range.mjs.
#
# 앱(allthatnba)이 옆에 있으면 화면 시험과 결정성까지 함께 본다. 없으면
# 라이브러리 것만 돌린다 — 라이브러리가 앱에 매이면 안 된다.
#
#   APP=/어디/apps/frontend bash tests/adversarial.sh
set -u
cd "$(dirname "$0")/.."
N="${1:-10}"
LOG="${2:-/tmp/adversarial.log}"
: > "$LOG"
APP="${APP:-$(cd .. 2>/dev/null && pwd)/allthatnba/apps/frontend}"
[ -d "$APP" ] || APP=""
REPO=""
[ -n "$APP" ] && REPO="$(cd "$APP/../.." && pwd)"

pkill -f 'vite examples' 2>/dev/null || true
(npx vite examples --port 4277 >/tmp/vite.log 2>&1 &)
for i in $(seq 1 60); do curl -sf http://localhost:4277/ >/dev/null && break; sleep 1; done

for R in $(seq 1 "$N"); do
  echo "═══ $R/$N ═══" >> "$LOG"
  o=$(bash tests/run.sh 1 2>&1)
  if echo "$o" | grep -q '모두 통과'; then
    echo "  엔진   OK  $(echo "$o" | grep -oE '적대적 [0-9]+개 · 예외 [0-9]+ · 느림 [0-9]+') · $(echo "$o" | grep -oE '기능 단언 [0-9]+개 중 통과 [0-9]+, 실패 [0-9]+')" >> "$LOG"
  else
    # 터진 시험의 자취까지 남긴다. 여태 '실패|✗|⚠' 만 걸러서, run.sh 가 찍어
    # 준 "range.mjs 이 터졌다" 와 스택이 통째로 버려졌다 — 한 바퀴가 터졌는데
    # 까닭을 다시 볼 수가 없었다.
    echo "  엔진   ✗" >> "$LOG"
    echo "$o" | grep -E '실패|✗|⚠|터졌다|Error|Node\.js v' | head -12 >> "$LOG"
  fi

  # 성공한 줄이 *있는지* 부터 본다. 실패 문자열이 없다고 통과로 보면, 터졌을
  # 때도 그 문자열이 없어 OK 로 찍힌다 — vite 가 안 떠 있으면 compare 가 종료
  # 코드 1 로 죽는데 실행기는 OK 라고 적은 일이 있다.
  if o=$(node tests/compare-pdfjs.mjs 2>&1); then rc=0; else rc=$?; fi
  sum=$(echo "$o" | grep -oE '견본 [0-9]+개 · 맞댈 수 있던 것 [0-9]+ · 크게다름 [0-9.]+% 초과 [0-9]+')
  if [ "$rc" != 0 ] || [ -z "$sum" ]; then
    echo "  pdfjs  ✗ 터짐(exit $rc)" >> "$LOG"; echo "$o" | tail -3 >> "$LOG"
  elif echo "$o" | grep -q '우리가 못 그린'; then
    echo "  pdfjs  ✗" >> "$LOG"; echo "$o" | grep -A2 '우리가 못 그린' >> "$LOG"
  else echo "  pdfjs  OK  $sum" >> "$LOG"; fi

  if o=$(node tests/roundtrip-pdfjs.mjs 2>&1); then rc=0; else rc=$?; fi
  sum=$(echo "$o" | grep -oE '견본 [0-9]+개 · 문제 [0-9]+개')
  if [ "$rc" != 0 ] || [ -z "$sum" ]; then
    echo "  왕복   ✗ 터짐(exit $rc)" >> "$LOG"; echo "$o" | tail -3 >> "$LOG"
  else echo "  왕복   OK  $sum" >> "$LOG"; fi

  echo "  환경   $(node tests/env.mjs 2>&1 | grep -qE '시나리오' && echo OK || echo ✗)" >> "$LOG"
  echo "  브라우저 $(node tests/browser-api.mjs 2>&1 | grep -q '통과' && echo OK || echo ✗)" >> "$LOG"

  if [ -z "$APP" ]; then
    echo "  앱     — 옆에 없어 건너뜀" >> "$LOG"
  else
    # 개수 바닥값은 앱 저장소(apps/frontend/scripts/e2e.sh)가 들고 있다.
    # 여기서도 세면 숫자가 둘로 갈려 한쪽만 낡는다.
    if o=$(cd "$REPO" && npm run test:e2e 2>&1); then
      echo "  앱     OK  $(echo "$o" | grep -oE '[0-9]+ 개 통과')" >> "$LOG"
    else
      echo "  앱     ✗ $(echo "$o" | grep -E '^── ' | tail -1)" >> "$LOG"
      echo "$o" | grep -E '✘' | head -4 >> "$LOG"
    fi
    # 결정성은 git 으로 보면 안 된다. 엔진이 실제로 바뀐 것과 빌드가 흔들리는
    # 것을 못 가른다 — 한 바퀴 안에서 두 번 구워 서로 맞댄다.
    a=$(cd "$APP" && shasum public/wasm/*.wasm | shasum | cut -c1-16)
    (cd "$APP" && bash scripts/build-wasm.sh >/dev/null 2>&1)
    b2=$(cd "$APP" && shasum public/wasm/*.wasm | shasum | cut -c1-16)
    if [ "$a" = "$b2" ]; then echo "  결정성 OK  두 번 구워 같음" >> "$LOG"
    else
      # 어느 파일이 흔들렸는지 남긴다. 합친 해시만 적으면 다음에 또 못 가른다.
      echo "  결정성 ✗ 두 번 구웠더니 다름 ($a / $b2)" >> "$LOG"
      (cd "$APP" && shasum public/wasm/*.wasm) >> "$LOG"
    fi
  fi
done
echo "═══ 끝 ═══" >> "$LOG"
pkill -f 'vite examples' 2>/dev/null || true

fail=$(grep -c '✗' "$LOG" || true)
echo "바퀴 $N · 실패 표시 $fail 개 — $LOG"
[ "$fail" = 0 ]
