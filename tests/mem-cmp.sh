#!/bin/bash
# 우리와 pdf.js 가 같은 문서에 쓰는 메모리를 맞대 본다.
#
#   bash tests/mem-cmp.sh [회차]
#
# 회차마다 프로세스를 새로 띄워 재고 가운데 값을 쓴다 — JS 힙은 GC 타이밍에
# 따라 흔들려 한 번 재서는 못 믿는다.
#
# 칸을 나눠 찍는 이유는 tests/mem.mjs 머리에 적어 두었다. 한 칸만 보면
# 결론이 뒤집힌다.
set -e
cd "$(dirname "$0")/.."
N=${1:-5}
mid() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
one() { node --expose-gc tests/mem.mjs "$1" "$2" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['$3'])"; }

printf "회차마다 프로세스를 새로 띄워 %s번 재고 가운데 값. 캔버스 라이브러리 값은 양쪽이 같아 뺐다.\n\n" "$N"
printf "%-18s %-7s %9s %9s %9s %9s\n" "문서" "" "들이기" "열고 그리기" "합" "wasm 예약"
for f in tests/fixtures/multi.pdf tests/fixtures/korean.pdf tests/fixtures/cmap2.pdf \
         tests/fixtures/pdf/scanned.pdf tests/fixtures/tile.pdf; do
  name=$(basename "$f")
  for w in ours pdfjs; do
    l=$(for i in $(seq 1 "$N"); do one "$w" "$f" load; done | mid)
    k=$(for i in $(seq 1 "$N"); do one "$w" "$f" work; done | mid)
    t=$(for i in $(seq 1 "$N"); do one "$w" "$f" total; done | mid)
    c=$(for i in $(seq 1 "$N"); do one "$w" "$f" canvas; done | mid)
    m=$(one "$w" "$f" wasm)
    printf "%-18s %-7s %8.1fMB %8.1fMB %8.1fMB %8.1fMB\n" \
      "$name" "$w" "$l" "$k" "$(echo "$t - $c" | bc)" "$m"
    name=""
  done
done
