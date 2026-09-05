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
        var g: u32 = 0;
        while (g < ng) : (g += 1) {
            const w = root.widthOf(f, g);
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

