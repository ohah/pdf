#!/bin/bash
# Zig 소스를 wasm 하나로 굽는다.
#
#   bash scripts/build.sh
#
# zig 0.16 이 있어야 한다(mise 를 쓰면 mise.toml 이 잡아 준다).
# 결과는 dist/pdf.wasm 이다.
set -e
cd "$(dirname "$0")/.."
ZIG="${ZIG:-$(command -v zig || echo "$HOME/.local/share/mise/installs/zig/0.16.0/zig")}"
if [ ! -x "$ZIG" ] && ! command -v "$ZIG" >/dev/null 2>&1; then echo "zig 를 찾지 못했다. https://ziglang.org 에서 받는다."; exit 1; fi
mkdir -p dist
cd c
# 내보낼 이름은 소스가 진짜다. 여기에 손으로 또 적으면 조용히 어긋난다 —
# 실제로 addFont·resetPage·runContent 셋이 소스에만 있고 이 목록엔 없었다.
EXPORTS=$(grep -ho '^\(pub \)\?export fn [A-Za-z_][A-Za-z0-9_]*' *.zig \
  | sed 's/.*export fn //' | sort -u | sed 's/^/--export=/' | tr '\n' ' ')
# shellcheck disable=SC2086
# 스택은 2MB 로 둔다.
#
# zig 의 wasm 기본값은 16MB 인데, 그게 통째로 초기 메모리에 잡힌다 —
# 문서를 열지도 않았는데 16MB 를 들고 시작한다. 견본 전부(스캔·JBIG2·
# 팩스·JPX·양식)를 열고 그리고 새로 내면서 잰 최대가 212KB 다. 2MB 면
# 열 배 가까운 여유이고, 넘치면 wasm 이 곧바로 트랩을 내므로 조용히
# 틀리지 않는다.
"$ZIG" build-exe pdf.zig pdfwrap.c miniz.c -target wasm32-wasi -O ReleaseSmall -fno-entry -lc \
  --stack 2097152 \
  -I. -DMINIZ_NO_STDIO=1 -DMINIZ_NO_ARCHIVE_APIS=1 $EXPORTS || {
  echo "빌드 실패 — 낡은 wasm 을 그대로 두지 않도록 여기서 멈춘다"
  exit 1
}
mv pdf.wasm ../dist/pdf.wasm
rm -f ./*.o 2>/dev/null || true

# wasm-opt 으로 한 번 더 줄인다 — 13% 가 빠진다(354,106 → 307,432).
#
# 켤 기능은 이 wasm 이 실제로 쓰는 것만 적는다. -all 로 다 켜면 안 쓰는
# 것까지 들어가 Node 가 "unknown import kind" 로 못 읽는 모듈이 나온다.
#
# 임시 자리에 내고 성한 것만 옮긴다. 같은 파일을 넣고 같은 파일로 내면
# (f -o f) 도중에 죽을 때 파일이 잘린다.
#
# 없으면 그냥 지나간다 — 빌드가 이 도구에 매이면 안 된다.
WASM_OPT="${WASM_OPT:-$(command -v wasm-opt || echo /opt/homebrew/opt/binaryen/bin/wasm-opt)}"
if [ -x "$WASM_OPT" ]; then
  if "$WASM_OPT" --enable-bulk-memory --enable-bulk-memory-opt \
       --enable-nontrapping-float-to-int --enable-sign-ext --enable-mutable-globals \
       -Oz --strip-debug --strip-producers \
       ../dist/pdf.wasm -o ../dist/pdf.wasm.tmp && [ -s ../dist/pdf.wasm.tmp ]; then
    mv ../dist/pdf.wasm.tmp ../dist/pdf.wasm
  else
    rm -f ../dist/pdf.wasm.tmp
    echo "  wasm-opt 이 실패했다 — 줄이기 전 파일을 그대로 둔다"
  fi
else
  echo "  wasm-opt 이 없다 — 줄이기를 건너뛴다 (brew install binaryen)"
fi
echo "dist/pdf.wasm  $(wc -c < ../dist/pdf.wasm | tr -d ' ') bytes"
