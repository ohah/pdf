//! 한 바이트 글꼴의 /Encoding 과 이름표
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 6개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 28개다.
//!
//! JS 에 내보내는 함수(0개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");
const pdfform = @import("pdfform.zig");

// ===== 단순 글꼴의 인코딩 =====
//
// 한 바이트 글꼴은 코드가 곧 글자가 아니다. /Encoding 이 정한다.
// ToUnicode 가 있으면 그게 낫지만, 없는 문서가 많다. 그때 코드를 그대로
// 유니코드로 보면 0x95(WinAnsi 의 가운뎃점 •)가 제어문자가 되어 사라지고,
// /Differences 를 쓰는 부분집합 글꼴은 글자가 통째로 엉뚱해진다.

/// WinAnsi 의 0x80~0x9F. 나머지는 라틴-1 과 같다.
const WIN_HI = [_]u16{
    0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
    0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
};

/// MacRoman 의 0x80~0xFF
const MAC_HI = [_]u16{
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
};

/// 글리프 이름 → 유니코드. /Differences 가 이름으로 온다.
const GNAMES =
    "space 32 exclam 33 quotedbl 34 numbersign 35 dollar 36 percent 37 ampersand 38 " ++
    "quotesingle 39 quoteright 8217 quoteleft 8216 parenleft 40 parenright 41 asterisk 42 " ++
    "plus 43 comma 44 hyphen 45 period 46 slash 47 zero 48 one 49 two 50 three 51 four 52 " ++
    "five 53 six 54 seven 55 eight 56 nine 57 colon 58 semicolon 59 less 60 equal 61 " ++
    "greater 62 question 63 at 64 bracketleft 91 backslash 92 bracketright 93 " ++
    "asciicircum 94 underscore 95 grave 96 braceleft 123 bar 124 braceright 125 " ++
    "asciitilde 126 bullet 8226 endash 8211 emdash 8212 quotedblleft 8220 " ++
    "quotedblright 8221 quotesinglbase 8218 quotedblbase 8222 dagger 8224 " ++
    "daggerdbl 8225 ellipsis 8230 perthousand 8240 guilsinglleft 8249 " ++
    "guilsinglright 8250 fraction 8260 florin 402 section 167 currency 164 yen 165 " ++
    "sterling 163 cent 162 copyright 169 registered 174 trademark 8482 degree 176 " ++
    "plusminus 177 mu 181 paragraph 182 periodcentered 183 onequarter 188 onehalf 189 " ++
    "threequarters 190 ordfeminine 170 ordmasculine 186 germandbls 223 ae 230 AE 198 " ++
    "oe 339 OE 338 oslash 248 Oslash 216 exclamdown 161 questiondown 191 " ++
    "guillemotleft 171 guillemotright 187 logicalnot 172 minus 8722 multiply 215 " ++
    "divide 247 nbspace 160 space 32 fi 64257 fl 64258 dotlessi 305 lslash 322 " ++
    "Lslash 321 scaron 353 Scaron 352 zcaron 382 Zcaron 381 ydieresis 255 " ++
    "Ydieresis 376 thorn 254 Thorn 222 eth 240 Eth 208 " ++
    "acute 180 circumflex 710 dieresis 168 caron 711 breve 728 tilde 732 " ++
    "macron 175 ring 730 cedilla 184 ogonek 731 dotaccent 729 hungarumlaut 733";

/// 유니코드 → 글리프 이름 (nameToUni 의 거꾸로). 표에 있으면 그 이름, 아스키 글자·숫자는
/// 표준 이름, 나머지는 uniXXXX. 밑글자+악센트(aacute) 도 짓는다
pub fn uniToName(uni: u32, out: *[64]u8) []const u8 {
    if (uni == 0) return &[_]u8{};
    if ((uni >= 'A' and uni <= 'Z') or (uni >= 'a' and uni <= 'z')) { out[0] = @intCast(uni); return out[0..1]; }
    var p: usize = 0;
    while (p < GNAMES.len) {
        const s0 = p;
        while (p < GNAMES.len and GNAMES[p] != ' ') p += 1;
        const key = GNAMES[s0..p];
        while (p < GNAMES.len and GNAMES[p] == ' ') p += 1;
        const v0 = p;
        while (p < GNAMES.len and GNAMES[p] != ' ') p += 1;
        var v: u32 = 0;
        var k = v0;
        while (k < p) : (k += 1) v = v * 10 + (GNAMES[k] - '0');
        while (p < GNAMES.len and GNAMES[p] == ' ') p += 1;
        if (v == uni) {
            const n = @min(key.len, 64);
            @memcpy(out[0..n], key[0..n]);
            return out[0..n];
        }
    }
    // 합자 ff·ffi·ffl
    if (uni == 0xFB00) { @memcpy(out[0..2], "ff"); return out[0..2]; }
    if (uni == 0xFB03) { @memcpy(out[0..3], "ffi"); return out[0..3]; }
    if (uni == 0xFB04) { @memcpy(out[0..3], "ffl"); return out[0..3]; }
    // 밑글자 + 악센트 (라틴-1·확장 A 의 흔한 것)
    const ACC = [_]struct { u: u32, base: u8, acc: []const u8 }{
        .{ .u = 0xE1, .base = 'a', .acc = "acute" }, .{ .u = 0xE0, .base = 'a', .acc = "grave" }, .{ .u = 0xE2, .base = 'a', .acc = "circumflex" }, .{ .u = 0xE3, .base = 'a', .acc = "tilde" }, .{ .u = 0xE4, .base = 'a', .acc = "dieresis" }, .{ .u = 0xE5, .base = 'a', .acc = "ring" },
        .{ .u = 0xE7, .base = 'c', .acc = "cedilla" }, .{ .u = 0xE9, .base = 'e', .acc = "acute" }, .{ .u = 0xE8, .base = 'e', .acc = "grave" }, .{ .u = 0xEA, .base = 'e', .acc = "circumflex" }, .{ .u = 0xEB, .base = 'e', .acc = "dieresis" },
        .{ .u = 0xED, .base = 'i', .acc = "acute" }, .{ .u = 0xEC, .base = 'i', .acc = "grave" }, .{ .u = 0xEE, .base = 'i', .acc = "circumflex" }, .{ .u = 0xEF, .base = 'i', .acc = "dieresis" }, .{ .u = 0xF1, .base = 'n', .acc = "tilde" },
        .{ .u = 0xF3, .base = 'o', .acc = "acute" }, .{ .u = 0xF2, .base = 'o', .acc = "grave" }, .{ .u = 0xF4, .base = 'o', .acc = "circumflex" }, .{ .u = 0xF5, .base = 'o', .acc = "tilde" }, .{ .u = 0xF6, .base = 'o', .acc = "dieresis" },
        .{ .u = 0xFA, .base = 'u', .acc = "acute" }, .{ .u = 0xF9, .base = 'u', .acc = "grave" }, .{ .u = 0xFB, .base = 'u', .acc = "circumflex" }, .{ .u = 0xFC, .base = 'u', .acc = "dieresis" }, .{ .u = 0xFD, .base = 'y', .acc = "acute" }, .{ .u = 0xFF, .base = 'y', .acc = "dieresis" },
        .{ .u = 0xC1, .base = 'A', .acc = "acute" }, .{ .u = 0xC0, .base = 'A', .acc = "grave" }, .{ .u = 0xC2, .base = 'A', .acc = "circumflex" }, .{ .u = 0xC3, .base = 'A', .acc = "tilde" }, .{ .u = 0xC4, .base = 'A', .acc = "dieresis" }, .{ .u = 0xC5, .base = 'A', .acc = "ring" },
        .{ .u = 0xC7, .base = 'C', .acc = "cedilla" }, .{ .u = 0xC9, .base = 'E', .acc = "acute" }, .{ .u = 0xC8, .base = 'E', .acc = "grave" }, .{ .u = 0xCA, .base = 'E', .acc = "circumflex" }, .{ .u = 0xCB, .base = 'E', .acc = "dieresis" },
        .{ .u = 0xCD, .base = 'I', .acc = "acute" }, .{ .u = 0xCC, .base = 'I', .acc = "grave" }, .{ .u = 0xCE, .base = 'I', .acc = "circumflex" }, .{ .u = 0xCF, .base = 'I', .acc = "dieresis" }, .{ .u = 0xD1, .base = 'N', .acc = "tilde" },
        .{ .u = 0xD3, .base = 'O', .acc = "acute" }, .{ .u = 0xD2, .base = 'O', .acc = "grave" }, .{ .u = 0xD4, .base = 'O', .acc = "circumflex" }, .{ .u = 0xD5, .base = 'O', .acc = "tilde" }, .{ .u = 0xD6, .base = 'O', .acc = "dieresis" },
        .{ .u = 0xDA, .base = 'U', .acc = "acute" }, .{ .u = 0xD9, .base = 'U', .acc = "grave" }, .{ .u = 0xDB, .base = 'U', .acc = "circumflex" }, .{ .u = 0xDC, .base = 'U', .acc = "dieresis" }, .{ .u = 0xDD, .base = 'Y', .acc = "acute" },
        .{ .u = 0x161, .base = 's', .acc = "caron" }, .{ .u = 0x160, .base = 'S', .acc = "caron" }, .{ .u = 0x17E, .base = 'z', .acc = "caron" }, .{ .u = 0x17D, .base = 'Z', .acc = "caron" },
    };
    for (ACC) |a| if (a.u == uni) {
        out[0] = a.base;
        @memcpy(out[1 .. 1 + a.acc.len], a.acc);
        return out[0 .. 1 + a.acc.len];
    };
    if (uni > 0xFFFF) return &[_]u8{};
    // uniXXXX
    const hex = "0123456789ABCDEF";
    @memcpy(out[0..3], "uni");
    out[3] = hex[(uni >> 12) & 15];
    out[4] = hex[(uni >> 8) & 15];
    out[5] = hex[(uni >> 4) & 15];
    out[6] = hex[uni & 15];
    return out[0..7];
}

/// "aacute" 처럼 밑글자+악센트인 이름은 밑글자만이라도 살린다.
const ACCENTS = "acute grave circumflex tilde dieresis ring cedilla caron breve macron ogonek";

pub fn nameToUni(nm: []const u8) u32 {
    if (nm.len == 0) return 0;
    if (nm.len == 1) return nm[0];
    // uniXXXX · uXXXX
    if (nm.len >= 7 and core.std_mem_eq(nm[0..3], "uni")) {
        var v: u32 = 0;
        var i: usize = 3;
        while (i < 7) : (i += 1) v = (v << 4) | (core.hexVal(nm[i]) orelse return 0);
        return v;
    }
    if (nm[0] == 'u' and nm.len >= 5 and nm.len <= 7) {
        var v: u32 = 0;
        var i: usize = 1;
        while (i < nm.len) : (i += 1) v = (v << 4) | (core.hexVal(nm[i]) orelse return 0);
        if (v > 0) return v;
    }
    // 표에서 찾는다
    var p: usize = 0;
    while (p < GNAMES.len) {
        const s0 = p;
        while (p < GNAMES.len and GNAMES[p] != ' ') p += 1;
        const key = GNAMES[s0..p];
        while (p < GNAMES.len and GNAMES[p] == ' ') p += 1;
        const v0 = p;
        while (p < GNAMES.len and GNAMES[p] != ' ') p += 1;
        if (key.len == nm.len and core.std_mem_eq(key, nm)) {
            var q: usize = 0;
            return @intFromFloat(@max(0, core.readFloat(GNAMES[v0..p], &q)));
        }
        while (p < GNAMES.len and GNAMES[p] == ' ') p += 1;
    }
    // "Aacute" 처럼 밑글자 + 악센트
    if (nm.len >= 2) {
        var q: usize = 0;
        while (q < ACCENTS.len) {
            const s0 = q;
            while (q < ACCENTS.len and ACCENTS[q] != ' ') q += 1;
            const acc = ACCENTS[s0..q];
            while (q < ACCENTS.len and ACCENTS[q] == ' ') q += 1;
            if (nm.len == acc.len + 1 and core.std_mem_eq(nm[1..], acc)) return nm[0];
        }
    }
    return 0;
}

/// 한 바이트 글꼴의 코드 → 유니코드 표를 인코딩에서 짓는다.
fn attachEncoding(b: []const u8, fbody: usize, fend: usize, f: *core.FontMap) void {
    var base: u8 = 0; // 0 표준 1 WinAnsi 2 MacRoman
    defer f.base_enc = base;
    // ToUnicode 가 있으면 그게 낫다 — 다만 이름 인코딩이 있는지는 적어 둔다(맨 CFF 가
    // 제 안의 인코딩 대신 이걸 따라야 한다)
    if (f.n > 0) {
        f.has_tu = true;
        if (core.find(b[fbody..fend], "/Encoding", 0)) |ea| {
            const w = b[fbody + ea .. @min(fend, fbody + ea + 40)];
            if (core.findIn(w, "WinAnsi", 0) != null) base = 1
            else if (core.findIn(w, "MacRoman", 0) != null) base = 2;
        }
        return;
    }
    var ds: usize = 0;
    var de: usize = 0;
    if (core.find(b[fbody..fend], "/Encoding", 0)) |ea| {
        var q = fbody + ea + 9;
        while (q < fend and core.isSpace(b[q])) q += 1;
        if (q < fend and b[q] == '/') {
            const w = b[q..@min(fend, q + 20)];
            if (core.findIn(w, "WinAnsi", 0) != null) base = 1
            else if (core.findIn(w, "MacRoman", 0) != null) base = 2;
        } else if (q < fend and (b[q] == '<' or core.isDigit(b[q]))) {
            if (b[q] == '<') { ds = q; de = dictEnd(b, q, fend); }
            else {
                const on = core.readUint(b, &q);
                if (core.findObj(b, on)) |ob| { ds = ob; de = core.objDictEnd(b, ob); }
            }
            if (de > ds) {
                const w = b[ds..de];
                if (core.findIn(w, "WinAnsi", 0) != null) base = 1
                else if (core.findIn(w, "MacRoman", 0) != null) base = 2;
            }
        }
    }
    // 밑바탕 인코딩
    var c: u32 = 32;
    while (c < 256) : (c += 1) {
        var u: u32 = 0;
        if (c < 127) u = c
        else if (base == 2) u = MAC_HI[c - 128]
        else if (base == 1) u = if (c < 160) WIN_HI[c - 128] else c
        else if (c >= 160) u = c;
        if (u == 0) continue;
        if (!core.mapRoom(f, f.n + 1)) break;
        f.codes.all()[f.n] = @intCast(c);
        f.unis.all()[f.n] = @intCast(@min(u, 65535));
        f.n += 1;
    }
    // /Differences 가 있으면 덮어쓴다
    if (de <= ds) return;
    const da = core.find(b[ds..de], "/Differences", 0) orelse return;
    var p = ds + da + 12;
    while (p < de and b[p] != '[') p += 1;
    p += 1;
    var code: u32 = 0;
    while (p < de and b[p] != ']') {
        while (p < de and core.isSpace(b[p])) p += 1;
        if (p >= de or b[p] == ']') break;
        if (core.isDigit(b[p])) {
            code = core.readUint(b, &p);
            continue;
        }
        if (b[p] != '/') { p += 1; continue; }
        var e2 = p + 1;
        while (e2 < de and !core.isSpace(b[e2]) and b[e2] != '/' and b[e2] != ']') e2 += 1;
        const u = nameToUni(b[p + 1 .. e2]);
        if (code < 256) f.diff[code >> 3] |= @as(u8, 1) << @intCast(code & 7);
        if (u != 0 and code < 256) {
            var k: u32 = 0;
            var hit = false;
            while (k < f.n) : (k += 1) if (f.codes.all()[k] == code) {
                f.unis.all()[k] = @intCast(@min(u, 65535));
                hit = true;
                break;
            };
            if (!hit and core.mapRoom(f, f.n + 1)) {
                f.codes.all()[f.n] = @intCast(code);
                f.unis.all()[f.n] = @intCast(@min(u, 65535));
                f.n += 1;
            }
        }
        code += 1;
        p = e2;
    }
}

/// 단순 글꼴의 /Widths — FirstChar 부터 차례로 늘어놓은 배열
fn readSimpleWidths(f: *core.FontMap, b: []const u8, s: usize, e: usize, first: u32) void {
    var p = s;
    var code = first;
    while (p < e) {
        while (p < e and core.isSpace(b[p])) p += 1;
        if (p >= e or b[p] == ']') break;
        if (!(core.isDigit(b[p]) or b[p] == '-' or b[p] == '.')) break;
        core.pushWidth(f, code, core.readFloat(b, &p));
        code += 1;
    }
}

/// CID 글꼴의 /W — "c [w ...]" 또는 "c1 c2 w" 가 섞여 나온다
/// /W 와 /W2 는 같은 꼴이다 — c [v v v …] 와 c1 c2 v. 한 항목이 폭은 수 하나,
/// 세로쓰기 자리는 셋(w1y vx vy). 따로 두 벌 두었더니 400 바이트가 겹쳤다.
fn readCidTable(f: *core.FontMap, b: []const u8, s: usize, e: usize, per: u32) void {
    var p = s;
    const num = struct {
        fn n(bb: []const u8, pp: *usize, ee: usize) ?f32 {
            while (pp.* < ee and core.isSpace(bb[pp.*])) pp.* += 1;
            if (pp.* >= ee or !(core.isDigit(bb[pp.*]) or bb[pp.*] == '-' or bb[pp.*] == '.')) return null;
            return core.readFloat(bb, pp);
        }
    }.n;
    const put = struct {
        fn g(ff: *core.FontMap, code: u32, v: [3]f32, k: u32) void {
            if (k == 1) core.pushWidth(ff, code, v[0]) else core.pushVMetric(ff, code, v[0], v[1], v[2]);
        }
    }.g;
    while (p < e) {
        while (p < e and core.isSpace(b[p])) p += 1;
        if (p >= e or b[p] == ']') break;
        if (!core.isDigit(b[p])) { p += 1; continue; }
        const c1: u32 = @intFromFloat(@max(0, core.readFloat(b, &p)));
        while (p < e and core.isSpace(b[p])) p += 1;
        var v: [3]f32 = .{ 0, 0, 0 };
        if (p < e and b[p] == '[') {
            p += 1;
            var code = c1;
            while (p < e) {
                while (p < e and core.isSpace(b[p])) p += 1;
                if (p >= e or b[p] == ']') { p += 1; break; }
                var k: u32 = 0;
                var ok = true;
                while (k < per) : (k += 1) v[k] = num(b, &p, e) orelse { ok = false; break; };
                if (!ok) { if (k == 0) { p += 1; continue; } else break; }
                put(f, code, v, per);
                code += 1;
            }
        } else {
            const c2: u32 = @intFromFloat(@max(0, num(b, &p, e) orelse continue));
            var k: u32 = 0;
            var ok = true;
            while (k < per) : (k += 1) v[k] = num(b, &p, e) orelse { ok = false; break; };
            if (!ok) continue;
            var c = c1;
            while (c <= c2 and c - c1 < 65535) : (c += 1) put(f, c, v, per);
        }
    }
}

/// "[" 로 시작하는 배열의 끝을 찾는다 (안쪽 배열까지 센다)
pub fn arrayEnd(b: []const u8, s: usize, limit: usize) usize {
    var p = s;
    var depth: u32 = 0;
    while (p < limit) : (p += 1) {
        if (b[p] == '[') depth += 1;
        if (b[p] == ']') { depth -= 1; if (depth == 0) return p; }
    }
    return limit;
}

/// Type0 이면 자손 글꼴 딕셔너리 범위를 준다.
fn descendantOf(b: []const u8, fbody: usize, fend: usize) ?[2]usize {
    const da = core.find(b[fbody..fend], "/DescendantFonts", 0) orelse return null;
    var p = fbody + da + 16;
    while (p < fend and (core.isSpace(b[p]) or b[p] == '[')) p += 1;
    if (p >= fend or !core.isDigit(b[p])) return null;
    const dn = core.readUint(b, &p);
    var db = core.findObj(b, dn) orelse return null;
    // /DescendantFonts 2910 0 R 이고 2910 이 "[2935 0 R]" 배열 객체인 문서(InDesign)가
    // 있다. 배열을 글꼴로 읽으면 /W 가 없어 모든 글자가 1000 폭이 되어 줄이
    // 쪽 밖으로 밀려 나갔다 — 한 번 더 따라간다
    var q2 = db;
    const de = core.find(b, "endobj", db) orelse b.len;
    while (q2 < de and core.isSpace(b[q2])) q2 += 1;
    if (q2 < de and b[q2] == '[') {
        q2 += 1;
        while (q2 < de and core.isSpace(b[q2])) q2 += 1;
        if (q2 >= de or !core.isDigit(b[q2])) return null;
        const dn2 = core.readUint(b, &q2);
        db = core.findObj(b, dn2) orelse return null;
    }
    return .{ db, core.find(b, "endobj", db) orelse b.len };
}

/// /W·/W2 배열의 안쪽 범위. "/W 71 0 R" 처럼 딴 객체에 둔 것(Word)도 따라간다 —
/// 안 따라가면 모든 글자가 DW(1000) 폭이 되어 한 줄이 두 줄 길이로 늘어나고,
/// 줄 뒤쪽 글자가 쪽 밖으로 밀려 글자 뽑기에서 사라졌다. "/W" 는 "/W2" 에도
/// 걸리므로 이름이 그 자리에서 끝나는 keyPos 로 찾는다.
fn cidArray(b: []const u8, db: usize, de: usize, key: []const u8) ?[2]usize {
    const wa = core.keyPos(b, db, de, key) orelse return null;
    var p = wa + key.len;
    while (p < de and core.isSpace(b[p])) p += 1;
    if (p < de and b[p] == '[') return .{ p + 1, arrayEnd(b, p, de) };
    if (p >= de or !core.isDigit(b[p])) return null;
    const on = core.readUint(b, &p);
    const ob = core.findObj(b, on) orelse return null;
    const oe = core.find(b, "endobj", ob) orelse b.len;
    var q = ob;
    while (q < oe and b[q] != '[') q += 1;
    if (q >= oe) return null;
    return .{ q + 1, arrayEnd(b, q, oe) };
}

/// 방금 등록한 글꼴에 폭 표를 채운다.
pub fn attachWidths(b: []const u8, fbody: usize) void {
    if (core.fontarea.n == 0) return;
    const f = &core.fonts.all()[core.fontarea.n - 1];
    const fend = core.find(b, "endobj", fbody) orelse b.len;
    // 두 바이트 코드는 Type0(합성) 글꼴만이다. ToUnicode 의 codespacerange 가 <0000> <FFFF>
    // 여도(InDesign 은 단순 글꼴에도 그렇게 적는다) 단순 글꼴은 한 바이트다 — 안 그러면
    // 낱말 사이(Tw)가 안 먹고 기본 폭이 1000 이 되고 글리프를 코드 번호로 집는다
    if (core.find(b[fbody..fend], "/Type0", 0) == null) f.two_byte = false;
    // Identity-H 는 두 바이트 코드가 곧 CID 다
    if (core.find(b[fbody..fend], "/Encoding", 0)) |ea2| {
        var q = fbody + ea2 + 9;
        while (q < fend and core.isSpace(b[q])) q += 1;
        if (q < fend and b[q] == '/') {
            var nq = q + 1;
            while (nq < fend and !core.isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>') nq += 1;
            const nm = b[q + 1 .. nq];
            f.cmap_kind = core.cmapKindOf(nm);
            if (f.cmap_kind == 1) f.identity = true;
            if (f.cmap_kind != 0) f.two_byte = true;
            if (nm.len >= 2 and nm[nm.len - 1] == 'V') f.vertical = true;
            // 받아 둔 표가 있으면 어림짐작 대신 그걸 쓴다
            f.cm = core.cmapFind(nm);
            if (f.cm >= 0) f.two_byte = true;
        }
    }

    if (descendantOf(b, fbody, fend)) |d| {
        const db = d[0];
        const de = d[1];
        // CIDToGIDMap 이 스트림이면 CID 와 글리프 번호가 다르다.
        // 표를 읽어 두면 번호로 글리프를 그대로 집을 수 있다.
        if (core.find(b[db..de], "/CIDToGIDMap", 0)) |ca| {
            var q = db + ca + 12;
            while (q < de and core.isSpace(b[q])) q += 1;
            if (q < de and core.isDigit(b[q])) {
                const gn = core.readUint(b, &q);
                // streamOf 의 결과는 다음 호출이 덮으므로 바로 옮겨 둔다
                if (pdfform.streamOf(b, gn)) |m| {
                    const room = core.C2G_POOL - core.c2g.used;
                    const n = @min(m.len, room);
                    if (n >= 2) {
                        @memcpy(core.c2g_pool()[core.c2g.used..][0..n], m[0..n]);
                        f.c2g_off = core.c2g.used;
                        f.c2g_len = @intCast(n);
                        core.c2g.used += @intCast(n);
                        // 표가 있으면 CID 로 글리프를 집을 수 있다
                        f.identity = true;
                    } else f.identity = false;
                } else f.identity = false;
            }
        }
        // 이 글꼴이 어느 계열인지 — CID 로 글자를 찾을 때 쓴다
        if (core.find(b[db..de], "/Ordering", 0)) |oa| {
            var q = db + oa + 9;
            while (q < de and core.isSpace(b[q])) q += 1;
            if (q < de and b[q] == '(') {
                var e = q + 1;
                while (e < de and e < q + 24 and b[e] != ')') e += 1;
                const on = b[q + 1 .. e];
                if (on.len <= 20) {
                    var tmp: [32]u8 = undefined;
                    @memcpy(tmp[0..on.len], on);
                    @memcpy(tmp[on.len..][0..5], "-UCS2");
                    f.uc = core.cmapFind(tmp[0 .. on.len + 5]);
                }
            }
        }
        if (core.intAfter(b, db, de, "/DW")) |dw| f.dw = @floatFromInt(dw);
        // 세로쓰기 자리 — /DW2 [vy w1y] 와 /W2 [c [w1y vx vy …] | c1 c2 w1y vx vy]
        if (core.keyPos(b, db, de, "/DW2")) |da| {
            var p = da + 4;
            while (p < de and core.isSpace(b[p])) p += 1;
            if (p < de and b[p] == '[') {
                p += 1;
                while (p < de and core.isSpace(b[p])) p += 1;
                f.dw2[0] = core.readFloat(b, &p);
                while (p < de and core.isSpace(b[p])) p += 1;
                f.dw2[1] = core.readFloat(b, &p);
            }
        }
        if (cidArray(b, db, de, "/W2")) |r| readCidTable(f, b, r[0], r[1], 3);
        if (cidArray(b, db, de, "/W")) |r| readCidTable(f, b, r[0], r[1], 1);
        if (f.dw == 0) f.dw = 1000; // 규격 기본값
        return;
    }
    // 한 바이트 글꼴이면 인코딩으로 코드→글자 표를 짓는다
    attachEncoding(b, fbody, fend, f);
    // 표준 14종이면 폭 표를 달아 둔다. /Widths 가 있으면 그쪽이 이긴다.
    f.std_w = core.std14For(b, fbody, fend);
    const first = core.intAfter(b, fbody, fend, "/FirstChar") orelse 0;
    const wa = core.find(b[fbody..fend], "/Widths", 0) orelse return;
    var p = fbody + wa + 7;
    while (p < fend and core.isSpace(b[p])) p += 1;
    if (p < fend and b[p] == '[') {
        readSimpleWidths(f, b, p + 1, arrayEnd(b, p, fend), first);
    } else if (p < fend and core.isDigit(b[p])) {
        const wn = core.readUint(b, &p);
        if (core.findObj(b, wn)) |wb| {
            const we = core.find(b, "endobj", wb) orelse b.len;
            var q = wb;
            while (q < we and b[q] != '[') q += 1;
            if (q < we) readSimpleWidths(f, b, q + 1, arrayEnd(b, q, we), first);
        }
    }
}

/// "<<" 로 시작하는 딕셔너리의 끝(">>" 다음)을 찾는다.
pub fn dictEnd(b: []const u8, s: usize, limit: usize) usize {
    var p = s;
    var depth: u32 = 0;
    while (p + 1 < limit) : (p += 1) {
        if (b[p] == '<' and b[p + 1] == '<') { depth += 1; p += 1; continue; }
        if (b[p] == '>' and b[p + 1] == '>') {
            depth -= 1;
            if (depth == 0) return p + 2;
            p += 1;
            continue;
        }
    }
    return limit;
}

/// 딕셔너리 구간에서 "/이름 N 0 R" 의 N 을 찾는다.
fn keyRef(b: []const u8, s: usize, e: usize, name: []const u8) ?u32 {
    var p = s;
    while (p + name.len + 1 < e) : (p += 1) {
        if (b[p] != '/') continue;
        if (!core.std_mem_eq(b[p + 1 .. p + 1 + name.len], name)) continue;
        const after = b[p + 1 + name.len];
        if (!core.isSpace(after) and after != '/' and after != '>') continue;
        var q = p + 1 + name.len;
        while (q < e and core.isSpace(b[q])) q += 1;
        if (q < e and core.isDigit(b[q])) return core.readUint(b, &q);
        return null;
    }
    return null;
}

/// Type3 글꼴의 글리프 그림을 찾아 코드마다 이어 둔다.
///
/// Type3 는 글리프가 글꼴 파일이 아니라 작은 콘텐츠 스트림으로 들어 있다.
/// 크롬이 맥에서 만든 PDF 의 한글이 그렇고, 관공서 문서의 바코드도 대개
/// 그렇다. 실을 글꼴이 없으니 시스템 글꼴로 때우면 엉뚱한 그림이 된다.
/// 우리는 콘텐츠 해석기를 이미 갖고 있으므로 그 스트림을 그대로 돌린다.
pub fn attachType3(b: []const u8, fbody: usize) void {
    if (core.fontarea.n == 0) return;
    const f = &core.fonts.all()[core.fontarea.n - 1];
    const fend = core.find(b, "endobj", fbody) orelse b.len;
    if (core.find(b[fbody..fend], "/Subtype", 0)) |sa| {
        var q = fbody + sa + 8;
        while (q < fend and core.isSpace(q_at(b, q))) q += 1;
        if (!(q + 6 <= fend and core.std_mem_eq(b[q .. q + 6], "/Type3"))) return;
    } else return;
    f.type3 = true;
    f.kind |= 32;

    // 글꼴 제 /Resources 도 훑는다.
    //
    // 자원은 쪽 단위로 미리 훑어 표에 담는데, Type3 글꼴은 제 자원을 따로
    // 들고 있다. 그걸 안 훑으면 글리프 프로그램 안의 /Im0 Do 나 /GS0 gs 가
    // 아무것도 못 찾아 조용히 지나간다 — 그림을 품은 글리프는 아예 안
    // 그려졌고, 투명도를 건 글리프는 불투명하게 나왔다(pdf.js 와 맞대 보고
    // 알았다).
    if (core.find(b[fbody..fend], "/Resources", 0)) |ra| {
        var rp = fbody + ra + 10;
        while (rp < fend and core.isSpace(b[rp])) rp += 1;
        if (rp < fend and b[rp] == '<') {
            core.scanResources(b, rp, dictEnd(b, rp, fend), 1);
        } else if (rp < fend and core.isDigit(b[rp])) {
            const rn = core.readUint(b, &rp);
            if (core.findObj(b, rn)) |rb| {
                core.scanResources(b, rb, core.find(b, "endobj", rb) orelse b.len, 1);
            }
        }
    }

    if (core.find(b[fbody..fend], "/FontMatrix", 0)) |ma| {
        var p = fbody + ma + 11;
        while (p < fend and b[p] != '[') p += 1;
        p += 1;
        var i: u32 = 0;
        while (i < 6 and p < fend) : (i += 1) f.fm[i] = core.readFloat(b, &p);
    }

    // CharProcs 구간
    var cs: usize = 0;
    var ce: usize = 0;
    if (core.find(b[fbody..fend], "/CharProcs", 0)) |ca| {
        var p = fbody + ca + 10;
        while (p < fend and core.isSpace(b[p])) p += 1;
        if (p < fend and b[p] == '<') { cs = p; ce = dictEnd(b, p, fend); }
        else if (p < fend and core.isDigit(b[p])) {
            const n = core.readUint(b, &p);
            if (core.findObj(b, n)) |cb| {
                const cend = core.find(b, "endobj", cb) orelse b.len;
                var q = cb;
                while (q < cend and b[q] != '<') q += 1;
                cs = q;
                ce = dictEnd(b, q, cend);
            }
        }
    }
    if (ce <= cs) return;

    // Encoding 의 Differences 로 코드→이름을 걷는다
    var es = fbody;
    var ee = fend;
    if (core.find(b[fbody..fend], "/Encoding", 0)) |ea| {
        var p = fbody + ea + 9;
        while (p < fend and core.isSpace(b[p])) p += 1;
        if (p < fend and b[p] == '<') { es = p; ee = dictEnd(b, p, fend); }
        else if (p < fend and core.isDigit(b[p])) {
            const n = core.readUint(b, &p);
            if (core.findObj(b, n)) |eb| { es = eb; ee = core.find(b, "endobj", eb) orelse b.len; }
        }
    }
    const da = core.find(b[es..ee], "/Differences", 0) orelse return;
    var p = es + da + 12;
    while (p < ee and b[p] != '[') p += 1;
    p += 1;
    var code: u32 = 0;
    var seen: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var distinct: u32 = 0;
    var assigned: u32 = 0;
    while (p < ee and b[p] != ']') {
        while (p < ee and core.isSpace(b[p])) p += 1;
        if (p >= ee or b[p] == ']') break;
        if (core.isDigit(b[p])) { code = core.readUint(b, &p); continue; }
        if (b[p] != '/') { p += 1; continue; }
        const ns = p + 1;
        var nq = ns;
        while (nq < ee and !core.isSpace(b[nq]) and b[nq] != '/' and b[nq] != ']') nq += 1;
        // .notdef 는 건너뛴다.
        //
        // 글리프 번호 0 은 규격상 .notdef 이고, 크롬은 그것을 /g0 으로 적는다.
        // 내용은 X 를 친 빈 네모다. 그대로 그리면 글자 대신 네모가 나오므로
        // 시스템 글꼴로 대신 그리게 비워 둔다.
        const nm = b[ns..nq];
        const is_notdef = core.txEq(nm, "g0") or core.txEq(nm, ".notdef");
        if (code < 256 and nq > ns and !is_notdef) {
            if (keyRef(b, cs, ce, nm)) |on| {
                f.t3[code] = on;
                assigned += 1;
                var k: u32 = 0;
                var found = false;
                while (k < distinct and k < seen.len) : (k += 1) if (seen[k] == on) { found = true; break; };
                if (!found and distinct < seen.len) { seen[distinct] = on; distinct += 1; }
            }
        }
        code += 1;
        p = nq;
    }

    // 글리프가 사실상 하나뿐이면 껍데기다.
    //
    // 크롬이 맥에서 만든 PDF 가 그렇다 — 모든 코드가 빈 네모(notdef) 하나를
    // 가리키고, 진짜 글꼴은 읽는 쪽 컴퓨터에 있으리라 기대한다. 그대로 그리면
    // 글자마다 X 친 네모가 나오므로, 그럴 때는 시스템 글꼴로 대신 그린다.
    if (distinct <= 1 and assigned > 8) {
        @memset(&f.t3, 0);
        f.kind |= 256;
    }
}

pub fn q_at(b: []const u8, i: usize) u8 { return if (i < b.len) b[i] else ' '; }

/// 글꼴 딕셔너리에서 박힌 글꼴 파일을 찾아 붙인다.
/// Type0 이면 자손 글꼴을 한 번 더 따라간다.
pub fn attachEmbedded(b: []const u8, fbody: usize) void {
    if (core.fontarea.n == 0) return;
    const f = &core.fonts.all()[core.fontarea.n - 1];
    const fend = core.find(b, "endobj", fbody) orelse b.len;
    var db = fbody;
    var de = fend;
    if (descendantOf(b, fbody, de)) |d| { db = d[0]; de = d[1]; }
    const fd = core.find(b[db..de], "/FontDescriptor", 0) orelse return;
    var p = db + fd + 15;
    while (p < de and core.isSpace(b[p])) p += 1;
    if (p >= de or !core.isDigit(b[p])) return;
    const dn = core.readUint(b, &p);
    const sb = core.findObj(b, dn) orelse return;
    const se = core.find(b, "endobj", sb) orelse b.len;

    // 굵기 — 이름(Bold·Medi·TB…)은 글꼴마다 달라 믿을 수 없다. 서술자의
    // /FontWeight ≥ 600, /StemV ≥ 120, /Flags 의 ForceBold(2^18) 가운데 하나면 굵다.
    if (core.intAfter(b, sb, se, "/FontWeight")) |fw| { if (fw >= 600) f.kind |= 2048; }
    if (core.intAfter(b, sb, se, "/StemV")) |sv| { if (sv >= 120) f.kind |= 2048; }
    if (core.intAfter(b, sb, se, "/Flags")) |fl| { if ((fl & (1 << 18)) != 0) f.kind |= 2048; }

    var fobj: u32 = 0;
    var is_cff = false;
    if (core.find(b[fbody..fend], "/Type3", 0) != null) f.kind |= 32;
    if (core.find(b[sb..se], "/FontFile2", 0) == null and
        core.find(b[sb..se], "/FontFile3", 0) == null and
        core.find(b[sb..se], "/FontFile", 0) == null) f.kind |= 128;
    if (core.find(b[sb..se], "/FontFile2", 0)) |a| {
        var q = sb + a + 10;
        while (q < se and core.isSpace(b[q])) q += 1;
        if (q < se and core.isDigit(b[q])) fobj = core.readUint(b, &q);
    } else if (core.find(b[sb..se], "/FontFile3", 0) == null and
        core.find(b[sb..se], "/FontFile", 0) != null)
    {
        // 옛 Type1. "/FontFile" 은 접두사라 3·2 를 다 삼키므로 마지막에 본다.
        const a1 = core.find(b[sb..se], "/FontFile", 0) orelse return;
        var q = sb + a1 + 9;
        while (q < se and core.isSpace(b[q])) q += 1;
        if (q < se and core.isDigit(b[q])) {
            const n1 = core.readUint(b, &q);
            if (pdfform.streamOf(b, n1)) |t1data| {
                core.attachType1(b, fbody, fend, t1data);
            }
        }
        if (!f.t1) f.kind |= 64;
        return;
    } else if (core.find(b[sb..se], "/FontFile3", 0)) |a| {
        // 형식 3 은 OpenType 로 싸여 있기도 하고 맨 CFF 이기도 하다.
        // 맨 CFF 는 우리가 OpenType 껍데기를 지어 씌운다.
        var q = sb + a + 10;
        while (q < se and core.isSpace(b[q])) q += 1;
        if (q < se and core.isDigit(b[q])) {
            const n3 = core.readUint(b, &q);
            if (core.findObj(b, n3)) |o3| {
                const e3 = core.objDictEnd(b, o3);
                if (core.find(b[o3..e3], "/OpenType", 0) != null) {
                    fobj = n3;
                } else if (core.find(b[o3..e3], "/Type1C", 0) != null or
                    core.find(b[o3..e3], "/CIDFontType0C", 0) != null)
                {
                    fobj = n3;
                    is_cff = true;
                } else {
                    f.kind |= 16;
                }
            }
        }
    }
    if (fobj == 0) return;
    const data = pdfform.streamOf(b, fobj) orelse return;
    // 맨 CFF 의 단순 글꼴은 /Differences 의 이름으로 글리프를 고른다
    if (is_cff and !f.two_byte) core.pdft1.loadDifferences(b, fbody, fend, true);
    core.attachFontFile(data, is_cff);
    if (is_cff and f.file_len == 0) f.kind |= 16; // 껍데기를 못 지었다
}

