// 베이스라인 JPEG 복호기.
//
// 보통 JPEG 은 브라우저에 그냥 넘긴다 — 빠르고 하드웨어가 거들기도 한다.
// 그런데 **CMYK JPEG 은 브라우저가 못 푼다.** Acrobat 으로 만든 인쇄용
// 문서에 흔한데, createImageBitmap 이 조용히 실패해 그림이 통째로 사라진다.
// 그래서 성분이 넷인 것은 여기서 직접 푼다. Node 처럼 브라우저가 없는
// 자리에서는 성분이 하나·셋인 것도 여기서 푼다.
//
// 규격은 ITU-T T.81 이다. 베이스라인(SOF0·SOF1)과 프로그레시브(SOF2)를
// 다 푼다.
//
// 프로그레시브는 한 블록을 한 번에 담지 않는다. 먼저 모든 블록의 DC 를
// 성기게 훑고, 그다음 훑기(scan)마다 AC 계수를 띠(Ss~Se)로 나눠 담거나
// 이미 담은 값의 아랫자리를 한 비트씩 채운다. 그래서 블록 하나를 만나는
// 즉시 화소로 펼 수가 없다 — 훑기를 다 모은 뒤에야 편다. 흐린 그림이
// 점점 또렷해지는 그 방식이다.
const std = @import("std");

pub const Info = struct {
    w: u32 = 0,
    h: u32 = 0,
    comps: u8 = 0,
    progressive: bool = false,
};

/// 머리말만 읽어 크기와 성분 수를 본다. 넘길지 직접 풀지 여기서 정한다.
pub fn probe(d: []const u8) Info {
    var out = Info{};
    var p: usize = 2;
    while (p + 4 <= d.len) {
        if (d[p] != 0xFF) { p += 1; continue; }
        const m = d[p + 1];
        if (m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7)) { p += 2; continue; }
        if (m == 0xD9) break;
        const len = (@as(usize, d[p + 2]) << 8) | d[p + 3];
        if (len < 2 or p + 2 + len > d.len) break;
        if (m == 0xC0 or m == 0xC1 or m == 0xC2) {
            if (p + 9 < d.len) {
                out.h = (@as(u32, d[p + 5]) << 8) | d[p + 6];
                out.w = (@as(u32, d[p + 7]) << 8) | d[p + 8];
                out.comps = d[p + 9];
                out.progressive = m == 0xC2;
            }
            return out;
        }
        p += 2 + len;
    }
    return out;
}

const Huff = struct {
    /// 길이별 첫 코드와 값 자리 (T.81 F.2.2.3)
    mincode: [17]i32 = .{0} ** 17,
    maxcode: [17]i32 = .{-1} ** 17,
    valptr: [17]u16 = .{0} ** 17,
    vals: [256]u8 = .{0} ** 256,
    n: u16 = 0,
};

fn buildHuff(h: *Huff, bits: []const u8, vals: []const u8) void {
    var code: i32 = 0;
    var k: u16 = 0;
    var l: u8 = 1;
    while (l <= 16) : (l += 1) {
        const cnt = bits[l - 1];
        h.valptr[l] = k;
        h.mincode[l] = code;
        code += cnt;
        k += cnt;
        h.maxcode[l] = if (cnt > 0) code - 1 else -1;
        code <<= 1;
    }
    h.n = k;
    var i: u16 = 0;
    while (i < k and i < vals.len and i < h.vals.len) : (i += 1) h.vals[i] = vals[i];
}

const Bits = struct {
    d: []const u8,
    p: usize,
    acc: u32 = 0,
    n: u5 = 0,
    /// 0xFF00 채움과 재시작 표식을 넘긴다
    fn bit(s: *Bits) u32 {
        if (s.n == 0) {
            if (s.p >= s.d.len) return 0;
            var v = s.d[s.p];
            s.p += 1;
            if (v == 0xFF) {
                // 0xFF00 은 자료의 0xFF, 그 밖은 표식이라 여기서 끝낸다
                if (s.p < s.d.len and s.d[s.p] == 0) s.p += 1
                else v = 0;
            }
            s.acc = v;
            s.n = 8;
        }
        s.n -= 1;
        return (s.acc >> @intCast(s.n)) & 1;
    }
    fn bits(s: *Bits, k: u5) u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < k) : (i += 1) v = (v << 1) | s.bit();
        return v;
    }
    fn reset(s: *Bits) void {
        s.n = 0;
        s.acc = 0;
    }
};

fn decodeHuff(s: *Bits, h: *const Huff) u8 {
    var code: i32 = 0;
    var l: u8 = 1;
    while (l <= 16) : (l += 1) {
        code = (code << 1) | @as(i32, @intCast(s.bit()));
        if (h.maxcode[l] >= code and code >= h.mincode[l]) {
            const idx = h.valptr[l] + @as(u16, @intCast(code - h.mincode[l]));
            if (idx < h.n) return h.vals[idx];
            return 0;
        }
    }
    return 0;
}

/// 붙은 비트를 부호 있는 값으로 편다 (T.81 F.2.2.1)
fn extend(v: u32, t: u5) i32 {
    if (t == 0) return 0;
    const half = @as(u32, 1) << (t - 1);
    if (v < half) return @as(i32, @intCast(v)) - (@as(i32, 1) << t) + 1;
    return @intCast(v);
}

const ZIGZAG = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// 8x8 역 DCT. 곧이곧대로 두 번 도는 판이라 느리지만 짧고 틀릴 데가 없다.
fn idct(blk: *[64]f32, out: *[64]u8) void {
    var tmp: [64]f32 = undefined;
    var u: u32 = 0;
    // 가로
    while (u < 8) : (u += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            var sum: f32 = 0;
            var v: u32 = 0;
            while (v < 8) : (v += 1) {
                const cv: f32 = if (v == 0) 0.70710678 else 1;
                sum += cv * blk[u * 8 + v] * COS[v][x];
            }
            tmp[u * 8 + x] = sum * 0.5;
        }
    }
    // 세로
    var x2: u32 = 0;
    while (x2 < 8) : (x2 += 1) {
        var y: u32 = 0;
        while (y < 8) : (y += 1) {
            var sum: f32 = 0;
            var uu: u32 = 0;
            while (uu < 8) : (uu += 1) {
                const cu: f32 = if (uu == 0) 0.70710678 else 1;
                sum += cu * tmp[uu * 8 + x2] * COS[uu][y];
            }
            const vv = sum * 0.5 + 128;
            out[y * 8 + x2] = @intFromFloat(@max(0, @min(255, vv)));
        }
    }
}

const COS = blk: {
    @setEvalBranchQuota(20000);
    var t: [8][8]f32 = undefined;
    var u: usize = 0;
    while (u < 8) : (u += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            t[u][x] = @cos((2.0 * @as(f32, @floatFromInt(x)) + 1.0) *
                @as(f32, @floatFromInt(u)) * std.math.pi / 16.0);
        }
    }
    break :blk t;
};

const Comp = struct {
    id: u8 = 0,
    hs: u8 = 1,
    vs: u8 = 1,
    tq: u8 = 0,
    td: u8 = 0,
    ta: u8 = 0,
    dc: i32 = 0,
    /// 성분마다 푼 화소 (부표본 그대로)
    off: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
};

/// CMYK(성분 4) JPEG 을 풀어 RGB 로 dst 에 담는다. 성공하면 화소 수.
///
/// scratch 는 성분별 중간 화소를 담을 자리다. dst 와 겹치면 안 된다.
pub fn decodeCmyk(d: []const u8, dst: []u8, scratch: []u8, invert: bool) u32 {
    return decode(d, dst, scratch, invert);
}

/// 성분이 하나(흑백)거나 셋(YCbCr·RGB)이거나 넷(CMYK·YCCK)인 JPEG 을 풀어
/// RGB 로 담는다.
///
/// 브라우저에서는 이 일을 브라우저가 해 주지만, Node 에는 해 줄 사람이
/// 없다. 그래서 우리가 푼다 — 그러지 않으면 스캔 문서가 흰 종이로 나온다.
/// 베이스라인(SOF0·SOF1)과 프로그레시브(SOF2)를 다 푼다.
pub fn decodeAny(d: []const u8, dst: []u8, scratch: []u8) u32 {
    return decode(d, dst, scratch, false);
}

fn decode(d: []const u8, dst: []u8, scratch: []u8, invert: bool) u32 {
    var qt = [_][64]u16{[_]u16{0} ** 64} ** 4;
    var hdc = [_]Huff{Huff{}} ** 4;
    var hac = [_]Huff{Huff{}} ** 4;
    var comps = [_]Comp{Comp{}} ** 4;
    var ncomp: u8 = 0;
    var w: u32 = 0;
    var h: u32 = 0;
    var ri: u32 = 0;
    var transform: u8 = 0;
    var have_transform = false;
    // 프로그레시브에 쓰는 것들
    var prog = false;
    var setup = false;
    var coef_n: usize = 0;
    var coff: [4]usize = .{ 0, 0, 0, 0 };
    var bw: [4]u32 = .{ 0, 0, 0, 0 };
    var bh: [4]u32 = .{ 0, 0, 0, 0 };
    var mcux: u32 = 0;
    var mcuy: u32 = 0;
    var hmax: u8 = 1;
    var vmax: u8 = 1;

    var p: usize = 2;
    while (p + 4 <= d.len) {
        if (d[p] != 0xFF) { p += 1; continue; }
        const m = d[p + 1];
        if (m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7)) { p += 2; continue; }
        if (m == 0xD9) break;
        const len = (@as(usize, d[p + 2]) << 8) | d[p + 3];
        if (len < 2 or p + 2 + len > d.len) return 0;
        const seg = d[p + 4 .. p + 2 + len];
        switch (m) {
            0xDB => { // 양자화표
                var q: usize = 0;
                while (q + 1 <= seg.len) {
                    const pq = seg[q] >> 4;
                    const tq = seg[q] & 15;
                    q += 1;
                    if (tq >= 4) return 0;
                    var i: usize = 0;
                    while (i < 64) : (i += 1) {
                        if (pq == 1) {
                            if (q + 1 >= seg.len) return 0;
                            qt[tq][i] = (@as(u16, seg[q]) << 8) | seg[q + 1];
                            q += 2;
                        } else {
                            if (q >= seg.len) return 0;
                            qt[tq][i] = seg[q];
                            q += 1;
                        }
                    }
                }
            },
            0xC4 => { // 허프만표
                var q: usize = 0;
                while (q + 17 <= seg.len) {
                    const tc = seg[q] >> 4;
                    const th = seg[q] & 15;
                    q += 1;
                    if (th >= 4) return 0;
                    var total: usize = 0;
                    var i: usize = 0;
                    while (i < 16) : (i += 1) total += seg[q + i];
                    if (q + 16 + total > seg.len or total > 256) return 0;
                    const bits = seg[q .. q + 16];
                    const vals = seg[q + 16 .. q + 16 + total];
                    if (tc == 0) buildHuff(&hdc[th], bits, vals) else buildHuff(&hac[th], bits, vals);
                    q += 16 + total;
                }
            },
            0xC0, 0xC1, 0xC2 => { // 머리말 (베이스라인·프로그레시브)
                if (seg.len < 6) return 0;
                prog = m == 0xC2;
                h = (@as(u32, seg[1]) << 8) | seg[2];
                w = (@as(u32, seg[3]) << 8) | seg[4];
                ncomp = seg[5];
                // 성분 하나(흑백)·셋(YCbCr)·넷(CMYK) 을 다 받는다
                if (ncomp == 0 or ncomp > 4 or ncomp == 2 or w == 0 or h == 0) return 0;
                if (seg.len < 6 + @as(usize, ncomp) * 3) return 0;
                var i: u8 = 0;
                while (i < ncomp) : (i += 1) {
                    const at = 6 + @as(usize, i) * 3;
                    comps[i].id = seg[at];
                    comps[i].hs = @max(1, seg[at + 1] >> 4);
                    comps[i].vs = @max(1, seg[at + 1] & 15);
                    comps[i].tq = seg[at + 2] & 3;
                }
            },
            0xDD => { // 재시작 간격
                if (seg.len >= 2) ri = (@as(u32, seg[0]) << 8) | seg[1];
            },
            0xEE => { // APP14 Adobe — CMYK 는 대개 뒤집혀 담긴다
                if (seg.len >= 11 and std.mem.eql(u8, seg[0..5], "Adobe")) {
                    transform = seg[seg.len - 1];
                    have_transform = true;
                }
            },
            0xDA => { // 훑기 시작
                if (seg.len < 1) return 0;
                const ns = seg[0];
                if (ns == 0 or ns > ncomp) return 0;
                var order: [4]u8 = .{ 0, 0, 0, 0 };
                var i: u8 = 0;
                while (i < ns) : (i += 1) {
                    const at = 1 + @as(usize, i) * 2;
                    if (at + 1 >= seg.len) return 0;
                    const cid = seg[at];
                    var k: u8 = 0;
                    while (k < ncomp) : (k += 1) {
                        if (comps[k].id == cid) {
                            comps[k].td = seg[at + 1] >> 4;
                            comps[k].ta = seg[at + 1] & 15;
                            order[i] = k;
                        }
                    }
                }
                if (!prog) {
                    if (ns != ncomp) return 0;
                    return scan(d, p + 2 + len, w, h, &comps, ncomp, &qt, &hdc, &hac, ri,
                        invert, transform, have_transform, dst, scratch);
                }
                // 프로그레시브 — 훑기마다 계수에 담아 두고 끝에 한 번에 편다
                const at2 = 1 + @as(usize, ns) * 2;
                if (at2 + 2 >= seg.len) return 0;
                const ss = seg[at2];
                const se = @min(@as(u8, 63), seg[at2 + 1]);
                const ah: u5 = @intCast(seg[at2 + 2] >> 4);
                const al: u5 = @intCast(seg[at2 + 2] & 15);
                if (!setup) {
                    var hmax0: u8 = 1;
                    var vmax0: u8 = 1;
                    var q: u8 = 0;
                    while (q < ncomp) : (q += 1) {
                        hmax0 = @max(hmax0, comps[q].hs);
                        vmax0 = @max(vmax0, comps[q].vs);
                    }
                    mcux = (w + @as(u32, hmax0) * 8 - 1) / (@as(u32, hmax0) * 8);
                    mcuy = (h + @as(u32, vmax0) * 8 - 1) / (@as(u32, vmax0) * 8);
                    var need: usize = 0;
                    q = 0;
                    while (q < ncomp) : (q += 1) {
                        comps[q].w = (w * comps[q].hs + hmax0 - 1) / hmax0;
                        comps[q].h = (h * comps[q].vs + vmax0 - 1) / vmax0;
                        bw[q] = mcux * comps[q].hs;
                        bh[q] = mcuy * comps[q].vs;
                        coff[q] = need;
                        need += @as(usize, bw[q]) * bh[q] * 64;
                    }
                    const bytes = need * 2;
                    if (bytes + 64 > scratch.len) return 0;
                    coef_n = need;
                    @memset(scratch[0..bytes], 0);
                    var used: usize = bytes;
                    q = 0;
                    while (q < ncomp) : (q += 1) {
                        const npx = @as(usize, comps[q].w) * comps[q].h;
                        if (used + npx > scratch.len) return 0;
                        comps[q].off = used;
                        used += npx;
                    }
                    hmax = hmax0;
                    vmax = vmax0;
                    setup = true;
                }
                const coef = @as([*]i16, @ptrCast(@alignCast(scratch.ptr)))[0..coef_n];
                const after = scanProg(d, p + 2 + len, &comps, ncomp, &hdc, &hac, ri,
                    ns, &order, ss, se, ah, al, coef, &coff, &bw, &bh, mcux, mcuy);
                // 다음 표식까지 건너뛴다
                p = after;
                while (p + 1 < d.len and !(d[p] == 0xFF and d[p + 1] != 0 and
                    !(d[p + 1] >= 0xD0 and d[p + 1] <= 0xD7))) p += 1;
                continue;
            },
            else => {},
        }
        p += 2 + len;
    }
    if (prog and setup) {
        // 모은 계수를 블록마다 되돌려 화소로 편다
        const coef = @as([*]i16, @ptrCast(@alignCast(scratch.ptr)))[0..coef_n];
        var q: u8 = 0;
        while (q < ncomp) : (q += 1) {
            const c = &comps[q];
            // 양자화표는 지그재그 차례로 들어 있다 — 제자리 차례로 옮긴다
            var qnat: [64]u16 = undefined;
            var k: usize = 0;
            while (k < 64) : (k += 1) qnat[ZIGZAG[k]] = qt[c.tq][k];
            const cbw = (c.w + 7) / 8;
            const cbh = (c.h + 7) / 8;
            var by: u32 = 0;
            while (by < cbh) : (by += 1) {
                var bx: u32 = 0;
                while (bx < cbw) : (bx += 1) {
                    const at = coff[q] + (@as(usize, by) * bw[q] + bx) * 64;
                    if (at + 64 > coef.len) continue;
                    var blk: [64]f32 = undefined;
                    var px: [64]u8 = undefined;
                    var z: usize = 0;
                    while (z < 64) : (z += 1)
                        blk[z] = @floatFromInt(@as(i32, coef[at + z]) * @as(i32, qnat[z]));
                    idct(&blk, &px);
                    var yy: u32 = 0;
                    while (yy < 8) : (yy += 1) {
                        const dy = by * 8 + yy;
                        if (dy >= c.h) break;
                        var xx: u32 = 0;
                        while (xx < 8) : (xx += 1) {
                            const dx = bx * 8 + xx;
                            if (dx >= c.w) break;
                            scratch[c.off + dy * c.w + dx] = px[yy * 8 + xx];
                        }
                    }
                }
            }
        }
        emit(w, h, &comps, ncomp, hmax, vmax, invert, transform, have_transform, dst, scratch);
        return w * h;
    }
    return 0;
}

/// 프로그레시브 훑기 하나를 계수에 담는다. 계수 자리는 scratch 앞쪽이다.
///
/// T.81 G.1.2 그대로다. 훑기마다 무엇을 담는지가 넷으로 갈린다.
///   DC 첫 훑기   — 차이를 읽어 Al 만큼 올려 담는다
///   DC 다듬기    — 비트 하나를 아랫자리에 붙인다
///   AC 첫 훑기   — Ss~Se 띠를 담는다. 0 이 이어지면 EOBRUN 으로 건너뛴다
///   AC 다듬기    — 이미 담은 값에 비트를 붙이고, 새로 생긴 값을 끼운다
fn scanProg(
    d: []const u8, start: usize, comps: *[4]Comp, ncomp: u8,
    hdc: *[4]Huff, hac: *[4]Huff, ri: u32,
    ns: u8, order: *const [4]u8, ss: u8, se: u8, ah: u5, al: u5,
    coef: []i16, coff: *const [4]usize, bw: *const [4]u32, bh: *const [4]u32,
    mcux: u32, mcuy: u32,
) usize {
    var bs = Bits{ .d = d, .p = start };
    var eobrun: u32 = 0;
    var i: u8 = 0;
    while (i < ncomp) : (i += 1) comps[i].dc = 0;

    const al4: u4 = @intCast(@min(al, 15));
    const p1: i16 = @as(i16, 1) << al4;
    const m1: i16 = -(@as(i16, 1) << al4);

    // 블록 하나를 담는다
    const Blk = struct {
        fn one(
            bsp: *Bits, c: *Comp, blk: []i16, hdc2: *[4]Huff, hac2: *[4]Huff,
            ss2: u8, se2: u8, ah2: u5, al2: u5, eob: *u32, pp1: i16, mm1: i16,
        ) void {
            if (ss2 == 0) {
                if (ah2 == 0) {
                    const t = decodeHuff(bsp, &hdc2[c.td]);
                    const diff = if (t == 0) 0 else extend(bsp.bits(@intCast(@min(t, 16))), @intCast(@min(t, 16)));
                    c.dc += diff;
                    blk[0] = @truncate(@as(i32, c.dc) << al2);
                } else {
                    if (bsp.bit() != 0) blk[0] |= pp1;
                }
                return;
            }
            if (ah2 == 0) {
                // AC 첫 훑기
                if (eob.* > 0) { eob.* -= 1; return; }
                var k: u32 = ss2;
                while (k <= se2) {
                    const rs = decodeHuff(bsp, &hac2[c.ta]);
                    const sz: u5 = @intCast(rs & 15);
                    const r: u32 = rs >> 4;
                    if (sz == 0) {
                        if (r < 15) {
                            eob.* = (@as(u32, 1) << @intCast(r)) - 1;
                            if (r > 0) eob.* += bsp.bits(@intCast(r));
                            return;
                        }
                        k += 16;
                        continue;
                    }
                    k += r;
                    if (k > 63) return;
                    blk[ZIGZAG[k]] = @truncate(extend(bsp.bits(sz), sz) << al2);
                    k += 1;
                }
                return;
            }
            // AC 다듬기 — 이미 담은 값에는 비트를 붙이고, 새 값은 끼운다
            var k: u32 = ss2;
            if (eob.* == 0) {
                while (k <= se2) {
                    const rs = decodeHuff(bsp, &hac2[c.ta]);
                    const sz = rs & 15;
                    var r: i32 = @intCast(rs >> 4);
                    var val: i16 = 0;
                    if (sz == 0) {
                        if (r < 15) {
                            eob.* = (@as(u32, 1) << @intCast(r));
                            if (r > 0) eob.* += bsp.bits(@intCast(r));
                            break;
                        }
                    } else {
                        val = if (bsp.bit() != 0) pp1 else mm1;
                    }
                    while (k <= se2) {
                        const z = ZIGZAG[k];
                        if (blk[z] != 0) {
                            if (bsp.bit() != 0) {
                                if ((blk[z] & pp1) == 0) {
                                    blk[z] += if (blk[z] >= 0) pp1 else mm1;
                                }
                            }
                        } else {
                            if (r == 0) {
                                if (val != 0) blk[z] = val;
                                k += 1;
                                break;
                            }
                            r -= 1;
                        }
                        k += 1;
                    }
                }
            }
            if (eob.* > 0) {
                // 남은 자리는 비트만 붙인다
                while (k <= se2) : (k += 1) {
                    const z = ZIGZAG[k];
                    if (blk[z] == 0) continue;
                    if (bsp.bit() != 0 and (blk[z] & pp1) == 0) {
                        blk[z] += if (blk[z] >= 0) pp1 else mm1;
                    }
                }
                eob.* -= 1;
            }
        }
    };

    var done: u32 = 0;
    if (ns == 1) {
        // 성분 하나만 담는 훑기 — 그 성분의 블록을 줄줄이 훑는다
        const ci = order[0];
        const c = &comps[ci];
        const cbw = (c.w + 7) / 8;
        const cbh = (c.h + 7) / 8;
        var by: u32 = 0;
        while (by < cbh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < cbw) : (bx += 1) {
                const at = coff[ci] + (@as(usize, by) * bw[ci] + bx) * 64;
                if (at + 64 > coef.len) return bs.p;
                Blk.one(&bs, c, coef[at .. at + 64], hdc, hac, ss, se, ah, al, &eobrun, p1, m1);
                done += 1;
                if (ri > 0 and done % ri == 0) {
                    bs.reset();
                    eobrun = 0;
                    var q: u8 = 0;
                    while (q < ncomp) : (q += 1) comps[q].dc = 0;
                    // 재시작 표식을 건너뛴다
                    while (bs.p + 1 < d.len and !(d[bs.p] == 0xFF and d[bs.p + 1] >= 0xD0 and d[bs.p + 1] <= 0xD7)) bs.p += 1;
                    if (bs.p + 1 < d.len) bs.p += 2;
                }
            }
        }
    } else {
        var my: u32 = 0;
        while (my < mcuy) : (my += 1) {
            var mx: u32 = 0;
            while (mx < mcux) : (mx += 1) {
                var q: u8 = 0;
                while (q < ns) : (q += 1) {
                    const ci = order[q];
                    const c = &comps[ci];
                    var vy: u8 = 0;
                    while (vy < c.vs) : (vy += 1) {
                        var vx: u8 = 0;
                        while (vx < c.hs) : (vx += 1) {
                            const bx = mx * c.hs + vx;
                            const by = my * c.vs + vy;
                            if (bx >= bw[ci] or by >= bh[ci]) continue;
                            const at = coff[ci] + (@as(usize, by) * bw[ci] + bx) * 64;
                            if (at + 64 > coef.len) return bs.p;
                            Blk.one(&bs, c, coef[at .. at + 64], hdc, hac, ss, se, ah, al, &eobrun, p1, m1);
                        }
                    }
                }
                done += 1;
                if (ri > 0 and done % ri == 0) {
                    bs.reset();
                    eobrun = 0;
                    var q2: u8 = 0;
                    while (q2 < ncomp) : (q2 += 1) comps[q2].dc = 0;
                    while (bs.p + 1 < d.len and !(d[bs.p] == 0xFF and d[bs.p + 1] >= 0xD0 and d[bs.p + 1] <= 0xD7)) bs.p += 1;
                    if (bs.p + 1 < d.len) bs.p += 2;
                }
            }
        }
    }
    return bs.p;
}

fn scan(
    d: []const u8, start: usize, w: u32, h: u32, comps: *[4]Comp, ncomp: u8,
    qt: *const [4][64]u16, hdc: *[4]Huff, hac: *[4]Huff, ri: u32,
    invert: bool, transform: u8, have_transform: bool, dst: []u8, scratch: []u8,
) u32 {
    var hmax: u8 = 1;
    var vmax: u8 = 1;
    var i: u8 = 0;
    while (i < ncomp) : (i += 1) {
        hmax = @max(hmax, comps[i].hs);
        vmax = @max(vmax, comps[i].vs);
    }
    const mcux = (w + @as(u32, hmax) * 8 - 1) / (@as(u32, hmax) * 8);
    const mcuy = (h + @as(u32, vmax) * 8 - 1) / (@as(u32, vmax) * 8);
    // 성분마다 자리를 잡는다
    var used: usize = 0;
    i = 0;
    while (i < ncomp) : (i += 1) {
        comps[i].w = mcux * comps[i].hs * 8;
        comps[i].h = mcuy * comps[i].vs * 8;
        comps[i].off = used;
        const need = @as(usize, comps[i].w) * comps[i].h;
        if (used + need > scratch.len) return 0;
        used += need;
        comps[i].dc = 0;
    }
    if (@as(usize, w) * h * 3 > dst.len) return 0;

    var bs = Bits{ .d = d, .p = start };
    var blk: [64]f32 = undefined;
    var px: [64]u8 = undefined;
    var mcu: u32 = 0;
    const total = mcux * mcuy;
    while (mcu < total) : (mcu += 1) {
        if (ri > 0 and mcu > 0 and mcu % ri == 0) {
            // 재시작 — 표식을 건너뛰고 DC 예측을 되돌린다
            bs.reset();
            var q = bs.p;
            while (q + 1 < d.len and !(d[q] == 0xFF and d[q + 1] >= 0xD0 and d[q + 1] <= 0xD7)) q += 1;
            if (q + 1 < d.len) bs.p = q + 2;
            i = 0;
            while (i < ncomp) : (i += 1) comps[i].dc = 0;
        }
        const my = mcu / mcux;
        const mx = mcu % mcux;
        i = 0;
        while (i < ncomp) : (i += 1) {
            const c = &comps[i];
            var by: u8 = 0;
            while (by < c.vs) : (by += 1) {
                var bx: u8 = 0;
                while (bx < c.hs) : (bx += 1) {
                    @memset(&blk, 0);
                    // DC
                    const t = decodeHuff(&bs, &hdc[c.td & 3]);
                    const diff = if (t == 0) 0 else extend(bs.bits(@intCast(@min(t, 16))), @intCast(@min(t, 16)));
                    c.dc += diff;
                    blk[0] = @floatFromInt(c.dc * @as(i32, qt[c.tq][0]));
                    // AC
                    var k: u32 = 1;
                    while (k < 64) {
                        const rs = decodeHuff(&bs, &hac[c.ta & 3]);
                        const r = rs >> 4;
                        const sz = rs & 15;
                        if (sz == 0) {
                            if (r != 15) break;
                            k += 16;
                            continue;
                        }
                        k += r;
                        if (k > 63) break;
                        const v = extend(bs.bits(@intCast(sz)), @intCast(sz));
                        const z = ZIGZAG[k];
                        blk[z] = @floatFromInt(v * @as(i32, qt[c.tq][k]));
                        k += 1;
                    }
                    idct(&blk, &px);
                    // 성분 판에 옮긴다
                    const ox = (mx * c.hs + bx) * 8;
                    const oy = (my * c.vs + by) * 8;
                    var yy: u32 = 0;
                    while (yy < 8) : (yy += 1) {
                        const dy = oy + yy;
                        if (dy >= c.h) break;
                        var xx: u32 = 0;
                        while (xx < 8) : (xx += 1) {
                            const dx = ox + xx;
                            if (dx >= c.w) break;
                            scratch[c.off + dy * c.w + dx] = px[yy * 8 + xx];
                        }
                    }
                }
            }
        }
    }

    emit(w, h, comps, ncomp, hmax, vmax, invert, transform, have_transform, dst, scratch);
    return w * h;
}

/// 성분 판을 합쳐 RGB 로 편다. 베이스라인과 프로그레시브가 함께 쓴다.
fn emit(
    w: u32, h: u32, comps: *[4]Comp, ncomp: u8, hmax: u8, vmax: u8,
    invert: bool, transform: u8, have_transform: bool, dst: []u8, scratch: []u8,
) void {
    var i: u8 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            i = 0;
            // 성분이 넷보다 적으면 그만큼만 읽는다 — 안 쓰는 성분 자리를
            // 읽으면 c.w 가 0 이라 나눗셈에서 죽는다
            while (i < ncomp) : (i += 1) {
                const c = &comps[i];
                if (c.w == 0 or c.h == 0) continue;
                const sx = @min(c.w - 1, x * c.hs / hmax);
                const sy = @min(c.h - 1, y * c.vs / vmax);
                v[i] = @floatFromInt(scratch[c.off + sy * c.w + sx]);
            }
            const o0 = (@as(usize, y) * w + x) * 3;
            if (ncomp == 1) {
                // 흑백 — 한 성분을 셋에 그대로 편다
                const g8: u8 = @intFromFloat(@max(0, @min(255, v[0])));
                dst[o0] = g8;
                dst[o0 + 1] = g8;
                dst[o0 + 2] = g8;
                continue;
            }
            if (ncomp == 3) {
                // Adobe 표식이 0 이면 이미 RGB 다. 없으면 YCbCr 로 본다 —
                // 규격이 그렇게 정하고, 실제 파일도 거의 다 그렇다.
                if (have_transform and transform == 0) {
                    dst[o0] = @intFromFloat(@max(0, @min(255, v[0])));
                    dst[o0 + 1] = @intFromFloat(@max(0, @min(255, v[1])));
                    dst[o0 + 2] = @intFromFloat(@max(0, @min(255, v[2])));
                } else {
                    const yy3 = v[0];
                    const cb3 = v[1] - 128;
                    const cr3 = v[2] - 128;
                    dst[o0] = @intFromFloat(@max(0, @min(255, yy3 + 1.402 * cr3)));
                    dst[o0 + 1] = @intFromFloat(@max(0, @min(255, yy3 - 0.344136 * cb3 - 0.714136 * cr3)));
                    dst[o0 + 2] = @intFromFloat(@max(0, @min(255, yy3 + 1.772 * cb3)));
                }
                continue;
            }
            var cy = v[0];
            var mm = v[1];
            var yl = v[2];
            const kk = v[3];
            if (transform == 2) {
                // YCCK — 앞 셋을 먼저 YCbCr 로 풀고 뒤집는다
                const yy2 = v[0];
                const cb = v[1] - 128;
                const cr = v[2] - 128;
                cy = 255 - @max(0, @min(255, yy2 + 1.402 * cr));
                mm = 255 - @max(0, @min(255, yy2 - 0.344136 * cb - 0.714136 * cr));
                yl = 255 - @max(0, @min(255, yy2 + 1.772 * cb));
            }
            // 포토샵이 만든 CMYK 는 뒤집혀 담긴다. PDF 가 /Decode [1 0 …] 로
            // 그렇다고 알려 주므로, 표식만 보고 넘겨짚지 않는다 — 넘겨짚으면
            // 안 뒤집힌 파일이 음화처럼 나온다.
            const c2 = if (invert) 255 - cy else cy;
            const m2 = if (invert) 255 - mm else mm;
            const y2 = if (invert) 255 - yl else yl;
            const k2 = if (invert) 255 - kk else kk;
            const o = (@as(usize, y) * w + x) * 3;
            dst[o] = @intFromFloat(@max(0, @min(255, (255 - c2) * (255 - k2) / 255)));
            dst[o + 1] = @intFromFloat(@max(0, @min(255, (255 - m2) * (255 - k2) / 255)));
            dst[o + 2] = @intFromFloat(@max(0, @min(255, (255 - y2) * (255 - k2) / 255)));
        }
    }
}
