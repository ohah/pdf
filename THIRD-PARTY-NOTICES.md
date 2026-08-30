# 제3자 저작물 고지

이 저장소의 코드는 MIT 다(`LICENSE`). 여기 적은 것들은 그와 별개로 저마다의
라이선스를 따른다.

## npm 꾸러미에 담겨 나가는 것

### miniz (MIT)

`c/miniz.c`·`c/miniz.h` 를 그대로 링크한다. `/FlateDecode` 를 푸는 데 쓰고
`dist/pdf.wasm` 안에 들어 있다.

> Copyright 2013-2014 RAD Game Tools and Valve Software
> Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software … (MIT 전문은 `c/miniz.c` 머리에 있다)

`miniz.h` 머리에는 "파일 끝의 unlicense 를 보라" 고 적혀 있으나 그 문구가 파일에
없다. 실효 라이선스는 `miniz.c` 의 MIT 로 본다.

### Adobe CMap 자료 (BSD 3-Clause)

`cmaps/*.bin` 195개는
[adobe-type-tools/cmap-resources](https://github.com/adobe-type-tools/cmap-resources)
의 CMap 을 `scripts/build-cmaps.mjs` 로 이진 변환한 파생물이다. 원본을 받아
다시 구울 수 있다.

> Copyright 1990-2019 Adobe. All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are
> met: … (BSD 3-Clause)

### 규격 문서에서 옮긴 표

부호표·상태표를 규격 그대로 옮긴 자리가 있다. 구현을 위한 통상적 사용이지만
출처를 밝혀 둔다.

- ITU-T T.4 — 팩스 런렝스 부호표 (`c/pdfccitt.zig`)
- ITU-T T.88 — MQ 산술 부호기 상태표, 보통 영역 문맥, 표준 허프만 표 (`c/pdfjbig2.zig`)
- ITU-T T.800 — 비트평면 문맥표, 소대역 이득 (`c/pdfjpx.zig`)
- FIPS 180-4 · FIPS 197 — SHA-2 상수, AES S-box (`c/pdfcrypt.zig`)
- ISO 32000-1 — 암호 채움 문자열, WinAnsi·MacRoman 인코딩 표 (`c/pdf.zig`)

## 시험 붙임감 (꾸러미에 담기지 않는다)

`tests/` 는 npm 꾸러미의 `files` 에서 빠져 있다. 저장소에는 담겨 있으므로
출처를 적어 둔다.

| 파일 | 출처 | 라이선스 |
|---|---|---|
| `tests/fixtures/annex-h.jbig2` | ITU-T T.88 부록 H 시험 흐름. 규격이 정한 시험 자료이고, 바이트는 jbig2dec 저장소의 사본에서 왔다 | 자료는 ITU, 사본 경로는 AGPL-3.0 프로젝트 — 아래 참고 |
| `tests/fixtures/jpx/p0_*.j2k`, `gray.jp2` | openjpeg-data (JPEG 2000 적합성 시험 자료) | BSD-2-Clause / ISO·IEC 15444-4 |
| `tests/fixtures/sub.ttf`, `korean.pdf` 안 글꼴 | NanumGothic Bold (NHN·산돌) | SIL OFL 1.1 |
| `tests/fixtures/cff.pdf` 안 글꼴 | STIXGeneral-Regular | SIL OFL 1.1 |
| `tests/fixtures/jb-sym.pdf` | 출처 기록 없음 (132x14, 1.1KB) | 담긴 것이 없다시피 하나 출처는 모름 |

나머지 붙임감은 `tests/mk*.mjs` 가 지은 것이다 — 어디서 가져온 것이 아니다.
출처를 알 수 없던 스캔 그림·문서는 모두 우리가 지은 것으로 갈아 끼웠다.

### 아직 정리하지 못한 두 가지

`annex-h.jbig2` 는 JBIG2 산술 복호기·하프톤·정교화를 규격의 시험 흐름으로
맞대 보는 유일한 붙임감이다. 우리 부호기(`tests/jbig2enc.mjs`)는 허프만 쪽만
지을 수 있어 아직 대신할 수 없다. `jb-sym.pdf` 는 출처 기록이 없다.

둘 다 공개 저장소에 두기 전에 (1) 우리 부호기로 산술·하프톤까지 지어 갈아
끼우거나 (2) 시험에서 빼는 편이 깨끗하다.
