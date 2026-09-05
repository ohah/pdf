//! 이름 붙은 목적지·뷰어 설정·XMP
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 10개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 16개다.
//!
//! JS 에 내보내는 함수(13개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");
const pdfform = @import("pdfform.zig");

// ===== 이름 목적지 · 뷰어 설정 · XMP =====
//
// 목차와 링크가 "3쪽" 대신 이름으로 가리키는 문서가 흔하다. 이름을 물어보면
// 풀어 주는 길은 있었는데(destByName) 목록을 통째로 내어 주는 길이 없었다.
/// dest_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
pub var dest_buf: core.Table(u8) = .{};
/// 이름 목적지. 256 이던 것을 올렸다 — 책 한 권은 그보다 많다.
/// 이름 붙은 자리의 이름 위치. 필요한 만큼 늘어난다(세는 상한 없음).
pub var dest_off: core.Table(u32) = .{};
/// 그 이름의 길이. 필요한 만큼 늘어난다(세는 상한 없음).
pub var dest_len: core.Table(u8) = .{};
/// 그 자리가 가리키는 쪽. 256 개로 못박혀 있었다. 필요한 만큼 늘어난다(세는 상한 없음).
pub var dest_page: core.Table(i32) = .{};
pub var dest_n: u32 = 0;
var dest_used: u32 = 0;

pub fn destCount() u32 { return dest_n; }
pub fn destNameOff(i: u32) u32 { return if (i < dest_n) dest_off.all()[i] else 0; }
pub fn destNameLen(i: u32) u32 { return if (i < dest_n) dest_len.all()[i] else 0; }
pub fn destPageOf(i: u32) i32 { return if (i < dest_n) dest_page.all()[i] else -1; }
pub fn destTextPtr() [*]u8 { return @ptrFromInt(if (dest_buf.at == 0) core.heapBase() else dest_buf.at); }

fn addDest(name: []const u8, page: i32) void {
    if (name.len == 0 or name.len > 255) return;
    if (!dest_off.room(dest_n + 1, 256) or !dest_len.room(dest_n + 1, 256) or !dest_page.room(dest_n + 1, 256)) return;
    _ = dest_buf.room(dest_used + @as(u32, @intCast(name.len)) + 64, 32768);
    if (dest_used + name.len > dest_buf.all().len) return;
    dest_off.all()[dest_n] = dest_used;
    dest_len.all()[dest_n] = @intCast(name.len);
    dest_page.all()[dest_n] = page;
    @memcpy(dest_buf.all()[dest_used..][0..name.len], name);
    dest_used += @intCast(name.len);
    dest_n += 1;
}

/// `(이름) [3 0 R /XYZ …]` 쌍을 죽 훑어 담는다. 이름 나무의 /Names 배열과
/// 옛 /Dests 사전이 같은 모양이라 한 함수로 본다.
fn scanDestPairs(b: []const u8, from: usize, to: usize) void {
    var p = from;
    var guard: u32 = 0;
    while (p < to and guard < 65536) : (guard += 1) {
        while (p < to and b[p] != '(' and b[p] != '/') p += 1;
        if (p >= to) break;
        var key: [128]u8 = undefined;
        var kn: u32 = 0;
        if (b[p] == '(') {
            p += 1;
            while (p < to and b[p] != ')' and kn < key.len) : (p += 1) {
                if (b[p] == '\\' and p + 1 < to) p += 1;
                key[kn] = b[p];
                kn += 1;
            }
            p += 1;
        } else {
            p += 1;
            while (p < to and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '(' and
                b[p] != '[' and b[p] != '<' and kn < key.len) : (p += 1)
            {
                key[kn] = b[p];
                kn += 1;
            }
        }
        if (kn == 0) continue;
        // 나무 자체의 낱말은 목적지 이름이 아니다
        if (core.txEq(key[0..kn], "Names") or core.txEq(key[0..kn], "Kids") or core.txEq(key[0..kn], "Limits")) continue;
        var page: i32 = -1;
        while (p < to and core.isSpace(b[p])) p += 1;
        if (p < to and b[p] == '[') {
            page = destArray(b, p, to);
            p = core.arrayEnd(b, p, to);
        } else if (p < to and b[p] == '<') {
            const de = core.dictEnd(b, p, to);
            if (core.find(b[p..de], "/D", 0)) |dd| {
                var q = p + dd + 2;
                while (q < de and core.isSpace(b[q])) q += 1;
                if (q < de and b[q] == '[') page = destArray(b, q, de);
            }
            p = de;
        } else if (p < to and core.isDigit(b[p])) {
            const n = core.readUint(b, &p);
            if (core.findObj(b, n)) |ob| {
                const oe = core.objDictEnd(b, ob);
                var q = ob;
                while (q < oe and core.isSpace(b[q])) q += 1;
                if (q < oe and b[q] == '[') {
                    page = destArray(b, q, oe);
                } else if (core.find(b[ob..oe], "/D", 0)) |dd| {
                    var q2 = ob + dd + 2;
                    while (q2 < oe and core.isSpace(b[q2])) q2 += 1;
                    if (q2 < oe and b[q2] == '[') page = destArray(b, q2, oe);
                }
            }
            // "3 0 R" 의 나머지를 건너뛴다
            while (p < to and core.isSpace(b[p])) p += 1;
            if (p < to and core.isDigit(b[p])) _ = core.readUint(b, &p);
            while (p < to and core.isSpace(b[p])) p += 1;
            if (p < to and b[p] == 'R') p += 1;
        } else continue;
        addDest(key[0..kn], page);
    }
}

fn walkDestTree(b: []const u8, ob: usize, oe: usize, depth: u8) void {
    if (depth > 8) return;
    if (core.find(b[ob..oe], "/Names", 0)) |na| {
        var q = ob + na + 6;
        while (q < oe and b[q] != '[') q += 1;
        if (q < oe) scanDestPairs(b, q + 1, core.arrayEnd(b, q, oe));
    }
    if (core.find(b[ob..oe], "/Kids", 0)) |ka| {
        var q = ob + ka + 5;
        while (q < oe and b[q] != '[') q += 1;
        const end = core.arrayEnd(b, q, oe);
        q += 1;
        var guard: u32 = 0;
        while (q < end and guard < 256) : (guard += 1) {
            while (q < end and core.isSpace(b[q])) q += 1;
            if (q >= end or !core.isDigit(b[q])) break;
            const kid = core.readUint(b, &q);
            while (q < end and core.isSpace(b[q])) q += 1;
            if (q < end and core.isDigit(b[q])) _ = core.readUint(b, &q);
            while (q < end and core.isSpace(b[q])) q += 1;
            if (q < end and b[q] == 'R') q += 1;
            if (core.findObj(b, kid)) |kb| walkDestTree(b, kb, core.objDictEnd(b, kb), depth + 1);
        }
    }
}

pub fn collectDests(b: []const u8) void {
    dest_n = 0;
    dest_used = 0;
    const cat = core.catalogRange(b) orelse return;
    // 요즘 방식(/Names 이름 나무)을 **먼저** 본다. 카탈로그 안의 /Dests 는
    // 그 나무를 가리키는 것일 수도 있어(/Names << /Dests 7 0 R >>), 옛 방식으로
    // 잘못 읽으면 "Names" 같은 낱말이 목적지로 섞여 들어온다.
    if (core.keyPos(b, cat.s, cat.e, "/Names")) |na| {
        var q = na + 6;
        while (q < cat.e and core.isSpace(b[q])) q += 1;
        var ns = q;
        var ne = cat.e;
        if (q < cat.e and core.isDigit(b[q])) {
            const n = core.readUint(b, &q);
            if (core.findObj(b, n)) |ob| { ns = ob; ne = core.objDictEnd(b, ob); }
        }
        if (core.keyPos(b, ns, ne, "/Dests")) |dd| {
            var q2 = dd + 6;
            while (q2 < ne and core.isSpace(b[q2])) q2 += 1;
            if (q2 < ne and core.isDigit(b[q2])) {
                const n2 = core.readUint(b, &q2);
                if (core.findObj(b, n2)) |ob2| walkDestTree(b, ob2, core.objDictEnd(b, ob2), 0);
            } else if (q2 < ne and b[q2] == '<') {
                walkDestTree(b, q2, core.dictEnd(b, q2, ne), 0);
            }
        }
    }
    if (dest_n > 0) return;
    // 옛 방식 — /Dests 사전을 그대로 둔다
    if (core.keyPos(b, cat.s, cat.e, "/Dests")) |da| {
        var q = da + 6;
        while (q < cat.e and core.isSpace(b[q])) q += 1;
        if (q < cat.e and core.isDigit(b[q])) {
            const n = core.readUint(b, &q);
            if (core.findObj(b, n)) |ob| scanDestPairs(b, ob, core.objDictEnd(b, ob));
        } else if (q < cat.e and b[q] == '<') {
            scanDestPairs(b, q, core.dictEnd(b, q, cat.e));
        }
    }
}

// 뷰어 설정 — 도구줄을 감출지, 제목을 창에 띄울지 같은 것.
var vp_buf: [1024]u8 = undefined;
var vp_koff: [24]u32 = undefined;
var vp_klen: [24]u8 = undefined;
var vp_voff: [24]u32 = undefined;
var vp_vlen: [24]u8 = undefined;
var vp_n: u32 = 0;

pub fn viewPrefCount() u32 { return vp_n; }
pub fn viewPrefKeyOff(i: u32) u32 { return if (i < vp_n) vp_koff[i] else 0; }
pub fn viewPrefKeyLen(i: u32) u32 { return if (i < vp_n) vp_klen[i] else 0; }
pub fn viewPrefValOff(i: u32) u32 { return if (i < vp_n) vp_voff[i] else 0; }
pub fn viewPrefValLen(i: u32) u32 { return if (i < vp_n) vp_vlen[i] else 0; }
pub fn viewPrefTextPtr() [*]u8 { return &vp_buf; }

pub fn collectViewPrefs(b: []const u8) void {
    vp_n = 0;
    var used: u32 = 0;
    const cat = core.catalogRange(b) orelse return;
    const va = core.keyPos(b, cat.s, cat.e, "/ViewerPreferences") orelse return;
    var q = va + 18;
    while (q < cat.e and core.isSpace(b[q])) q += 1;
    var vs = q;
    var ve = cat.e;
    if (q < cat.e and core.isDigit(b[q])) {
        const n = core.readUint(b, &q);
        if (core.findObj(b, n)) |ob| { vs = ob; ve = core.objDictEnd(b, ob); }
    } else if (q < cat.e and b[q] == '<') {
        vs = q;
        ve = core.dictEnd(b, q, cat.e);
    } else return;

    var p = vs;
    while (p < ve and vp_n < vp_koff.len) {
        while (p < ve and b[p] != '/') p += 1;
        if (p >= ve) break;
        p += 1;
        var key: [32]u8 = undefined;
        var kn: u32 = 0;
        while (p < ve and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '>' and b[p] != '[' and kn < key.len) : (p += 1) {
            key[kn] = b[p];
            kn += 1;
        }
        if (kn == 0) continue;
        while (p < ve and core.isSpace(b[p])) p += 1;
        var val: [48]u8 = undefined;
        var vn: u32 = 0;
        if (p < ve and b[p] == '/') {
            p += 1;
            while (p < ve and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '>' and vn < val.len) : (p += 1) {
                val[vn] = b[p];
                vn += 1;
            }
        } else if (p < ve and b[p] == '[') {
            // 배열은 그대로 옮긴다 (/PrintPageRange 등)
            const ae = core.arrayEnd(b, p, ve);
            while (p <= ae and vn < val.len) : (p += 1) { val[vn] = b[p]; vn += 1; }
        } else {
            while (p < ve and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '>' and vn < val.len) : (p += 1) {
                val[vn] = b[p];
                vn += 1;
            }
        }
        if (vn == 0 or used + kn + vn > vp_buf.len) continue;
        vp_koff[vp_n] = used;
        vp_klen[vp_n] = @intCast(kn);
        @memcpy(vp_buf[used..][0..kn], key[0..kn]);
        used += kn;
        vp_voff[vp_n] = used;
        vp_vlen[vp_n] = @intCast(vn);
        @memcpy(vp_buf[used..][0..vn], val[0..vn]);
        used += vn;
        vp_n += 1;
    }
}

// XMP — 요즘 문서는 제목·지은이를 여기에도 적는다(RDF/XML 덩어리).
// 통째로 내어 주고 뜯는 것은 쓰는 쪽에 맡긴다.
var xmp_n: u32 = 0;
var xmp_at: u32 = 0;
pub fn xmpLen() u32 { return xmp_n; }
pub fn xmpPtr() [*]const u8 {
    return @as([*]const u8, @ptrFromInt(xmp_at));
}

pub fn collectXmp(b: []const u8) void {
    xmp_n = 0;
    xmp_at = 0;
    const cat = core.catalogRange(b) orelse return;
    const ma = core.keyPos(b, cat.s, cat.e, "/Metadata") orelse return;
    var q = ma + 9;
    while (q < cat.e and core.isSpace(b[q])) q += 1;
    if (q >= cat.e or !core.isDigit(b[q])) return;
    const num = core.readUint(b, &q);
    const data = pdfform.streamOf(b, num) orelse return;
    if (data.len == 0) return;
    xmp_at = @intFromPtr(data.ptr);
    xmp_n = @intCast(data.len);
}

pub fn findKeyDest(b: []const u8, from: usize, to: usize, name: []const u8) ?i32 {
    var p = from;
    var guard: u32 = 0;
    while (p < to and guard < 4096) : (guard += 1) {
        while (p < to and b[p] != '(' and b[p] != '/') p += 1;
        if (p >= to) break;
        var key: [128]u8 = undefined;
        var kn: u32 = 0;
        if (b[p] == '(') {
            p += 1;
            while (p < to and b[p] != ')' and kn < key.len) : (p += 1) {
                if (b[p] == '\\' and p + 1 < to) p += 1;
                key[kn] = b[p];
                kn += 1;
            }
            p += 1;
        } else {
            p += 1;
            while (p < to and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '(' and
                b[p] != '[' and b[p] != '<' and kn < key.len) : (p += 1)
            {
                key[kn] = b[p];
                kn += 1;
            }
        }
        if (kn == 0) continue;
        if (!core.txEq(key[0..kn], name)) continue;
        // 값이 배열이면 그 안, 딕셔너리면 /D 를 본다
        while (p < to and core.isSpace(b[p])) p += 1;
        if (p < to and b[p] == '[') return destArray(b, p, to);
        if (p < to and b[p] == '<') {
            const de = core.dictEnd(b, p, to);
            if (core.find(b[p..de], "/D", 0)) |dd| {
                var q = p + dd + 2;
                while (q < de and core.isSpace(b[q])) q += 1;
                if (q < de and b[q] == '[') return destArray(b, q, de);
            }
            return null;
        }
        if (p < to and core.isDigit(b[p])) {
            const n = core.readUint(b, &p);
            if (core.findObj(b, n)) |ob| {
                const oe = core.objDictEnd(b, ob);
                var q = ob;
                while (q < oe and core.isSpace(b[q])) q += 1;
                if (q < oe and b[q] == '[') return destArray(b, q, oe);
                if (core.find(b[ob..oe], "/D", 0)) |dd| {
                    var q2 = ob + dd + 2;
                    while (q2 < oe and core.isSpace(b[q2])) q2 += 1;
                    if (q2 < oe and b[q2] == '[') return destArray(b, q2, oe);
                }
            }
            return null;
        }
        return null;
    }
    return null;
}

/// `[3 0 R /XYZ …]` 에서 쪽 번호를 뽑는다.
pub fn destArray(b: []const u8, at: usize, to: usize) i32 {
    var p = at + 1;
    while (p < to and core.isSpace(b[p])) p += 1;
    if (p < to and core.isDigit(b[p])) return core.pageIndexOf(core.readUint(b, &p));
    return -1;
}

