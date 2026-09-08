/**
 * 표준 14글꼴을 밖에서 받아 쓴다.
 *
 * 문서가 Helvetica·Times 처럼 "다들 갖고 있는 글꼴"을 쓸 때는 글꼴 파일을
 * 안 싣는다. 그러면 그리는 쪽은 시스템 글꼴로 대신 그리는데, 그 글꼴은
 * OS 마다 다르고 브라우저마다도 다르다 — 세 브라우저에 같은 글을 재 보니
 * serif 폭이 chromium 241 · firefox 273 · webkit 241 로 갈렸다.
 *
 * 진짜 글꼴을 실으면 그 차이가 사라진다. 다만 번들에 담을 수는 없다 —
 * 다 담으면 816KB 로 엔진(346KB)보다 크다. 그래서 CMap 과 같은 꼴로,
 * 쓰는 쪽이 어디 두었는지만 알려 주고 필요한 것만 받아 온다.
 *
 *   PDFDocument.open(bytes, { fonts: "/standard_fonts" })
 *
 * 안 알려 주면 지금까지처럼 시스템 글꼴로 그린다 — 받는 것도, 번들에
 * 늘어나는 것도 없다.
 *
 * .pfb(Type1)는 여기서 안 다룬다. 세 브라우저 다 FontFace 로 거부한다
 * (chromium "Invalid font data" · firefox "Invalid source buffer" ·
 * webkit "did not match the expected pattern"). Times·Courier·Symbol 은
 * 그래서 엔진의 Type1 해석기가 그려야 한다 — 아직 이어 붙이지 않았다.
 */

/** 이름을 견주기 좋게 다듬는다 — 대소문자·공백·쉼표를 지운다. */
function norm(s: string): string {
  return s.toLowerCase().replace(/[\s,_]/g, "");
}

/** 굵기·기울기를 이름 뒤에서 읽는다. */
function face(n: string): { bold: boolean; italic: boolean } {
  return {
    bold: /bold|black|heavy|semibold|demibold/.test(n),
    italic: /italic|oblique/.test(n),
  };
}

/**
 * /BaseFont 이름 → 밖에 둔 파일 이름. 우리가 실을 수 없는 것은 undefined.
 *
 * Helvetica 계열만 낸다. Liberation Sans 는 TrueType 이라 세 브라우저가
 * 다 FontFace 로 받아 준다(직접 물어봤다).
 */
export function stdFontFile(base: string): string | undefined {
  const n = norm(base);
  if (!n) return undefined;
  // Arial 은 Helvetica 와 같은 자리에 놓는 것이 관례다.
  const sans = /^(helvetica|arial|arialmt|arialunicodems|liberationsans)/.test(n);
  if (!sans) return undefined;
  const { bold, italic } = face(n);
  if (bold && italic) return "LiberationSans-BoldItalic.ttf";
  if (bold) return "LiberationSans-Bold.ttf";
  if (italic) return "LiberationSans-Italic.ttf";
  return "LiberationSans-Regular.ttf";
}

/** 폴더 주소와 이름을 잇는다. 끝의 / 는 있으나 없으나 같게 본다. */
export function stdFontUrl(dir: string, base: string): string | undefined {
  const f = stdFontFile(base);
  return f ? `${dir.replace(/\/+$/, "")}/${f}` : undefined;
}
