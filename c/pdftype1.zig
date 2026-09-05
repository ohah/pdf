//! Type1 글꼴 — 외곽선 프로그램(charstring)을 푼다
//!
//! pdf.zig 가 14,000 줄을 넘어 한 파일에서 다루기 어려워졌다. 안팎으로 얽힌
//! 정도를 재서 바깥이 거의 안 쓰는 덩이부터 떼어 낸다. 여기서 바깥이 쓰는
//! 것은 3개다.
//!
//! 반대로 이쪽은 pdf.zig 의 도구를 18개 쓴다. 그것들은 아직 옮길 자리가
//! 마땅치 않아 root. 을 붙여 부른다.

const std = @import("std");
const root = @import("pdf.zig");
const pdfenc = @import("pdfenc.zig");

// ===== Type1 글꼴 =====
//
// FontFile 은 옛 Type1 프로그램이다. 앞은 평문 포스트스크립트, 뒤는 eexec 로
// 암호화된 부분이고 그 안에 글리프마다 다시 암호화된 charstring 이 들어 있다.
// CFF 로 바꾸는 길도 있지만(PDF.js 가 그렇게 한다), 우리는 Type3 처럼
// 외곽선을 바로 해석해 그린다 — 그리기 명령을 이미 갖고 있어 훨씬 짧다.

const T1Range = struct { off: u32, len: u32 };
pub var t1_pool: [8192]T1Range = undefined;
var t1_pool_n: u32 = 0;

/// 코드 → 글리프 이름 (지금 읽고 있는 글꼴 하나에만 쓰는 임시 자리)
var enc_off: [256]u16 = undefined;
var enc_len: [256]u8 = undefined;
var enc_buf: [8192]u8 = undefined;
var enc_buf_n: u16 = 0;

fn encSet(code: u32, name: []const u8) void {
    if (code > 255 or name.len == 0 or name.len > 63) return;
    if (@as(usize, enc_buf_n) + name.len > enc_buf.len) return;
    @memcpy(enc_buf[enc_buf_n..][0..name.len], name);
    enc_off[code] = enc_buf_n;
    enc_len[code] = @intCast(name.len);
    enc_buf_n += @intCast(name.len);
}
fn encGet(code: u32) []const u8 {
    if (code > 255 or enc_len[code] == 0) return &[_]u8{};
    return enc_buf[enc_off[code]..][0..enc_len[code]];
}

/// 표준 인코딩의 이름들. 글자·숫자는 규칙적이라 기호만 적어 둔다.
const STD_PUNCT = "space exclam quotedbl numbersign dollar percent ampersand quoteright " ++
    "parenleft parenright asterisk plus comma hyphen period slash";
const STD_PUNCT2 = "colon semicolon less equal greater question at";
const STD_PUNCT3 = "bracketleft backslash bracketright asciicircum underscore quoteleft";
const STD_PUNCT4 = "braceleft bar braceright asciitilde";
const STD_DIGIT = "zero one two three four five six seven eight nine";

fn nthWord(s: []const u8, n: u32) []const u8 {
    var i: usize = 0;
    var k: u32 = 0;
    while (i < s.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        const st = i;
        while (i < s.len and s[i] != ' ') i += 1;
        if (k == n) return s[st..i];
        k += 1;
    }
    return &[_]u8{};
}

/// 표준 인코딩을 채운다 (아스키 구간만 — 실제로 쓰이는 곳이다)
/// 표준 인코딩에서 코드 하나의 이름
fn stdName(c: u32, buf: *[1]u8) []const u8 {
    if (c >= 32 and c <= 47) return nthWord(STD_PUNCT, c - 32);
    if (c >= 48 and c <= 57) return nthWord(STD_DIGIT, c - 48);
    if (c >= 58 and c <= 64) return nthWord(STD_PUNCT2, c - 58);
    if ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)) { buf[0] = @intCast(c); return buf[0..1]; }
    if (c >= 91 and c <= 96) return nthWord(STD_PUNCT3, c - 91);
    if (c >= 123 and c <= 126) return nthWord(STD_PUNCT4, c - 123);
    return &[_]u8{};
}

fn fillStandardEncoding() void {
    var c: u32 = 32;
    while (c <= 47) : (c += 1) encSet(c, nthWord(STD_PUNCT, c - 32));
    c = 48;
    while (c <= 57) : (c += 1) encSet(c, nthWord(STD_DIGIT, c - 48));
    c = 58;
    while (c <= 64) : (c += 1) encSet(c, nthWord(STD_PUNCT2, c - 58));
    var buf: [1]u8 = undefined;
    c = 65;
    while (c <= 90) : (c += 1) { buf[0] = @intCast(c); encSet(c, buf[0..1]); }
    c = 91;
    while (c <= 96) : (c += 1) encSet(c, nthWord(STD_PUNCT3, c - 91));
    c = 97;
    while (c <= 122) : (c += 1) { buf[0] = @intCast(c); encSet(c, buf[0..1]); }
    c = 123;
    while (c <= 126) : (c += 1) encSet(c, nthWord(STD_PUNCT4, c - 123));
}

/// eexec 및 charstring 풀기. 앞의 skip 바이트는 버린다.
fn t1Decrypt(src: []const u8, dst: []u8, r0: u16, skip: usize) u32 {
    var r: u16 = r0;
    var n: u32 = 0;
    for (src, 0..) |c, i| {
        const plain: u8 = c ^ @as(u8, @truncate(r >> 8));
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
        if (i >= skip) {
            if (n >= dst.len) break;
            dst[n] = plain;
            n += 1;
        }
    }
    return n;
}

fn isHexRun(b: []const u8) bool {
    var seen: u32 = 0;
    var i: usize = 0;
    while (i < b.len and seen < 4) : (i += 1) {
        if (root.isSpace(b[i])) continue;
        if (root.hexVal(b[i]) == null) return false;
        seen += 1;
    }
    return seen == 4;
}

/// "이름 길이 RD <이진>" 을 읽는다. 이진의 시작과 길이를 준다.
fn t1Entry(d: []const u8, p: *usize) ?struct { name: []const u8, off: usize, len: usize } {
    var i = p.*;
    while (i < d.len and d[i] != '/') i += 1;
    if (i >= d.len) { p.* = d.len; return null; }
    const ns = i + 1;
    var nq = ns;
    while (nq < d.len and !root.isSpace(d[nq]) and d[nq] != '(' and d[nq] != '/') nq += 1;
    // 무엇이 되든 이름 뒤로는 넘어간다 — 안 그러면 제자리를 맴돈다
    p.* = @max(nq, ns);
    i = nq;
    while (i < d.len and root.isSpace(d[i])) i += 1;
    if (i >= d.len or !root.isDigit(d[i])) return null;
    const len = root.readUint(d, &i);
    while (i < d.len and root.isSpace(d[i])) i += 1;
    // RD 나 -| 같은 토큰 하나
    while (i < d.len and !root.isSpace(d[i])) i += 1;
    i += 1; // 공백 하나
    if (len == 0 or i + len > d.len) return null;
    p.* = i + len;
    return .{ .name = d[ns..nq], .off = i, .len = len };
}

/// Type1 프로그램을 읽어 글리프 프로그램을 풀어 둔다.
pub fn attachType1(b: []const u8, fbody: usize, fend: usize, data: []const u8) void {
    if (root.fontarea.n == 0 or root.t1Area() == 0) return;
    const f = &root.fonts.all()[root.fontarea.n - 1];
    if (data.len < 64) return;

    // 평문 구간에서 eexec 자리를 찾는다
    const ee = root.findIn(data, "eexec", 0) orelse return;
    var es = ee + 5;
    while (es < data.len and (data[es] == '\r' or data[es] == '\n' or data[es] == ' ' or data[es] == '\t')) es += 1;
    if (es >= data.len) return;

    const room = root.t1s.cap - root.t1s.used;
    if (room < 65536) return;
    const area = @as([*]u8, @ptrFromInt(root.t1Area() + root.t1s.used))[0..room];

    // 16진으로 적힌 것도 있다
    var enc_src = data[es..];
    var hexbuf_len: u32 = 0;
    if (isHexRun(enc_src)) {
        var w: u32 = 0;
        var hi: ?u8 = null;
        for (enc_src) |c| {
            const v = root.hexVal(c) orelse continue;
            if (hi) |h| {
                if (w >= area.len / 2) break;
                area[w] = (h << 4) | v;
                w += 1;
                hi = null;
            } else hi = v;
        }
        hexbuf_len = w;
        enc_src = area[0..w];
    }
    const dec_at = if (hexbuf_len > 0) hexbuf_len else 0;
    const dec = area[dec_at..];
    const dn = t1Decrypt(enc_src, dec, 55665, 4);
    if (dn < 32) return;
    const priv = dec[0..dn];

    var leniv: usize = 4;
    if (root.findIn(priv, "/lenIV", 0)) |li| {
        var q = li + 6;
        while (q < priv.len and root.isSpace(priv[q])) q += 1;
        if (q < priv.len and root.isDigit(priv[q])) leniv = root.readUint(priv, &q);
        if (leniv > 16) leniv = 4;
    }

    // 코드 → 이름: PDF 의 Differences 가 가장 세고, 없으면 프로그램의 Encoding,
    // 그것도 없으면 표준 인코딩.
    @memset(&enc_len, 0);
    enc_buf_n = 0;
    if (root.findIn(data[0..es], "StandardEncoding", 0) != null) fillStandardEncoding();
    {
        // dup <코드> /<이름> put
        var q: usize = 0;
        while (root.findIn(data[0..es], "dup ", q)) |at| {
            var r = at + 4;
            while (r < es and root.isSpace(data[r])) r += 1;
            if (r < es and root.isDigit(data[r])) {
                const code = root.readUint(data, &r);
                while (r < es and root.isSpace(data[r])) r += 1;
                if (r < es and data[r] == '/') {
                    const ns = r + 1;
                    var nq = ns;
                    while (nq < es and !root.isSpace(data[nq]) and data[nq] != '/') nq += 1;
                    encSet(code, data[ns..nq]);
                }
            }
            q = at + 4;
        }
    }
    // PDF 쪽 Differences 가 있으면 덮어쓴다
    {
        var es2 = fbody;
        var ee2 = fend;
        if (root.find(b[fbody..fend], "/Encoding", 0)) |ea| {
            var q = fbody + ea + 9;
            while (q < fend and root.isSpace(b[q])) q += 1;
            if (q < fend and b[q] == '<') { es2 = q; ee2 = pdfenc.dictEnd(b, q, fend); }
            else if (q < fend and root.isDigit(b[q])) {
                const n2 = root.readUint(b, &q);
                if (root.findObj(b, n2)) |eb| { es2 = eb; ee2 = root.find(b, "endobj", eb) orelse b.len; }
            }
        }
        if (root.find(b[es2..ee2], "/Differences", 0)) |da| {
            var q = es2 + da + 12;
            while (q < ee2 and b[q] != '[') q += 1;
            q += 1;
            var code: u32 = 0;
            while (q < ee2 and b[q] != ']') {
                while (q < ee2 and root.isSpace(b[q])) q += 1;
                if (q >= ee2 or b[q] == ']') break;
                if (root.isDigit(b[q])) { code = root.readUint(b, &q); continue; }
                if (b[q] != '/') { q += 1; continue; }
                const ns = q + 1;
                var nq = ns;
                while (nq < ee2 and !root.isSpace(b[nq]) and b[nq] != '/' and b[nq] != ']') nq += 1;
                encSet(code, b[ns..nq]);
                code += 1;
                q = nq;
            }
        }
    }

    // 글리프 프로그램을 풀 자리
    var w_at: u32 = dec_at + dn;
    if (w_at + 4096 > area.len) return;
    if (t1_pool_n + 256 + 512 > t1_pool.len) return;
    f.t1_cs = @intCast(t1_pool_n);
    var i: u32 = 0;
    while (i < 256) : (i += 1) { t1_pool[t1_pool_n + i] = .{ .off = 0, .len = 0 }; }
    t1_pool_n += 256;
    f.t1_sub = @intCast(t1_pool_n);
    f.t1_sub_n = 0;
    @memset(&f.t1_std, 0);

    const stash = struct {
        fn go(ar: []u8, wp: *u32, src: []const u8, iv: usize) T1Range {
            const cap = ar.len - wp.*;
            if (cap < src.len + 8) return .{ .off = 0, .len = 0 };
            const n = t1Decrypt(src, ar[wp.*..], 4330, iv);
            const r = T1Range{ .off = wp.*, .len = n };
            wp.* += n;
            return r;
        }
    }.go;

    // Subrs
    if (root.findIn(priv, "/Subrs", 0)) |sa| {
        var q = sa + 6;
        while (q < priv.len and root.isSpace(priv[q])) q += 1;
        const cnt = if (q < priv.len and root.isDigit(priv[q])) root.readUint(priv, &q) else 0;
        var k: u32 = 0;
        while (k < cnt and k < 512) : (k += 1) {
            const at = root.findIn(priv, "dup ", q) orelse break;
            var r = at + 4;
            while (r < priv.len and root.isSpace(priv[r])) r += 1;
            if (r >= priv.len or !root.isDigit(priv[r])) { q = at + 4; continue; }
            const idx = root.readUint(priv, &r);
            while (r < priv.len and root.isSpace(priv[r])) r += 1;
            if (r >= priv.len or !root.isDigit(priv[r])) { q = at + 4; continue; }
            const len = root.readUint(priv, &r);
            while (r < priv.len and root.isSpace(priv[r])) r += 1;
            while (r < priv.len and !root.isSpace(priv[r])) r += 1;
            r += 1;
            if (r + len > priv.len) break;
            if (idx < 512) {
                const rr = stash(area, &w_at, priv[r .. r + len], leniv);
                t1_pool[f.t1_sub + idx] = rr;
                if (idx + 1 > f.t1_sub_n) f.t1_sub_n = @intCast(idx + 1);
            }
            q = r + len;
        }
        t1_pool_n += 512;
    } else {
        t1_pool_n += 512;
    }

    // CharStrings — 코드에 이름이 맞는 것만 담는다
    var got: u32 = 0;
    if (root.findIn(priv, "/CharStrings", 0)) |ca| {
        var q = ca + 12;
        var guard: u32 = 0;
        while (q < priv.len and guard < 4096) {
            guard += 1;
            const e = t1Entry(priv, &q) orelse continue;
            if (e.len == 0 or e.len > 65535) continue;
            var c: u32 = 0;
            var used = false;
            while (c < 256) : (c += 1) {
                if (enc_len[c] == 0) continue;
                if (!root.txEq(encGet(c), e.name)) continue;
                if (!used) {
                    const rr = stash(area, &w_at, priv[e.off .. e.off + e.len], leniv);
                    if (rr.len == 0) break;
                    t1_pool[f.t1_cs + c] = rr;
                    used = true;
                    got += 1;
                } else {
                    t1_pool[f.t1_cs + c] = t1_pool[f.t1_cs + c - 1];
                }
            }
            if (used) {
                // 표준 인코딩 이름과도 맞춰 둔다 (seac 가 그 코드로 부른다)
                var sc2: u32 = 32;
                var nb: [1]u8 = undefined;
                while (sc2 < 127) : (sc2 += 1) {
                    if (!root.txEq(stdName(sc2, &nb), e.name)) continue;
                    var c3: u32 = 0;
                    while (c3 < 256) : (c3 += 1) {
                        if (enc_len[c3] == 0 or !root.txEq(encGet(c3), e.name)) continue;
                        if (t1_pool[f.t1_cs + c3].len > 0) f.t1_std[sc2] = @intCast(c3);
                        break;
                    }
                }
                // 같은 이름이 여러 코드에 걸리면 앞의 것을 나눠 쓴다
                var c2: u32 = 0;
                var first: ?T1Range = null;
                while (c2 < 256) : (c2 += 1) {
                    if (enc_len[c2] == 0 or !root.txEq(encGet(c2), e.name)) continue;
                    if (first == null) first = t1_pool[f.t1_cs + c2] else t1_pool[f.t1_cs + c2] = first.?;
                }
            }
        }
    }
    if (got == 0) return;
    root.t1s.used += (w_at + 3) & ~@as(u32, 3);
    f.t1 = true;
    f.kind |= 1024;
    if (root.find(b[fbody..fend], "/FontMatrix", 0)) |ma| {
        var q = fbody + ma + 11;
        while (q < fend and b[q] != '[') q += 1;
        q += 1;
        var k: u32 = 0;
        while (k < 6 and q < fend) : (k += 1) f.fm[k] = root.readFloat(b, &q);
    }
}

/// Type1 charstring 을 돌려 외곽선을 그리기 명령으로 낸다.
const T1State = struct {
    x: f32 = 0,
    y: f32 = 0,
    st: [48]f32 = undefined,
    sp: usize = 0,
    ps: [32]f32 = undefined,
    ps_head: usize = 0,
    ps_n: usize = 0,
    flex: bool = false,
    fx: [8]f32 = undefined,
    fy: [8]f32 = undefined,
    fn_: usize = 0,
    drew: bool = false,
    done: bool = false,
    sb: f32 = 0,
    seac: bool = false,
    asb: f32 = 0,
    adx: f32 = 0,
    ady: f32 = 0,
    bchar: u32 = 0,
    achar: u32 = 0,
};

fn t1Push(s: *T1State, v: f32) void {
    if (s.sp < s.st.len) { s.st[s.sp] = v; s.sp += 1; }
}
fn t1Pop(s: *T1State) f32 {
    if (s.sp == 0) return 0;
    s.sp -= 1;
    return s.st[s.sp];
}
fn t1PsPush(s: *T1State, v: f32) void {
    if (s.ps_n < s.ps.len) { s.ps[s.ps_n] = v; s.ps_n += 1; }
}
fn t1PsPop(s: *T1State) f32 {
    if (s.ps_head >= s.ps_n) return 0;
    const v = s.ps[s.ps_head];
    s.ps_head += 1;
    return v;
}

fn t1Slice(r: T1Range) []const u8 {
    if (r.len == 0 or root.t1Area() == 0) return &[_]u8{};
    return @as([*]const u8, @ptrFromInt(root.t1Area() + r.off))[0..r.len];
}

/// 이동 — flex 중이면 점만 모은다
fn t1Move(s: *T1State, dx: f32, dy: f32) void {
    s.x += dx;
    s.y += dy;
    if (s.flex) {
        if (s.fn_ < 8) { s.fx[s.fn_] = s.x; s.fy[s.fn_] = s.y; s.fn_ += 1; }
        return;
    }
    root.emitOp(1, &[_]f32{ s.x, s.y });
    s.drew = true;
}

fn t1Run(f: *const root.FontMap, r: T1Range, s: *T1State, dep: u32) void {
    if (dep > 10) return;
    const d = t1Slice(r);
    var i: usize = 0;
    while (i < d.len and !s.done) {
        const v = d[i];
        if (v >= 32) {
            if (v <= 246) {
                t1Push(s, @as(f32, @floatFromInt(@as(i32, v) - 139)));
                i += 1;
            } else if (v <= 250) {
                if (i + 2 > d.len) return;
                t1Push(s, @floatFromInt((@as(i32, v) - 247) * 256 + @as(i32, d[i + 1]) + 108));
                i += 2;
            } else if (v <= 254) {
                if (i + 2 > d.len) return;
                t1Push(s, @floatFromInt(-(@as(i32, v) - 251) * 256 - @as(i32, d[i + 1]) - 108));
                i += 2;
            } else {
                if (i + 5 > d.len) return;
                t1Push(s, @floatFromInt(@as(i32, @bitCast(root.be32(d, i + 1)))));
                i += 5;
            }
            continue;
        }
        i += 1;
        switch (v) {
            13 => { // hsbw: 왼쪽 여백과 폭
                if (s.sp >= 1) { s.x = s.st[0]; s.sb = s.st[0]; }
                s.y = 0;
                s.sp = 0;
            },
            9 => { root.emitOp(4, &[_]f32{}); s.sp = 0; }, // closepath
            21 => { if (s.sp >= 2) t1Move(s, s.st[s.sp - 2], s.st[s.sp - 1]); s.sp = 0; },
            22 => { if (s.sp >= 1) t1Move(s, s.st[s.sp - 1], 0); s.sp = 0; },
            4 => { if (s.sp >= 1) t1Move(s, 0, s.st[s.sp - 1]); s.sp = 0; },
            5 => {
                if (s.sp >= 2) { s.x += s.st[0]; s.y += s.st[1]; root.emitOp(2, &[_]f32{ s.x, s.y }); s.drew = true; }
                s.sp = 0;
            },
            6 => {
                if (s.sp >= 1) { s.x += s.st[0]; root.emitOp(2, &[_]f32{ s.x, s.y }); s.drew = true; }
                s.sp = 0;
            },
            7 => {
                if (s.sp >= 1) { s.y += s.st[0]; root.emitOp(2, &[_]f32{ s.x, s.y }); s.drew = true; }
                s.sp = 0;
            },
            8 => { // rrcurveto
                if (s.sp >= 6) {
                    const x1 = s.x + s.st[0];
                    const y1 = s.y + s.st[1];
                    const x2 = x1 + s.st[2];
                    const y2 = y1 + s.st[3];
                    s.x = x2 + s.st[4];
                    s.y = y2 + s.st[5];
                    root.emitOp(3, &[_]f32{ x1, y1, x2, y2, s.x, s.y });
                    s.drew = true;
                }
                s.sp = 0;
            },
            30 => { // vhcurveto
                if (s.sp >= 4) {
                    const x1 = s.x;
                    const y1 = s.y + s.st[0];
                    const x2 = x1 + s.st[1];
                    const y2 = y1 + s.st[2];
                    s.x = x2 + s.st[3];
                    s.y = y2;
                    root.emitOp(3, &[_]f32{ x1, y1, x2, y2, s.x, s.y });
                    s.drew = true;
                }
                s.sp = 0;
            },
            31 => { // hvcurveto
                if (s.sp >= 4) {
                    const x1 = s.x + s.st[0];
                    const y1 = s.y;
                    const x2 = x1 + s.st[1];
                    const y2 = y1 + s.st[2];
                    s.x = x2;
                    s.y = y2 + s.st[3];
                    root.emitOp(3, &[_]f32{ x1, y1, x2, y2, s.x, s.y });
                    s.drew = true;
                }
                s.sp = 0;
            },
            10 => { // callsubr
                const idx = t1Pop(s);
                const k: i32 = @intFromFloat(idx);
                if (k >= 0 and @as(u32, @intCast(k)) < f.t1_sub_n)
                    t1Run(f, t1_pool[f.t1_sub + @as(u32, @intCast(k))], s, dep + 1);
            },
            11 => return, // return
            14 => { s.done = true; return; }, // endchar
            1, 3 => s.sp = 0, // hstem/vstem
            12 => {
                if (i >= d.len) return;
                const v2 = d[i];
                i += 1;
                switch (v2) {
                    12 => { // div
                        const bb = t1Pop(s);
                        const aa = t1Pop(s);
                        t1Push(s, if (bb == 0) 0 else aa / bb);
                    },
                    16 => { // callothersubr
                        const othr: i32 = @intFromFloat(t1Pop(s));
                        const cnt: i32 = @intFromFloat(t1Pop(s));
                        var n: usize = if (cnt > 0) @intCast(cnt) else 0;
                        if (n > s.sp) n = s.sp;
                        s.ps_head = 0;
                        s.ps_n = 0;
                        if (othr == 1) {
                            s.flex = true;
                            s.fn_ = 0;
                            s.sp -= n;
                        } else if (othr == 0) {
                            // flex 끝 — 모은 점 여섯 개가 곡선 두 개다
                            if (s.fn_ >= 7) {
                                root.emitOp(3, &[_]f32{ s.fx[1], s.fy[1], s.fx[2], s.fy[2], s.fx[3], s.fy[3] });
                                root.emitOp(3, &[_]f32{ s.fx[4], s.fy[4], s.fx[5], s.fy[5], s.fx[6], s.fy[6] });
                                s.x = s.fx[6];
                                s.y = s.fy[6];
                                s.drew = true;
                            }
                            s.flex = false;
                            s.sp -= n;
                            t1PsPush(s, s.x);
                            t1PsPush(s, s.y);
                        } else if (othr == 3) {
                            const arg = if (n >= 1) s.st[s.sp - 1] else 3;
                            s.sp -= n;
                            t1PsPush(s, arg);
                        } else {
                            var k: usize = 0;
                            while (k < n) : (k += 1) t1PsPush(s, s.st[s.sp - n + k]);
                            s.sp -= n;
                        }
                    },
                    17 => t1Push(s, t1PsPop(s)), // pop
                    33 => { // setcurrentpoint
                        if (s.sp >= 2) { s.x = s.st[0]; s.y = s.st[1]; }
                        s.sp = 0;
                    },
                    6 => { // seac — 밑글자에 악센트를 얹는다
                        if (s.sp >= 5) {
                            s.asb = s.st[s.sp - 5];
                            s.adx = s.st[s.sp - 4];
                            s.ady = s.st[s.sp - 3];
                            s.bchar = @intFromFloat(@max(0, @min(126, s.st[s.sp - 2])));
                            s.achar = @intFromFloat(@max(0, @min(126, s.st[s.sp - 1])));
                            s.seac = true;
                        }
                        s.sp = 0;
                        s.done = true;
                        return;
                    },
                    else => s.sp = 0, // dotsection·stem3 등
                }
            },
            else => s.sp = 0,
        }
    }
}

/// 코드 하나를 외곽선으로 그린다. 그렸으면 true.
pub fn drawType1(f: *const root.FontMap, code: u32) bool {
    if (!f.t1 or code > 255) return false;
    const r = t1_pool[f.t1_cs + code];
    if (r.len == 0) return false;
    var s = T1State{};
    t1Run(f, r, &s, 0);
    if (s.seac) {
        // 밑글자와 악센트를 따로 그린다
        const bi = if (s.bchar < 128) f.t1_std[s.bchar] else 0;
        const ai = if (s.achar < 128) f.t1_std[s.achar] else 0;
        var drew = false;
        if (bi != 0 and t1_pool[f.t1_cs + bi].len > 0) {
            var sb2 = T1State{};
            t1Run(f, t1_pool[f.t1_cs + bi], &sb2, 0);
            if (sb2.drew) { root.emitOp(4, &[_]f32{}); root.emitOp(6, &[_]f32{0}); drew = true; }
        }
        if (ai != 0 and t1_pool[f.t1_cs + ai].len > 0) {
            root.emitOp(14, &[_]f32{});
            root.emitOp(16, &[_]f32{ 1, 0, 0, 1, s.sb - s.asb + s.adx, s.ady });
            var sa2 = T1State{};
            t1Run(f, t1_pool[f.t1_cs + ai], &sa2, 0);
            if (sa2.drew) { root.emitOp(4, &[_]f32{}); root.emitOp(6, &[_]f32{0}); drew = true; }
            root.emitOp(15, &[_]f32{});
        }
        return drew;
    }
    if (!s.drew) return false;
    root.emitOp(4, &[_]f32{}); // closepath
    root.emitOp(6, &[_]f32{0}); // 채우기 (비영 감김)
    return true;
}

