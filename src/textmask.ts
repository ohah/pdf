/**
 * 글자를 화면 글꼴로 그려 1비트 마스크로 만든다.
 *
 * PDF 의 표준 글꼴(Helvetica)에는 한글이 없다. 글꼴 파일을 심으려면 몇 MB
 * 짜리를 들고 있어야 하고, 문서에 그런 글꼴이 있으리란 보장도 없다.
 * 브라우저는 이미 한글 글꼴을 갖고 있으니 그걸로 그려 그림으로 심는다.
 *
 * PDF 의 ImageMask 는 값이 0 인 자리를 지금 색으로 칠한다. 글자가 있는
 * 자리를 0 으로 둔다.
 */
export type TextMask = {
  /** 그림 화소 크기 */
  w: number;
  h: number;
  bits: Uint8Array;
  /** 쪽에 놓을 크기 (pt) */
  pw: number;
  ph: number;
  /** 글자 밑선이 그림 위에서 차지하는 비율 */
  baseline: number;
};

const FAMILY = 'system-ui, -apple-system, "Apple SD Gothic Neo", "Malgun Gothic", sans-serif';

/** 표준 글꼴에 없는 글자가 섞였는가. */
export function nonLatin(v: string): boolean {
  for (const ch of v) if ((ch.codePointAt(0) ?? 0) > 0xff) return true;
  return false;
}

/**
 * 한 줄짜리 글을 그린다. size 는 PDF 단위(pt)다.
 * 네 배 해상도로 그리되 너무 커지면 배율을 낮춘다.
 */
export function textMask(text: string, size: number): TextMask | null {
  if (!text) return null;
  const probe = document.createElement("canvas").getContext("2d");
  if (!probe) return null;
  probe.font = `${size}px ${FAMILY}`;
  const pw = Math.max(1, probe.measureText(text).width);
  const ph = Math.max(1, size * 1.3);
  let scale = 4;
  while (pw * scale * ph * scale > 4_000_000 && scale > 1) scale -= 1;
  const w = Math.max(1, Math.ceil(pw * scale));
  const h = Math.max(1, Math.ceil(ph * scale));
  const cv = document.createElement("canvas");
  cv.width = w;
  cv.height = h;
  const g = cv.getContext("2d", { willReadFrequently: true });
  if (!g) return null;
  g.fillStyle = "#fff";
  g.fillRect(0, 0, w, h);
  g.fillStyle = "#000";
  g.font = `${size * scale}px ${FAMILY}`;
  g.textBaseline = "alphabetic";
  const baseline = 0.8;
  g.fillText(text, 0, h * baseline);
  const im = g.getImageData(0, 0, w, h).data;
  const stride = (w + 7) >> 3;
  const bits = new Uint8Array(stride * h).fill(0xff);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (im[(y * w + x) * 4] < 128) bits[y * stride + (x >> 3)] &= ~(0x80 >> (x & 7));
    }
  }
  return { w, h, bits, pw, ph, baseline };
}
