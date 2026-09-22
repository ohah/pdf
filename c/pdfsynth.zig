//! 없는 폭 표·인코딩을 지어 채운다
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 0개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 10개다.
//!
//! JS 에 내보내는 함수(0개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");

// ===== 없는 표를 지어 채우기 =====
//
// 브라우저는 글꼴을 그냥 받지 않고 한 번 걸러 본다(크롬은 OTS). 규격이
// 있어야 한다고 정한 표가 빠져 있으면 통째로 거절한다 — FontFace 가
// "Invalid font data" 를 던지고, 우리는 글리프를 사용자 영역 번호로 집기
// 때문에 대체 글꼴에도 그 번호가 없어 글자가 **한 자도 안 그려진다**.
//
// 실제로 한글 워드프로세서가 뽑은 문서가 name·OS/2·post 없이 글꼴을 담아,
// 여섯 쪽이 거의 빈 채로 나왔다. 없으면 여기서 최소한으로 지어 넣는다.

/// name — 이름표. 창(3,1,영어) 자리에 넉 줄만 둔다.
fn buildNameTable(dst: []u8) u32 {
    const FAM = "PDFEmbedded";
    const SUB = "Regular";
    const nrec = 4;
    const storage = 6 + nrec * 12;
    if (dst.len < storage + (FAM.len + SUB.len) * 2) return 0;
    core.wr16(dst, 0, 0); // format 0
    core.wr16(dst, 2, nrec);
    core.wr16(dst, 4, @intCast(storage));
    // 글자열은 UTF-16BE 로 담는다
    var w: u32 = @intCast(storage);
    const fam_off: u32 = 0;
    var i: usize = 0;
    while (i < FAM.len) : (i += 1) {
        core.wr16(dst, w, FAM[i]);
        w += 2;
    }
    const subOff: u32 = @intCast(FAM.len * 2);
    i = 0;
    while (i < SUB.len) : (i += 1) {
        core.wr16(dst, w, SUB[i]);
        w += 2;
    }
    // 줄은 (플랫폼, 인코딩, 언어, 이름번호) 차례로 놓여야 한다
    const ids = [nrec]u16{ 1, 2, 4, 6 };
    var r: u32 = 6;
    var k: u32 = 0;
    while (k < nrec) : (k += 1) {
        const fam = ids[k] != 2;
        core.wr16(dst, r, 3); // 윈도
        core.wr16(dst, r + 2, 1); // 유니코드 BMP
        core.wr16(dst, r + 4, 0x0409); // 영어
        core.wr16(dst, r + 6, ids[k]);
        core.wr16(dst, r + 8, @intCast(if (fam) FAM.len * 2 else SUB.len * 2));
        core.wr16(dst, r + 10, @intCast(if (fam) fam_off else subOff));
        r += 12;
    }
    return w;
}

/// OS/2 — 판 4. 값은 흔한 본문 글꼴에 맞춰 무난하게 둔다.
fn buildOs2Table(dst: []u8) u32 {
    if (dst.len < 96) return 0;
    @memset(dst[0..96], 0);
    core.wr16(dst, 0, 4); // version
    core.wr16(dst, 2, 500); // xAvgCharWidth
    core.wr16(dst, 4, 400); // usWeightClass 보통
    core.wr16(dst, 6, 5); // usWidthClass 보통
    core.wr16(dst, 8, 0); // fsType — 심는 데 제한 없음
    core.wr16(dst, 10, 650);
    core.wr16(dst, 12, 600);
    core.wr16(dst, 16, 75);
    core.wr16(dst, 18, 650);
    core.wr16(dst, 20, 600);
    core.wr16(dst, 24, 350);
    core.wr16(dst, 26, 50);
    core.wr16(dst, 28, 250);
    // achVendID
    dst[58] = 'P';
    dst[59] = 'D';
    dst[60] = 'F';
    dst[61] = ' ';
    core.wr16(dst, 62, 0x0040); // fsSelection — 보통체
    core.wr16(dst, 64, 0x0020); // usFirstCharIndex
    core.wr16(dst, 66, 0xFFFF); // usLastCharIndex
    core.wr16(dst, 68, 800); // sTypoAscender
    core.wr16(dst, 70, @bitCast(@as(i16, -200))); // sTypoDescender
    core.wr16(dst, 72, 200); // sTypoLineGap
    core.wr16(dst, 74, 1000); // usWinAscent
    core.wr16(dst, 76, 200); // usWinDescent
    core.wr32(dst, 78, 1); // ulCodePageRange1 — 라틴1
    core.wr16(dst, 86, 500); // sxHeight
    core.wr16(dst, 88, 700); // sCapHeight
    core.wr16(dst, 92, 0x20); // usBreakChar
    core.wr16(dst, 94, 1); // usMaxContext
    return 96;
}

/// post — 판 3.0. 글리프 이름은 담지 않는다.
fn buildPostTable(dst: []u8) u32 {
    if (dst.len < 32) return 0;
    @memset(dst[0..32], 0);
    core.wr32(dst, 0, 0x00030000);
    core.wr16(dst, 8, @bitCast(@as(i16, -100))); // underlinePosition
    core.wr16(dst, 10, 50); // underlineThickness
    return 32;
}

/// 글꼴 파일의 cmap 을 f 의 코드표로 갈아 끼워 dst 에 새로 적는다.
/// 성공하면 새 파일 길이, 실패하면 0.
pub fn patchFont(src: []const u8, f: *core.FontMap, dst: []u8) u32 {
    if (src.len < 12) return 0;
    const tag = core.be32(src, 0);
    // 0x00010000(트루타입), 'true', 'OTTO' 만 받는다
    if (tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F) return 0;
    const num = core.be16(src, 4);
    if (num == 0 or num > 64 or 12 + @as(usize, num) * 16 > src.len) return 0;
    if (dst.len < 4096) return 0;
    const scratch = dst.len / 2;

    // 글리프 수는 maxp 에 있다
    var nglyphs: u32 = 0;
    {
        var t: u16 = 0;
        while (t < num) : (t += 1) {
            const r = 12 + @as(usize, t) * 16;
            if (core.be32(src, r) == 0x6D617870) { // 'maxp'
                const off = core.be32(src, r + 8);
                if (off + 6 <= src.len) nglyphs = core.be16(src, off + 4);
            }
        }
    }

    const cmap_len = buildFontCmapFrom(src, f, @intCast(@min(nglyphs, 65535)), dst[scratch..]);
    if (cmap_len == 0) return 0;

    // 표 하나: from 0 이면 원본, 1 이면 임시 자리(dst[scratch..])
    const Tbl = struct { tag: u32, from: u8, off: u32, len: u32 };
    var tbl: [80]Tbl = undefined;
    var tn: u32 = 0;

    // 원본에서 남길 것 (cmap 은 우리 것으로 바꾼다)
    var has_name = false;
    var has_os2 = false;
    var has_post = false;
    var t: u16 = 0;
    while (t < num and tn + 8 < tbl.len) : (t += 1) {
        const r = 12 + @as(usize, t) * 16;
        const tt = core.be32(src, r);
        if (tt == 0x636D6170) continue; // 'cmap'
        // 글리프 치환·자리 표(GSUB·GPOS·GDEF·kern·morx)는 뺀다. PDF 는 글리프를 이미 골라
        // 놓았는데 브라우저가 부분집합 글꼴의 GSUB 를 다시 먹여 숫자 글리프를 (빠진)
        // 대체 글리프로 바꿔 "2026"·"37" 이 비어 나왔다(통계청 소식지). 커닝도 PDF 자리와
        // 어긋나므로 같이 뺀다
        if (tt == 0x47535542 or tt == 0x47504F53 or tt == 0x47444546 or tt == 0x6B65726E or
            tt == 0x6D6F7278 or tt == 0x42415345 or tt == 0x4A535446 or tt == 0x66656174) continue;
        const off = core.be32(src, r + 8);
        const ln = core.be32(src, r + 12);
        if (off > src.len or ln > src.len - off) return 0;
        if (tt == 0x6E616D65) has_name = true;
        if (tt == 0x4F532F32) has_os2 = true;
        if (tt == 0x706F7374) has_post = true;
        tbl[tn] = .{ .tag = tt, .from = 0, .off = off, .len = ln };
        tn += 1;
    }
    // 우리가 지은 cmap
    tbl[tn] = .{ .tag = 0x636D6170, .from = 1, .off = 0, .len = cmap_len };
    tn += 1;

    // 규격이 있어야 한다고 정한 표가 빠졌으면 지어 넣는다.
    // 없으면 브라우저가 글꼴을 통째로 거절해 글자가 한 자도 안 그려진다.
    var syn: u32 = (cmap_len + 3) & ~@as(u32, 3);
    const room = dst.len - scratch;
    if (!has_name and syn + 256 < room) {
        const n2 = buildNameTable(dst[scratch + syn ..]);
        if (n2 > 0) {
            tbl[tn] = .{ .tag = 0x6E616D65, .from = 1, .off = syn, .len = n2 };
            tn += 1;
            syn = (syn + n2 + 3) & ~@as(u32, 3);
        }
    }
    if (!has_os2 and syn + 128 < room) {
        const n2 = buildOs2Table(dst[scratch + syn ..]);
        if (n2 > 0) {
            tbl[tn] = .{ .tag = 0x4F532F32, .from = 1, .off = syn, .len = n2 };
            tn += 1;
            syn = (syn + n2 + 3) & ~@as(u32, 3);
        }
    }
    if (!has_post and syn + 64 < room) {
        const n2 = buildPostTable(dst[scratch + syn ..]);
        if (n2 > 0) {
            tbl[tn] = .{ .tag = 0x706F7374, .from = 1, .off = syn, .len = n2 };
            tn += 1;
            syn = (syn + n2 + 3) & ~@as(u32, 3);
        }
    }

    // 표 목록은 이름순이어야 한다 (규격). 개수가 적어 그냥 끼워 넣기로 센다.
    {
        var si: u32 = 1;
        while (si < tn) : (si += 1) {
            const v = tbl[si];
            var j: u32 = si;
            while (j > 0 and tbl[j - 1].tag > v.tag) : (j -= 1) tbl[j] = tbl[j - 1];
            tbl[j] = v;
        }
    }
    const out_n = tn;
    // 표들이 서로 겹쳐 있으면 옮겨 적을 때 원본보다 몇 배로 부푼다.
    // 부풀 만큼만 허락하고 그 위는 손대지 않는다.
    var claim: u32 = 0;
    var ci: u32 = 0;
    while (ci < tn) : (ci += 1) claim += tbl[ci].len + 3;
    if (claim > 4 * src.len + 65536) return 0;
    const dir = 12 + out_n * 16;
    var pos: u32 = (dir + 3) & ~@as(u32, 3);
    if (pos >= scratch) return 0;

    // 표를 차례로 옮겨 적고 표 목록을 만든다
    var head_pos: u32 = 0;
    var recs: u32 = 0;
    var w: u32 = 0;
    while (w < out_n) : (w += 1) {
        const tt = tbl[w].tag;
        const ln = tbl[w].len;
        if (pos + ln > scratch) return 0;
        if (tbl[w].from == 1) {
            @memcpy(dst[pos..][0..ln], dst[scratch + tbl[w].off ..][0..ln]);
        } else {
            @memcpy(dst[pos..][0..ln], src[tbl[w].off..][0..ln]);
        }
        if (tt == 0x68656164) head_pos = pos; // 'head'
        const r = 12 + recs * 16;
        core.wr32(dst, r, tt);
        core.wr32(dst, r + 4, core.sumTable(dst, pos, ln));
        core.wr32(dst, r + 8, pos);
        core.wr32(dst, r + 12, ln);
        recs += 1;
        const end = pos + ln;
        pos = (end + 3) & ~@as(u32, 3);
        // 4바이트 맞춤으로 생긴 빈틈. 이전 쪽의 찌꺼기가 남지 않게 0 으로 둔다.
        @memset(dst[end..pos], 0);
    }

    core.wr32(dst, 0, tag);
    core.wr16(dst, 4, @intCast(out_n));
    var p2: u32 = 1;
    var es: u16 = 0;
    while (p2 * 2 <= out_n) : (p2 *= 2) es += 1;
    core.wr16(dst, 6, @intCast(p2 * 16));
    core.wr16(dst, 8, es);
    core.wr16(dst, 10, @intCast(out_n * 16 - p2 * 16));

    // head 의 checkSumAdjustment 를 다시 센다
    if (head_pos != 0 and head_pos + 12 <= pos) {
        core.wr32(dst, head_pos + 8, 0);
        const whole = core.sumTable(dst, 0, pos);
        core.wr32(dst, head_pos + 8, 0xB1B0AFBA -% whole);
    }
    return pos;
}

/// 글꼴 하나에 쓸 cmap 을 만든다.
///
/// Identity-H 는 문자 코드가 곧 글리프 번호라, 유니코드를 거치지 않고
/// 사용자 영역(U+E000~)에 번호를 그대로 붙인다. 그렇지 않으면 ToUnicode 를
/// 뒤집어 "유니코드 → 글리프" 표를 만든다.
/// 트루타입 원본 cmap 에서 (platform, encoding) 부표의 코드 하나를 찾는다. 형식 0·4·6·12.
fn ttfCmapGid(src: []const u8, plat: u16, enc: u16, code: u32) ?u16 {
    if (src.len < 12) return null;
    const num = core.be16(src, 4);
    var t: u16 = 0;
    var cmap: usize = 0;
    var clen: usize = 0;
    while (t < num) : (t += 1) {
        const r = 12 + @as(usize, t) * 16;
        if (r + 16 > src.len) return null;
        if (core.be32(src, r) == 0x636D6170) { cmap = core.be32(src, r + 8); clen = core.be32(src, r + 12); }
    }
    if (cmap == 0 or cmap + 4 > src.len) return null;
    const nt = core.be16(src, cmap + 2);
    var k: u16 = 0;
    while (k < nt) : (k += 1) {
        const e = cmap + 4 + @as(usize, k) * 8;
        if (e + 8 > src.len) return null;
        if (core.be16(src, e) != plat or core.be16(src, e + 2) != enc) continue;
        const so = cmap + core.be32(src, e + 4);
        if (so + 4 > src.len) return null;
        const fmt = core.be16(src, so);
        if (fmt == 0) {
            if (code > 255 or so + 6 + code >= src.len) return null;
            const g = src[so + 6 + code];
            return if (g == 0) null else g;
        }
        if (fmt == 6) {
            const first = core.be16(src, so + 6);
            const cnt = core.be16(src, so + 8);
            if (code < first or code >= @as(u32, first) + cnt) return null;
            const at = so + 10 + (code - first) * 2;
            if (at + 2 > src.len) return null;
            const g = core.be16(src, at);
            return if (g == 0) null else g;
        }
        if (fmt == 4) {
            if (code > 0xFFFF) return null;
            const segx2 = core.be16(src, so + 6);
            const seg = segx2 / 2;
            const ends = so + 14;
            const starts = ends + segx2 + 2;
            const deltas = starts + segx2;
            const ranges = deltas + segx2;
            if (ranges + segx2 > src.len) return null;
            var i: usize = 0;
            while (i < seg) : (i += 1) {
                const end = core.be16(src, ends + i * 2);
                if (code > end) continue;
                const start = core.be16(src, starts + i * 2);
                if (code < start) return null;
                const delta = core.be16(src, deltas + i * 2);
                const ro = core.be16(src, ranges + i * 2);
                var g: u16 = 0;
                if (ro == 0) {
                    g = @intCast((code + delta) & 0xFFFF);
                } else {
                    const at = ranges + i * 2 + ro + (code - start) * 2;
                    if (at + 2 > src.len) return null;
                    g = core.be16(src, at);
                    if (g != 0) g = @intCast((@as(u32, g) + delta) & 0xFFFF);
                }
                return if (g == 0) null else g;
            }
            return null;
        }
        if (fmt == 12) {
            const ngroups = core.be32(src, so + 12);
            var i: usize = 0;
            while (i < ngroups and i < 100000) : (i += 1) {
                const at = so + 16 + i * 12;
                if (at + 12 > src.len) return null;
                const sc = core.be32(src, at);
                const ec = core.be32(src, at + 4);
                if (code < sc) return null;
                if (code <= ec) {
                    const g = core.be32(src, at + 8) + (code - sc);
                    return if (g == 0 or g > 0xFFFF) null else @intCast(g);
                }
            }
            return null;
        }
        return null;
    }
    return null;
}

/// 단순 트루타입 글꼴에서 코드 하나의 글리프 번호 — pdf.js 와 같은 차례로 원본 cmap 을 본다.
/// (3,1) 은 유니코드로, (3,0) 은 F0xx·코드로, (1,0) 은 코드로. 아무 표도 없으면 코드 = 번호.
fn simpleGid(src: ?[]const u8, code: u32, uni: u32) u32 {
    const b = src orelse return code;
    if (uni != 0) if (ttfCmapGid(b, 3, 1, uni)) |g| return g;
    if (ttfCmapGid(b, 3, 0, 0xF000 | (code & 0xFF))) |g| return g;
    if (ttfCmapGid(b, 3, 0, code)) |g| return g;
    if (ttfCmapGid(b, 1, 0, code)) |g| return g;
    if (ttfCmapGid(b, 0, 3, uni)) |g| return g;
    if (ttfCmapGid(b, 0, 4, uni)) |g| return g;
    if (ttfCmapGid(b, 0, 6, uni)) |g| return g;
    return code;
}

pub fn buildFontCmap(f: *core.FontMap, nglyphs: u16, dst: []u8) u32 {
    return buildFontCmapFrom(null, f, nglyphs, dst);
}

pub fn buildFontCmapFrom(src: ?[]const u8, f: *core.FontMap, nglyphs: u16, dst: []u8) u32 {
    f.pua = false;
    if (f.identity and nglyphs > 0 and nglyphs <= 6400) {
        const n = core.buildPuaCmap(dst, nglyphs);
        if (n > 0) { f.pua = true; return n; }
    }
    @memset(&core.uni2gid, 0);
    // 본 유니코드를 적어 두는 자리. 2048 개로 못박혀 있어 그 뒤 글자가
    // cmap 에서 빠졌다. u16 전 영역을 담게 넓힌다.
    var has: [65536]u16 = undefined;
    var has_n: u32 = 0;
    var i: u16 = 0;
    while (i < f.n) : (i += 1) {
        const u = f.unis.all()[i];
        const code = f.codes.all()[i];
        // 단순 트루타입은 코드가 글리프 번호가 아니다 — 원본 cmap 으로 찾는다. 예전에는 코드를
        // 번호로 써서 InDesign 부분집합(코드 '3' → 글리프 51 = 'R')이 "Vol. 37" 을 "Vol. R" 로 그렸다
        const gid: u32 = if (f.cff_map) (if (code < 256) f.cff_gid[code] else 0) else if (f.identity or f.two_byte) code else simpleGid(src, code, u);
        if (u == 0 or gid == 0) continue;
        if (core.uni2gid[u] == 0) {
            core.uni2gid[u] = @intCast(@min(gid, 65535));
            if (has_n < has.len) { has[has_n] = u; has_n += 1; }
        }
    }
    if (has_n == 0) return 0;
    var a: u32 = 1;
    while (a < has_n) : (a += 1) {
        const v = has[a];
        var b2: u32 = a;
        while (b2 > 0 and has[b2 - 1] > v) : (b2 -= 1) has[b2] = has[b2 - 1];
        has[b2] = v;
    }
    return core.buildCmap(dst, &has, has_n);
}

