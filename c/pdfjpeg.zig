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
    /// 아홉 비트 이하 코드를 한 번에 집는 표.
    ///
    /// 코드 하나를 읽으려고 비트를 하나씩 열여섯 번까지 세고 있었다.
    /// 사진 한 장에 계수가 수백만 개라 그 셈이 통째로 값이 된다.
    /// 앞 아홉 비트를 그대로 색인으로 삼으면 대개 한 번에 끝난다.
    /// 값은 (기호 << 5) | 길이, 0 이면 표에 없다는 뜻이다.
    fast: [512]u16 = .{0} ** 512,
};

const FAST_BITS: u5 = 9;

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

    // 빠른 표를 짓는다 — 아홉 비트 이하 코드마다 그 코드로 시작하는
    // 모든 색인 자리에 (기호, 길이) 를 박아 둔다
    @memset(&h.fast, 0);
    var code2: u32 = 0;
    var vi: u16 = 0;
    var ln: u5 = 1;
    while (ln <= 16) : (ln += 1) {
        const cnt = if (ln - 1 < bits.len) bits[ln - 1] else 0;
        var c: u8 = 0;
        while (c < cnt) : (c += 1) {
            if (ln <= FAST_BITS and vi < h.n and vi < h.vals.len) {
                const shift: u5 = FAST_BITS - ln;
                const base = code2 << shift;
                const span = @as(u32, 1) << shift;
                var q: u32 = 0;
                while (q < span) : (q += 1) {
                    const at = base + q;
                    if (at < h.fast.len) h.fast[at] = (@as(u16, h.vals[vi]) << 5) | ln;
                }
            }
            code2 += 1;
            vi += 1;
        }
        code2 <<= 1;
    }
}

/// 비트를 통으로 담아 읽는다.
///
/// 예전에는 바이트 하나를 담고 비트를 하나씩 꺼냈다. 계수 하나에 코드
/// 하나와 값 몇 비트를 읽으니, 사진 한 장이면 그 셈이 수천만 번이다.
/// 서른두 비트를 미리 채워 두고 필요한 만큼 떼어 쓴다.
const Bits = struct {
    d: []const u8,
    p: usize,
    acc: u32 = 0,
    /// 담아 둔 비트 수. u5 로 두었더니 24+8 에서 넘쳐 0 이 되고 되돌이가
    /// 끝나지 않았다 — 32 까지 담으므로 넉넉한 자리를 쓴다.
    n: u32 = 0,

    /// 스물넷 비트가 차도록 바이트를 밀어 넣는다.
    /// 0xFF00 은 자료의 0xFF 이고, 그 밖의 0xFF 는 표식이라 거기서 멈춘다.
    fn fill(s: *Bits) void {
        while (s.n <= 24) {
            var v: u8 = 0;
            if (s.p < s.d.len) {
                v = s.d[s.p];
                if (v == 0xFF) {
                    if (s.p + 1 < s.d.len and s.d[s.p + 1] == 0) {
                        s.p += 2;
                    } else {
                        v = 0; // 표식 — 여기서부터는 0 으로 채운다
                    }
                } else {
                    s.p += 1;
                }
            }
            s.acc |= @as(u32, v) << @intCast(24 - s.n);
            s.n += 8;
        }
    }
    /// 앞 k 비트를 보되 쓰지는 않는다
    fn peek(s: *Bits, k: u5) u32 {
        if (k == 0) return 0;
        if (s.n < k) s.fill();
        return s.acc >> @intCast(32 - @as(u32, k));
    }
    fn skip(s: *Bits, k: u5) void {
        if (k == 0) return;
        if (s.n < k) s.fill();
        const kk: u32 = @min(@as(u32, k), s.n);
        if (kk >= 32) { s.acc = 0; s.n = 0; return; }
        s.acc <<= @intCast(kk);
        s.n -= kk;
    }
    fn bit(s: *Bits) u32 {
        const v = s.peek(1);
        s.skip(1);
        return v;
    }
    fn bits(s: *Bits, k: u5) u32 {
        if (k == 0) return 0;
        const v = s.peek(k);
        s.skip(k);
        return v;
    }
    fn reset(s: *Bits) void {
        s.n = 0;
        s.acc = 0;
    }
};

fn decodeHuff(s: *Bits, h: *const Huff) u8 {
    // 앞 아홉 비트로 한 번에 집는다
    const look = s.peek(FAST_BITS);
    const hit = h.fast[@intCast(look)];
    if (hit != 0) {
        const len: u5 = @intCast(hit & 31);
        s.skip(len);
        return @intCast(hit >> 5);
    }
    // 아홉 비트를 넘는 긴 코드 — 규격대로 한 비트씩 늘려 본다
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

/// 8x8 역 DCT.
///
/// 곧이곧대로 두 겹으로 돌면 블록마다 곱셈이 1024번이다. 그 판으로 재 보니
/// 192만 화소짜리 사진 하나를 푸는 데 122ms 였다 — libjpeg 은 5ms 다.
///
/// 그래서 나비꼴(butterfly)로 바꿨다. 한 줄을 여덟 값으로 한 번에 풀면
/// 곱셈이 열몇 번이면 된다. 세로로 한 번 더 돌려 8x8 을 끝낸다.
/// 상수는 규격의 코사인 값에서 나온 것으로, libjpeg·stb_image 가 쓰는 것과
/// 같다. 결과는 예전 판과 화소 단위로 맞춰 확인했다.
fn idct1d(s0: f32, s1: f32, s2: f32, s3: f32, s4: f32, s5: f32, s6: f32, s7: f32, out: *[8]f32) void {
    // 짝수 쪽
    var p2 = s2;
    var p3 = s6;
    var p1 = (p2 + p3) * 0.5411961;
    const t2 = p1 + p3 * -1.847759;
    const t3e = p1 + p2 * 0.765367;
    p2 = s0;
    p3 = s4;
    const t0e = p2 + p3;
    const t1e = p2 - p3;
    const x0 = t0e + t3e;
    const x3 = t0e - t3e;
    const x1 = t1e + t2;
    const x2 = t1e - t2;
    // 홀수 쪽
    var t0 = s7;
    var t1 = s5;
    var t2o = s3;
    var t3 = s1;
    p3 = t0 + t2o;
    var p4 = t1 + t3;
    p1 = t0 + t3;
    p2 = t1 + t2o;
    const p5 = (p3 + p4) * 1.175876;
    t0 *= 0.298631;
    t1 *= 2.053120;
    t2o *= 3.072711;
    t3 *= 1.501321;
    p1 = p5 + p1 * -0.899976;
    p2 = p5 + p2 * -2.562915;
    p3 *= -1.961571;
    p4 *= -0.390181;
    t3 += p1 + p4;
    t2o += p2 + p3;
    t1 += p2 + p4;
    t0 += p1 + p3;
    out[0] = x0 + t3;
    out[7] = x0 - t3;
    out[1] = x1 + t2o;
    out[6] = x1 - t2o;
    out[2] = x2 + t1;
    out[5] = x2 - t1;
    out[3] = x3 + t0;
    out[4] = x3 - t0;
}

fn idct(blk: *[64]f32, out: *[64]u8) void {
    var tmp: [64]f32 = undefined;
    var row: [8]f32 = undefined;
    // 가로
    var u: usize = 0;
    while (u < 8) : (u += 1) {
        const b = blk[u * 8 ..][0..8];
        idct1d(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], &row);
        var x: usize = 0;
        // 두 겹을 합쳐 1/8 이면 된다 — 가로에서는 그대로 두고 세로에서 나눈다
        while (x < 8) : (x += 1) tmp[u * 8 + x] = row[x];
    }
    // 세로
    var x2: usize = 0;
    while (x2 < 8) : (x2 += 1) {
        idct1d(tmp[x2], tmp[8 + x2], tmp[16 + x2], tmp[24 + x2],
            tmp[32 + x2], tmp[40 + x2], tmp[48 + x2], tmp[56 + x2], &row);
        var y: usize = 0;
        while (y < 8) : (y += 1) {
            const v = row[y] * 0.125 + 128;
            out[y * 8 + x2] = @intFromFloat(@max(0, @min(255, v)));
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

/// 흔한 꼴(성분 셋 · YCbCr)을 위한 빠른 길.
///
/// 화소마다 실수로 곱하고 나누면 192만 화소짜리 사진에서 그것만 수천만
/// 번이다. 두 가지를 바꾼다.
///
///   가로 무게는 x 에만 딸린 값이라 줄마다 다시 셈할 까닭이 없다 —
///   한 번 만들어 두고 모든 줄에서 쓴다.
///   YCbCr→RGB 는 정수 표로 바꾼다. libjpeg 이 하는 것과 같은 방식이다.
///
/// 자리가 모자라거나 꼴이 다르면 false 를 주고 일반 길로 간다.
fn emitFast(
    w: u32, h: u32, comps: *[4]Comp, hmax: u8, vmax: u8, dst: []u8, scratch: []u8,
) bool {
    if (w == 0 or h == 0) return false;
    // 성분 판 뒤의 남은 자리에 가로 무게표를 놓는다
    var end: usize = 0;
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const c = &comps[i];
        if (c.w == 0 or c.h == 0) return false;
        end = @max(end, c.off + @as(usize, c.w) * c.h);
    }
    end = (end + 7) & ~@as(usize, 7);
    const tbl_bytes = @as(usize, w) * 3 * 4 * 2; // 성분 셋 × (lo, hi, 무게)
    if (end + tbl_bytes > scratch.len) return false;
    const tbl = @as([*]u32, @ptrCast(@alignCast(scratch.ptr + end)));

    // 가로 무게 (16.16 고정소수)
    i = 0;
    while (i < 3) : (i += 1) {
        const c = &comps[i];
        const base = @as(usize, i) * @as(usize, w) * 3;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            if (c.hs == hmax) {
                const sx = @min(c.w - 1, x);
                tbl[base + x * 3] = sx;
                tbl[base + x * 3 + 1] = sx;
                tbl[base + x * 3 + 2] = 0;
                continue;
            }
            const f = (@as(f32, @floatFromInt(x)) + 0.5) *
                @as(f32, @floatFromInt(c.hs)) / @as(f32, @floatFromInt(hmax)) - 0.5;
            const g = @max(@as(f32, 0), f);
            const lo: u32 = @min(c.w - 1, @as(u32, @intFromFloat(g)));
            const hi: u32 = @min(c.w - 1, lo + 1);
            const t = g - @as(f32, @floatFromInt(lo));
            tbl[base + x * 3] = lo;
            tbl[base + x * 3 + 1] = hi;
            tbl[base + x * 3 + 2] = @intFromFloat(@max(0, @min(65536, t * 65536)));
        }
    }

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        // 세로 무게는 줄마다 한 번만
        var ylo: [3]usize = undefined;
        var yhi: [3]usize = undefined;
        var yw: [3]i32 = undefined;
        i = 0;
        while (i < 3) : (i += 1) {
            const c = &comps[i];
            if (c.vs == vmax) {
                const sy = @min(c.h - 1, y);
                ylo[i] = c.off + @as(usize, sy) * c.w;
                yhi[i] = ylo[i];
                yw[i] = 0;
                continue;
            }
            const f = (@as(f32, @floatFromInt(y)) + 0.5) *
                @as(f32, @floatFromInt(c.vs)) / @as(f32, @floatFromInt(vmax)) - 0.5;
            const g = @max(@as(f32, 0), f);
            const l: u32 = @min(c.h - 1, @as(u32, @intFromFloat(g)));
            const hh: u32 = @min(c.h - 1, l + 1);
            ylo[i] = c.off + @as(usize, l) * c.w;
            yhi[i] = c.off + @as(usize, hh) * c.w;
            yw[i] = @intFromFloat(@max(0, @min(65536, (g - @as(f32, @floatFromInt(l))) * 65536)));
        }
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var v: [3]i32 = .{ 0, 0, 0 };
            i = 0;
            while (i < 3) : (i += 1) {
                const base = @as(usize, i) * @as(usize, w) * 3 + @as(usize, x) * 3;
                const lo = tbl[base];
                const hi = tbl[base + 1];
                const tx: i32 = @intCast(tbl[base + 2]);
                const a: i32 = scratch[ylo[i] + lo];
                const b: i32 = scratch[ylo[i] + hi];
                const c2: i32 = scratch[yhi[i] + lo];
                const d2: i32 = scratch[yhi[i] + hi];
                const top = a + @divTrunc((b - a) * tx, 65536);
                const bot = c2 + @divTrunc((d2 - c2) * tx, 65536);
                v[i] = top + @divTrunc((bot - top) * yw[i], 65536);
            }
            // YCbCr → RGB (정수)
            const yy = v[0];
            const cb = v[1] - 128;
            const cr = v[2] - 128;
            const r = yy + @divTrunc(91881 * cr, 65536);
            const g2 = yy - @divTrunc(22554 * cb + 46802 * cr, 65536);
            const b3 = yy + @divTrunc(116130 * cb, 65536);
            const o = (@as(usize, y) * w + x) * 3;
            dst[o] = @intCast(@max(0, @min(255, r)));
            dst[o + 1] = @intCast(@max(0, @min(255, g2)));
            dst[o + 2] = @intCast(@max(0, @min(255, b3)));
        }
    }
    return true;
}

/// 성분 판을 합쳐 RGB 로 편다. 베이스라인과 프로그레시브가 함께 쓴다.
fn emit(
    w: u32, h: u32, comps: *[4]Comp, ncomp: u8, hmax: u8, vmax: u8,
    invert: bool, transform: u8, have_transform: bool, dst: []u8, scratch: []u8,
) void {
    // 흔한 꼴이면 빠른 길로 간다
    if (ncomp == 3 and !(have_transform and transform == 0) and
        @as(usize, w) * h * 3 <= dst.len)
    {
        if (emitFast(w, h, comps, hmax, vmax, dst, scratch)) return;
    }
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
                if (c.hs == hmax and c.vs == vmax) {
                    // 이 성분은 줄이지 않고 담겼다 — 그대로 읽는다
                    const sx = @min(c.w - 1, x);
                    const sy = @min(c.h - 1, y);
                    v[i] = @floatFromInt(scratch[c.off + sy * c.w + sx]);
                    continue;
                }
                // 줄여 담은 성분(대개 색차)을 늘린다.
                //
                // 눈은 밝기보다 색에 둔해서 JPEG 은 색을 절반·사분의 일로
                // 줄여 담는다(4:2:0). 그린 것을 다시 늘려야 하는데, 가장
                // 가까운 값을 그대로 쓰면 색 경계가 계단처럼 각진다.
                // 네 이웃을 거리에 따라 섞으면(쌍선형) 그 계단이 사라진다 —
                // libjpeg 이 "fancy upsampling" 이라 부르는 것과 같은 일이다.
                const fx = (@as(f32, @floatFromInt(x)) + 0.5) *
                    @as(f32, @floatFromInt(c.hs)) / @as(f32, @floatFromInt(hmax)) - 0.5;
                const fy = (@as(f32, @floatFromInt(y)) + 0.5) *
                    @as(f32, @floatFromInt(c.vs)) / @as(f32, @floatFromInt(vmax)) - 0.5;
                const gx = @max(@as(f32, 0), fx);
                const gy = @max(@as(f32, 0), fy);
                const x0: u32 = @min(c.w - 1, @as(u32, @intFromFloat(gx)));
                const y0: u32 = @min(c.h - 1, @as(u32, @intFromFloat(gy)));
                const x1: u32 = @min(c.w - 1, x0 + 1);
                const y1: u32 = @min(c.h - 1, y0 + 1);
                const tx = gx - @as(f32, @floatFromInt(x0));
                const ty = gy - @as(f32, @floatFromInt(y0));
                const a: f32 = @floatFromInt(scratch[c.off + y0 * c.w + x0]);
                const b2: f32 = @floatFromInt(scratch[c.off + y0 * c.w + x1]);
                const c2: f32 = @floatFromInt(scratch[c.off + y1 * c.w + x0]);
                const d2: f32 = @floatFromInt(scratch[c.off + y1 * c.w + x1]);
                v[i] = (a * (1 - tx) + b2 * tx) * (1 - ty) + (c2 * (1 - tx) + d2 * tx) * ty;
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
