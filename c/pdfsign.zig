//! 전자 서명을 붙이고 확인한다
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 2개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 14개다.
//!
//! JS 에 내보내는 함수(15개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");

// ===== 전자 서명 =====
//
// 서명 딕셔너리에는 /ByteRange 로 "어디부터 어디까지를 서명했는지" 가 적혀
// 있고, 그 사이의 구멍에 PKCS#7 뭉치(/Contents)가 들어간다. 원본 바이트가
// 있어야 다시 셈할 수 있으므로, 스트림을 풀기 전에 걷어 둔다.
//
// 뭉치를 뜯어 서명을 실제로 맞춰 보는 일은 화면 쪽이 한다 — 브라우저에
// 이미 서명 검증기(WebCrypto)가 있어 굳이 여기서 큰 수 셈을 다시 짤 까닭이
// 없다. 여기서는 자리와 바이트만 정확히 건네 준다.
const SigT = struct {
    obj: u32,
    range: [4]u32,
    der_off: u32,
    der_len: u32,
    name_off: u32,
    name_len: u32,
    date_off: u32,
    date_len: u32,
    reason_off: u32,
    reason_len: u32,
    sub_off: u32,
    sub_len: u32,
    covers: bool,
};
/// 서명. 16 이던 것을 올렸다 — 결재선이 긴 문서는 그보다 많다.
/// 전자 서명. 필요한 만큼 늘어난다(세는 상한 없음).
var sigs_at: usize = 0;
var sigs_cap: u32 = 0;
fn sigsBuf() []SigT {
    if (sigs_at == 0 or sigs_cap == 0) return &[_]SigT{};
    return @as([*]SigT, @ptrFromInt(sigs_at))[0..sigs_cap];
}
fn sigsRoom(want: u32) bool { return core.growTable(&sigs_at, &sigs_cap, want, @sizeOf(SigT), 8); }
var sig_n: u32 = 0;
const SIG_BUF = 1024 * 1024;
/// sig_buf — 쓸 때 잡는다(그 갈래 문서가 아니면 안 잡는다)
var sig_buf_at: usize = 0;
fn sig_buf() []u8 {
    if (sig_buf_at == 0) {
        sig_buf_at = core.zoneAlloc(SIG_BUF) orelse 0;
        if (sig_buf_at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(sig_buf_at))[0..SIG_BUF];
}
var sig_used: u32 = 0;

/// 글자열 하나를 주어진 곳간에 담는다. UTF-16BE 는 utf-8 로 옮긴다.
pub fn sigPutStrTo(b: []const u8, from: usize, to: usize, buf: []u8, used: *u32) [2]u32 {
    const start = used.*;
    var p = from;
    while (p < to and core.isSpace(b[p])) p += 1;
    if (p < to and b[p] == '(') {
        p += 1;
        var depth: u32 = 1;
        while (p < to and used.* + 4 < buf.len) : (p += 1) {
            if (b[p] == '\\' and p + 1 < to) {
                p += 1;
                buf[used.*] = switch (b[p]) {
                    'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p],
                };
                used.* += 1;
                continue;
            }
            if (b[p] == '(') depth += 1;
            if (b[p] == ')') { depth -= 1; if (depth == 0) break; }
            buf[used.*] = b[p];
            used.* += 1;
        }
    } else if (p < to and b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < to and b[p] != '>' and used.* + 4 < buf.len) : (p += 1) {
            const hv = core.hexVal(b[p]) orelse continue;
            if (hi) |h| { buf[used.*] = (h << 4) | hv; used.* += 1; hi = null; } else hi = hv;
        }
    }
    const n = used.* - start;
    if (n >= 2 and buf[start] == 0xFE and buf[start + 1] == 0xFF) {
        var tmp: [512]u8 = undefined;
        var w: u32 = 0;
        var i: u32 = start + 2;
        while (i + 1 < start + n and w + 4 < tmp.len) : (i += 2) {
            const cp: u32 = (@as(u32, buf[i]) << 8) | buf[i + 1];
            if (cp < 0x80) { tmp[w] = @intCast(cp); w += 1; }
            else if (cp < 0x800) {
                tmp[w] = @intCast(0xC0 | (cp >> 6));
                tmp[w + 1] = @intCast(0x80 | (cp & 63));
                w += 2;
            } else {
                tmp[w] = @intCast(0xE0 | (cp >> 12));
                tmp[w + 1] = @intCast(0x80 | ((cp >> 6) & 63));
                tmp[w + 2] = @intCast(0x80 | (cp & 63));
                w += 3;
            }
        }
        @memcpy(buf[start..][0..w], tmp[0..w]);
        used.* = start + w;
    }
    return .{ start, used.* - start };
}

fn sigPutStr(b: []const u8, from: usize, to: usize) [2]u32 {
    const start = sig_used;
    var p = from;
    while (p < to and core.isSpace(b[p])) p += 1;
    if (p < to and b[p] == '(') {
        p += 1;
        var depth: u32 = 1;
        while (p < to and sig_used + 4 < sig_buf().len) : (p += 1) {
            if (b[p] == '\\' and p + 1 < to) {
                p += 1;
                sig_buf()[sig_used] = switch (b[p]) {
                    'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p],
                };
                sig_used += 1;
                continue;
            }
            if (b[p] == '(') depth += 1;
            if (b[p] == ')') { depth -= 1; if (depth == 0) break; }
            sig_buf()[sig_used] = b[p];
            sig_used += 1;
        }
    } else if (p < to and b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < to and b[p] != '>' and sig_used + 4 < sig_buf().len) : (p += 1) {
            const hv = core.hexVal(b[p]) orelse continue;
            if (hi) |h| { sig_buf()[sig_used] = (h << 4) | hv; sig_used += 1; hi = null; } else hi = hv;
        }
    }
    // UTF-16BE 로 적힌 것은 utf-8 로 옮긴다
    const n = sig_used - start;
    if (n >= 2 and sig_buf()[start] == 0xFE and sig_buf()[start + 1] == 0xFF) {
        var tmp: [512]u8 = undefined;
        var w: u32 = 0;
        var i: u32 = start + 2;
        while (i + 1 < start + n and w + 4 < tmp.len) : (i += 2) {
            const cp: u32 = (@as(u32, sig_buf()[i]) << 8) | sig_buf()[i + 1];
            if (cp < 0x80) { tmp[w] = @intCast(cp); w += 1; }
            else if (cp < 0x800) {
                tmp[w] = @intCast(0xC0 | (cp >> 6));
                tmp[w + 1] = @intCast(0x80 | (cp & 63));
                w += 2;
            } else {
                tmp[w] = @intCast(0xE0 | (cp >> 12));
                tmp[w + 1] = @intCast(0x80 | ((cp >> 6) & 63));
                tmp[w + 2] = @intCast(0x80 | (cp & 63));
                w += 3;
            }
        }
        @memcpy(sig_buf()[start..][0..w], tmp[0..w]);
        sig_used = start + w;
    }
    return .{ start, sig_used - start };
}

pub fn collectSigs(b: []const u8) void {
    sig_n = 0;
    sig_used = 0;
    // 객체를 하나하나 열어 보기 전에 파일에 열쇠말이 있기나 한지 본다.
    //
    // /ByteRange 는 서명 딕셔너리에만 나온다. 그런데 이 고리는 문서에 든 객체를
    // 전부 돌며 딕셔너리를 뒤진다 — 객체 딕셔너리를 다 합치면 결국 파일만 하다.
    // 서명 없는 문서가 대부분인데 34MB 문서에서 19ms 를 여기서 버리고 있었다.
    // 한 번 훑어 없으면 그대로 돌아선다(4ms). 딕셔너리마다 뒤지던 자리를 모두
    // 덮는 훑기라, 여기서 못 찾으면 아래 고리도 못 찾는다.
    if (core.find(b, "/ByteRange", 0) == null) return;
    var num: u32 = 1;
    while (num < core.obj_cap and sigsRoom(sig_n + 1)) : (num += 1) {
        if (core.objRankTable()[num] == 0) continue;
        const body = core.objOff()[num];
        if (body >= b.len) continue;
        const e = core.objDictEnd(b, body);
        if (core.find(b[body..e], "/ByteRange", 0) == null) continue;
        const ca = core.find(b[body..e], "/Contents", 0) orelse continue;
        // /Contents 는 16진 문자열이어야 한다 (스트림 쪽 /Contents 와 가른다)
        var cp = body + ca + 9;
        while (cp < e and core.isSpace(b[cp])) cp += 1;
        if (cp >= e or b[cp] != '<' or (cp + 1 < e and b[cp + 1] == '<')) continue;

        const f = &sigsBuf()[sig_n];
        f.* = .{
            .obj = num, .range = .{ 0, 0, 0, 0 }, .der_off = 0, .der_len = 0,
            .name_off = 0, .name_len = 0, .date_off = 0, .date_len = 0,
            .reason_off = 0, .reason_len = 0, .sub_off = 0, .sub_len = 0, .covers = false,
        };
        // /ByteRange [a b c d]
        {
            const ra = core.find(b[body..e], "/ByteRange", 0).?;
            var rp = body + ra + 10;
            while (rp < e and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < e) : (i += 1) {
                while (rp < e and core.isSpace(b[rp])) rp += 1;
                if (rp >= e or !core.isDigit(b[rp])) break;
                f.range[i] = core.readUint(b, &rp);
            }
            if (i < 4) continue;
        }
        // 뭉치 — 16진을 날바이트로
        {
            const start = sig_used;
            var q = cp + 1;
            var hi: ?u8 = null;
            while (q < e and b[q] != '>' and sig_used + 4 < sig_buf().len) : (q += 1) {
                const hv = core.hexVal(b[q]) orelse continue;
                if (hi) |h| { sig_buf()[sig_used] = (h << 4) | hv; sig_used += 1; hi = null; } else hi = hv;
            }
            // 뒤쪽 0 채움은 덜어 낸다
            var n = sig_used - start;
            while (n > 0 and sig_buf()[start + n - 1] == 0) n -= 1;
            sig_used = start + n;
            f.der_off = start;
            f.der_len = n;
        }
        if (core.find(b[body..e], "/Name", 0)) |a| {
            const r = sigPutStr(b, body + a + 5, e);
            f.name_off = r[0];
            f.name_len = r[1];
        }
        if (core.find(b[body..e], "/M", 0)) |a| {
            if (core.keyIs(b, body + a, e, "/M")) {
                const r = sigPutStr(b, body + a + 2, e);
                f.date_off = r[0];
                f.date_len = r[1];
            }
        }
        if (core.find(b[body..e], "/Reason", 0)) |a| {
            const r = sigPutStr(b, body + a + 7, e);
            f.reason_off = r[0];
            f.reason_len = r[1];
        }
        if (core.find(b[body..e], "/SubFilter", 0)) |a| {
            var q = body + a + 10;
            while (q < e and core.isSpace(b[q])) q += 1;
            const start = sig_used;
            if (q < e and b[q] == '/') {
                q += 1;
                while (q < e and !core.isSpace(b[q]) and b[q] != '/' and b[q] != '>' and
                    sig_used + 4 < sig_buf().len) : (q += 1)
                {
                    sig_buf()[sig_used] = b[q];
                    sig_used += 1;
                }
            }
            f.sub_off = start;
            f.sub_len = sig_used - start;
        }
        // 서명이 파일 끝까지 덮는가 — 뒤에 덧붙은 고침이 있으면 아니다
        const tail = f.range[2] + f.range[3];
        f.covers = f.range[0] == 0 and tail <= b.len and b.len - tail <= 2;
        sig_n += 1;
    }
}

pub fn sigCount() u32 { return sig_n; }
pub fn sigRange(i: u32, k: u32) u32 { return if (i < sig_n and k < 4) sigsBuf()[i].range[k] else 0; }
pub fn sigTextPtr() usize {
    const p = sig_buf();
    return if (p.len == 0) core.heapBase() else @intFromPtr(p.ptr);
}
pub fn sigDerOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].der_off else 0; }
pub fn sigDerLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].der_len else 0; }
pub fn sigNameOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].name_off else 0; }
pub fn sigNameLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].name_len else 0; }
pub fn sigDateOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].date_off else 0; }
pub fn sigDateLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].date_len else 0; }
pub fn sigReasonOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].reason_off else 0; }
pub fn sigReasonLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].reason_len else 0; }
pub fn sigSubOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].sub_off else 0; }
pub fn sigSubLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].sub_len else 0; }
pub fn sigCovers(i: u32) u32 { return if (i < sig_n and sigsBuf()[i].covers) 1 else 0; }
pub fn sigObj(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].obj else 0; }
