// 베이스라인 JPEG 복호기.
//
// 보통 JPEG 은 브라우저에 그냥 넘긴다 — 빠르고 하드웨어가 거들기도 한다.
// 그런데 **CMYK JPEG 은 브라우저가 못 푼다.** Acrobat 으로 만든 인쇄용
// 문서에 흔한데, createImageBitmap 이 조용히 실패해 그림이 통째로 사라진다.
// 그래서 성분이 넷인 것만 여기서 직접 푼다.
//
// 규격은 ITU-T T.81 이다. 베이스라인(SOF0·SOF1)만 다룬다 — 프로그레시브
// CMYK 는 만나기 어렵다.
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
            0xC0, 0xC1 => { // 베이스라인 머리말
                if (seg.len < 6) return 0;
                h = (@as(u32, seg[1]) << 8) | seg[2];
                w = (@as(u32, seg[3]) << 8) | seg[4];
                ncomp = seg[5];
                if (ncomp != 4 or w == 0 or h == 0) return 0;
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
            0xC2 => return 0, // 프로그레시브는 다루지 않는다
            0xDD => { // 재시작 간격
                if (seg.len >= 2) ri = (@as(u32, seg[0]) << 8) | seg[1];
            },
            0xEE => { // APP14 Adobe — CMYK 는 대개 뒤집혀 담긴다
                if (seg.len >= 11 and std.mem.eql(u8, seg[0..5], "Adobe")) {
                    transform = seg[seg.len - 1];
                    have_transform = true;
                }
            },
            0xDA => { // 스캔 시작
                if (seg.len < 1) return 0;
                const ns = seg[0];
                if (ns != ncomp) return 0;
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
                        }
                    }
                }
                return scan(d, p + 2 + len, w, h, &comps, ncomp, &qt, &hdc, &hac, ri,
                    invert, if (have_transform) transform else 0, dst, scratch);
            },
            else => {},
        }
        p += 2 + len;
    }
    return 0;
}

fn scan(
    d: []const u8, start: usize, w: u32, h: u32, comps: *[4]Comp, ncomp: u8,
    qt: *const [4][64]u16, hdc: *[4]Huff, hac: *[4]Huff, ri: u32,
    invert: bool, transform: u8, dst: []u8, scratch: []u8,
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

    // 성분을 합쳐 RGB 로 편다
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            i = 0;
            while (i < 4) : (i += 1) {
                const c = &comps[i];
                const sx = @min(c.w - 1, x * c.hs / hmax);
                const sy = @min(c.h - 1, y * c.vs / vmax);
                v[i] = @floatFromInt(scratch[c.off + sy * c.w + sx]);
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
    return w * h;
}
