//! PDF 함수(/FunctionType 0·2·3·4)와 셰이딩 딕셔너리를 읽는다.
//!
//! pdf.zig 가 14,000 줄을 넘어 한 파일에서 다루기 어려워졌다. 안팎으로
//! 얽힌 정도를 재서, 바깥이 거의 안 쓰는 덩이부터 떼어 낸다. 여기가 그
//! 첫 덩이다 — 바깥이 쓰는 것은 넷뿐이다(evalFnN·readShade·rgbFrom·shadeFn).
//!
//! 반대로 이쪽은 pdf.zig 의 읽기 도구를 스무 개쯤 쓴다. 그것들은 아직
//! 옮길 자리가 마땅치 않아 root. 을 붙여 부른다. 다음에 뜯을 때 함께
//! 정리한다.

const std = @import("std");
const root = @import("pdf.zig");
const pdfenc = @import("pdfenc.zig");

// ===== 계산기 함수 (/FunctionType 4) =====
//
// 포스트스크립트 토막이 통째로 들어 있다. Separation·DeviceN 색이 잉크
// 농도를 실제 색으로 옮길 때, 셰이딩이 색을 계산할 때 쓴다. 읽지 않으면
// 그 색이 통째로 틀린다.

fn psTok(d: []const u8, p: *usize, end: usize) []const u8 {
    while (p.* < end and (root.isSpace(d[p.*]) or d[p.*] == '%')) {
        if (d[p.*] == '%') {
            while (p.* < end and d[p.*] != '\n') p.* += 1;
        } else p.* += 1;
    }
    if (p.* >= end) return &[_]u8{};
    const s0 = p.*;
    if (d[p.*] == '{' or d[p.*] == '}') {
        p.* += 1;
        return d[s0..p.*];
    }
    while (p.* < end and !root.isSpace(d[p.*]) and d[p.*] != '{' and d[p.*] != '}') p.* += 1;
    return d[s0..p.*];
}

/// 짝이 되는 닫는 괄호 자리
fn psMatch(d: []const u8, from: usize, end: usize) usize {
    var depth: u32 = 1;
    var p = from;
    while (p < end) : (p += 1) {
        if (d[p] == '{') depth += 1
        else if (d[p] == '}') { depth -= 1; if (depth == 0) return p; }
    }
    return end;
}

const PS = struct {
    st: [128]f32 = undefined,
    sp: usize = 0,
    fn push(s: *PS, v: f32) void {
        if (s.sp < s.st.len) { s.st[s.sp] = v; s.sp += 1; }
    }
    fn pop(s: *PS) f32 {
        if (s.sp == 0) return 0;
        s.sp -= 1;
        return s.st[s.sp];
    }
};

fn psExec(d: []const u8, from: usize, to: usize, s: *PS, depth: u32) void {
    if (depth > 32) return;
    var p = from;
    // if·ifelse 는 앞에 놓인 { } 토막을 받는다
    var pb: [4][2]usize = undefined;
    var pn: usize = 0;
    var guard: u32 = 0;
    while (p < to and guard < 100000) {
        guard += 1;
        const t = psTok(d, &p, to);
        if (t.len == 0) break;
        if (t[0] == '{') {
            const e = psMatch(d, p, to);
            if (pn < 4) { pb[pn] = .{ p, e }; pn += 1; }
            p = e + 1;
            continue;
        }
        if (t[0] == '}') continue;
        if (t[0] == '-' or t[0] == '.' or (t[0] >= '0' and t[0] <= '9')) {
            var q: usize = 0;
            s.push(root.readFloat(t, &q));
            continue;
        }
        const eq = struct {
            fn f(a: []const u8, w: []const u8) bool {
                if (a.len != w.len) return false;
                for (a, 0..) |ch, i| if (ch != w[i]) return false;
                return true;
            }
        }.f;
        if (eq(t, "add")) { const bv = s.pop(); s.push(s.pop() + bv); }
        else if (eq(t, "sub")) { const bv = s.pop(); s.push(s.pop() - bv); }
        else if (eq(t, "mul")) { const bv = s.pop(); s.push(s.pop() * bv); }
        else if (eq(t, "div")) { const bv = s.pop(); s.push(if (bv == 0) 0 else s.pop() / bv); }
        else if (eq(t, "idiv")) {
            const bv = s.pop();
            const av = s.pop();
            s.push(if (bv == 0) 0 else @trunc(av / bv));
        }
        else if (eq(t, "mod")) {
            const bv = s.pop();
            const av = s.pop();
            s.push(if (bv == 0) 0 else av - bv * @trunc(av / bv));
        }
        else if (eq(t, "neg")) s.push(-s.pop())
        else if (eq(t, "abs")) s.push(@abs(s.pop()))
        else if (eq(t, "ceiling")) s.push(@ceil(s.pop()))
        else if (eq(t, "floor")) s.push(@floor(s.pop()))
        else if (eq(t, "round")) s.push(@round(s.pop()))
        else if (eq(t, "truncate")) s.push(@trunc(s.pop()))
        else if (eq(t, "sqrt")) s.push(@sqrt(@max(0, s.pop())))
        else if (eq(t, "sin")) s.push(@sin(s.pop() * 3.14159265 / 180))
        else if (eq(t, "cos")) s.push(@cos(s.pop() * 3.14159265 / 180))
        else if (eq(t, "atan")) {
            const den = s.pop();
            const num = s.pop();
            var ang = atan2Deg(num, den);
            if (ang < 0) ang += 360;
            s.push(ang);
        }
        else if (eq(t, "exp")) {
            const e2 = s.pop();
            const bv = s.pop();
            s.push(powf(bv, e2));
        }
        else if (eq(t, "ln")) s.push(lnf(@max(1e-20, s.pop())))
        else if (eq(t, "log")) s.push(lnf(@max(1e-20, s.pop())) / 2.302585093)
        else if (eq(t, "cvi")) s.push(@trunc(s.pop()))
        else if (eq(t, "cvr")) {}
        else if (eq(t, "dup")) { const v = s.pop(); s.push(v); s.push(v); }
        else if (eq(t, "pop")) _ = s.pop()
        else if (eq(t, "exch")) { const bv = s.pop(); const av = s.pop(); s.push(bv); s.push(av); }
        else if (eq(t, "copy")) {
            const nv: usize = @intFromFloat(@max(0, @min(32, s.pop())));
            if (nv <= s.sp) {
                var kx: usize = 0;
                while (kx < nv) : (kx += 1) s.push(s.st[s.sp - nv]);
            }
        }
        else if (eq(t, "index")) {
            const nv: usize = @intFromFloat(@max(0, @min(127, s.pop())));
            s.push(if (nv < s.sp) s.st[s.sp - 1 - nv] else 0);
        }
        else if (eq(t, "roll")) {
            const j = s.pop();
            const nv: usize = @intFromFloat(@max(0, @min(64, s.pop())));
            if (nv > 0 and nv <= s.sp) {
                var ji: i32 = @intFromFloat(j);
                const ni: i32 = @intCast(nv);
                ji = @mod(ji, ni);
                if (ji < 0) ji += ni;
                var tmp: [64]f32 = undefined;
                var kx: usize = 0;
                while (kx < nv) : (kx += 1) {
                    const from2 = (kx + nv - @as(usize, @intCast(ji))) % nv;
                    tmp[kx] = s.st[s.sp - nv + from2];
                }
                kx = 0;
                while (kx < nv) : (kx += 1) s.st[s.sp - nv + kx] = tmp[kx];
            }
        }
        else if (eq(t, "eq")) { const bv = s.pop(); s.push(if (s.pop() == bv) 1 else 0); }
        else if (eq(t, "ne")) { const bv = s.pop(); s.push(if (s.pop() != bv) 1 else 0); }
        else if (eq(t, "gt")) { const bv = s.pop(); s.push(if (s.pop() > bv) 1 else 0); }
        else if (eq(t, "ge")) { const bv = s.pop(); s.push(if (s.pop() >= bv) 1 else 0); }
        else if (eq(t, "lt")) { const bv = s.pop(); s.push(if (s.pop() < bv) 1 else 0); }
        else if (eq(t, "le")) { const bv = s.pop(); s.push(if (s.pop() <= bv) 1 else 0); }
        else if (eq(t, "and")) {
            const bv: i32 = @intFromFloat(s.pop());
            const av: i32 = @intFromFloat(s.pop());
            s.push(@floatFromInt(av & bv));
        }
        else if (eq(t, "or")) {
            const bv: i32 = @intFromFloat(s.pop());
            const av: i32 = @intFromFloat(s.pop());
            s.push(@floatFromInt(av | bv));
        }
        else if (eq(t, "xor")) {
            const bv: i32 = @intFromFloat(s.pop());
            const av: i32 = @intFromFloat(s.pop());
            s.push(@floatFromInt(av ^ bv));
        }
        else if (eq(t, "not")) {
            const av = s.pop();
            s.push(if (av == 0) 1 else if (av == 1) 0 else @floatFromInt(~@as(i32, @intFromFloat(av))));
        }
        else if (eq(t, "bitshift")) {
            const sh = s.pop();
            const av: i32 = @intFromFloat(s.pop());
            const k: i32 = @intFromFloat(sh);
            const kk: u5 = @intCast(@min(31, @abs(k)));
            s.push(@floatFromInt(if (k >= 0) av << kk else av >> kk));
        }
        else if (eq(t, "true")) s.push(1)
        else if (eq(t, "false")) s.push(0)
        else if (eq(t, "if")) {
            const cond = s.pop();
            if (pn >= 1) {
                if (cond != 0) psExec(d, pb[pn - 1][0], pb[pn - 1][1], s, depth + 1);
                pn -= 1;
            }
        }
        else if (eq(t, "ifelse")) {
            const cond = s.pop();
            if (pn >= 2) {
                const blk = if (cond != 0) pb[pn - 2] else pb[pn - 1];
                psExec(d, blk[0], blk[1], s, depth + 1);
                pn -= 2;
            }
        }
    }
}

fn atan2Deg(y: f32, x: f32) f32 {
    if (x == 0 and y == 0) return 0;
    const pi: f32 = 3.14159265;
    var r: f32 = 0;
    if (x > 0) r = atanf(y / x)
    else if (x < 0) r = atanf(y / x) + (if (y >= 0) pi else -pi)
    else r = if (y > 0) pi / 2 else -pi / 2;
    return r * 180 / pi;
}
fn atanf(v: f32) f32 {
    // 급수 몇 개면 색을 정하기에 넉넉하다
    const a = @abs(v);
    if (a > 1) return (if (v > 0) @as(f32, 1.5707963) else @as(f32, -1.5707963)) - atanf(1 / v);
    const x2 = v * v;
    return v * (1 - x2 * (0.3333333 - x2 * (0.2 - x2 * (0.1428571 - x2 * 0.1111111))));
}
fn lnf(v: f32) f32 {
    // v = m * 2^e 로 갈라 급수로 센다
    var m = v;
    var e: f32 = 0;
    while (m > 2) { m /= 2; e += 1; }
    while (m < 1) { m *= 2; e -= 1; }
    const z = (m - 1) / (m + 1);
    const z2 = z * z;
    const l = 2 * z * (1 + z2 * (0.3333333 + z2 * (0.2 + z2 * 0.1428571)));
    return l + e * 0.6931472;
}
fn powf(b: f32, e: f32) f32 {
    if (b <= 0) return 0;
    return expf(e * lnf(b));
}
fn expf(v: f32) f32 {
    if (v > 60) return 1e26;
    if (v < -60) return 0;
    var n: i32 = @intFromFloat(@round(v / 0.6931472));
    const r = v - @as(f32, @floatFromInt(n)) * 0.6931472;
    var s2: f32 = 1 + r * (1 + r * (0.5 + r * (0.1666667 + r * (0.0416667 + r * 0.0083333))));
    while (n > 0) : (n -= 1) s2 *= 2;
    while (n < 0) : (n += 1) s2 *= 0.5;
    return s2;
}

/// 함수를 t 에서 찍어 색을 낸다. 성분 수만큼 out 에 담는다.
fn evalFn(b: []const u8, fs: usize, fe: usize, t: f32, out: *[4]f32) u32 {
    return evalFnN(b, fs, fe, &[_]f32{t}, out);
}

/// 들어가는 값이 둘인 함수(셰이딩 1형)까지 받는 판.
pub fn evalFnN(b: []const u8, fs: usize, fe: usize, in: []const f32, out: *[4]f32) u32 {
    const t = in[0];
    const ft = root.intAfter(b, fs, fe, "/FunctionType") orelse return 0;
    if (ft == 2) {
        var c0: [4]f32 = .{ 0, 0, 0, 0 };
        var c1: [4]f32 = .{ 1, 1, 1, 1 };
        var n0: u32 = 1;
        var n1: u32 = 1;
        if (root.find(b[fs..fe], "/C0", 0)) |a| {
            var p = fs + a + 3;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            n0 = 0;
            while (n0 < 4 and p < fe and b[p] != ']') : (n0 += 1) {
                while (p < fe and root.isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                c0[n0] = root.readFloat(b, &p);
            }
        }
        if (root.find(b[fs..fe], "/C1", 0)) |a| {
            var p = fs + a + 3;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            n1 = 0;
            while (n1 < 4 and p < fe and b[p] != ']') : (n1 += 1) {
                while (p < fe and root.isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                c1[n1] = root.readFloat(b, &p);
            }
        }
        const n = @max(@max(n0, n1), 1);
        var i: u32 = 0;
        while (i < n and i < 4) : (i += 1) out[i] = c0[i] + t * (c1[i] - c0[i]);
        return n;
    }
    if (ft == 3) {
        // 이어붙임 — 경계로 나눠 하위 함수에 넘긴다
        var bounds: [8]f32 = undefined;
        var nb: u32 = 0;
        if (root.find(b[fs..fe], "/Bounds", 0)) |a| {
            var p = fs + a + 7;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            while (nb < 8 and p < fe) {
                while (p < fe and root.isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                bounds[nb] = root.readFloat(b, &p);
                nb += 1;
            }
        }
        var subs: [9]u32 = undefined;
        var ns: u32 = 0;
        if (root.find(b[fs..fe], "/Functions", 0)) |a| {
            var p = fs + a + 10;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            while (ns < 9 and p < fe and b[p] != ']') {
                while (p < fe and root.isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                if (!root.isDigit(b[p])) { p += 1; continue; }
                subs[ns] = root.readUint(b, &p);
                ns += 1;
                while (p < fe and root.isSpace(b[p])) p += 1;
                if (p < fe and root.isDigit(b[p])) _ = root.readUint(b, &p);
                while (p < fe and root.isSpace(b[p])) p += 1;
                if (p < fe and b[p] == 'R') p += 1;
            }
        }
        if (ns == 0) return 0;
        var k: u32 = 0;
        while (k < nb and t >= bounds[k]) k += 1;
        if (k >= ns) k = ns - 1;
        const lo: f32 = if (k == 0) 0 else bounds[k - 1];
        const hi: f32 = if (k >= nb) 1 else bounds[k];
        const tt = if (hi > lo) (t - lo) / (hi - lo) else 0;
        if (root.findObj(b, subs[k])) |sb2| {
            const se2 = root.objDictEnd(b, sb2);
            return evalFn(b, sb2, se2, tt, out);
        }
        return 0;
    }
    if (ft == 0) {
        // 표본 함수. 격자 위의 값을 스트림에 늘어놓은 것이다.
        //
        // 예전에는 이걸 읽지 않고 t 를 그대로 회색으로 봤다. 그러면 색이
        // 통째로 틀린다 — 파란 그라데이션이 회색 띠가 됐다.
        var rng: [32]f32 = undefined;
        const nr = root.readArr(b, fs, fe, "/Range", &rng);
        if (nr < 2) return 0;
        const nout = @min(nr / 2, 4);
        var size: [2]f32 = .{ 0, 0 };
        const nin = @min(root.readArr(b, fs, fe, "/Size", &size), 2);
        if (nin == 0 or size[0] < 1) return 0;
        const bps = root.intAfter(b, fs, fe, "/BitsPerSample") orelse 8;
        if (bps == 0 or bps > 32) return 0;
        var dom: [4]f32 = .{ 0, 1, 0, 1 };
        _ = root.readArr(b, fs, fe, "/Domain", &dom);
        var encp: [4]f32 = undefined;
        const ne = root.readArr(b, fs, fe, "/Encode", &encp);
        var dec: [32]f32 = undefined;
        const nd = root.readArr(b, fs, fe, "/Decode", &dec);
        const d = root.sampleData(b, fs) orelse return 0;

        // 들어온 값을 격자 자리로 옮긴다.
        //
        // 규격이 정한 기본은 사이값을 잇는 것이다(/Order 1). 예전에는 첫 축만
        // 이었고, 축이 둘이면 그것마저 껐다 — 축 넷을 그물처럼 잇는 대신 가장
        // 가까운 칸을 집었다. 그래서 Size [4 4] 짜리 셰이딩이 네 단으로
        // 뭉쳐 나왔다(pdf.js 는 매끄러운데 우리만 띠가 졌다).
        var idx: [2]u32 = .{ 0, 0 };
        var frac: [2]f32 = .{ 0, 0 };
        var lim: [2]u32 = .{ 1, 1 };
        var k: u32 = 0;
        while (k < nin) : (k += 1) {
            const sz = @max(1, size[k]);
            const e0: f32 = if (ne >= (k + 1) * 2) encp[k * 2] else 0;
            const e1: f32 = if (ne >= (k + 1) * 2) encp[k * 2 + 1] else sz - 1;
            const x = if (k < in.len) in[k] else 0;
            var e = root.lerp(x, dom[k * 2], dom[k * 2 + 1], e0, e1);
            e = @max(0, @min(sz - 1, e));
            idx[k] = @intFromFloat(e);
            frac[k] = e - @as(f32, @floatFromInt(idx[k]));
            lim[k] = @intFromFloat(sz);
        }
        const w0: u64 = lim[0];
        // 네 귀퉁이. 격자 끝에서는 제자리를 다시 집어 밖으로 안 나간다.
        const gx0: u64 = idx[0];
        const gx1: u64 = if (idx[0] + 1 < lim[0]) idx[0] + 1 else idx[0];
        const gy0: u64 = idx[1];
        const gy1: u64 = if (nin >= 2 and idx[1] + 1 < lim[1]) idx[1] + 1 else idx[1];
        const corner: [4]u64 = .{ gx0 + gy0 * w0, gx1 + gy0 * w0, gx0 + gy1 * w0, gx1 + gy1 * w0 };
        const fx = frac[0];
        const fy = if (nin >= 2) frac[1] else 0;
        const maxv: f32 = @floatFromInt((@as(u64, 1) << @intCast(bps)) - 1);
        var c: u32 = 0;
        while (c < nout) : (c += 1) {
            var v: [4]f32 = undefined;
            var q: usize = 0;
            while (q < 4) : (q += 1)
                v[q] = @floatFromInt(root.bitsAt(d, (corner[q] * nout + c) * bps, bps));
            const top = v[0] + (v[1] - v[0]) * fx;
            const bot = v[2] + (v[3] - v[2]) * fx;
            const raw = (top + (bot - top) * fy) / maxv;
            const lo: f32 = if (nd >= (c + 1) * 2) dec[c * 2] else rng[c * 2];
            const hi: f32 = if (nd >= (c + 1) * 2) dec[c * 2 + 1] else rng[c * 2 + 1];
            out[c] = lo + raw * (hi - lo);
        }
        return nout;
    }
    if (ft == 4) {
        // 계산기 — 스트림 안 포스트스크립트를 돌린다
        var rng: [32]f32 = undefined;
        const nr = root.readArr(b, fs, fe, "/Range", &rng);
        if (nr < 2) return 0;
        const nout = @min(nr / 2, 4);
        const d = root.sampleData(b, fs) orelse return 0;
        var p2: usize = 0;
        while (p2 < d.len and d[p2] != '{') p2 += 1;
        if (p2 >= d.len) return 0;
        var ps = PS{};
        for (in) |v| ps.push(v);
        psExec(d, p2 + 1, psMatch(d, p2 + 1, d.len), &ps, 0);
        var c: u32 = 0;
        while (c < nout) : (c += 1) {
            const idx = nout - 1 - c;
            const v = ps.pop();
            out[idx] = @max(rng[idx * 2], @min(rng[idx * 2 + 1], v));
        }
        return nout;
    }
    return 0;
}

pub fn rgbFrom(comps: u32, v: [4]f32, out: *[3]f32) void {
    if (comps >= 4) {
        root.cmykRgb(v[0], v[1], v[2], v[3], out);
    } else if (comps == 3) {
        out[0] = v[0];
        out[1] = v[1];
        out[2] = v[2];
    } else {
        out[0] = v[0];
        out[1] = v[0];
        out[2] = v[0];
    }
}

/// 셰이딩 딕셔너리 하나를 읽는다.
pub fn readShade(b: []const u8, ds: usize, de: usize, name: []const u8) void {
    if (!root.shades.room(root.shade_n + 1, 16)) return;
    const st2 = root.intAfter(b, ds, de, "/ShadingType") orelse return;
    if (st2 < 1 or st2 > 7) return;
    const sh = &root.shades.all()[root.shade_n];
    sh.ds = @intCast(ds);
    sh.de = @intCast(de);
    sh.fs = 0;
    sh.fe = 0;
    sh.fxn = 0;
    sh.mat = .{ 1, 0, 0, 1, 0, 0 };
    sh.dom = .{ 0, 1, 0, 1 };
    sh.ncomp = 3;
    const nl = @min(name.len, 24);
    var k: usize = 0;
    while (k < nl) : (k += 1) sh.name[k] = name[k];
    sh.name_len = @intCast(nl);
    sh.kind = @intCast(st2);
    sh.ext0 = false;
    sh.ext1 = false;
    sh.stop_n = 0;
    var i: u32 = 0;
    while (i < 6) : (i += 1) sh.coords[i] = 0;
    if (root.find(b[ds..de], "/Coords", 0)) |a| {
        var p = ds + a + 7;
        while (p < de and b[p] != '[') p += 1;
        p += 1;
        const want: u32 = if (st2 == 2) 4 else 6;
        i = 0;
        while (i < want and p < de) : (i += 1) sh.coords[i] = root.readFloat(b, &p);
    }
    if (root.find(b[ds..de], "/Extend", 0)) |a| {
        var p = ds + a + 7;
        while (p < de and b[p] != '[') p += 1;
        p += 1;
        while (p < de and root.isSpace(b[p])) p += 1;
        sh.ext0 = p + 4 <= de and root.std_mem_eq(b[p .. p + 4], "true");
        while (p < de and !root.isSpace(b[p])) p += 1;
        while (p < de and root.isSpace(b[p])) p += 1;
        sh.ext1 = p + 4 <= de and root.std_mem_eq(b[p .. p + 4], "true");
    }
    // 함수 자리를 찾아 둔다. 2·3형은 여기서 여덟 군데를 찍고,
    // 그물은 그릴 때 꼭짓점마다 찍는다.
    var fs: usize = 0;
    var fe: usize = 0;
    if (root.find(b[ds..de], "/Function", 0)) |a| {
        var p = ds + a + 9;
        while (p < de and root.isSpace(b[p])) p += 1;
        const arr = p < de and b[p] == '[';
        if (arr) p += 1;
        var got: u32 = 0;
        while (got < 4) {
            while (p < de and root.isSpace(b[p])) p += 1;
            if (p >= de or b[p] == ']') break;
            var s2: usize = 0;
            var e2: usize = 0;
            if (b[p] == '<') {
                s2 = p;
                e2 = pdfenc.dictEnd(b, p, de);
                p = e2;
            } else if (root.isDigit(b[p])) {
                const fnum = root.readUint(b, &p);
                while (p < de and root.isSpace(b[p])) p += 1;
                if (p < de and root.isDigit(b[p])) _ = root.readUint(b, &p);
                while (p < de and root.isSpace(b[p])) p += 1;
                if (p < de and b[p] == 'R') p += 1;
                if (root.findObj(b, fnum)) |fb| { s2 = fb; e2 = root.objDictEnd(b, fb); }
            } else break;
            if (e2 > s2) {
                sh.fx[got] = .{ @intCast(s2), @intCast(e2) };
                got += 1;
                if (got == 1) { fs = s2; fe = e2; }
            }
            if (!arr) break;
        }
        sh.fxn = @intCast(got);
    }
    sh.fs = @intCast(fs);
    sh.fe = @intCast(fe);

    if (st2 != 2 and st2 != 3) {
        // 1형은 x·y 를 받는 함수 하나로 칠한다
        if (st2 == 1) {
            _ = root.readArr(b, ds, de, "/Domain", &sh.dom);
            var m: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
            if (root.readArr(b, ds, de, "/Matrix", &m) == 6) sh.mat = m;
            if (fe <= fs) return;
        } else if (fe <= fs) {
            // 함수가 없으면 색을 꼭짓점이 직접 들고 있다.
            // 성분 수는 색 공간이 정한다.
            sh.ncomp = shadeComps(b, ds, de);
        }
        sh.stop_n = 0;
        root.shade_n += 1;
        return;
    }

    if (fe <= fs) return;
    i = 0;
    while (i < 8) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 7;
        var v: [4]f32 = .{ 0, 0, 0, 0 };
        const nc = shadeFn(b, sh, t, &v);
        var rgb3: [3]f32 = .{ 0, 0, 0 };
        rgbFrom(nc, v, &rgb3);
        sh.stops[i * 4] = t;
        sh.stops[i * 4 + 1] = rgb3[0];
        sh.stops[i * 4 + 2] = rgb3[1];
        sh.stops[i * 4 + 3] = rgb3[2];
    }
    sh.stop_n = 8;
    root.shade_n += 1;
}

/// 셰이딩의 함수를 t 에서 찍는다.
///
/// 함수가 여럿 오면 성분마다 하나씩이다 — 각각 값을 하나만 낸다.
pub fn shadeFn(b: []const u8, sh: *const root.Shade, t: f32, out: *[4]f32) u32 {
    if (sh.fxn > 1) {
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < sh.fxn and i < 4) : (i += 1) {
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            if (evalFn(b, sh.fx[i][0], sh.fx[i][1], t, &v) == 0) return 0;
            out[i] = v[0];
            n += 1;
        }
        return n;
    }
    if (sh.fe <= sh.fs) return 0;
    return evalFn(b, sh.fs, sh.fe, t, out);
}

/// 색 공간의 성분 수. 그물 셰이딩이 꼭짓점 색을 몇 개씩 들고 있는지 정한다.
fn shadeComps(b: []const u8, ds: usize, de: usize) u8 {
    const a = root.find(b[ds..de], "/ColorSpace", 0) orelse return 3;
    var p = ds + a + 11;
    while (p < de and root.isSpace(b[p])) p += 1;
    var s2 = p;
    var e2 = de;
    if (p < de and root.isDigit(b[p])) {
        const n = root.readUint(b, &p);
        if (root.findObj(b, n)) |ob| { s2 = ob; e2 = root.objDictEnd(b, ob); }
    }
    const w = b[s2..@min(e2, s2 + 64)];
    if (root.findIn(w, "DeviceCMYK", 0) != null) return 4;
    if (root.findIn(w, "DeviceGray", 0) != null or root.findIn(w, "CalGray", 0) != null) return 1;
    if (root.findIn(w, "DeviceRGB", 0) != null or root.findIn(w, "CalRGB", 0) != null or
        root.findIn(w, "Lab", 0) != null) return 3;
    if (root.findIn(w, "ICCBased", 0) != null) {
        // /N 이 성분 수다
        var q = s2;
        while (q < e2 and root.isDigit(b[q]) == false and b[q] != '/') q += 1;
        if (root.intAfter(b, s2, @min(e2, s2 + 256), "/N")) |n2| return @intCast(@max(1, @min(4, n2)));
        return 3;
    }
    return 3;
}

