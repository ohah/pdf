// JPEG 2000 (JPX) — 스캔 문서와 보존용 PDF 가 쓰는 그림 형식.
//
// JPEG 와는 뼈대부터 다르다. 그림을 웨이블릿으로 여러 해상도로 쪼개고,
// 각 조각을 비트평면 단위로 산술 부호화한다. 산술 복호기는 JBIG2 와 같은
// MQ 다 — 그래서 그쪽 것을 그대로 쓴다.
//
// 여기서 다루는 것: 코드스트림(과 JP2 상자), 타일, 층, 프리싱크트,
// 태그트리 패킷 머리, EBCOT 1단, 5/3·9/7 역웨이블릿, RCT·ICT 성분 변환.
// 다루지 않는 것: ROI, PPM/PPT(패킷 머리 몰아 담기), 부호 없는 성분의
// 특이한 조합.

const jb = @import("pdfjbig2.zig");

// ===== 자리 잡기 =====
//
// 그림 하나에 계수 배열이 여러 개 필요하다. 미리 정적으로 잡으면 몇십 MB 가
// 되므로, 부른 쪽이 준 자리를 앞에서부터 잘라 쓴다.
const Arena = struct {
    buf: []u8,
    used: usize = 0,

    fn take(a: *Arena, comptime T: type, n: usize) ?[]T {
        const al = @alignOf(T);
        const start = (a.used + al - 1) & ~@as(usize, al - 1);
        const bytes = n * @sizeOf(T);
        if (start + bytes > a.buf.len) return null;
        a.used = start + bytes;
        const p: [*]T = @ptrCast(@alignCast(a.buf.ptr + start));
        const s = p[0..n];
        @memset(@as([*]u8, @ptrCast(p))[0..bytes], 0);
        return s;
    }
};

fn be16(d: []const u8, at: usize) u32 {
    if (at + 2 > d.len) return 0;
    return (@as(u32, d[at]) << 8) | d[at + 1];
}
fn be32(d: []const u8, at: usize) u32 {
    if (at + 4 > d.len) return 0;
    return (@as(u32, d[at]) << 24) | (@as(u32, d[at + 1]) << 16) |
        (@as(u32, d[at + 2]) << 8) | d[at + 3];
}
fn ceilDiv(a: i64, b: i64) i64 {
    if (b == 0) return 0;
    return @divFloor(a + b - 1, b);
}

const MAX_COMP = 4;
const MAX_LEV = 32;

const Cod = struct {
    prog: u8 = 0,
    layers: u32 = 1,
    mct: bool = false,
    levels: u32 = 5,
    xcb: u5 = 6,
    ycb: u5 = 6,
    seg_sym: bool = false,
    reset_cx: bool = false,
    reversible: bool = false,
    custom_prec: bool = false,
    sop: bool = false,
    eph: bool = false,
    ppx: [MAX_LEV + 1]u5 = .{15} ** (MAX_LEV + 1),
    ppy: [MAX_LEV + 1]u5 = .{15} ** (MAX_LEV + 1),
};

const Qcd = struct {
    style: u8 = 0,
    guard: u32 = 2,
    eps: [3 * MAX_LEV + 1]u32 = .{0} ** (3 * MAX_LEV + 1),
    mu: [3 * MAX_LEV + 1]u32 = .{0} ** (3 * MAX_LEV + 1),
    n: u32 = 0,
    expounded: bool = false,
};

const Chunk = struct { off: u32, len: u32, passes: u32, next: i32 };

const CB = struct {
    cbx: u32,
    cby: u32,
    xa: u32,
    ya: u32,
    xb: u32,
    yb: u32,
    prec: u32,
    included: bool,
    seen: bool,
    lblock: u8,
    zbp: u8,
    head: i32,
    tail: i32,
    passes: u32,
};

const Prec = struct {
    cbxmin: u32 = 0,
    cbymin: u32 = 0,
    cbxmax: u32 = 0,
    cbymax: u32 = 0,
    has: bool = false,
    built: bool = false,
    // 태그트리 자리 (arena 안 시작 칸)
    inc_lv: u32 = 0,
    zbp_lv: u32 = 0,
};

const Sub = struct {
    kind: u8 = 0, // 0 LL 1 HL 2 LH 3 HH
    xa: i64 = 0,
    ya: i64 = 0,
    xb: i64 = 0,
    yb: i64 = 0,
    cbs: []CB = &[_]CB{},
    res: u32 = 0,
    precs: []Prec = &[_]Prec{},
};

const Res = struct {
    xa: i64 = 0,
    ya: i64 = 0,
    xb: i64 = 0,
    yb: i64 = 0,
    lev: u32 = 0,
    ppx: u5 = 15,
    ppy: u5 = 15,
    xcb: u5 = 6,
    ycb: u5 = 6,
    pw: u32 = 0,
    ph: u32 = 0,
    nprec: u32 = 0,
    subs: [3]u32 = .{ 0, 0, 0 },
    nsub: u32 = 0,
};

// 태그트리 한 그루 (arena 에 값과 표시를 함께 둔다)
const TT = struct {
    nlev: u32,
    w: [12]u32,
    h: [12]u32,
    off: [12]u32,
    val: []u8,
    known: []u8,
    idx: [12]u32,
    cur: i32,
    value: u32,

    fn make(a: *Arena, w0: u32, h0: u32, fill: u8) ?TT {
        var t = TT{ .nlev = 0, .w = undefined, .h = undefined, .off = undefined,
            .val = &[_]u8{}, .known = &[_]u8{}, .idx = undefined, .cur = 0, .value = 0 };
        var w = @max(w0, 1);
        var h = @max(h0, 1);
        var total: u32 = 0;
        while (t.nlev < 12) {
            t.w[t.nlev] = w;
            t.h[t.nlev] = h;
            t.off[t.nlev] = total;
            total += w * h;
            t.nlev += 1;
            if (w == 1 and h == 1) break;
            w = (w + 1) / 2;
            h = (h + 1) / 2;
        }
        t.val = a.take(u8, total) orelse return null;
        t.known = a.take(u8, total) orelse return null;
        if (fill != 0) @memset(t.val, fill);
        return t;
    }
};

/// 값이 정해질 때까지 자란다 (B.10.2). 0 비트평면 수에 쓴다.
fn ttReset(t: *TT, ra: u32, rb: u32) void {
    var i = ra;
    var j = rb;
    var lev: u32 = 0;
    var value: u32 = 0;
    while (lev < t.nlev) {
        const idx = i + j * t.w[lev];
        t.idx[lev] = idx;
        if (t.known[t.off[lev] + idx] != 0) {
            value = t.val[t.off[lev] + idx];
            break;
        }
        i >>= 1;
        j >>= 1;
        lev += 1;
    }
    if (lev == 0) {
        t.cur = 0;
        t.value = value;
        return;
    }
    const l = lev - 1;
    t.val[t.off[l] + t.idx[l]] = @intCast(@min(value, 255));
    t.known[t.off[l] + t.idx[l]] = 1;
    t.cur = @intCast(l);
    t.value = 0;
}
fn ttInc(t: *TT) void {
    const l: u32 = @intCast(@max(t.cur, 0));
    const p = t.off[l] + t.idx[l];
    if (t.val[p] < 255) t.val[p] += 1;
}
fn ttNext(t: *TT) bool {
    const l: u32 = @intCast(@max(t.cur, 0));
    const v = t.val[t.off[l] + t.idx[l]];
    if (t.cur == 0) {
        t.value = v;
        return false;
    }
    t.cur -= 1;
    const l2: u32 = @intCast(t.cur);
    t.val[t.off[l2] + t.idx[l2]] = v;
    t.known[t.off[l2] + t.idx[l2]] = 1;
    return true;
}

/// 이 코드블록이 이 층에 들어 있는가 (B.10.4)
fn itReset(t: *TT, ra: u32, rb: u32, stop: u32) bool {
    var i = ra;
    var j = rb;
    var lev: u32 = 0;
    while (lev < t.nlev) {
        const idx = i + j * t.w[lev];
        t.idx[lev] = idx;
        const v = t.val[t.off[lev] + idx];
        if (v == 0xFF) break;
        if (v > stop) {
            t.cur = @intCast(lev);
            itProp(t);
            return false;
        }
        i >>= 1;
        j >>= 1;
        lev += 1;
    }
    t.cur = @as(i32, @intCast(lev)) - 1;
    return true;
}
fn itProp(t: *TT) void {
    if (t.cur < 0) return;
    var l: i32 = t.cur;
    const v = t.val[t.off[@intCast(l)] + t.idx[@intCast(l)]];
    l -= 1;
    while (l >= 0) : (l -= 1) {
        const u: u32 = @intCast(l);
        t.val[t.off[u] + t.idx[u]] = v;
    }
}
fn itInc(t: *TT, stop: u32) void {
    if (t.cur < 0) return;
    const u: u32 = @intCast(t.cur);
    t.val[t.off[u] + t.idx[u]] = @intCast(@min(stop + 1, 254));
    itProp(t);
}
fn itNext(t: *TT) bool {
    if (t.cur < 0) return false;
    const u: u32 = @intCast(t.cur);
    const v = t.val[t.off[u] + t.idx[u]];
    t.val[t.off[u] + t.idx[u]] = 0xFF;
    t.cur -= 1;
    if (t.cur < 0) return false;
    const uz: u32 = @intCast(t.cur);
    t.val[t.off[uz] + t.idx[uz]] = v;
    return true;
}

// ===== EBCOT 1단 (부록 D) =====

const LLLH = [_]u8{
    0, 5, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, 1, 6, 8, 0, 3, 7, 8, 0, 4,
    7, 8, 0, 0, 0, 0, 0, 2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, 2, 6,
    8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, 2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8,
};
const HLT = [_]u8{
    0, 3, 4, 0, 5, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, 1, 3, 4, 0, 6, 7, 7, 0, 8,
    8, 8, 0, 0, 0, 0, 0, 2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, 2, 3,
    4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, 2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8,
};
const HHT = [_]u8{
    0, 1, 2, 0, 1, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 0, 3, 4, 5, 0, 4, 5, 5, 0, 5,
    5, 5, 0, 0, 0, 0, 0, 6, 7, 7, 0, 7, 7, 7, 0, 7, 7, 7, 0, 0, 0, 0, 0, 8, 8,
    8, 0, 8, 8, 8, 0, 8, 8, 8, 0, 0, 0, 0, 0, 8, 8, 8, 0, 8, 8, 8, 0, 8, 8, 8,
};
const UNIFORM_CX = 17;
const RUNLEN_CX = 18;

const BitModel = struct {
    w: u32,
    h: u32,
    tab: []const u8,
    nsig: []u8,
    sign: []u8,
    mag: []u32,
    flags: []u8,
    nbits: []u8,
    cx: [19]u8,
    mq: jb.MQ,

    fn init(self: *BitModel, kind: u8) void {
        self.tab = switch (kind) {
            3 => &HHT,
            1 => &HLT,
            else => &LLLH,
        };
        self.reset();
    }
    fn reset(self: *BitModel) void {
        @memset(&self.cx, 0);
        self.cx[0] = (4 << 1);
        self.cx[UNIFORM_CX] = (46 << 1);
        self.cx[RUNLEN_CX] = (3 << 1);
    }

    fn setNeighbors(self: *BitModel, row: u32, col: u32, idx: u32) void {
        const left = col > 0;
        const right = col + 1 < self.w;
        if (row > 0) {
            const i = idx - self.w;
            if (left) self.nsig[i - 1] +%= 0x10;
            if (right) self.nsig[i + 1] +%= 0x10;
            self.nsig[i] +%= 0x04;
        }
        if (row + 1 < self.h) {
            const i = idx + self.w;
            if (left) self.nsig[i - 1] +%= 0x10;
            if (right) self.nsig[i + 1] +%= 0x10;
            self.nsig[i] +%= 0x04;
        }
        if (left) self.nsig[idx - 1] +%= 0x01;
        if (right) self.nsig[idx + 1] +%= 0x01;
        self.nsig[idx] |= 0x80;
    }

    fn signBit(self: *BitModel, row: u32, col: u32, idx: u32) u32 {
        var contrib: i32 = 0;
        var s1: bool = col > 0 and self.mag[idx - 1] != 0;
        if (col + 1 < self.w and self.mag[idx + 1] != 0) {
            const b = @as(i32, self.sign[idx + 1]);
            contrib = if (s1) 1 - b - @as(i32, self.sign[idx - 1]) else 1 - b - b;
        } else if (s1) {
            const a = @as(i32, self.sign[idx - 1]);
            contrib = 1 - a - a;
        }
        const horiz = 3 * contrib;
        s1 = row > 0 and self.mag[idx - self.w] != 0;
        if (row + 1 < self.h and self.mag[idx + self.w] != 0) {
            const b = @as(i32, self.sign[idx + self.w]);
            contrib = if (s1) 1 - b - @as(i32, self.sign[idx - self.w]) + horiz else 1 - b - b + horiz;
        } else if (s1) {
            const a = @as(i32, self.sign[idx - self.w]);
            contrib = 1 - a - a + horiz;
        } else contrib = horiz;
        if (contrib >= 0) return self.mq.bit(self.cx[0..], @intCast(9 + contrib));
        return self.mq.bit(self.cx[0..], @intCast(9 - contrib)) ^ 1;
    }

    fn passSig(self: *BitModel) void {
        var ra: u32 = 0;
        while (ra < self.h) : (ra += 4) {
            var j: u32 = 0;
            while (j < self.w) : (j += 1) {
                var idx = ra * self.w + j;
                var ea: u32 = 0;
                while (ea < 4) : (ea += 1) {
                    const i = ra + ea;
                    if (i >= self.h) break;
                    self.flags[idx] &= ~@as(u8, 1);
                    if (self.mag[idx] != 0 or self.nsig[idx] == 0) {
                        idx += self.w;
                        continue;
                    }
                    const lbl = self.tab[@min(self.nsig[idx], @as(u8, 78))];
                    if (self.mq.bit(self.cx[0..], lbl) != 0) {
                        self.sign[idx] = @intCast(self.signBit(i, j, idx));
                        self.mag[idx] = 1;
                        self.setNeighbors(i, j, idx);
                        self.flags[idx] |= 2;
                    }
                    if (self.nbits[idx] < 255) self.nbits[idx] += 1;
                    self.flags[idx] |= 1;
                    idx += self.w;
                }
            }
        }
    }

    fn passRef(self: *BitModel) void {
        const len = self.w * self.h;
        const w4 = self.w * 4;
        var ra: u32 = 0;
        while (ra < len) {
            const next = @min(len, ra + w4);
            var j: u32 = 0;
            while (j < self.w) : (j += 1) {
                var idx = ra + j;
                while (idx < next) : (idx += self.w) {
                    if (self.mag[idx] == 0 or (self.flags[idx] & 1) != 0) continue;
                    var lbl: u8 = 16;
                    if ((self.flags[idx] & 2) != 0) {
                        self.flags[idx] ^= 2;
                        lbl = if ((self.nsig[idx] & 127) == 0) 15 else 14;
                    }
                    const b = self.mq.bit(self.cx[0..], lbl);
                    self.mag[idx] = (self.mag[idx] << 1) | b;
                    if (self.nbits[idx] < 255) self.nbits[idx] += 1;
                    self.flags[idx] |= 1;
                }
            }
            ra = next;
        }
    }

    fn passClean(self: *BitModel) void {
        const w = self.w;
        var ra: u32 = 0;
        while (ra < self.h) {
            const inext = @min(ra + 4, self.h);
            const base = ra * w;
            const check = ra + 3 < self.h;
            var j: u32 = 0;
            while (j < w) : (j += 1) {
                const ix0 = base + j;
                const empty = check and
                    self.flags[ix0] == 0 and self.flags[ix0 + w] == 0 and
                    self.flags[ix0 + 2 * w] == 0 and self.flags[ix0 + 3 * w] == 0 and
                    self.nsig[ix0] == 0 and self.nsig[ix0 + w] == 0 and
                    self.nsig[ix0 + 2 * w] == 0 and self.nsig[ix0 + 3 * w] == 0;
                var ea: u32 = 0;
                var idx = ix0;
                var i = ra;
                if (empty) {
                    if (self.mq.bit(self.cx[0..], RUNLEN_CX) == 0) {
                        var k: u32 = 0;
                        while (k < 4) : (k += 1) if (self.nbits[ix0 + k * w] < 255) {
                            self.nbits[ix0 + k * w] += 1;
                        };
                        continue;
                    }
                    ea = (self.mq.bit(self.cx[0..], UNIFORM_CX) << 1) |
                        self.mq.bit(self.cx[0..], UNIFORM_CX);
                    if (ea != 0) {
                        i = ra + ea;
                        idx += ea * w;
                    }
                    self.sign[idx] = @intCast(self.signBit(i, j, idx));
                    self.mag[idx] = 1;
                    self.setNeighbors(i, j, idx);
                    self.flags[idx] |= 2;
                    var k = ix0;
                    var ec = ra;
                    while (ec <= i) : (ec += 1) {
                        if (self.nbits[k] < 255) self.nbits[k] += 1;
                        k += w;
                    }
                    ea += 1;
                }
                i = ra + ea;
                idx = ix0 + ea * w;
                while (i < inext) : (i += 1) {
                    if (self.mag[idx] == 0 and (self.flags[idx] & 1) == 0) {
                        const lbl = self.tab[@min(self.nsig[idx], @as(u8, 78))];
                        if (self.mq.bit(self.cx[0..], lbl) != 0) {
                            self.sign[idx] = @intCast(self.signBit(i, j, idx));
                            self.mag[idx] = 1;
                            self.setNeighbors(i, j, idx);
                            self.flags[idx] |= 2;
                        }
                        if (self.nbits[idx] < 255) self.nbits[idx] += 1;
                    }
                    idx += w;
                }
            }
            ra = inext;
        }
    }

    fn segSymbol(self: *BitModel) void {
        _ = (self.mq.bit(self.cx[0..], UNIFORM_CX) << 3) |
            (self.mq.bit(self.cx[0..], UNIFORM_CX) << 2) |
            (self.mq.bit(self.cx[0..], UNIFORM_CX) << 1) |
            self.mq.bit(self.cx[0..], UNIFORM_CX);
    }
};

// ===== 코드스트림 읽기 =====

const Ctx = struct {
    a: Arena,
    // SIZ
    xsiz: i64 = 0,
    ysiz: i64 = 0,
    xa: i64 = 0,
    ya: i64 = 0,
    xt: i64 = 0,
    yt: i64 = 0,
    xt0: i64 = 0,
    yt0: i64 = 0,
    ncomp: u32 = 0,
    prec: [MAX_COMP]u32 = .{8} ** MAX_COMP,
    /// 관심 구역 올림값 (RGN, 부록 H). 이만큼 올려 담긴 계수를 도로 내린다.
    roi: [MAX_COMP]u32 = .{0} ** MAX_COMP,
    csign: [MAX_COMP]bool = .{false} ** MAX_COMP,
    dx: [MAX_COMP]u32 = .{1} ** MAX_COMP,
    dy: [MAX_COMP]u32 = .{1} ** MAX_COMP,
    cod: Cod = .{},
    coc: [MAX_COMP]Cod = .{Cod{}} ** MAX_COMP,
    has_coc: [MAX_COMP]bool = .{false} ** MAX_COMP,
    qcd: Qcd = .{},
    qcc: [MAX_COMP]Qcd = .{Qcd{}} ** MAX_COMP,
    has_qcc: [MAX_COMP]bool = .{false} ** MAX_COMP,
};

fn readCod(d: []const u8, c: *Cod) void {
    if (d.len < 10) return;
    const scod = d[0];
    c.custom_prec = (scod & 1) != 0;
    c.sop = (scod & 2) != 0;
    c.eph = (scod & 4) != 0;
    c.prog = d[1];
    c.layers = be16(d, 2);
    c.mct = d[4] != 0;
    c.levels = @min(d[5], MAX_LEV);
    c.xcb = @intCast(@min((d[6] & 15) + 2, 10));
    c.ycb = @intCast(@min((d[7] & 15) + 2, 10));
    c.seg_sym = (d[8] & 0x20) != 0;
    c.reset_cx = (d[8] & 0x02) != 0;
    c.reversible = d[9] == 1;
    if (c.custom_prec) {
        var i: u32 = 0;
        while (i <= c.levels and 10 + i < d.len) : (i += 1) {
            c.ppx[i] = @intCast(d[10 + i] & 15);
            c.ppy[i] = @intCast((d[10 + i] >> 4) & 15);
        }
    }
}

/// COC 는 COD 와 앞부분이 다르다 — 성분 하나에만 걸리는 부호 방식이다.
fn readCoc(d: []const u8, base: Cod, c: *Cod) void {
    c.* = base;
    if (d.len < 6) return;
    c.custom_prec = (d[0] & 1) != 0;
    c.levels = @min(d[1], MAX_LEV);
    c.xcb = @intCast(@min((d[2] & 15) + 2, 10));
    c.ycb = @intCast(@min((d[3] & 15) + 2, 10));
    c.seg_sym = (d[4] & 0x20) != 0;
    c.reset_cx = (d[4] & 0x02) != 0;
    c.reversible = d[5] == 1;
    if (c.custom_prec) {
        var i: u32 = 0;
        while (i <= c.levels and 6 + i < d.len) : (i += 1) {
            c.ppx[i] = @intCast(d[6 + i] & 15);
            c.ppy[i] = @intCast((d[6 + i] >> 4) & 15);
        }
    }
}

fn readQcd(d: []const u8, q: *Qcd) void {
    if (d.len < 1) return;
    const s = d[0];
    q.style = s & 0x1F;
    q.guard = s >> 5;
    q.n = 0;
    if (q.style == 0) {
        // 되돌릴 수 있는 방식 — 지수만 온다
        var i: usize = 1;
        while (i < d.len and q.n < q.eps.len) : (i += 1) {
            q.eps[q.n] = d[i] >> 3;
            q.mu[q.n] = 0;
            q.n += 1;
        }
        q.expounded = true;
    } else {
        var i: usize = 1;
        while (i + 1 < d.len and q.n < q.eps.len) : (i += 2) {
            const v = be16(d, i);
            q.eps[q.n] = v >> 11;
            q.mu[q.n] = v & 0x7FF;
            q.n += 1;
        }
        q.expounded = q.style == 2;
    }
    if (q.n == 0) { q.eps[0] = 8; q.mu[0] = 0; q.n = 1; }
}

// ===== 패킷 머리 읽개 =====

const PkR = struct {
    d: []const u8,
    pos: usize = 0,
    buf: u32 = 0,
    n: u32 = 0,
    skip: bool = false,

    fn bits(r: *PkR, cnt: u32) u32 {
        while (r.n < cnt) {
            const b: u32 = if (r.pos < r.d.len) r.d[r.pos] else 0;
            r.pos += 1;
            if (r.skip) {
                r.buf = (r.buf << 7) | b;
                r.n += 7;
                r.skip = false;
            } else {
                r.buf = (r.buf << 8) | b;
                r.n += 8;
            }
            if (b == 0xFF) r.skip = true;
        }
        r.n -= cnt;
        return (r.buf >> @intCast(r.n)) & ((@as(u32, 1) << @intCast(cnt)) - 1);
    }
    fn alignByte(r: *PkR) void {
        r.n = 0;
        if (r.skip) {
            r.pos += 1;
            r.skip = false;
        }
    }
    fn skipMarker(r: *PkR, v: u8) bool {
        if (r.pos > 0 and r.pos - 1 < r.d.len and r.d[r.pos - 1] == 0xFF and
            r.pos < r.d.len and r.d[r.pos] == v)
        {
            r.pos += 1;
            return true;
        }
        if (r.pos + 1 < r.d.len and r.d[r.pos] == 0xFF and r.d[r.pos + 1] == v) {
            r.pos += 2;
            return true;
        }
        return false;
    }
    fn passes(r: *PkR) u32 {
        if (r.bits(1) == 0) return 1;
        if (r.bits(1) == 0) return 2;
        var v = r.bits(2);
        if (v < 3) return v + 3;
        v = r.bits(5);
        if (v < 31) return v + 6;
        return r.bits(7) + 37;
    }
};

fn log2u(v: u32) u32 {
    var n: u32 = 0;
    while ((@as(u32, 1) << @intCast(n)) < v and n < 31) n += 1;
    return n;
}

// ===== 타일 하나 =====

const TComp = struct {
    xa: i64 = 0,
    ya: i64 = 0,
    xb: i64 = 0,
    yb: i64 = 0,
    cod: Cod = .{},
    qcd: Qcd = .{},
    res: []Res = &[_]Res{},
    subs: []Sub = &[_]Sub{},
};

var chunks: []Chunk = &[_]Chunk{};
var chunk_n: u32 = 0;

fn buildTileComp(a: *Arena, tc: *TComp) bool {
    const nlev = tc.cod.levels;
    tc.res = a.take(Res, nlev + 1) orelse return false;
    tc.subs = a.take(Sub, nlev * 3 + 1) orelse return false;
    var nsub: u32 = 0;
    var r: u32 = 0;
    while (r <= nlev) : (r += 1) {
        const scale: i64 = @as(i64, 1) << @intCast(nlev - r);
        const rr = &tc.res[r];
        rr.xa = ceilDiv(tc.xa, scale);
        rr.ya = ceilDiv(tc.ya, scale);
        rr.xb = ceilDiv(tc.xb, scale);
        rr.yb = ceilDiv(tc.yb, scale);
        rr.lev = r;
        rr.ppx = if (tc.cod.custom_prec) tc.cod.ppx[r] else 15;
        rr.ppy = if (tc.cod.custom_prec) tc.cod.ppy[r] else 15;
        rr.xcb = if (r > 0) @min(tc.cod.xcb, @max(rr.ppx, 1) - 1) else @min(tc.cod.xcb, rr.ppx);
        rr.ycb = if (r > 0) @min(tc.cod.ycb, @max(rr.ppy, 1) - 1) else @min(tc.cod.ycb, rr.ppy);
        // 프리싱크트 나누기 (B.6)
        const pw: i64 = @as(i64, 1) << rr.ppx;
        const ph: i64 = @as(i64, 1) << rr.ppy;
        rr.pw = if (rr.xb > rr.xa) @intCast(ceilDiv(rr.xb, pw) - @divFloor(rr.xa, pw)) else 0;
        rr.ph = if (rr.yb > rr.ya) @intCast(ceilDiv(rr.yb, ph) - @divFloor(rr.ya, ph)) else 0;
        rr.nprec = rr.pw * rr.ph;
        // 소대역 (B.5)
        if (r == 0) {
            const s = &tc.subs[nsub];
            s.kind = 0;
            s.xa = rr.xa;
            s.ya = rr.ya;
            s.xb = rr.xb;
            s.yb = rr.yb;
            s.res = r;
            rr.subs[0] = nsub;
            rr.nsub = 1;
            nsub += 1;
        } else {
            const bs: i64 = @as(i64, 1) << @intCast(nlev - r + 1);
            const kinds = [_]u8{ 1, 2, 3 };
            var k: u32 = 0;
            while (k < 3) : (k += 1) {
                const s = &tc.subs[nsub];
                s.kind = kinds[k];
                const hx = kinds[k] == 1 or kinds[k] == 3;
                const hy = kinds[k] == 2 or kinds[k] == 3;
                s.xa = if (hx) ceilDiv(tc.xa - (bs >> 1), bs) else ceilDiv(tc.xa, bs);
                s.xb = if (hx) ceilDiv(tc.xb - (bs >> 1), bs) else ceilDiv(tc.xb, bs);
                s.ya = if (hy) ceilDiv(tc.ya - (bs >> 1), bs) else ceilDiv(tc.ya, bs);
                s.yb = if (hy) ceilDiv(tc.yb - (bs >> 1), bs) else ceilDiv(tc.yb, bs);
                s.res = r;
                rr.subs[k] = nsub;
                nsub += 1;
            }
            rr.nsub = 3;
        }
    }
    // 코드블록 나누기 (B.7)
    var si: u32 = 0;
    while (si < nsub) : (si += 1) {
        const s = &tc.subs[si];
        const rr = &tc.res[s.res];
        const cw: i64 = @as(i64, 1) << rr.xcb;
        const ch: i64 = @as(i64, 1) << rr.ycb;
        if (s.xb <= s.xa or s.yb <= s.ya) continue;
        if (rr.nprec == 0) continue;
        // 프리싱크트는 소대역마다 따로다. 해상도 단위로 묶으면 코드블록
        // 묶음 크기가 섞여 태그트리 모양이 어긋난다.
        s.precs = a.take(Prec, rr.nprec) orelse return false;
        const cbx0 = @divFloor(s.xa, cw);
        const cby0 = @divFloor(s.ya, ch);
        const cbx1 = @divFloor(s.xb + cw - 1, cw);
        const cby1 = @divFloor(s.yb + ch - 1, ch);
        const n: usize = @intCast(@max(0, (cbx1 - cbx0) * (cby1 - cby0)));
        if (n == 0 or n > 1 << 20) continue;
        const buf = a.take(CB, n) orelse return false;
        // 프리싱크트 안 코드블록 묶음 크기
        const zero = rr.lev == 0;
        const pws: i64 = @as(i64, 1) << @intCast(@as(u32, rr.ppx) - (if (zero) @as(u32, 0) else 1));
        const phs: i64 = @as(i64, 1) << @intCast(@as(u32, rr.ppy) - (if (zero) @as(u32, 0) else 1));
        var cnt: usize = 0;
        var j = cby0;
        while (j < cby1) : (j += 1) {
            var i = cbx0;
            while (i < cbx1) : (i += 1) {
                const bx0 = @max(s.xa, cw * i);
                const by0 = @max(s.ya, ch * j);
                const bx1 = @min(s.xb, cw * (i + 1));
                const by1 = @min(s.yb, ch * (j + 1));
                if (bx1 <= bx0 or by1 <= by0) continue;
                const pi: u32 = @intCast(@divFloor(bx0 - s.xa, pws));
                const pj: u32 = @intCast(@divFloor(by0 - s.ya, phs));
                const pn = pi + pj * rr.pw;
                if (pn >= rr.nprec) continue;
                buf[cnt] = .{
                    .cbx = @intCast(i - cbx0), .cby = @intCast(j - cby0),
                    .xa = @intCast(bx0), .ya = @intCast(by0),
                    .xb = @intCast(bx1), .yb = @intCast(by1),
                    .prec = pn, .included = false, .seen = false,
                    .lblock = 3, .zbp = 0, .head = -1, .tail = -1, .passes = 0,
                };
                const p = &s.precs[pn];
                if (!p.has) {
                    p.* = .{ .cbxmin = @intCast(i), .cbymin = @intCast(j),
                        .cbxmax = @intCast(i), .cbymax = @intCast(j), .has = true };
                } else {
                    const ui: u32 = @intCast(i);
                    const uj: u32 = @intCast(j);
                    if (ui < p.cbxmin) p.cbxmin = ui;
                    if (ui > p.cbxmax) p.cbxmax = ui;
                    if (uj < p.cbymin) p.cbymin = uj;
                    if (uj > p.cbymax) p.cbymax = uj;
                }
                cnt += 1;
            }
        }
        s.cbs = buf[0..cnt];
        // 코드블록 안 자리는 프리싱크트 기준으로 다시 매긴다
        var k: usize = 0;
        while (k < cnt) : (k += 1) {
            const p = s.precs[s.cbs[k].prec];
            s.cbs[k].cbx = @intCast(@as(i64, s.cbs[k].cbx) + cbx0 - @as(i64, p.cbxmin));
            s.cbs[k].cby = @intCast(@as(i64, s.cbs[k].cby) + cby0 - @as(i64, p.cbymin));
        }
    }
    return true;
}

// 프리싱크트마다 태그트리 두 그루 (들어있나 · 0 비트평면 수)
var inc_trees: []TT = &[_]TT{};
var zbp_trees: []TT = &[_]TT{};
var tree_n: u32 = 0;

/// 패킷 하나를 읽는다. 코드블록마다 자료 조각을 이어 단다.
fn readPacket(
    a: *Arena, r: *PkR, tc: []TComp, comp: u32, res: u32, prec: u32, layer: u32,
    base: usize,
) bool {
    const rr = &tc[comp].res[res];
    if (prec >= rr.nprec) return true;
    r.alignByte();
    if (tc[comp].cod.sop) {
        if (r.skipMarker(0x91)) r.pos += 4;
    }
    if (r.bits(1) == 0) {
        r.alignByte();
        if (tc[comp].cod.eph) _ = r.skipMarker(0x92);
        return true;
    }
    // 이 패킷에 든 코드블록을 훑는다
    const QN = 4096;
    var q_cb: [QN]*CB = undefined;
    var q_len: [QN]u32 = undefined;
    var q_pass: [QN]u32 = undefined;
    var qn: u32 = 0;

    var si: u32 = 0;
    while (si < rr.nsub) : (si += 1) {
        const s = &tc[comp].subs[rr.subs[si]];
        if (prec >= s.precs.len) continue;
        const p = &s.precs[prec];
        if (!p.has) continue;
        if (!p.built) {
            const w = p.cbxmax - p.cbxmin + 1;
            const h = p.cbymax - p.cbymin + 1;
            if (tree_n >= inc_trees.len) return false;
            p.inc_lv = tree_n;
            inc_trees[tree_n] = TT.make(a, w, h, @intCast(@min(layer, 254))) orelse return false;
            zbp_trees[tree_n] = TT.make(a, w, h, 0) orelse return false;
            tree_n += 1;
            p.built = true;
            var l: u32 = 0;
            while (l < layer) : (l += 1) {
                if (r.bits(1) != 0) return false;
            }
        }
        const inc = &inc_trees[p.inc_lv];
        const zbp = &zbp_trees[p.inc_lv];

        var ci: usize = 0;
        while (ci < s.cbs.len) : (ci += 1) {
            const cb = &s.cbs[ci];
            if (cb.prec != prec) continue;
            var included = false;
            var first = false;
            if (cb.seen) {
                included = r.bits(1) != 0;
            } else {
                if (itReset(inc, cb.cbx, cb.cby, layer)) {
                    while (true) {
                        if (r.bits(1) != 0) {
                            if (!itNext(inc)) {
                                cb.seen = true;
                                included = true;
                                first = true;
                                break;
                            }
                        } else {
                            itInc(inc, layer);
                            break;
                        }
                    }
                }
            }
            if (!included) continue;
            if (first) {
                ttReset(zbp, cb.cbx, cb.cby);
                while (true) {
                    if (r.bits(1) != 0) {
                        if (!ttNext(zbp)) break;
                    } else ttInc(zbp);
                }
                cb.zbp = @intCast(@min(zbp.value, 255));
            }
            const np = r.passes();
            while (r.bits(1) != 0) {
                if (cb.lblock < 32) cb.lblock += 1;
            }
            const lg = log2u(np);
            const bits2 = (if (np < (@as(u32, 1) << @intCast(lg))) lg - 1 else lg) + cb.lblock;
            if (bits2 > 31) return false;
            const dlen = r.bits(bits2);
            if (qn < QN) {
                q_cb[qn] = cb;
                q_len[qn] = dlen;
                q_pass[qn] = np;
                qn += 1;
            }
        }
    }
    r.alignByte();
    if (tc[comp].cod.eph) _ = r.skipMarker(0x92);
    var k: u32 = 0;
    while (k < qn) : (k += 1) {
        const cb = q_cb[k];
        if (chunk_n < chunks.len) {
            chunks[chunk_n] = .{
                .off = @intCast(base + r.pos), .len = q_len[k],
                .passes = q_pass[k], .next = -1,
            };
            if (cb.tail >= 0) chunks[@intCast(cb.tail)].next = @intCast(chunk_n)
            else cb.head = @intCast(chunk_n);
            cb.tail = @intCast(chunk_n);
            cb.passes += q_pass[k];
            chunk_n += 1;
        }
        r.pos += q_len[k];
    }
    return true;
}

// ===== 역웨이블릿 (부록 F) =====

const PAD = 4;

fn extend(x: []f32, off: usize, size: usize) void {
    var ea = off - 1;
    var eb = off + 1;
    var ec = off + size - 2;
    var ed = off + size;
    var k: u32 = 0;
    while (k < 3) : (k += 1) {
        x[ea] = x[eb];
        x[ed] = x[ec];
        if (ea == 0) break;
        ea -= 1;
        eb += 1;
        if (ec == 0) break;
        ec -= 1;
        ed += 1;
    }
    x[ea] = x[eb];
    x[ed] = x[ec];
}

fn filt53(x: []f32, off: usize, len: usize) void {
    const half = len >> 1;
    var j = off;
    var n = half + 1;
    while (n > 0) : (n -= 1) {
        x[j] -= @floor((x[j - 1] + x[j + 1] + 2) / 4);
        j += 2;
    }
    j = off + 1;
    n = half;
    while (n > 0) : (n -= 1) {
        x[j] += @floor((x[j - 1] + x[j + 1]) / 2);
        j += 2;
    }
}

fn filt97(x: []f32, off: usize, len: usize) void {
    const half = len >> 1;
    const alpha: f32 = -1.586134342059924;
    const beta: f32 = -0.052980118572961;
    const gamma: f32 = 0.882911075530934;
    const delta: f32 = 0.443506852043971;
    const K: f32 = 1.230174104914001;
    const Ki: f32 = 1.0 / K;

    var j: usize = off - 3;
    var n: usize = half + 4;
    while (n > 0) : (n -= 1) {
        x[j] *= Ki;
        j += 2;
    }
    j = off - 2;
    n = half + 3;
    var cur = delta * x[j - 1];
    while (n > 0) : (n -= 1) {
        const next = delta * x[j + 1];
        x[j] = K * x[j] - cur - next;
        cur = next;
        j += 2;
    }
    j = off - 1;
    n = half + 2;
    cur = gamma * x[j - 1];
    while (n > 0) : (n -= 1) {
        const next = gamma * x[j + 1];
        x[j] -= cur + next;
        cur = next;
        j += 2;
    }
    j = off;
    n = half + 1;
    cur = beta * x[j - 1];
    while (n > 0) : (n -= 1) {
        const next = beta * x[j + 1];
        x[j] -= cur + next;
        cur = next;
        j += 2;
    }
    if (half != 0) {
        j = off + 1;
        n = half;
        cur = alpha * x[j - 1];
        while (n > 0) : (n -= 1) {
            const next = alpha * x[j + 1];
            x[j] -= cur + next;
            cur = next;
            j += 2;
        }
    }
}

/// LL 을 짝수 자리에 끼워 넣고 가로·세로로 되돌린다 (F.3.3~F.3.5).
fn iterate(
    ll: []f32, llw: u32, llh: u32,
    items: []f32, w: u32, h: u32,
    pu: i64, pv: i64, rev: bool, row: []f32,
) void {
    var i: u32 = 0;
    var k: u32 = 0;
    while (i < llh) : (i += 1) {
        var l = i * 2 * w;
        var j: u32 = 0;
        while (j < llw) : (j += 1) {
            if (l < items.len) items[l] = ll[k];
            k += 1;
            l += 2;
        }
    }
    if (w == 1) {
        if ((pu & 1) != 0) {
            var v: u32 = 0;
            while (v < h) : (v += 1) items[v * w] *= 0.5;
        }
    } else {
        var v: u32 = 0;
        while (v < h) : (v += 1) {
            const at = v * w;
            @memcpy(row[PAD .. PAD + w], items[at .. at + w]);
            extend(row, PAD, w);
            if (rev) filt53(row, PAD, w) else filt97(row, PAD, w);
            @memcpy(items[at .. at + w], row[PAD .. PAD + w]);
        }
    }
    if (h == 1) {
        if ((pv & 1) != 0) {
            var u: u32 = 0;
            while (u < w) : (u += 1) items[u] *= 0.5;
        }
    } else {
        var u: u32 = 0;
        while (u < w) : (u += 1) {
            var y: u32 = 0;
            while (y < h) : (y += 1) row[PAD + y] = items[y * w + u];
            extend(row, PAD, h);
            if (rev) filt53(row, PAD, h) else filt97(row, PAD, h);
            y = 0;
            while (y < h) : (y += 1) items[y * w + u] = row[PAD + y];
        }
    }
}

const GAIN = [_]u32{ 0, 1, 1, 2 };

/// 코드블록 하나를 풀어 계수 배열에 옮긴다.
fn decodeCb(
    a: *Arena, src: []const u8, cb: *CB, kind: u8, mb: u32, delta: f32,
    rev: bool, seg: bool, rstcx: bool,
    coefs: []f32, lw: u32, sx0: i64, sy0: i64, sw: u32, roi: u32,
) void {
    const bw = cb.xb - cb.xa;
    const bh = cb.yb - cb.ya;
    if (bw == 0 or bh == 0 or cb.head < 0) return;
    const n = bw * bh;
    const save = a.used;
    defer a.used = save;

    var bm = BitModel{
        .w = bw, .h = bh, .tab = &LLLH,
        .nsig = a.take(u8, n) orelse return,
        .sign = a.take(u8, n) orelse return,
        .mag = a.take(u32, n) orelse return,
        .flags = a.take(u8, n) orelse return,
        .nbits = a.take(u8, n) orelse return,
        .cx = undefined, .mq = undefined,
    };
    bm.init(kind);
    if (cb.zbp != 0) @memset(bm.nbits, cb.zbp);

    // 조각들을 이어 붙인다
    var total: u32 = 0;
    var ci = cb.head;
    while (ci >= 0) : (ci = chunks[@intCast(ci)].next) total += chunks[@intCast(ci)].len;
    if (total == 0) return;
    const buf = a.take(u8, total) orelse return;
    var at: u32 = 0;
    ci = cb.head;
    while (ci >= 0) : (ci = chunks[@intCast(ci)].next) {
        const c = chunks[@intCast(ci)];
        if (c.off + c.len <= src.len) {
            @memcpy(buf[at..][0..c.len], src[c.off..][0..c.len]);
        }
        at += c.len;
    }
    bm.mq = jb.MQ.init(buf);

    var pass_kind: u32 = 2;
    var p: u32 = 0;
    while (p < cb.passes and p < 200) : (p += 1) {
        switch (pass_kind) {
            0 => bm.passSig(),
            1 => bm.passRef(),
            else => {
                bm.passClean();
                if (seg) bm.segSymbol();
            },
        }
        if (rstcx) bm.reset();
        pass_kind = (pass_kind + 1) % 3;
    }

    // 계수를 제자리에 놓는다. LL 이 아니면 짝·홀 자리에 끼워 넣는다.
    const right: u32 = if (kind == 1 or kind == 3) 1 else 0;
    const bottom: u32 = if (kind == 2 or kind == 3) lw else 0;
    const inter = kind != 0;
    const corr: f32 = if (rev) 0 else 0.5;
    var off: u32 = @intCast((@as(i64, cb.xa) - sx0) + (@as(i64, cb.ya) - sy0) * @as(i64, sw));
    var pos: u32 = 0;
    var j: u32 = 0;
    while (j < bh) : (j += 1) {
        const rw = off / @max(sw, 1);
        const lo = 2 * rw * (lw - sw) + right + bottom;
        var k: u32 = 0;
        while (k < bw) : (k += 1) {
            var m = bm.mag[pos];
            // 관심 구역은 나머지보다 위 비트면에 올려 담는다. 문턱을 넘는
            // 계수는 그만큼 도로 내려야 제 크기가 된다 (부록 H.2).
            if (roi > 0 and m >= (@as(u32, 1) << @intCast(roi))) m >>= @intCast(roi);
            if (m != 0) {
                var v = (@as(f32, @floatFromInt(m)) + corr) * delta;
                if (bm.sign[pos] != 0) v = -v;
                const nb = bm.nbits[pos];
                const dst = if (inter) lo + off * 2 else off;
                if (dst < coefs.len) {
                    coefs[dst] = if (rev and nb >= mb) v
                        else v * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(@min(mb -| nb, 31))));
                }
            }
            off += 1;
            pos += 1;
        }
        off += sw - bw;
    }
}

/// PDF 안의 JPX 그림 하나를 푼다.
/// out 에는 성분을 섞어 8비트로 담는다. arena 는 작업용 자리다.
pub fn decode(
    input: []const u8, arena_buf: []u8, out: []u8,
    ow: *u32, oh: *u32, oc: *u32,
) bool {
    var c = Ctx{ .a = .{ .buf = arena_buf } };
    // JP2 상자면 코드스트림을 꺼낸다
    var src = input;
    if (input.len > 12 and be32(input, 0) == 12 and
        input[4] == 'j' and input[5] == 'P')
    {
        var p: usize = 0;
        var found = false;
        while (p + 8 <= input.len) {
            var len: usize = be32(input, p);
            var hdr: usize = 8;
            const typ = input[p + 4 .. p + 8];
            if (len == 1) {
                if (p + 16 > input.len) break;
                len = @intCast(be32(input, p + 12));
                hdr = 16;
            }
            if (len == 0) len = input.len - p;
            if (len < hdr or p + len > input.len) break;
            if (typ[0] == 'j' and typ[1] == 'p' and typ[2] == '2' and typ[3] == 'c') {
                src = input[p + hdr .. p + len];
                found = true;
                break;
            }
            p += len;
        }
        if (!found) return false;
    }
    if (src.len < 4 or src[0] != 0xFF or src[1] != 0x4F) return false;

    // 표식 훑기 — 머리말과 타일 조각 자리
    const TP = struct { idx: u32, off: u32, len: u32 };
    var tparts: [2048]TP = undefined;
    var tp_n: u32 = 0;
    var i: usize = 2;
    while (i + 2 <= src.len) {
        const m = be16(src, i);
        if (m == 0xFFD9) break;
        if (m < 0xFF00) break;
        if (i + 4 > src.len) break;
        const len = be16(src, i + 2);
        if (len < 2 or i + 2 + len > src.len) break;
        const body = src[i + 4 .. i + 2 + len];
        if (m == 0xFF90) { // SOT — 여기부터 타일 조각이다
            if (body.len < 8) break;
            const tidx = be16(body, 0);
            const psot = be32(body, 2);
            const tend = if (psot > 0) @min(i + psot, src.len) else src.len;
            // SOD 를 찾아 그 뒤가 자료다
            var q = i + 2 + len;
            while (q + 2 <= tend and be16(src, q) != 0xFF93) {
                if (q + 4 > tend) break;
                const l2 = be16(src, q + 2);
                if (l2 < 2) break;
                q += 2 + l2;
            }
            if (q + 2 <= tend and be16(src, q) == 0xFF93 and tp_n < tparts.len) {
                tparts[tp_n] = .{ .idx = tidx, .off = @intCast(q + 2), .len = @intCast(tend - (q + 2)) };
                tp_n += 1;
            }
            i = tend;
            continue;
        }
        switch (m) {
            0xFF51 => { // SIZ
                if (body.len < 36) return false;
                c.xsiz = be32(body, 2);
                c.ysiz = be32(body, 6);
                c.xa = be32(body, 10);
                c.ya = be32(body, 14);
                c.xt = be32(body, 18);
                c.yt = be32(body, 22);
                c.xt0 = be32(body, 26);
                c.yt0 = be32(body, 30);
                c.ncomp = be16(body, 34);
                if (c.ncomp == 0 or c.ncomp > MAX_COMP) return false;
                var k2: u32 = 0;
                while (k2 < c.ncomp) : (k2 += 1) {
                    const at = 36 + k2 * 3;
                    if (at + 2 >= body.len) return false;
                    c.prec[k2] = (body[at] & 0x7F) + 1;
                    c.csign[k2] = (body[at] & 0x80) != 0;
                    c.dx[k2] = @max(body[at + 1], 1);
                    c.dy[k2] = @max(body[at + 2], 1);
                }
            },
            0xFF52 => readCod(body, &c.cod),
            0xFF53 => {
                const ci2: u32 = if (c.ncomp < 257) body[0] else be16(body, 0);
                const skip: usize = if (c.ncomp < 257) 1 else 2;
                if (ci2 < MAX_COMP and body.len > skip) {
                    readCoc(body[skip..], c.cod, &c.coc[ci2]);
                    c.has_coc[ci2] = true;
                }
            },
            0xFF5E => { // RGN — 눈여겨볼 구역만 크게 담아 둔 꼴
                const skip: usize = if (c.ncomp < 257) 1 else 2;
                if (body.len >= skip + 2) {
                    const ci2: u32 = if (c.ncomp < 257) body[0] else be16(body, 0);
                    // Srgn 0 = 문턱 방식. 다른 값은 규격에 없다.
                    if (ci2 < MAX_COMP and body[skip] == 0) c.roi[ci2] = @min(body[skip + 1], 31);
                }
            },
            0xFF5C => readQcd(body, &c.qcd),
            0xFF5D => {
                const ci2: u32 = if (c.ncomp < 257) body[0] else be16(body, 0);
                const skip: usize = if (c.ncomp < 257) 1 else 2;
                if (ci2 < MAX_COMP and body.len > skip) {
                    readQcd(body[skip..], &c.qcc[ci2]);
                    c.has_qcc[ci2] = true;
                }
            },
            else => {},
        }
        i += 2 + len;
    }
    if (c.ncomp == 0 or c.xsiz <= c.xa or c.ysiz <= c.ya or tp_n == 0) return false;

    const iw: u32 = @intCast(c.xsiz - c.xa);
    const ih: u32 = @intCast(c.ysiz - c.ya);
    if (iw == 0 or ih == 0 or @as(u64, iw) * ih > 40_000_000) return false;
    if (out.len < @as(usize, iw) * ih * c.ncomp) return false;
    ow.* = iw;
    oh.* = ih;
    oc.* = c.ncomp;
    if (c.xt <= 0) c.xt = c.xsiz;
    if (c.yt <= 0) c.yt = c.ysiz;

    const comp_px: usize = @as(usize, iw) * ih;
    var planes: [MAX_COMP][]f32 = undefined;
    var k: u32 = 0;
    while (k < c.ncomp) : (k += 1) {
        planes[k] = c.a.take(f32, comp_px) orelse return false;
    }
    const rowbuf = c.a.take(f32, @max(iw, ih) + 2 * PAD + 16) orelse return false;
    const tile_base = c.a.used;

    const ntx: u32 = @intCast(@max(1, ceilDiv(c.xsiz - c.xt0, c.xt)));
    const nty: u32 = @intCast(@max(1, ceilDiv(c.ysiz - c.yt0, c.yt)));
    if (@as(u64, ntx) * nty > 4096) return false;

    var ti: u32 = 0;
    while (ti < ntx * nty) : (ti += 1) {
        // 이 타일의 조각을 모은다
        var total: u32 = 0;
        var pi: u32 = 0;
        while (pi < tp_n) : (pi += 1) if (tparts[pi].idx == ti) { total += tparts[pi].len; };
        if (total == 0) continue;
        c.a.used = tile_base;
        const tdata = c.a.take(u8, total) orelse return false;
        var at: u32 = 0;
        pi = 0;
        while (pi < tp_n) : (pi += 1) {
            if (tparts[pi].idx != ti) continue;
            const o = tparts[pi].off;
            const l = tparts[pi].len;
            if (o + l <= src.len) @memcpy(tdata[at..][0..l], src[o..][0..l]);
            at += l;
        }

        const px2: i64 = @intCast(ti % ntx);
        const py2: i64 = @intCast(ti / ntx);
        const tx0 = @max(c.xt0 + px2 * c.xt, c.xa);
        const ty0 = @max(c.yt0 + py2 * c.yt, c.ya);
        const tx1 = @min(c.xt0 + (px2 + 1) * c.xt, c.xsiz);
        const ty1 = @min(c.yt0 + (py2 + 1) * c.yt, c.ysiz);
        if (tx1 <= tx0 or ty1 <= ty0) continue;

        var tc: [MAX_COMP]TComp = undefined;
        k = 0;
        while (k < c.ncomp) : (k += 1) {
            tc[k] = .{};
            tc[k].xa = ceilDiv(tx0, c.dx[k]);
            tc[k].ya = ceilDiv(ty0, c.dy[k]);
            tc[k].xb = ceilDiv(tx1, c.dx[k]);
            tc[k].yb = ceilDiv(ty1, c.dy[k]);
            tc[k].cod = if (c.has_coc[k]) c.coc[k] else c.cod;
            tc[k].qcd = if (c.has_qcc[k]) c.qcc[k] else c.qcd;
            if (!buildTileComp(&c.a, &tc[k])) return false;
        }
        var nprec_total: u32 = 0;
        k = 0;
        while (k < c.ncomp) : (k += 1) {
            var r2: u32 = 0;
            while (r2 <= tc[k].cod.levels) : (r2 += 1) nprec_total += tc[k].res[r2].nprec * 3;
        }
        inc_trees = c.a.take(TT, nprec_total + 8) orelse return false;
        zbp_trees = c.a.take(TT, nprec_total + 8) orelse return false;
        tree_n = 0;
        chunks = c.a.take(Chunk, @min(200000, 4000 + nprec_total * 32)) orelse return false;
        chunk_n = 0;

        // 패킷 훑기
        {
            var r = PkR{ .d = tdata };
            const maxr = blk: {
                var mx: u32 = 0;
                var kk: u32 = 0;
                while (kk < c.ncomp) : (kk += 1) mx = @max(mx, tc[kk].cod.levels);
                break :blk mx;
            };
            const layers = c.cod.layers;
            var guard: u32 = 0;
            const pk = struct {
                fn go(cc2: *Ctx, rr2: *PkR, tcs: []TComp, comp: u32, res: u32, prc: u32, lay: u32) bool {
                    return readPacket(&cc2.a, rr2, tcs, comp, res, prc, lay, 0);
                }
            }.go;
            switch (c.cod.prog) {
                1 => {
                    var rr: u32 = 0;
                    while (rr <= maxr) : (rr += 1) {
                        var l: u32 = 0;
                        while (l < layers) : (l += 1) {
                            var cc: u32 = 0;
                            while (cc < c.ncomp) : (cc += 1) {
                                if (rr > tc[cc].cod.levels) continue;
                                var pp: u32 = 0;
                                while (pp < tc[cc].res[rr].nprec) : (pp += 1) {
                                    guard += 1;
                                    if (guard > 1_000_000 or r.pos >= tdata.len) break;
                                    if (!pk(&c, &r, tc[0..c.ncomp], cc, rr, pp, l)) break;
                                }
                            }
                        }
                    }
                },
                2, 3, 4 => {
                    var rr: u32 = 0;
                    while (rr <= maxr) : (rr += 1) {
                        var pp: u32 = 0;
                        while (pp < 100000) : (pp += 1) {
                            var any = false;
                            var cc: u32 = 0;
                            while (cc < c.ncomp) : (cc += 1) {
                                if (rr > tc[cc].cod.levels or pp >= tc[cc].res[rr].nprec) continue;
                                any = true;
                                var l: u32 = 0;
                                while (l < layers) : (l += 1) {
                                    guard += 1;
                                    if (guard > 1_000_000 or r.pos >= tdata.len) break;
                                    if (!pk(&c, &r, tc[0..c.ncomp], cc, rr, pp, l)) break;
                                }
                            }
                            if (!any) break;
                        }
                    }
                },
                else => {
                    var l: u32 = 0;
                    while (l < layers) : (l += 1) {
                        var rr: u32 = 0;
                        while (rr <= maxr) : (rr += 1) {
                            var cc: u32 = 0;
                            while (cc < c.ncomp) : (cc += 1) {
                                if (rr > tc[cc].cod.levels) continue;
                                var pp: u32 = 0;
                                while (pp < tc[cc].res[rr].nprec) : (pp += 1) {
                                    guard += 1;
                                    if (guard > 1_000_000 or r.pos >= tdata.len) break;
                                    if (!pk(&c, &r, tc[0..c.ncomp], cc, rr, pp, l)) break;
                                }
                            }
                        }
                    }
                },
            }
        }

        // 성분마다 계수를 채우고 되돌려 그림 자리에 옮긴다
        k = 0;
        while (k < c.ncomp) : (k += 1) {
            const t = &tc[k];
            const nlev = t.cod.levels;
            const rev = t.cod.reversible;
            const save = c.a.used;
            var prev: []f32 = &[_]f32{};
            var pw: u32 = 0;
            var ph: u32 = 0;
            var b: u32 = 0;
            var r: u32 = 0;
            while (r <= nlev) : (r += 1) {
                const rr = &t.res[r];
                const w: u32 = @intCast(@max(0, rr.xb - rr.xa));
                const h: u32 = @intCast(@max(0, rr.yb - rr.ya));
                const cur = c.a.take(f32, @max(@as(usize, w) * h, 1)) orelse return false;
                var si: u32 = 0;
                while (si < rr.nsub) : (si += 1) {
                    const sb = &t.subs[rr.subs[si]];
                    var eps: u32 = undefined;
                    var mu: u32 = undefined;
                    if (!t.qcd.expounded) {
                        mu = t.qcd.mu[0];
                        eps = t.qcd.eps[0] + (if (r > 0) 1 - r else 0);
                    } else {
                        const bi = @min(b, t.qcd.n - 1);
                        mu = t.qcd.mu[bi];
                        eps = t.qcd.eps[bi];
                        b += 1;
                    }
                    const gain = GAIN[sb.kind];
                    const delta: f32 = if (rev) 1 else blk: {
                        const e: i32 = @as(i32, @intCast(c.prec[k] + gain)) - @as(i32, @intCast(eps));
                        var d2: f32 = 1;
                        var q: i32 = 0;
                        if (e > 0) { while (q < e and q < 40) : (q += 1) d2 *= 2; }
                        else { while (q > e and q > -40) : (q -= 1) d2 *= 0.5; }
                        break :blk d2 * (1 + @as(f32, @floatFromInt(mu)) / 2048);
                    };
                    const mb = t.qcd.guard + eps - 1;
                    const sw: u32 = @intCast(@max(0, sb.xb - sb.xa));
                    var ci: usize = 0;
                    while (ci < sb.cbs.len) : (ci += 1) {
                        decodeCb(&c.a, tdata, &sb.cbs[ci], sb.kind, mb, delta, rev,
                            t.cod.seg_sym, t.cod.reset_cx, cur, w, sb.xa, sb.ya, sw, c.roi[k]);
                    }
                }
                if (r > 0 and w > 0 and h > 0) {
                    iterate(prev, pw, ph, cur, w, h, t.xa, t.ya, rev, rowbuf);
                }
                prev = cur;
                pw = w;
                ph = h;
            }
            // 타일 자리에 옮긴다 (부표본이면 늘려서)
            var y: u32 = 0;
            while (y < ih) : (y += 1) {
                const gy = @as(i64, y) + c.ya;
                if (gy < ty0 or gy >= ty1) continue;
                // 성분 한 칸은 그림에서 dx×dy 칸을 덮는다 — 내림이 맞다
                const cy = @divFloor(gy, @as(i64, c.dy[k])) - t.ya;
                const sy: u32 = @intCast(@max(0, @min(@as(i64, @intCast(ph)) - 1, cy)));
                var x: u32 = 0;
                while (x < iw) : (x += 1) {
                    const gx = @as(i64, x) + c.xa;
                    if (gx < tx0 or gx >= tx1) continue;
                    const cx = @divFloor(gx, @as(i64, c.dx[k])) - t.xa;
                    const sx: u32 = @intCast(@max(0, @min(@as(i64, @intCast(pw)) - 1, cx)));
                    planes[k][y * iw + x] = if (pw > 0 and ph > 0) prev[sy * pw + sx] else 0;
                }
            }
            c.a.used = save;
        }
    }

    // 성분 변환 (G.2) 과 8비트로 자르기
    const shift: i32 = @as(i32, @intCast(c.prec[0])) - 8;
    const offv: f32 = @as(f32, @floatFromInt(@as(u32, 128) << @intCast(@max(shift, 0)))) + 0.5;
    const sc: f32 = blk: {
        var v: f32 = 1;
        var q: i32 = 0;
        while (q < shift and q < 24) : (q += 1) v *= 0.5;
        while (q > shift and q > -24) : (q -= 1) v *= 2;
        break :blk v;
    };
    const clamp = struct {
        fn f(v: f32) u8 {
            if (v <= 0) return 0;
            if (v >= 255) return 255;
            return @intFromFloat(v);
        }
    }.f;
    const n = comp_px;
    if (c.cod.mct and c.ncomp >= 3) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const ya = planes[0][j] + offv;
            const yb = planes[1][j];
            const yc = planes[2][j];
            var ca: f32 = undefined;
            var cb2: f32 = undefined;
            var cc: f32 = undefined;
            if (!c.cod.reversible) {
                ca = ya + 1.402 * yc;
                cb2 = ya - 0.34413 * yb - 0.71414 * yc;
                cc = ya + 1.772 * yb;
            } else {
                const g = ya - @floor((yc + yb) / 4);
                ca = g + yc;
                cb2 = g;
                cc = g + yb;
            }
            out[j * c.ncomp] = clamp(ca * sc);
            out[j * c.ncomp + 1] = clamp(cb2 * sc);
            out[j * c.ncomp + 2] = clamp(cc * sc);
            if (c.ncomp == 4) out[j * c.ncomp + 3] = clamp((planes[3][j] + offv) * sc);
        }
    } else {
        k = 0;
        while (k < c.ncomp) : (k += 1) {
            const sh2: i32 = @as(i32, @intCast(c.prec[k])) - 8;
            const off2: f32 = @as(f32, @floatFromInt(@as(u32, 128) << @intCast(@max(sh2, 0)))) + 0.5;
            var s2: f32 = 1;
            var q: i32 = 0;
            while (q < sh2 and q < 24) : (q += 1) s2 *= 0.5;
            while (q > sh2 and q > -24) : (q -= 1) s2 *= 2;
            var j: usize = 0;
            while (j < n) : (j += 1) out[j * c.ncomp + k] = clamp((planes[k][j] + off2) * s2);
        }
    }
    return true;
}
