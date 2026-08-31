// 표준 14종의 글자 폭 표를 Zig 로 굽는다. 자료는 Adobe 의 AFM 을 담은
// @pdf-lib/standard-fonts 에서 그대로 가져온다.
import { FontNames, Font, Encodings } from '@pdf-lib/standard-fonts';

const FONTS = [
  ['Courier', 'WinAnsi'], ['CourierBold', 'WinAnsi'], ['CourierOblique', 'WinAnsi'], ['CourierBoldOblique', 'WinAnsi'],
  ['Helvetica', 'WinAnsi'], ['HelveticaBold', 'WinAnsi'], ['HelveticaOblique', 'WinAnsi'], ['HelveticaBoldOblique', 'WinAnsi'],
  ['TimesRoman', 'WinAnsi'], ['TimesRomanBold', 'WinAnsi'], ['TimesRomanItalic', 'WinAnsi'], ['TimesRomanBoldItalic', 'WinAnsi'],
  ['Symbol', 'Symbol'], ['ZapfDingbats', 'ZapfDingbats'],
];

const out = [];
out.push('// 표준 14종 글꼴의 글자 폭 (1000 단위).');
out.push('//');
out.push('// PDF 규격은 이 열넷을 "어느 뷰어에나 있다"고 보고 문서에 /Widths 를 안 적어도');
out.push('// 되게 해 두었다. 폭을 모르면 자간이 통째로 어긋나므로 Adobe 가 낸 AFM 값을');
out.push('// 표로 담아 둔다. 자료 출처는 @pdf-lib/standard-fonts (Adobe AFM 그대로).');
out.push('//');
out.push('// scripts/gen-std14.mjs 가 만든 파일이다 — 손으로 고치지 않는다.');
out.push('');

const names = [];
for (const [name, encName] of FONTS) {
  const font = Font.load(FontNames[name]);
  const enc = Encodings[encName];
  const w = new Array(256).fill(0);
  for (const [code, glyph] of Object.entries(enc.unicodeMappings)) {
    // unicodeMappings: 유니코드 → [코드, 글리프이름]
    const [c, g] = glyph;
    if (c >= 0 && c < 256) {
      const width = font.getWidthOfGlyph(g);
      if (Number.isFinite(width)) w[c] = Math.round(width);
    }
  }
  const zigName = 'W_' + name;
  names.push([name, zigName]);
  out.push(`const ${zigName} = [256]u16{ ${w.join(', ')} };`);
}

out.push('');
out.push('/// 표준 14종의 이름과 폭 표. 이름은 소문자로 견준다(문서마다 표기가 갈린다).');
out.push('pub const Std14 = struct { name: []const u8, w: *const [256]u16 };');
out.push('pub const STD14 = [_]Std14{');
for (const [name, zigName] of names) out.push(`    .{ .name = "${name.toLowerCase()}", .w = &${zigName} },`);
out.push('};');
console.log(out.join('\n'));
