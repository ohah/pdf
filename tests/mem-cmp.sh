#!/bin/bash
# 우리와 pdf.js 가 같은 문서에 쓰는 메모리를 맞대 본다.
#
#   bash tests/mem-cmp.sh [회차]
#
# 회차마다 프로세스를 새로 띄워 재고 가운데 값을 쓴다. JS 힙은 GC 타이밍에
# 따라 흔들려 한 번 재서는 못 믿는다. 최고점은 노드·캔버스가 쥐는 바닥이
# 섞이므로 대조군(문서를 안 여는 판)을 빼고 본다.
set -e
cd "$(dirname "$0")/.."
N=${1:-5}
mid() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
one() { node --expose-gc tests/mem.mjs "$1" "$2" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['$3'])"; }

# 최고점은 같은 프로세스 안에서 문서를 열기 직전과 견준다 — 노드·캔버스가
# 쥐는 바닥은 그 시점에 이미 잡혀 있으므로 저절로 빠진다.
printf "회차마다 프로세스를 새로 띄워 %s번 재고 가운데 값을 쓴다\n\n" "$N"
printf "%-20s %10s %10s %10s | %10s %10s\n" "문서" "우리 rss" "우리 peak" "우리 wasm" "pdfjs rss" "pdfjs peak"
for f in tests/fixtures/multi.pdf tests/fixtures/korean.pdf tests/fixtures/cmap2.pdf \
         tests/fixtures/pdf/scanned.pdf tests/fixtures/jb-globals.pdf tests/fixtures/tile.pdf; do
  ar=$(for i in $(seq 1 "$N"); do one ours "$f" rss; done | mid)
  ap=$(for i in $(seq 1 "$N"); do one ours "$f" peak; done | mid)
  aw=$(one ours "$f" wasm)
  br=$(for i in $(seq 1 "$N"); do one pdfjs "$f" rss; done | mid)
  bp=$(for i in $(seq 1 "$N"); do one pdfjs "$f" peak; done | mid)
  printf "%-20s %9.1fMB %9.1fMB %9.1fMB | %9.1fMB %9.1fMB\n" "$(basename "$f")" \
    "$ar" "$ap" "$aw" "$br" "$bp"
done
