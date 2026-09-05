//! 입력 칸(AcroForm) — 읽기와 채우기
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 12개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 35개다.
//!
//! JS 에 내보내는 함수(25개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");

// ===== 입력 칸 (AcroForm) =====
//
// PDF 의 양식은 쪽의 /Annots 에 /Subtype /Widget 으로 얹혀 있다. 각 칸은
// 자리(/Rect)와 갈래(/FT)와 값(/V)을 들고 있고, 겉모습(/AP /N)은 그 값을
// 그려 둔 그림이다. 우리는 자리와 값을 꺼내 화면에 진짜 입력 칸을 얹고,
// 만들 때 값과 겉모습을 다시 써 넣는다.
/// 문서의 입력 칸. 세는 상한은 없다.
var field_at: usize = 0;
var field_cap: u32 = 0;
const FieldT = struct {
    obj: u32,
    rect: [4]f32,
    /// 0 글상자 · 1 확인란 · 2 라디오 · 3 목록 · 4 누름단추
    kind: u8,
    flags: u32,
    maxlen: u32,
    size: f32,
    align_: u8,
    name_off: u32,
    name_len: u32,
    val_off: u32,
    val_len: u32,
    on_off: u32,
    on_len: u32,
    opts_off: u32,
    opts_len: u32,
    checked: bool,
    /// 칸에 붙은 자바스크립트(/AA). 계산식(/C)과 서식(/F).
    /// 값이 바뀔 때 다른 칸을 다시 셈하는 양식이 흔하다 — 합계·부가세 따위다.
    calc_off: u32,
    calc_len: u32,
    fmt_off: u32,
    fmt_len: u32,
};
fn fields() []FieldT {
    if (field_at == 0 or field_cap == 0) return &[_]FieldT{};
    return @as([*]FieldT, @ptrFromInt(field_at))[0..field_cap];
}
pub var field_n: u32 = 0;
/// fld_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var fld_buf_at: usize = 0;
var fld_buf_cap: u32 = 0;
pub fn fld_buf() []u8 {
    if (fld_buf_at == 0 or fld_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(fld_buf_at))[0..fld_buf_cap];
}
fn fld_bufRoom(want: u32) bool {
    return core.growTable(&fld_buf_at, &fld_buf_cap, want, 1, 65536);
}
pub var fld_used: u32 = 0;

pub fn fieldCount() u32 { return field_n; }
pub fn fieldObj(i: u32) u32 { return if (i < field_n) fields()[i].obj else 0; }
pub fn fieldRect(i: u32, k: u32) f32 { return if (i < field_n and k < 4) fields()[i].rect[k] else 0; }
pub fn fieldKind(i: u32) u32 { return if (i < field_n) fields()[i].kind else 0; }
pub fn fieldFlags(i: u32) u32 { return if (i < field_n) fields()[i].flags else 0; }
pub fn fieldMaxLen(i: u32) u32 { return if (i < field_n) fields()[i].maxlen else 0; }
pub fn fieldSize(i: u32) f32 { return if (i < field_n) fields()[i].size else 0; }
pub fn fieldAlign(i: u32) u32 { return if (i < field_n) fields()[i].align_ else 0; }
pub fn fieldCalcOff(i: u32) u32 { return if (i < field_n) fields()[i].calc_off else 0; }
pub fn fieldCalcLen(i: u32) u32 { return if (i < field_n) fields()[i].calc_len else 0; }
pub fn fieldFmtOff(i: u32) u32 { return if (i < field_n) fields()[i].fmt_off else 0; }
pub fn fieldFmtLen(i: u32) u32 { return if (i < field_n) fields()[i].fmt_len else 0; }
pub fn fieldChecked(i: u32) u32 { return if (i < field_n and fields()[i].checked) 1 else 0; }
pub fn fieldTextPtr() [*]u8 { return @ptrFromInt(if (fld_buf_at == 0) core.heapBase() else fld_buf_at); }
pub fn fieldNameOff(i: u32) u32 { return if (i < field_n) fields()[i].name_off else 0; }
pub fn fieldNameLen(i: u32) u32 { return if (i < field_n) fields()[i].name_len else 0; }
pub fn fieldValOff(i: u32) u32 { return if (i < field_n) fields()[i].val_off else 0; }
pub fn fieldValLen(i: u32) u32 { return if (i < field_n) fields()[i].val_len else 0; }
pub fn fieldOnOff(i: u32) u32 { return if (i < field_n) fields()[i].on_off else 0; }
pub fn fieldOnLen(i: u32) u32 { return if (i < field_n) fields()[i].on_len else 0; }
pub fn fieldOptsOff(i: u32) u32 { return if (i < field_n) fields()[i].opts_off else 0; }
pub fn fieldOptsLen(i: u32) u32 { return if (i < field_n) fields()[i].opts_len else 0; }

fn fldPut(bytes: []const u8) [2]u32 {
    _ = fld_bufRoom(fld_used + @as(u32, @intCast(bytes.len)) + 64);
    const n: u32 = @intCast(@min(bytes.len, fld_buf().len - fld_used));
    if (n == 0) return .{ fld_used, 0 };
    @memcpy(fld_buf()[fld_used..][0..n], bytes[0..n]);
    const off = fld_used;
    fld_used += n;
    return .{ off, n };
}

/// PDF 문자열 하나를 utf-8 로 풀어 담는다. (…) 와 <…> 를 다 받는다.
pub fn fldPutStr(b: []const u8, s0: usize, e0: usize) [2]u32 {
    const off = fld_used;
    var p = s0;
    while (p < e0 and core.isSpace(b[p])) p += 1;
    if (p >= e0) return .{ off, 0 };
    var tmp: [16384]u8 = undefined;
    var n: usize = 0;
    if (b[p] == '(') {
        p += 1;
        var nest: u32 = 1;
        while (p < e0 and n < tmp.len) : (p += 1) {
            if (b[p] == '\\' and p + 1 < e0) {
                p += 1;
                if (b[p] >= '0' and b[p] <= '7') {
                    var v: u32 = 0;
                    var d: u32 = 0;
                    while (d < 3 and p < e0 and b[p] >= '0' and b[p] <= '7') : (d += 1) {
                        v = v * 8 + (b[p] - '0');
                        p += 1;
                    }
                    p -= 1;
                    tmp[n] = @truncate(v);
                    n += 1;
                    continue;
                }
                tmp[n] = switch (b[p]) { 'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p] };
                n += 1;
                continue;
            }
            if (b[p] == '(') nest += 1;
            if (b[p] == ')') { nest -= 1; if (nest == 0) break; }
            tmp[n] = b[p];
            n += 1;
        }
    } else if (b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < e0 and b[p] != '>' and n < tmp.len) : (p += 1) {
            const hv = core.hexVal(b[p]) orelse continue;
            if (hi) |h| { tmp[n] = (h << 4) | hv; n += 1; hi = null; } else hi = hv;
        }
    } else if (b[p] == '/') {
        p += 1;
        while (p < e0 and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '>' and b[p] != ']' and n < tmp.len) : (p += 1) {
            tmp[n] = b[p];
            n += 1;
        }
        return fldPut(tmp[0..n]);
    } else return .{ off, 0 };

    // UTF-16BE 면 풀어 준다
    if (n >= 2 and tmp[0] == 0xFE and tmp[1] == 0xFF) {
        var out: [4096]u8 = undefined;
        var m: usize = 0;
        var i: usize = 2;
        while (i + 1 < n and m + 4 < out.len) : (i += 2) {
            const u: u32 = (@as(u32, tmp[i]) << 8) | tmp[i + 1];
            if (u < 0x80) { out[m] = @intCast(u); m += 1; }
            else if (u < 0x800) {
                out[m] = @intCast(0xC0 | (u >> 6));
                out[m + 1] = @intCast(0x80 | (u & 63));
                m += 2;
            } else {
                out[m] = @intCast(0xE0 | (u >> 12));
                out[m + 1] = @intCast(0x80 | ((u >> 6) & 63));
                out[m + 2] = @intCast(0x80 | (u & 63));
                m += 3;
            }
        }
        return fldPut(out[0..m]);
    }
    // 라틴-1 → utf-8
    var out2: [4096]u8 = undefined;
    var kb: usize = 0;
    var ka: usize = 0;
    while (ka < n and kb + 2 < out2.len) : (ka += 1) {
        const ch = tmp[ka];
        if (ch < 0x80) { out2[kb] = ch; kb += 1; }
        else {
            out2[kb] = 0xC0 | (ch >> 6);
            out2[kb + 1] = 0x80 | (ch & 63);
            kb += 2;
        }
    }
    return fldPut(out2[0..kb]);
}

/// 값을 위젯에서 못 찾으면 부모 필드까지 거슬러 올라간다.
pub fn keyAt(b: []const u8, s0: usize, e0: usize, key: []const u8) ?usize {
    // /T 는 /Type 의 앞머리다. 열쇠 뒤에 구분자가 와야 진짜다.
    var from: usize = 0;
    while (core.find(b[s0..e0], key, from)) |a| {
        const after = s0 + a + key.len;
        if (after >= e0) return null;
        const c = b[after];
        if (core.isSpace(c) or c == '/' or c == '(' or c == '<' or c == '[' or
            core.isDigit(c) or c == '-' or c == '.') return after;
        from = a + 1;
    }
    return null;
}

pub fn fieldLookup(b: []const u8, obj: u32, key: []const u8, depth: u32) ?[2]usize {
    if (depth > 8) return null;
    const ob = core.findObj(b, obj) orelse return null;
    const oe = core.objDictEnd(b, ob);
    if (keyAt(b, ob, oe, key)) |a| return .{ a, oe };
    if (core.find(b[ob..oe], "/Parent", 0)) |pa| {
        var q = ob + pa + 7;
        while (q < oe and core.isSpace(b[q])) q += 1;
        if (q < oe and core.isDigit(b[q])) return fieldLookup(b, core.readUint(b, &q), key, depth + 1);
    }
    return null;
}

/// 이 쪽의 입력 칸을 모은다.
/// 칸에 붙은 자바스크립트를 꺼낸다. sub 는 "/C"(계산) 또는 "/F"(서식).
///
/// /AA << /C << /S /JavaScript /JS (…) >> >> 꼴이고, 어디든 참조로 빠져
/// 있을 수 있다. /JS 는 문자열일 때도, 스트림일 때도 있다.
fn fieldScript(b: []const u8, num: u32, sub: []const u8) [2]u32 {
    const r = fieldLookup(b, num, "/AA", 0) orelse return .{ 0, 0 };
    var s0 = r[0];
    while (s0 < r[1] and core.isSpace(b[s0])) s0 += 1;
    var ds = s0;
    var de = r[1];
    if (s0 < r[1] and core.isDigit(b[s0])) {
        var q = s0;
        const n = core.readUint(b, &q);
        if (core.findObj(b, n)) |ob| { ds = ob; de = core.objDictEnd(b, ob); }
    } else if (s0 < r[1] and b[s0] == '<') {
        de = core.dictEnd(b, s0, r[1]);
    }
    const ka = keyAt(b, ds, de, sub) orelse return .{ 0, 0 };
    var q2 = ka;
    while (q2 < de and core.isSpace(b[q2])) q2 += 1;
    var js_s = q2;
    var js_e = de;
    if (q2 < de and core.isDigit(b[q2])) {
        var q3 = q2;
        const n2 = core.readUint(b, &q3);
        if (core.findObj(b, n2)) |ob2| { js_s = ob2; js_e = core.objDictEnd(b, ob2); }
    } else if (q2 < de and b[q2] == '<') {
        js_e = core.dictEnd(b, q2, de);
    }
    const ja = keyAt(b, js_s, js_e, "/JS") orelse return .{ 0, 0 };
    var jp = ja;
    while (jp < js_e and core.isSpace(b[jp])) jp += 1;
    if (jp >= js_e) return .{ 0, 0 };
    if (b[jp] == '(' or b[jp] == '<') return fldPutStr(b, jp, js_e);
    if (core.isDigit(b[jp])) {
        var q4 = jp;
        const n3 = core.readUint(b, &q4);
        if (streamOf(b, n3)) |st| return fldPut(st);
    }
    return .{ 0, 0 };
}

/// 셈하는 차례 (/AcroForm /CO). 값을 하나 고치면 이 차례로 다시 셈한다.
var calc_at: usize = 0;
var calc_cap: u32 = 0;
var calc_n: u32 = 0;
fn calcBuf() []u32 {
    if (calc_at == 0 or calc_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(calc_at))[0..calc_cap];
}
pub fn calcOrderCount() u32 { return calc_n; }
pub fn calcOrderObj(i: u32) u32 { return if (i < calc_n) calcBuf()[i] else 0; }

pub fn collectCalcOrder(b: []const u8) void {
    calc_n = 0;
    const cat = core.catalogRange(b) orelse return;
    const fa = core.keyPos(b, cat.s, cat.e, "/AcroForm") orelse return;
    var p = fa + 9;
    while (p < cat.e and core.isSpace(b[p])) p += 1;
    var ds = p;
    var de = cat.e;
    if (p < cat.e and core.isDigit(b[p])) {
        var q = p;
        const n = core.readUint(b, &q);
        if (core.findObj(b, n)) |ob| { ds = ob; de = core.objDictEnd(b, ob); } else return;
    } else if (p < cat.e and b[p] == '<') {
        de = core.dictEnd(b, p, cat.e);
    }
    const co = keyAt(b, ds, de, "/CO") orelse return;
    var q2 = co;
    while (q2 < de and core.isSpace(b[q2])) q2 += 1;
    if (q2 >= de or b[q2] != '[') return;
    const end = core.arrayEnd(b, q2, de);
    q2 += 1;
    while (q2 < end) {
        while (q2 < end and core.isSpace(b[q2])) q2 += 1;
        if (q2 >= end or b[q2] == ']') break;
        if (!core.isDigit(b[q2])) { q2 += 1; continue; }
        const num = core.readUint(b, &q2);
        while (q2 < end and core.isSpace(b[q2])) q2 += 1;
        if (q2 < end and core.isDigit(b[q2])) _ = core.readUint(b, &q2);
        while (q2 < end and core.isSpace(b[q2])) q2 += 1;
        if (q2 < end and b[q2] == 'R') q2 += 1;
        if (!core.growTable(&calc_at, &calc_cap, calc_n + 1, 4, 16)) break;
        calcBuf()[calc_n] = num;
        calc_n += 1;
    }
}

pub fn collectFields(b: []const u8, body: usize, end: usize) void {
    const aa = core.find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and core.isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') {
        as2 = p + 1;
        ae = core.arrayEnd(b, p, end);
    } else if (p < end and core.isDigit(b[p])) {
        const an = core.readUint(b, &p);
        if (core.findObj(b, an)) |ab| {
            const abe = core.find(b, "endobj", ab) orelse b.len;
            var q2 = ab;
            while (q2 < abe and b[q2] != '[') q2 += 1;
            as2 = q2 + 1;
            ae = core.arrayEnd(b, q2, abe);
        } else return;
    } else return;

    var q = as2;
    var count: u32 = 0;
    // /Annots 를 훑는 횟수. 1024 이던 것을 올렸다 — 링크·주석이 앞에 많이
    // 붙은 쪽에서는 뒤에 있는 입력 칸까지 차례가 안 갔다(링크 300 + 주석
    // 400 이 앞서면 칸은 324 개까지만 걷혔다).
    while (q < ae and count < 1 << 20) {
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!core.isDigit(b[q])) { q += 1; continue; }
        const num = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and core.isDigit(b[q])) _ = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;
        count += 1;

        const ab = core.findObj(b, num) orelse continue;
        const abe = core.objDictEnd(b, ab);
        if (core.find(b[ab..abe], "/Widget", 0) == null) continue;
        if (core.intAfter(b, ab, abe, "/F")) |fl| {
            if ((fl & 2) != 0) continue; // 숨김
        }
        if (!core.growTable(&field_at, &field_cap, field_n, @sizeOf(FieldT), 64)) break;
        const f = &fields()[field_n];
        f.* = .{
            .obj = num, .rect = .{ 0, 0, 0, 0 }, .kind = 0, .flags = 0, .maxlen = 0,
            .size = 0, .align_ = 0, .name_off = 0, .name_len = 0, .val_off = 0,
            .val_len = 0, .on_off = 0, .on_len = 0, .opts_off = 0, .opts_len = 0,
            .checked = false, .calc_off = 0, .calc_len = 0, .fmt_off = 0, .fmt_len = 0,
        };
        if (core.find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) f.rect[i] = core.readFloat(b, &rp);
        } else continue;
        if (f.rect[2] < f.rect[0]) { const t = f.rect[0]; f.rect[0] = f.rect[2]; f.rect[2] = t; }
        if (f.rect[3] < f.rect[1]) { const t = f.rect[1]; f.rect[1] = f.rect[3]; f.rect[3] = t; }
        if (f.rect[2] - f.rect[0] < 1 or f.rect[3] - f.rect[1] < 1) continue;

        // 갈래
        var ft: u8 = 255;
        if (fieldLookup(b, num, "/FT", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and core.isSpace(b[vp])) vp += 1;
            if (vp + 3 <= r[1] and b[vp] == '/') {
                const nm = b[vp + 1 .. @min(r[1], vp + 3)];
                if (nm[0] == 'T' and nm[1] == 'x') ft = 0
                else if (nm[0] == 'B' and nm[1] == 't') ft = 1
                else if (nm[0] == 'C' and nm[1] == 'h') ft = 3
                else if (nm[0] == 'S' and nm[1] == 'i') ft = 4; // 서명 — 못 채운다
            }
        }
        if (ft == 255) continue;
        if (fieldLookup(b, num, "/Ff", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and core.isSpace(b[vp])) vp += 1;
            if (vp < r[1] and (core.isDigit(b[vp]) or b[vp] == '-')) f.flags = @intFromFloat(@max(0, core.readFloat(b, &vp)));
        }
        if (ft == 1) {
            // 라디오(1<<15) · 누름단추(1<<16)
            if ((f.flags & (1 << 16)) != 0) continue; // 누름단추는 채울 것이 없다
            f.kind = if ((f.flags & (1 << 15)) != 0) 2 else 1;
        } else f.kind = ft;

        if (fieldLookup(b, num, "/MaxLen", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and core.isSpace(b[vp])) vp += 1;
            if (vp < r[1] and core.isDigit(b[vp])) f.maxlen = core.readUint(b, &vp);
        }
        if (fieldLookup(b, num, "/Q", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and core.isSpace(b[vp])) vp += 1;
            if (vp < r[1] and core.isDigit(b[vp])) f.align_ = @intCast(@min(2, core.readUint(b, &vp)));
        }
        // 값이 바뀔 때 도는 계산식과 서식
        {
            const c = fieldScript(b, num, "/C");
            f.calc_off = c[0];
            f.calc_len = c[1];
            const g2 = fieldScript(b, num, "/F");
            f.fmt_off = g2[0];
            f.fmt_len = g2[1];
        }
        // /DA 에서 글자 크기 — "/Helv 9 Tf 0 g"
        if (fieldLookup(b, num, "/DA", 0)) |r| {
            const da = fldPutStr(b, r[0], r[1]);
            const txt = fld_buf()[da[0]..][0..da[1]];
            if (core.findIn(txt, " Tf", 0)) |ti| {
                var j: usize = ti;
                while (j > 0 and (core.isSpace(txt[j - 1]))) j -= 1;
                var k: usize = j;
                while (k > 0 and (core.isDigit(txt[k - 1]) or txt[k - 1] == '.')) k -= 1;
                var pz: usize = 0;
                if (k < j) f.size = core.readFloat(txt[k..j], &pz);
            }
            fld_used = da[0]; // 임시로 썼던 자리를 되돌린다
        }
        // 이름
        if (fieldLookup(b, num, "/T", 0)) |r| {
            const nm = fldPutStr(b, r[0], r[1]);
            f.name_off = nm[0];
            f.name_len = nm[1];
        }
        // 값
        if (fieldLookup(b, num, "/V", 0)) |r| {
            const v = fldPutStr(b, r[0], r[1]);
            f.val_off = v[0];
            f.val_len = v[1];
        }
        if (f.kind == 1 or f.kind == 2) {
            // 켜짐 상태 이름은 /AP /N 의 열쇠 중 Off 가 아닌 것
            if (core.find(b[ab..abe], "/AP", 0)) |apa| {
                var ap = ab + apa + 3;
                while (ap < abe and core.isSpace(b[ap])) ap += 1;
                var aps = ap;
                var ape = abe;
                if (ap < abe and b[ap] == '<') ape = core.dictEnd(b, ap, abe)
                else if (ap < abe and core.isDigit(b[ap])) {
                    const apn = core.readUint(b, &ap);
                    if (core.findObj(b, apn)) |apb| { aps = apb; ape = core.objDictEnd(b, apb); }
                }
                if (core.find(b[aps..ape], "/N", 0)) |na| {
                    var np = aps + na + 2;
                    while (np < ape and core.isSpace(b[np])) np += 1;
                    if (np < ape and b[np] == '<') {
                        const nde = core.dictEnd(b, np, ape);
                        var w = np + 2;
                        while (w < nde) {
                            if (b[w] != '/') { w += 1; continue; }
                            var wq = w + 1;
                            while (wq < nde and !core.isSpace(b[wq]) and b[wq] != '/' and b[wq] != '>') wq += 1;
                            const key = b[w + 1 .. wq];
                            if (!(key.len == 3 and key[0] == 'O' and key[1] == 'f' and key[2] == 'f')) {
                                const on = fldPut(key);
                                f.on_off = on[0];
                                f.on_len = on[1];
                                break;
                            }
                            w = wq;
                            // 값 하나를 건너뛴다
                            while (w < nde and core.isSpace(b[w])) w += 1;
                            if (w < nde and core.isDigit(b[w])) {
                                _ = core.readUint(b, &w);
                                while (w < nde and core.isSpace(b[w])) w += 1;
                                if (w < nde and core.isDigit(b[w])) _ = core.readUint(b, &w);
                                while (w < nde and core.isSpace(b[w])) w += 1;
                                if (w < nde and b[w] == 'R') w += 1;
                            }
                        }
                    }
                }
            }
            // 켜져 있나 — /AS 가 Off 가 아니면 켜짐
            if (core.find(b[ab..abe], "/AS", 0)) |sa| {
                var sp2 = ab + sa + 3;
                while (sp2 < abe and core.isSpace(b[sp2])) sp2 += 1;
                if (sp2 + 1 < abe and b[sp2] == '/') {
                    const st = b[sp2 + 1 .. @min(abe, sp2 + 4)];
                    f.checked = !(st.len >= 3 and st[0] == 'O' and st[1] == 'f' and st[2] == 'f');
                }
            }
        }
        if (f.kind == 3) {
            // 목록 항목
            if (fieldLookup(b, num, "/Opt", 0)) |r| {
                var vp = r[0];
                while (vp < r[1] and core.isSpace(b[vp])) vp += 1;
                if (vp < r[1] and b[vp] == '[') {
                    const oe2 = core.arrayEnd(b, vp, r[1]);
                    f.opts_off = fld_used;
                    var w = vp + 1;
                    var cnt: u32 = 0;
                    while (w < oe2 and cnt < 200) {
                        while (w < oe2 and (core.isSpace(b[w]) or b[w] == '[')) w += 1;
                        if (w >= oe2 or b[w] == ']') break;
                        if (b[w] != '(' and b[w] != '<') { w += 1; continue; }
                        const one = fldPutStr(b, w, oe2);
                        _ = one;
                        _ = fldPut("\n");
                        cnt += 1;
                        // 문자열 끝으로 건너뛴다
                        const close: u8 = if (b[w] == '(') ')' else '>';
                        var d2: u32 = 0;
                        while (w < oe2) : (w += 1) {
                            if (b[w] == '\\') { w += 1; continue; }
                            if (b[w] == '(' or b[w] == '<') d2 += 1;
                            if (b[w] == close) { d2 -= 1; if (d2 == 0) { w += 1; break; } }
                        }
                    }
                    f.opts_len = fld_used - f.opts_off;
                }
            }
        }
        field_n += 1;
    }
}

/// 화면에 진짜 입력 칸을 얹을 때는 위젯의 겉모습을 그리지 않는다.
/// 그리면 예전 값이 입력 칸 뒤에 겹쳐 보인다.
var form_layer: bool = false;
pub fn setFormLayer(on: u32) void { form_layer = on != 0; }

pub fn drawAnnots(b: []const u8, body: usize, end: usize) void {
    const aa = core.find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and core.isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') {
        as2 = p + 1;
        ae = core.arrayEnd(b, p, end);
    } else if (p < end and core.isDigit(b[p])) {
        const an = core.readUint(b, &p);
        if (core.findObj(b, an)) |ab| {
            const abe = core.find(b, "endobj", ab) orelse b.len;
            var q = ab;
            while (q < abe and b[q] != '[') q += 1;
            as2 = q + 1;
            ae = core.arrayEnd(b, q, abe);
        } else return;
    } else return;

    var q = as2;
    var count: u32 = 0;
    while (q < ae and count < 256) {
        while (q < ae and core.isSpace(core.q_at(b, q))) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!core.isDigit(b[q])) { q += 1; continue; }
        const num = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and core.isDigit(b[q])) _ = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;
        count += 1;

        const ab = core.findObj(b, num) orelse continue;
        const abe = core.find(b, "endobj", ab) orelse b.len;
        // 링크·팝업은 그릴 것이 없다
        if (core.find(b[ab..abe], "/Link", 0) != null) continue;
        if (core.find(b[ab..abe], "/Popup", 0) != null) continue;
        if (form_layer and core.find(b[ab..abe], "/Widget", 0) != null) continue;
        // 숨김(2)·보기 금지(32) 깃발
        if (core.intAfter(b, ab, abe, "/F")) |fl| {
            if ((fl & 2) != 0 or (fl & 32) != 0) continue;
        }
        var rect: [4]f32 = .{ 0, 0, 0, 0 };
        if (core.find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) rect[i] = core.readFloat(b, &rp);
        } else continue;
        if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
        if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }

        // /AP /N — 상태별 딕셔너리면 /AS 로 고른다
        const apa = core.find(b[ab..abe], "/AP", 0) orelse continue;
        var ap = ab + apa + 3;
        while (ap < abe and core.isSpace(b[ap])) ap += 1;
        var aps = ap;
        var ape = abe;
        if (ap < abe and b[ap] == '<') {
            ape = core.dictEnd(b, ap, abe);
        } else if (ap < abe and core.isDigit(b[ap])) {
            const apn = core.readUint(b, &ap);
            if (core.findObj(b, apn)) |apb| {
                aps = apb;
                ape = core.find(b, "endobj", apb) orelse b.len;
            } else continue;
        } else continue;
        const na = core.find(b[aps..ape], "/N", 0) orelse continue;
        var np = aps + na + 2;
        while (np < ape and core.isSpace(b[np])) np += 1;
        var form_obj: u32 = 0;
        if (np < ape and core.isDigit(b[np])) {
            form_obj = core.readUint(b, &np);
        } else if (np < ape and b[np] == '<') {
            // 상태별 — /AS 가 가리키는 것을 쓴다
            const nde = core.dictEnd(b, np, ape);
            var want: []const u8 = &[_]u8{};
            if (core.find(b[ab..abe], "/AS", 0)) |sa| {
                var sp2 = ab + sa + 3;
                while (sp2 < abe and core.isSpace(b[sp2])) sp2 += 1;
                if (sp2 < abe and b[sp2] == '/') {
                    var sq = sp2 + 1;
                    while (sq < abe and !core.isSpace(b[sq]) and b[sq] != '/' and b[sq] != '>') sq += 1;
                    want = b[sp2 + 1 .. sq];
                }
            }
            var w = np;
            while (w < nde) {
                if (b[w] != '/') { w += 1; continue; }
                var wq = w + 1;
                while (wq < nde and !core.isSpace(b[wq]) and b[wq] != '/' and b[wq] != '>') wq += 1;
                var vp2 = wq;
                while (vp2 < nde and core.isSpace(b[vp2])) vp2 += 1;
                if (vp2 < nde and core.isDigit(b[vp2])) {
                    const cand = core.readUint(b, &vp2);
                    if (want.len == 0 or core.txEq(b[w + 1 .. wq], want)) { form_obj = cand; break; }
                    if (form_obj == 0) form_obj = cand;
                }
                w = wq;
            }
        }
        if (form_obj == 0) continue;
        const fb = core.findObj(b, form_obj) orelse continue;
        const fe2 = core.objDictEnd(b, fb);

        var mat: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
        if (core.find(b[fb..fe2], "/Matrix", 0)) |ma| {
            var mp = fb + ma + 7;
            while (mp < fe2 and b[mp] != '[') mp += 1;
            mp += 1;
            var i: u32 = 0;
            while (i < 6 and mp < fe2) : (i += 1) mat[i] = core.readFloat(b, &mp);
        }
        var bbox: [4]f32 = .{ 0, 0, 1, 1 };
        if (core.find(b[fb..fe2], "/BBox", 0)) |ba| {
            var bp = fb + ba + 5;
            while (bp < fe2 and b[bp] != '[') bp += 1;
            bp += 1;
            var i: u32 = 0;
            while (i < 4 and bp < fe2) : (i += 1) bbox[i] = core.readFloat(b, &bp);
        }
        // BBox 네 모서리를 Matrix 로 옮겨 감싸는 상자를 구한다
        var minx: f32 = 1e30;
        var miny: f32 = 1e30;
        var maxx: f32 = -1e30;
        var maxy: f32 = -1e30;
        const xs = [_]f32{ bbox[0], bbox[2], bbox[0], bbox[2] };
        const ys = [_]f32{ bbox[1], bbox[1], bbox[3], bbox[3] };
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const tx = mat[0] * xs[i] + mat[2] * ys[i] + mat[4];
            const ty = mat[1] * xs[i] + mat[3] * ys[i] + mat[5];
            if (tx < minx) minx = tx;
            if (tx > maxx) maxx = tx;
            if (ty < miny) miny = ty;
            if (ty > maxy) maxy = ty;
        }
        const bw = maxx - minx;
        const bh = maxy - miny;
        const sx = if (bw > 0.0001) (rect[2] - rect[0]) / bw else 1;
        const sy = if (bh > 0.0001) (rect[3] - rect[1]) / bh else 1;

        // 겉모습이 가진 리소스도 등록해 둔다
        if (core.find(b[fb..fe2], "/Resources", 0)) |ra2| {
            var rp = fb + ra2 + 10;
            while (rp < fe2 and core.isSpace(b[rp])) rp += 1;
            if (rp < fe2 and b[rp] == '<') {
                core.scanResources(b, rp, core.dictEnd(b, rp, fe2), 1);
            } else if (rp < fe2 and core.isDigit(b[rp])) {
                const rn2 = core.readUint(b, &rp);
                if (core.findObj(b, rn2)) |rb2| {
                    core.scanResources(b, rb2, core.find(b, "endobj", rb2) orelse b.len, 1);
                }
            }
        }

        core.emitOp(14, &[_]f32{});
        // 주석은 깨끗한 상태에서 그린다. 앞의 투명도·섞는 방식이 남아 있으면
        // 도장이나 양식 값이 엉뚱한 색으로 나온다.
        core.emitOp(21, &[_]f32{1});
        core.emitOp(23, &[_]f32{1});
        core.emitOp(26, &[_]f32{0});
        core.emitOp(11, &[_]f32{ 0, 0, 0 });
        core.emitOp(12, &[_]f32{ 0, 0, 0 });
        core.emitOp(13, &[_]f32{1});
        core.emitOp(24, &[_]f32{ 0, 0, 0, 0, 0, 0, 0, 0 });
        core.emitOp(16, &[_]f32{ sx, 0, 0, sy, rect[0] - minx * sx, rect[1] - miny * sy });
        core.emitOp(16, &[_]f32{ mat[0], mat[1], mat[2], mat[3], mat[4], mat[5] });
        core.emitOp(5, &[_]f32{ bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1] });
        core.emitOp(10, &[_]f32{0});
        core.emitOp(9, &[_]f32{});
        if (core.subStream(form_obj, 0)) |fs3| core.runOps(fs3, 1);
        core.emitOp(15, &[_]f32{});
    }
}

/// 타일 무늬를 지금 경로 안에 깐다.
///
/// 경로로 자른 뒤 타일 내용을 XStep·YStep 만큼 옮겨 가며 되풀이한다.
/// 무늬를 진짜로 깔지 않으면 단색으로 뭉개져 보인다.
/// 타일 무늬를 지금 경로 안에 깐다.
///
/// 예전에는 타일 내용을 XStep·YStep 만큼 옮겨 가며 최대 60×60 = 3600 번
/// 되풀이해 명령으로 냈다. 무늬 하나를 그리는 데 명령이 수만 개 나갔고,
/// 그걸 캔버스가 한 번씩 다 실행했다.
///
/// 이제는 한 번만 낸다. 화면 쪽(draw.ts)이 그 한 판을 작은 캔버스에 그려
/// createPattern 으로 되풀이한다 — 되풀이는 브라우저가 하는 일이다.
/// pdf.js 도 같은 길을 간다.
pub fn paintTile(idx: u32, depth: u32) void {
    const t = &core.tiles.all()[idx];
    const xs = if (t.xstep > 0.01) t.xstep else 1;
    const ys = if (t.ystep > 0.01) t.ystep else 1;
    const stream = core.subStream(t.obj, depth) orelse return;
    core.emitOp(14, &[_]f32{}); // save
    core.emitOp(10, &[_]f32{0}); // 지금 경로로 자른다
    core.emitOp(9, &[_]f32{}); // 경로 비우기
    // 한 판 크기와 무늬 좌표계를 알려 준다
    core.emitOp(35, &[_]f32{ xs, ys, t.mat[0], t.mat[1], t.mat[2], t.mat[3], t.mat[4], t.mat[5] });
    core.runOps(stream, depth + 1);
    core.emitOp(36, &[_]f32{});
    core.emitOp(15, &[_]f32{}); // restore
}

/// 쪽의 /Contents 를 한 덩어리로 모은다.
///
/// 배열이면 여러 스트림이 한 쪽을 이룬다 — 규격상 이어 붙인 것과 같다.
/// 우리가 워터마크를 넣은 파일이 바로 그 꼴이라, 첫 스트림만 보면 원래 내용이
/// 통째로 사라진다.
pub fn collectContents(b: []const u8, body: usize, end: usize) ?[]const u8 {
    const ca = core.find(b[body..end], "/Contents", 0) orelse return null;
    var p = body + ca + 9;
    while (p < end and core.isSpace(b[p])) p += 1;
    if (p >= end) return null;
    var dst = growBuf(&cont_at, &cont_cap, 64 * 1024, 256 * 1024, 0) orelse return null;
    var w: usize = 0;

    // 하나뿐이라도 제자리로 옮겨 둔다.
    //
    // streamOf 는 압축을 임시 자리에 푼다. 그 자리를 그대로 훑으면, 훑는
    // 도중에 Type3 글리프 그림을 꺼내는 순간 읽던 내용이 덮인다. 실제로
    // 글자가 통째로 깨졌다.
    if (b[p] != '[') {
        if (!core.isDigit(b[p])) return null;
        const n = core.readUint(b, &p);
        const cs = streamOf(b, n) orelse return null;
        dst = growBuf(&cont_at, &cont_cap, cs.len + 1, 256 * 1024, 0) orelse return null;
        @memcpy(dst[0..cs.len], cs);
        dst[cs.len] = '\n';
        return dst[0 .. cs.len + 1];
    }
    p += 1;
    while (p < end) {
        while (p < end and core.isSpace(b[p])) p += 1;
        if (p >= end or b[p] == ']') break;
        if (!core.isDigit(b[p])) { p += 1; continue; }
        const n = core.readUint(b, &p);
        while (p < end and core.isSpace(b[p])) p += 1;
        if (p < end and core.isDigit(b[p])) _ = core.readUint(b, &p);
        while (p < end and core.isSpace(b[p])) p += 1;
        if (p < end and b[p] == 'R') p += 1;
        const cs = streamOf(b, n) orelse continue;
        // 앞 스트림의 마지막 토큰과 붙지 않게 줄바꿈을 끼운다.
        // 자리가 모자라면 늘린다 — 여기서 멈추면 쪽 뒷부분이 소리 없이 잘린다.
        dst = growBuf(&cont_at, &cont_cap, w + cs.len + 1, 256 * 1024, w) orelse break;
        @memcpy(dst[w..][0..cs.len], cs);
        w += cs.len;
        dst[w] = '\n';
        w += 1;
    }
    return if (w > 0) dst[0..w] else null;
}

/// 임시 자리 두 곳. content 는 /Contents 를 모으는 자리, stream_tmp 는
/// 스트림 하나를 푸는 자리다.
///
/// 예전에는 둘 다 "펼친 객체 뒤에 남은 자리" 를 8분의 1·2분의 1 지점에서
/// 잘라 썼다. 그 자리는 파일 크기에 딸린 값이라, 작은 파일에 빽빽한 쪽이
/// 들어 있으면 모자랐다 — 그리고 모자라면 null 을 돌려 쪽이 통째로 백지가
/// 됐다. 같은 쪽(내용 1.03MB)이 1MB 파일에서는 백지, 9MB 파일에서는
/// 멀쩡했다. 이제는 필요한 만큼 zone 에서 잡고 모자라면 배로 늘린다.
var cont_at: usize = 0;
var cont_cap: usize = 0;
var tmp_at: usize = 0;
var tmp_cap: usize = 0;
pub fn layoutScratch() void {
    // zone 은 parse 마다 되감기므로 들고 있던 자리도 함께 버린다
    cont_at = 0;
    cont_cap = 0;
    tmp_at = 0;
    tmp_cap = 0;
}

/// 자리를 need 만큼 마련한다. 이미 잡아 둔 것이 크면 그대로 쓴다.
/// keep 바이트는 새 자리로 옮겨 준다 — 스트림을 이어 붙이는 중이면
/// 앞서 담은 것이 날아가면 안 된다.
fn growBuf(at: *usize, cap: *usize, need: usize, least: usize, keep: usize) ?[]u8 {
    // 구역이 되감겼으면(merge·compact 가 그런다) 들고 있던 자리는 남의 것이다
    if (at.* != 0 and at.* + cap.* > core.zoneTop()) {
        at.* = 0;
        cap.* = 0;
    }
    if (at.* != 0 and cap.* >= need) return @as([*]u8, @ptrFromInt(at.*))[0..cap.*];
    var want = if (cap.* == 0) least else cap.*;
    while (want < need) {
        const dbl = want *| 2;
        if (dbl <= want) return null; // 넘침
        want = dbl;
    }
    const got = core.zoneAlloc(want) orelse return null;
    const dst = @as([*]u8, @ptrFromInt(got))[0..want];
    if (keep > 0 and at.* != 0) {
        const src = @as([*]const u8, @ptrFromInt(at.*))[0..@min(keep, cap.*)];
        @memcpy(dst[0..src.len], src);
    }
    at.* = got;
    cap.* = want;
    return dst;
}

/// 스트림 하나를 필터 사슬대로 풀어 dst 에 담는다. 담은 길이를 준다.
///
/// 필터는 [/ASCII85Decode /FlateDecode] 처럼 여러 개가 이어 붙기도 한다.
/// 마지막에 /Predictor 가 있으면 되돌린다.
pub fn decodeChain(b: []const u8, ds: usize, de: usize, data: usize, length: usize, dst: []u8) u32 {
    if (length == 0 or data > b.len or length > b.len - data) return 0;
    // 필터 이름을 차례로 모은다
    var names: [4][]const u8 = undefined;
    var nn: usize = 0;
    if (core.find(b[ds..de], "/Filter", 0)) |fa| {
        var p = ds + fa + 7;
        while (p < de and core.isSpace(b[p])) p += 1;
        // 배열이 아니면 이름 하나로 끝이다. 계속 읽으면 뒤따르는
        // /Length 까지 필터로 잡는다.
        const is_arr = p < de and b[p] == '[';
        if (is_arr) p += 1;
        while (p < de and nn < 4) {
            while (p < de and core.isSpace(b[p])) p += 1;
            if (p >= de or b[p] != '/') break;
            const s2 = p + 1;
            var q = s2;
            while (q < de and !core.isSpace(b[q]) and b[q] != '/' and b[q] != ']' and b[q] != '>') q += 1;
            names[nn] = b[s2..q];
            nn += 1;
            p = q;
            if (!is_arr) break;
            while (p < de and core.isSpace(b[p])) p += 1;
            if (p < de and (b[p] == ']' or b[p] == '>')) break;
        }
    }
    if (nn == 0) {
        if (length > dst.len) return 0;
        @memcpy(dst[0..length], b[data..][0..length]);
        return @intCast(length);
    }

    // 사슬을 돌린다. 중간 결과는 병합용 자리를 빌린다.
    const tmp = @as([*]u8, @ptrFromInt(core.b2_off))[0..core.b2_cap];
    var cur_src: []const u8 = b[data..][0..length];
    var out_n: u32 = 0;
    var i: usize = 0;
    while (i < nn) : (i += 1) {
        const name = names[i];
        const into: []u8 = if (i % 2 == 0) dst else tmp;
        var n2: u32 = 0;
        if (core.txEq(name, "FlateDecode") or core.txEq(name, "Fl")) {
            const r = core.pw_inflate(cur_src.ptr, @intCast(cur_src.len), into.ptr, @intCast(into.len));
            if (r <= 0) return 0;
            n2 = @intCast(r);
        } else if (core.txEq(name, "ASCIIHexDecode") or core.txEq(name, "AHx")) {
            n2 = core.filt.asciiHex(cur_src, into);
        } else if (core.txEq(name, "ASCII85Decode") or core.txEq(name, "A85")) {
            n2 = core.filt.ascii85(cur_src, into);
        } else if (core.txEq(name, "RunLengthDecode") or core.txEq(name, "RL")) {
            n2 = core.filt.runLength(cur_src, into);
        } else if (core.txEq(name, "LZWDecode") or core.txEq(name, "LZW")) {
            const early = core.intAfter(b, ds, de, "/EarlyChange") orelse 1;
            n2 = core.filt.lzw(cur_src, into, early);
        } else {
            // 우리가 못 푸는 필터(DCT·JPX·JBIG2·CCITT)는 여기서 다루지 않는다
            return 0;
        }
        if (n2 == 0) return 0;
        cur_src = into[0..n2];
        out_n = n2;
    }
    // 홀수 번이면 결과가 tmp 에 있다
    if (nn % 2 == 0) {
        if (out_n > dst.len) return 0;
        @memcpy(dst[0..out_n], tmp[0..out_n]);
    }

    // 예측기
    if (core.find(b[ds..de], "/Predictor", 0)) |_| {
        const pred = core.intAfter(b, ds, de, "/Predictor") orelse 1;
        if (pred > 1) {
            const colors = core.intAfter(b, ds, de, "/Colors") orelse 1;
            const bpc2 = core.intAfter(b, ds, de, "/BitsPerComponent") orelse 8;
            const cols = core.intAfter(b, ds, de, "/Columns") orelse 1;
            out_n = core.filt.unpredict(dst[0..out_n], pred, colors, bpc2, cols);
        }
    }
    return out_n;
}

/// 객체 num 의 스트림을 풀어 임시 자리에 두고 돌려준다.
/// 두 번 부르면 앞의 것이 덮인다 — 부른 쪽이 곧바로 써야 한다.
pub fn streamOf(b: []const u8, num: u32) ?[]const u8 {
    return streamFrom(b, core.findObj(b, num) orelse return null);
}

/// 객체 몸통 자리를 알 때 쓰는 판. 번호를 모르는 자리에서도 스트림을 편다.
pub fn streamFrom(b: []const u8, body: usize) ?[]const u8 {
    const sp = core.find(b, "stream", body) orelse return null;
    // 길이를 못 읽어도 포기하지 않는다 — endstream 이 어디 있는지는 보인다
    const raw_len = core.lengthOf(b, body, sp) orelse 0;
    var data = sp + 6;
    if (data < b.len and b[data] == '\r') data += 1;
    if (data < b.len and b[data] == '\n') data += 1;
    const length = core.fixStreamLen(b, data, raw_len);
    // data 는 b 안이므로 b.len - data 는 안전하다. data + length 로 견주면
    // 넘쳐서 통과해 버린다(위 fixStreamLen 주석).
    if (length > b.len - data) return null;

    if (core.find(b[body..sp], "/Filter", 0) == null) {
        return b[data .. data + length]; // 필터가 없으면 그대로
    }
    // 푼 크기는 미리 알 수 없다. 넉넉히 잡아 풀되, 자리를 꽉 채웠으면
    // 잘렸다는 뜻이므로 배로 늘려 다시 푼다. 예전에는 남은 자리에 맞춰
    // 자르고 말았고, 그래서 큰 쪽이 반만 그려지거나 통째로 사라졌다.
    var want = @max(@as(usize, 1024 * 1024), length *| 4);
    var tries: u32 = 0;
    while (tries < 8) : (tries += 1) {
        const dst = growBuf(&tmp_at, &tmp_cap, want, 1024 * 1024, 0) orelse return null;
        const got = decodeChain(b, body, sp, data, length, dst);
        if (got == 0) return null;
        if (got < dst.len) return dst[0..got];
        // 딱 맞게 찼다 — 더 있는지 모르니 늘려서 다시 본다
        want = dst.len *| 2;
        if (want <= dst.len) return dst[0..got];
    }
    return @as([*]const u8, @ptrFromInt(tmp_at))[0..tmp_cap];
}


