//! 맨 CFF 를 OpenType 으로 감싼다
//!
//! pdf.zig 가 14,000 줄을 넘어 한 파일에서 다루기 어려워졌다. 안팎으로 얽힌
//! 정도를 재서 바깥이 거의 안 쓰는 덩이부터 떼어 낸다. 여기서 바깥이 쓰는
//! 것은 2개다.
//!
//! 반대로 이쪽은 pdf.zig 의 도구를 16개 쓴다. 그것들은 아직 옮길 자리가
//! 마땅치 않아 root. 을 붙여 부른다.

const std = @import("std");
const root = @import("pdf.zig");
const pdfsynth = @import("pdfsynth.zig");
const pdfenc = @import("pdfenc.zig");

// ===== CFF 를 OpenType 으로 감싸기 =====
//
// PDF 의 FontFile3 은 대개 맨 CFF 다 — sfnt 껍데기가 없어 FontFace 가 받지
// 않는다. PDF.js 도 같은 일을 한다: CFF 를 그대로 'CFF ' 표에 넣고, 규격이
// 요구하는 나머지 표(head·hhea·maxp·hmtx·OS/2·name·post)를 지어 붙인다.
// 글자 폭은 PDF 가 이미 알려 준 /W·/Widths 를 쓴다.

fn readOff(b: []const u8, at: usize, n: u8) u32 {
    var v: u32 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (at + i >= b.len) return 0;
        v = (v << 8) | b[at + i];
    }
    return v;
}

/// INDEX 의 끝 위치 (CFF1)
fn cffIndexEnd(b: []const u8, at: usize) ?usize {
    if (at + 2 > b.len) return null;
    const count = root.be16(b, at);
    if (count == 0) return at + 2;
    if (at + 3 > b.len) return null;
    const os = b[at + 2];
    if (os < 1 or os > 4) return null;
    const offs = at + 3;
    const last_at = offs + @as(usize, count) * os;
    if (last_at + os > b.len) return null;
    const last = readOff(b, last_at, os);
    const data = offs + (@as(usize, count) + 1) * os - 1;
    if (data > b.len or last > b.len - data) return null;
    return data + last;
}

fn cffIndexItem(b: []const u8, at: usize, i: u32) ?[]const u8 {
    if (at + 3 > b.len) return null;
    const count = root.be16(b, at);
    if (i >= count) return null;
    const os = b[at + 2];
    if (os < 1 or os > 4) return null;
    const offs = at + 3;
    const o1 = readOff(b, offs + @as(usize, i) * os, os);
    const o2 = readOff(b, offs + (@as(usize, i) + 1) * os, os);
    const data = offs + (@as(usize, count) + 1) * os - 1;
    if (o2 < o1 or data > b.len or o2 > b.len - data or o1 == 0) return null;
    return b[data + o1 .. data + o2];
}

/// Top DICT 에서 연산자 하나의 마지막 피연산자를 읽는다.
fn cffDictInt(d: []const u8, want: u16) ?i32 {
    var i: usize = 0;
    var last: i32 = 0;
    var have = false;
    while (i < d.len) {
        const b0 = d[i];
        if (b0 <= 21) {
            var key: u16 = b0;
            i += 1;
            if (b0 == 12) {
                if (i >= d.len) return null;
                key = 0x0C00 | @as(u16, d[i]);
                i += 1;
            }
            if (key == want and have) return last;
            have = false;
            continue;
        }
        if (b0 == 28) {
            if (i + 3 > d.len) return null;
            last = @as(i16, @bitCast(root.be16(d, i + 1)));
            have = true;
            i += 3;
        } else if (b0 == 29) {
            if (i + 5 > d.len) return null;
            last = @bitCast(root.be32(d, i + 1));
            have = true;
            i += 5;
        } else if (b0 == 30) {
            // 실수 — 0xf 반니블이 끝을 알린다
            i += 1;
            while (i < d.len) : (i += 1) {
                const v = d[i];
                if ((v >> 4) == 0x0F or (v & 0x0F) == 0x0F) { i += 1; break; }
            }
            have = false;
        } else if (b0 >= 32 and b0 <= 246) {
            last = @as(i32, b0) - 139;
            have = true;
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            if (i + 2 > d.len) return null;
            last = (@as(i32, b0) - 247) * 256 + @as(i32, d[i + 1]) + 108;
            have = true;
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            if (i + 2 > d.len) return null;
            last = -(@as(i32, b0) - 251) * 256 - @as(i32, d[i + 1]) - 108;
            have = true;
            i += 2;
        } else {
            i += 1;
        }
    }
    return null;
}

/// CFF 의 글리프 수 (CharStrings INDEX 의 개수)
fn cffGlyphCount(cff: []const u8) u32 {
    if (cff.len < 8) return 0;
    if (cff[0] != 1) return 0; // CFF1 만
    var at: usize = cff[2]; // hdrSize
    at = cffIndexEnd(cff, at) orelse return 0; // Name INDEX
    const top_at = at;
    at = cffIndexEnd(cff, at) orelse return 0; // Top DICT INDEX
    const top = cffIndexItem(cff, top_at, 0) orelse return 0;
    const cs = cffDictInt(top, 17) orelse return 0;
    if (cs <= 0 or @as(usize, @intCast(cs)) + 2 > cff.len) return 0;
    return root.be16(cff, @intCast(cs));
}

fn wrStr(d: []u8, o: usize, s: []const u8) void {
    if (o + s.len > d.len) return;
    @memcpy(d[o..][0..s.len], s);
}

/// UTF-16BE 로 적는다 (아스키만)
fn wrU16Str(d: []u8, o: usize, s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (o + i * 2 + 2 > d.len) break;
        d[o + i * 2] = 0;
        d[o + i * 2 + 1] = s[i];
    }
    return s.len * 2;
}

/// name 표 하나를 짓는다. 쓴 바이트 수.
fn buildName(dst: []u8) u32 {
    const ids = [_]u16{ 1, 2, 3, 4, 6 };
    const count: u16 = ids.len;
    const str_off: u16 = 6 + count * 12;
    if (dst.len < str_off + 32) return 0;
    root.wr16(dst, 0, 0);
    root.wr16(dst, 2, count);
    root.wr16(dst, 4, str_off);
    const fam = "PDFEmbedded";
    const sub = "Regular";
    const fam_len = wrU16Str(dst, str_off, fam);
    const sub_len = wrU16Str(dst, str_off + fam_len, sub);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = 6 + i * 12;
        root.wr16(dst, r + 0, 3); // 윈도
        root.wr16(dst, r + 2, 1); // 유니코드 BMP
        root.wr16(dst, r + 4, 0x0409);
        root.wr16(dst, r + 6, ids[i]);
        if (ids[i] == 2) {
            root.wr16(dst, r + 8, @intCast(sub_len));
            root.wr16(dst, r + 10, @intCast(fam_len));
        } else {
            root.wr16(dst, r + 8, @intCast(fam_len));
            root.wr16(dst, r + 10, 0);
        }
    }
    return @intCast(str_off + fam_len + sub_len);
}

/// 맨 CFF 를 OTTO 로 감싼다. 성공하면 길이, 실패하면 0.
/// Name INDEX 의 글꼴 이름을 브라우저가 받는 글자로 고친다.
///
/// 한글 문서(HWP 가 낸 PDF)는 글꼴 이름을 EUC-KR 바이트 그대로 적는다 — OTS 는
/// Name INDEX 에 0x21~0x7E 밖 글자가 있으면 글꼴을 통째로 거절한다. 길이는 그대로
/// 두고(뒤의 자리들이 안 밀리게) 글자만 'X' 로 바꾼다
fn sanitizeCffName(cff: []u8) void {
    if (cff.len < 8 or cff[0] != 1) return;
    const at: usize = cff[2];
    if (at + 3 > cff.len) return;
    const count = root.be16(cff, at);
    if (count == 0) return;
    const os = cff[at + 2];
    if (os < 1 or os > 4) return;
    const offs = at + 3;
    const data = offs + (@as(usize, count) + 1) * os - 1;
    const end = cffIndexEnd(cff, at) orelse return;
    var i: usize = data + 1;
    while (i < end and i < cff.len) : (i += 1) {
        const c = cff[i];
        const bad = c < 0x21 or c > 0x7E or c == '[' or c == ']' or c == '(' or c == ')' or
            c == '{' or c == '}' or c == '<' or c == '>' or c == '/' or c == '%';
        if (bad) cff[i] = 'X';
    }
}

fn buildOtto(cff: []const u8, f: *root.FontMap, dst: []u8) u32 {
    const ng = cffGlyphCount(cff);
    if (ng == 0 or ng > 65535) return 0;
    if (dst.len < cff.len + 4096) return 0;
    const scratch = dst.len - (dst.len / 4);
    if (scratch <= cff.len + 1024) return 0;

    const cmap_len = pdfsynth.buildFontCmap(f, @intCast(ng), dst[scratch..]);
    if (cmap_len == 0) return 0;

    // 표 아홉 개 — 태그 오름차순이어야 한다
    const out_n: u32 = 9;
    const dir = 12 + out_n * 16;
    var pos: u32 = (dir + 3) & ~@as(u32, 3);

    var tags: [9]u32 = undefined;
    var offs: [9]u32 = undefined;
    var lens: [9]u32 = undefined;
    var head_pos: u32 = 0;
    var t: u32 = 0;

    const put = struct {
        fn go(d: []u8, p: *u32, tg: *[9]u32, of: *[9]u32, ln: *[9]u32, idx: *u32,
             tag: u32, len: u32, limit: u32) bool
        {
            if (p.* + len > limit) return false;
            tg[idx.*] = tag;
            of[idx.*] = p.*;
            ln[idx.*] = len;
            idx.* += 1;
            const end = p.* + len;
            p.* = (end + 3) & ~@as(u32, 3);
            @memset(d[end..p.*], 0);
            return true;
        }
    }.go;

    // CFF
    if (pos + cff.len > scratch) return 0;
    @memcpy(dst[pos..][0..cff.len], cff);
    sanitizeCffName(dst[pos..][0..cff.len]);
    if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x43464620, @intCast(cff.len), @intCast(scratch))) return 0;

    // OS/2 (판 4)
    {
        const at = pos;
        @memset(dst[at .. at + 96], 0);
        root.wr16(dst, at + 0, 4);
        root.wr16(dst, at + 2, 500); // xAvgCharWidth
        root.wr16(dst, at + 4, 400); // usWeightClass
        root.wr16(dst, at + 6, 5); // usWidthClass
        root.wr16(dst, at + 30, 50); // yStrikeoutSize
        root.wr16(dst, at + 32, 300); // yStrikeoutPosition
        wrStr(dst, at + 58, "PDF ");
        root.wr16(dst, at + 62, 0x0040); // fsSelection = REGULAR
        root.wr16(dst, at + 64, 0x0020);
        root.wr16(dst, at + 66, 0xFFFF);
        root.wr16(dst, at + 68, 800); // sTypoAscender
        root.wr16(dst, at + 70, @as(u16, 0) -% 200); // sTypoDescender
        root.wr16(dst, at + 72, 200);
        root.wr16(dst, at + 74, 1000); // usWinAscent
        root.wr16(dst, at + 76, 300); // usWinDescent
        root.wr32(dst, at + 78, 1); // ulCodePageRange1
        root.wr16(dst, at + 86, 500); // sxHeight
        root.wr16(dst, at + 88, 700); // sCapHeight
        root.wr16(dst, at + 92, 0x20); // usBreakChar
        root.wr16(dst, at + 94, 1); // usMaxContext
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x4F532F32, 96, @intCast(scratch))) return 0;
    }

    // cmap
    if (pos + cmap_len > scratch) return 0;
    @memcpy(dst[pos..][0..cmap_len], dst[scratch..][0..cmap_len]);
    if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x636D6170, cmap_len, @intCast(scratch))) return 0;

    // head
    {
        const at = pos;
        head_pos = at;
        @memset(dst[at .. at + 54], 0);
        root.wr32(dst, at + 0, 0x00010000);
        root.wr32(dst, at + 4, 0x00010000);
        root.wr32(dst, at + 12, 0x5F0F3CF5); // magic
        root.wr16(dst, at + 16, 3); // flags
        root.wr16(dst, at + 18, 1000); // unitsPerEm
        root.wr16(dst, at + 36, @as(u16, 0) -% 500); // xMin
        root.wr16(dst, at + 38, @as(u16, 0) -% 500); // yMin
        root.wr16(dst, at + 40, 1500); // xMax
        root.wr16(dst, at + 42, 1500); // yMax
        root.wr16(dst, at + 46, 3); // lowestRecPPEM
        root.wr16(dst, at + 48, 2); // fontDirectionHint
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x68656164, 54, @intCast(scratch))) return 0;
    }

    // hhea
    {
        const at = pos;
        @memset(dst[at .. at + 36], 0);
        root.wr32(dst, at + 0, 0x00010000);
        root.wr16(dst, at + 4, 800); // ascender
        root.wr16(dst, at + 6, @as(u16, 0) -% 200); // descender
        root.wr16(dst, at + 10, 1000); // advanceWidthMax
        root.wr16(dst, at + 16, 1000); // xMaxExtent
        root.wr16(dst, at + 18, 1); // caretSlopeRise
        root.wr16(dst, at + 34, @intCast(ng)); // numberOfHMetrics
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x68686561, 36, @intCast(scratch))) return 0;
    }

    // hmtx — 폭은 PDF 가 알려 준 값을 쓴다
    {
        const at = pos;
        const len = ng * 4;
        if (at + len > scratch) return 0;
        // CID 키 글꼴이면 GID 의 CID 를 찾아 그 폭을 — /W 는 CID 로 적혀 있다
        var gid2cid: [65536]u16 = undefined;
        if (f.c2g_len > 0) {
            @memset(&gid2cid, 0);
            const pool = root.c2g_pool();
            var cid: u32 = 0;
            while (cid * 2 + 1 < f.c2g_len) : (cid += 1) {
                const gg = (@as(u32, pool[f.c2g_off + cid * 2]) << 8) | pool[f.c2g_off + cid * 2 + 1];
                if (gg != 0 and gg < 65536) gid2cid[gg] = @intCast(cid);
            }
        }
        // 단순 CFF 는 GID 의 코드를 되짚어 그 폭을 — /Widths 는 코드로 적혀 있다
        var gid2code: [65536]u16 = undefined;
        if (f.cff_map) {
            @memset(&gid2code, 0xFFFF);
            var c: u32 = 0;
            while (c < 256) : (c += 1) {
                const gg = f.cff_gid[c];
                if (gg == 0) continue;
                // 한 글리프에 코드가 둘이면(제 인코딩의 0x27 과 WinAnsi 의 0x92 가 다
                // quoteright) /Widths 에 폭이 적힌 코드를 고른다 — 0 인 코드를 잡으면
                // 글리프 폭이 0 이 되어 뒷글자가 겹쳤다(IRS 안내서의 "What's")
                if (gid2code[gg] == 0xFFFF or root.widthOf(f, gid2code[gg]) <= 0) gid2code[gg] = @intCast(c);
            }
        }
        var g: u32 = 0;
        while (g < ng) : (g += 1) {
            const key: u32 = if (f.c2g_len > 0) gid2cid[g] else if (f.cff_map) (if (gid2code[g] == 0xFFFF) 0xFFFF else gid2code[g]) else g;
            const w = if (key == 0xFFFF) @as(f32, 0) else root.widthOf(f, key);
            const wi: u16 = @intFromFloat(@max(0, @min(65535, w)));
            root.wr16(dst, at + g * 4, wi);
            root.wr16(dst, at + g * 4 + 2, 0);
        }
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x686D7478, len, @intCast(scratch))) return 0;
    }

    // maxp (CFF 는 0.5 판)
    {
        const at = pos;
        root.wr32(dst, at + 0, 0x00005000);
        root.wr16(dst, at + 4, @intCast(ng));
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x6D617870, 6, @intCast(scratch))) return 0;
    }

    // name
    {
        const at = pos;
        const len = buildName(dst[at..scratch]);
        if (len == 0) return 0;
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x6E616D65, len, @intCast(scratch))) return 0;
    }

    // post 3.0
    {
        const at = pos;
        @memset(dst[at .. at + 32], 0);
        root.wr32(dst, at + 0, 0x00030000);
        root.wr16(dst, at + 8, @as(u16, 0) -% 100); // underlinePosition
        root.wr16(dst, at + 10, 50);
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x706F7374, 32, @intCast(scratch))) return 0;
    }

    // 표 목록
    root.wr32(dst, 0, 0x4F54544F); // 'OTTO'
    root.wr16(dst, 4, @intCast(out_n));
    var p2: u32 = 1;
    var es: u16 = 0;
    while (p2 * 2 <= out_n) : (p2 *= 2) es += 1;
    root.wr16(dst, 6, @intCast(p2 * 16));
    root.wr16(dst, 8, es);
    root.wr16(dst, 10, @intCast(out_n * 16 - p2 * 16));
    var k: u32 = 0;
    while (k < t) : (k += 1) {
        const r = 12 + k * 16;
        root.wr32(dst, r, tags[k]);
        root.wr32(dst, r + 4, root.sumTable(dst, offs[k], lens[k]));
        root.wr32(dst, r + 8, offs[k]);
        root.wr32(dst, r + 12, lens[k]);
    }
    if (head_pos != 0) {
        root.wr32(dst, head_pos + 8, 0);
        const whole = root.sumTable(dst, 0, pos);
        root.wr32(dst, head_pos + 8, 0xB1B0AFBA -% whole);
    }
    return pos;
}

/// CFF 표준 문자열 391개(SID 0~390). charset 이 글리프마다 SID 를 적고, 391 미만은 이 표다
const CFF_STD =
    ".notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft " ++
    "parenright asterisk plus comma hyphen period slash zero one two three four five six seven " ++
    "eight nine colon semicolon less equal greater question at A B C D E F G H I J K L M N O P " ++
    "Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft a " ++
    "b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde " ++
    "exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft " ++
    "guillemotleft guilsinglleft guilsinglright fi fl endash dagger daggerdbl periodcentered " ++
    "paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis " ++
    "perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis " ++
    "ring cedilla hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE " ++
    "ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior logicalnot mu trademark " ++
    "Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters " ++
    "twosuperior registered minus eth multiply threesuperior copyright Aacute Acircumflex " ++
    "Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute " ++
    "Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde Scaron " ++
    "Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis " ++
    "agrave aring atilde ccedilla eacute ecircumflex edieresis egrave iacute icircumflex " ++
    "idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde scaron uacute " ++
    "ucircumflex udieresis ugrave yacute ydieresis zcaron exclamsmall Hungarumlautsmall " ++
    "dollaroldstyle dollarsuperior ampersandsmall Acutesmall parenleftsuperior " ++
    "parenrightsuperior twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle " ++
    "threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle eightoldstyle " ++
    "nineoldstyle commasuperior threequartersemdash periodsuperior questionsmall asuperior " ++
    "bsuperior centsuperior dsuperior esuperior isuperior lsuperior msuperior nsuperior " ++
    "osuperior rsuperior ssuperior tsuperior ff ffi ffl parenleftinferior parenrightinferior " ++
    "Circumflexsmall hyphensuperior Gravesmall Asmall Bsmall Csmall Dsmall Esmall Fsmall " ++
    "Gsmall Hsmall Ismall Jsmall Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall " ++
    "Ssmall Tsmall Usmall Vsmall Wsmall Xsmall Ysmall Zsmall colonmonetary onefitted rupiah " ++
    "Tildesmall exclamdownsmall centoldstyle Lslashsmall Scaronsmall Zcaronsmall Dieresissmall " ++
    "Brevesmall Caronsmall Dotaccentsmall Macronsmall figuredash hypheninferior Ogoneksmall " ++
    "Ringsmall Cedillasmall questiondownsmall oneeighth threeeighths fiveeighths seveneighths " ++
    "onethird twothirds zerosuperior foursuperior fivesuperior sixsuperior sevensuperior " ++
    "eightsuperior ninesuperior zeroinferior oneinferior twoinferior threeinferior " ++
    "fourinferior fiveinferior sixinferior seveninferior eightinferior nineinferior " ++
    "centinferior dollarinferior periodinferior commainferior Agravesmall Aacutesmall " ++
    "Acircumflexsmall Atildesmall Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall " ++
    "Eacutesmall Ecircumflexsmall Edieresissmall Igravesmall Iacutesmall Icircumflexsmall " ++
    "Idieresissmall Ethsmall Ntildesmall Ogravesmall Oacutesmall Ocircumflexsmall Otildesmall " ++
    "Odieresissmall OEsmall Oslashsmall Ugravesmall Uacutesmall Ucircumflexsmall " ++
    "Udieresissmall Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 001.002 001.003 " ++
    "Black Bold Book Light Medium Regular Roman Semibold ";
/// StandardEncoding 코드 → SID (0 은 없음)
const STD_ENC_SID = [_]u16{ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,0,111,112,113,114,0,115,116,117,118,119,120,121,122,0,123,0,124,125,126,127,128,129,130,131,0,132,133,0,134,135,136,137,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,138,0,139,0,0,0,0,140,141,142,143,0,0,0,0,0,144,0,0,0,145,0,0,146,147,148,149,0,0,0,0 };

fn stdString(sid: u32, out: *[64]u8) []const u8 {
    var p: usize = 0;
    var k: u32 = 0;
    while (p < CFF_STD.len) {
        const st = p;
        while (p < CFF_STD.len and CFF_STD[p] != ' ') p += 1;
        if (k == sid) {
            const n = @min(p - st, 64);
            @memcpy(out[0..n], CFF_STD[st .. st + n]);
            return out[0..n];
        }
        k += 1;
        p += 1;
    }
    return &[_]u8{};
}

/// SID 의 이름 — 표준 문자열이거나 String INDEX 의 것
fn sidName(cff: []const u8, str_at: usize, sid: u32, out: *[64]u8) []const u8 {
    if (sid < 391) return stdString(sid, out);
    return cffIndexItem(cff, str_at, sid - 391) orelse &[_]u8{};
}

/// 이름의 SID — 표준 문자열에서 찾고 없으면 String INDEX 에서
fn nameSid(cff: []const u8, str_at: usize, name: []const u8) ?u32 {
    var p: usize = 0;
    var k: u32 = 0;
    while (p < CFF_STD.len) {
        const st = p;
        while (p < CFF_STD.len and CFF_STD[p] != ' ') p += 1;
        if (p - st == name.len and root.std_mem_eq(CFF_STD[st..p], name)) return k;
        k += 1;
        p += 1;
    }
    if (str_at + 2 > cff.len) return null;
    const count = root.be16(cff, str_at);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const it = cffIndexItem(cff, str_at, i) orelse continue;
        if (it.len == name.len and root.std_mem_eq(it, name)) return 391 + i;
    }
    return null;
}

/// charset 을 읽어 gid→SID 표를 채운다(ng 개). 미리 정의된 charset 0(ISOAdobe)은 SID = GID
fn cffCharset(cff: []const u8, top: []const u8, ng: u32, sids: []u16) void {
    var g: u32 = 0;
    while (g < ng and g < sids.len) : (g += 1) sids[g] = @intCast(@min(g, 65535));
    const cs_off = cffDictInt(top, 15) orelse 0;
    if (cs_off <= 2) return;
    var q: usize = @intCast(cs_off);
    if (q >= cff.len) return;
    const fmt = cff[q];
    q += 1;
    var gid: u32 = 1;
    while (gid < ng and gid < sids.len) {
        if (fmt == 0) {
            if (q + 2 > cff.len) break;
            sids[gid] = root.be16(cff, q);
            q += 2;
            gid += 1;
        } else if (fmt == 1 or fmt == 2) {
            const nl: usize = if (fmt == 1) 1 else 2;
            if (q + 2 + nl > cff.len) break;
            const first = root.be16(cff, q);
            const left: u32 = if (fmt == 1) cff[q + 2] else root.be16(cff, q + 2);
            var k: u32 = 0;
            while (k <= left and gid < ng and gid < sids.len) : (k += 1) {
                sids[gid] = @intCast(@min(first + k, 65535));
                gid += 1;
            }
            q += 2 + nl;
        } else return;
    }
}

/// 단순(비 CID) CFF 의 코드→글리프 표를 짓는다 — f.cff_gid.
///
/// Type1C 글꼴(pdfTeX·dvips 가 만든 arXiv 논문 전부)은 글리프를 이름으로 고른다: 코드 →
/// (PDF 의 /Differences 나 CFF 안 인코딩) → 이름 → charset 의 SID → GID. 예전에는 코드를
/// GID 로 써서 글리프가 없다고 시스템 글꼴로 떨어졌다 — 논문 본문이 전부 산세리프였다.
fn cffSimpleMap(cff: []const u8, f: *root.FontMap) bool {
    if (cff.len < 8 or cff[0] != 1) return false;
    var at: usize = cff[2];
    at = cffIndexEnd(cff, at) orelse return false;
    const top_at = at;
    at = cffIndexEnd(cff, at) orelse return false;
    const str_at = at;
    const top = cffIndexItem(cff, top_at, 0) orelse return false;
    if (cffDictInt(top, 0x0C1E) != null) return false; // CID 키 글꼴은 charset 이 CID 다
    const ng = cffGlyphCount(cff);
    if (ng < 2) return false;
    var sids: [65536]u16 = undefined;
    cffCharset(cff, top, ng, &sids);
    const gidOfSid = struct {
        fn go(s: []const u16, n: u32, sid: u32) u16 {
            var g: u32 = 1;
            while (g < n) : (g += 1) if (s[g] == sid) return @intCast(g);
            return 0;
        }
    }.go;
    @memset(&f.cff_gid, 0);
    // 1) CFF 안 인코딩 — 0 표준, 1 전문가(안 다룸), 그 밖은 자리
    const enc_off = cffDictInt(top, 16) orelse 0;
    if (enc_off == 0) {
        var c: u32 = 0;
        while (c < 256) : (c += 1) {
            const sid = STD_ENC_SID[c];
            if (sid != 0) f.cff_gid[c] = gidOfSid(&sids, ng, sid);
        }
    } else if (enc_off > 1 and @as(usize, @intCast(enc_off)) < cff.len) {
        var q: usize = @intCast(enc_off);
        const fmt = cff[q];
        q += 1;
        if ((fmt & 0x7F) == 0) {
            const n = cff[q];
            q += 1;
            var i: u32 = 1;
            while (i <= n and q < cff.len) : (i += 1) {
                f.cff_gid[cff[q]] = @intCast(@min(i, 65535));
                q += 1;
            }
        } else if ((fmt & 0x7F) == 1) {
            const nr = cff[q];
            q += 1;
            var gid: u32 = 1;
            var r: u32 = 0;
            while (r < nr and q + 2 <= cff.len) : (r += 1) {
                const first = cff[q];
                const left = cff[q + 1];
                var k: u32 = 0;
                while (k <= left) : (k += 1) {
                    const code = @as(u32, first) + k;
                    if (code < 256) f.cff_gid[code] = @intCast(@min(gid, 65535));
                    gid += 1;
                }
                q += 2;
            }
        }
        if ((fmt & 0x80) != 0 and q < cff.len) {
            // 보충: 코드 → SID
            const ns = cff[q];
            q += 1;
            var i: u32 = 0;
            while (i < ns and q + 3 <= cff.len) : (i += 1) {
                const code = cff[q];
                const sid = root.be16(cff, q + 1);
                f.cff_gid[code] = gidOfSid(&sids, ng, sid);
                q += 3;
            }
        }
    }
    // 2) PDF 의 /Differences 가 준 이름이 이긴다 — 이름 그대로(g7267 같은 제 이름도)
    //    맞춰 보고, 안 맞으면 유니코드에서 이름을 되짚는다
    var i: u32 = 0;
    while (i < f.n) : (i += 1) {
        const code = f.codes.all()[i];
        const uni = f.unis.all()[i];
        if (code > 255) continue;
        const has_diff = (f.diff[code >> 3] & (@as(u8, 1) << @intCast(code & 7))) != 0;
        // PDF 가 WinAnsi 같은 이름 인코딩을 줬으면 그 이름이 제 안의 인코딩보다 세다
        if (!has_diff and f.base_enc == 0 and f.cff_gid[code] != 0) continue;
        const dn = root.pdft1.diffName(code);
        if (dn.len > 0) {
            if (nameSid(cff, str_at, dn)) |sid| {
                const g = gidOfSid(&sids, ng, sid);
                if (g != 0) { f.cff_gid[code] = g; continue; }
            }
        }
        if (uni == 0) continue;
        var nb: [64]u8 = undefined;
        const nm = pdfenc.uniToName(uni, &nb);
        if (nm.len == 0) continue;
        if (nameSid(cff, str_at, nm)) |sid| {
            const g = gidOfSid(&sids, ng, sid);
            if (g != 0) f.cff_gid[code] = g;
        }
    }
    f.cff_map = true;
    return true;
}

/// CID 키 CFF(CIDFontType0C)의 charset 을 뒤집어 CID→GID 표를 c2g 곳간에 담는다.
///
/// CID 글꼴은 대개 CID 가 곧 글리프 번호지만, CFF 바탕은 charset 이 "GID n 은 CID m" 을
/// 적는다. 부분집합 글꼴은 GID 가 1·2·3 인데 CID 는 3·49·243 이라, 번호를 그대로 쓰면
/// 글리프가 없어 시스템 글꼴로 떨어졌다 — 통계청 소식지 표지의 큰 DATA 가 헬베티카로
/// 나왔다. 표가 있으면 true.
fn cffCidToGid(cff: []const u8, f: *root.FontMap) bool {
    if (cff.len < 8 or cff[0] != 1) return false;
    var at: usize = cff[2];
    at = cffIndexEnd(cff, at) orelse return false;
    const top_at = at;
    at = cffIndexEnd(cff, at) orelse return false;
    const top = cffIndexItem(cff, top_at, 0) orelse return false;
    // ROS(12 30) 가 있어야 CID 키 글꼴이다
    if (cffDictInt(top, 0x0C1E) == null) return false;
    const ng = cffGlyphCount(cff);
    if (ng < 2) return false;
    const cs_off = cffDictInt(top, 15) orelse return false; // charset
    if (cs_off <= 2) return false; // 0·1·2 는 미리 정의된 표(CID 글꼴엔 안 쓴다)
    var p: usize = @intCast(cs_off);
    if (p >= cff.len) return false;
    const fmt = cff[p];
    p += 1;
    // gid→cid 를 읽으며 cid→gid 표에 적는다. 표는 CID 최댓값까지 2바이트씩
    var max_cid: u32 = 0;
    var gid: u32 = 1;
    var q = p;
    while (gid < ng) {
        if (fmt == 0) {
            if (q + 2 > cff.len) break;
            max_cid = @max(max_cid, root.be16(cff, q));
            q += 2;
            gid += 1;
        } else if (fmt == 1 or fmt == 2) {
            const nl: usize = if (fmt == 1) 1 else 2;
            if (q + 2 + nl > cff.len) break;
            const first = root.be16(cff, q);
            const left: u32 = if (fmt == 1) cff[q + 2] else root.be16(cff, q + 2);
            max_cid = @max(max_cid, first + left);
            q += 2 + nl;
            gid += left + 1;
        } else return false;
    }
    if (max_cid == 0 or max_cid > 65535) return false;
    const need = (max_cid + 1) * 2;
    const pool = root.c2g_pool();
    if (pool.len == 0 or root.c2g.used + need > pool.len) return false;
    const tbl = pool[root.c2g.used..][0..need];
    @memset(tbl, 0);
    gid = 1;
    q = p;
    while (gid < ng) {
        if (fmt == 0) {
            if (q + 2 > cff.len) break;
            const cid = root.be16(cff, q);
            tbl[cid * 2] = @intCast(gid >> 8);
            tbl[cid * 2 + 1] = @intCast(gid & 0xFF);
            q += 2;
            gid += 1;
        } else {
            const nl: usize = if (fmt == 1) 1 else 2;
            if (q + 2 + nl > cff.len) break;
            const first = root.be16(cff, q);
            const left: u32 = if (fmt == 1) cff[q + 2] else root.be16(cff, q + 2);
            var k: u32 = 0;
            while (k <= left and gid < ng) : (k += 1) {
                const cid = first + k;
                if (cid <= max_cid) {
                    tbl[cid * 2] = @intCast(gid >> 8);
                    tbl[cid * 2 + 1] = @intCast(gid & 0xFF);
                }
                gid += 1;
            }
            q += 2 + nl;
        }
    }
    f.c2g_off = root.c2g.used;
    f.c2g_len = @intCast(need);
    root.c2g.used += @intCast(need);
    f.identity = true;
    return true;
}

/// 방금 등록한 글꼴에 파일을 붙인다.
pub fn attachFontFile(data: []const u8, is_cff: bool) void {
    if (root.fontarea.n == 0 or root.fontArea() == 0) return;
    const f = &root.fonts.all()[root.fontarea.n - 1];
    const room = root.fontarea.cap - root.fontarea.used;
    if (room < 4096) return;
    // 필요한 만큼만 떼어 준다.
    //
    // 예전에는 남은 자리를 통째로 넘겼다. 그런데 글꼴을 다시 짜는 쪽은
    // "받은 자리의 절반" 을 임시 자리로 쓴다(scratch = dst.len / 2). 8MB 를
    // 통째로 주면 4MB 지점에 쓰고, OTTO 는 6MB 지점에도 쓴다 — 실제로는
    // 100KB 도 안 쓰면서 8MB 전체를 만지게 되고, 그만큼이 진짜 메모리가
    // 된다. 한글 문서 하나를 그리는 데 13MB 가 그렇게 나갔다.
    //
    // 원본의 네 배에 여유를 얹으면 넉넉하다 — 표를 다시 짜고 cmap 을
    // 새로 붙여도 그 안에 든다.
    const want = @min(room, @max(@as(usize, 256 * 1024), data.len * 4 + 128 * 1024));
    const area = @as([*]u8, @ptrFromInt(root.fontArea() + root.fontarea.used))[0..want];
    var n: u32 = 0;
    if (is_cff) {
        // CID 키 CFF 면 charset 으로 CID→GID 를 먼저 — 그래야 cmap(PUA=GID)과 맞는다.
        // 단순 CFF 는 이름으로 코드→GID 표를 짓는다
        if (f.two_byte) _ = cffCidToGid(data, f) else _ = cffSimpleMap(data, f);
        n = buildOtto(data, f, area);
        if (n == 0) return; // 껍데기를 못 지으면 싣지 않는다
        f.kind |= 512;
        f.file_off = root.fontarea.used;
        f.file_len = n;
        root.fontarea.used += (n + 3) & ~@as(u32, 3);
        return;
    }
    if (f.n > 0 or f.identity) n = pdfsynth.patchFont(data, f, area);
    if (n == 0) {
        // 코드표가 없으면 파일의 cmap 을 그대로 믿는다. 다만 겉이라도 성한
        // 것만 싣는다 — 깨진 파일을 넘겨 봐야 FontFace 가 거절하고, 그동안
        // 메모리만 먹는다.
        if (data.len < 12 or data.len > room or data.len > 4 * 1024 * 1024) return;
        const tag = root.be32(data, 0);
        if (tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F) return;
        const num = root.be16(data, 4);
        if (num == 0 or num > 64 or 12 + @as(usize, num) * 16 > data.len) return;
        @memcpy(area[0..data.len], data);
        n = @intCast(data.len);
    }
    f.file_off = root.fontarea.used;
    f.file_len = n;
    root.fontarea.used += (n + 3) & ~@as(u32, 3);
}

/// 글자 하나만큼 자리를 옮긴다. 세로쓰기는 아래로 흐른다.
pub fn advance(f: ?*const root.FontMap, adv: f32, m: root.Mat) root.Mat {
    const vert = if (f) |ff| ff.vertical else false;
    if (vert) return root.matMul(.{ .e = 0, .f = -adv }, m);
    return root.matMul(.{ .e = adv, .f = 0 }, m);
}

