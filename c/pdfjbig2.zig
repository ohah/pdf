// JBIG2 — 스캔한 문서를 담는 형식.
//
// 팩스(CCITT)와 달리 글자를 낱개로 떼어 사전에 담고, 쪽에는 "몇 번 글자를
// 어디에" 만 적는다. 같은 글자가 수천 번 나오는 문서라 아주 잘 줄어든다.
// 그 대신 푸는 쪽이 할 일이 많다 — 산술 복호기, 사전, 글자 배치.
//
// PDF 안에서는 파일 머리글 없이 세그먼트만 이어 붙인 꼴로 들어온다.
// /DecodeParms 의 /JBIG2Globals 에 사전이 따로 있기도 하다.
//
// 여기서 다루는 것: 보통 영역(산술·MMR), 글자 사전, 글자 영역.
// 다루지 않는 것: 세밀화(refinement), 하프톤, 허프만 사전 — PDF 에서는
// 거의 안 쓰인다.

const ccitt = @import("pdfccitt.zig");

// ===== MQ 산술 복호기 (T.88) =====

const QeRow = struct { qe: u16, nmps: u8, nlps: u8, sw: u8 };
const QE = [_]QeRow{
    .{ .qe = 0x5601, .nmps = 1, .nlps = 1, .sw = 1 },
    .{ .qe = 0x3401, .nmps = 2, .nlps = 6, .sw = 0 },
    .{ .qe = 0x1801, .nmps = 3, .nlps = 9, .sw = 0 },
    .{ .qe = 0x0AC1, .nmps = 4, .nlps = 12, .sw = 0 },
    .{ .qe = 0x0521, .nmps = 5, .nlps = 29, .sw = 0 },
    .{ .qe = 0x0221, .nmps = 38, .nlps = 33, .sw = 0 },
    .{ .qe = 0x5601, .nmps = 7, .nlps = 6, .sw = 1 },
    .{ .qe = 0x5401, .nmps = 8, .nlps = 14, .sw = 0 },
    .{ .qe = 0x4801, .nmps = 9, .nlps = 14, .sw = 0 },
    .{ .qe = 0x3801, .nmps = 10, .nlps = 14, .sw = 0 },
    .{ .qe = 0x3001, .nmps = 11, .nlps = 17, .sw = 0 },
    .{ .qe = 0x2401, .nmps = 12, .nlps = 18, .sw = 0 },
    .{ .qe = 0x1C01, .nmps = 13, .nlps = 20, .sw = 0 },
    .{ .qe = 0x1601, .nmps = 29, .nlps = 21, .sw = 0 },
    .{ .qe = 0x5601, .nmps = 15, .nlps = 14, .sw = 1 },
    .{ .qe = 0x5401, .nmps = 16, .nlps = 14, .sw = 0 },
    .{ .qe = 0x5101, .nmps = 17, .nlps = 15, .sw = 0 },
    .{ .qe = 0x4801, .nmps = 18, .nlps = 16, .sw = 0 },
    .{ .qe = 0x3801, .nmps = 19, .nlps = 17, .sw = 0 },
    .{ .qe = 0x3401, .nmps = 20, .nlps = 18, .sw = 0 },
    .{ .qe = 0x3001, .nmps = 21, .nlps = 19, .sw = 0 },
    .{ .qe = 0x2801, .nmps = 22, .nlps = 19, .sw = 0 },
    .{ .qe = 0x2401, .nmps = 23, .nlps = 20, .sw = 0 },
    .{ .qe = 0x2201, .nmps = 24, .nlps = 21, .sw = 0 },
    .{ .qe = 0x1C01, .nmps = 25, .nlps = 22, .sw = 0 },
    .{ .qe = 0x1801, .nmps = 26, .nlps = 23, .sw = 0 },
    .{ .qe = 0x1601, .nmps = 27, .nlps = 24, .sw = 0 },
    .{ .qe = 0x1401, .nmps = 28, .nlps = 25, .sw = 0 },
    .{ .qe = 0x1201, .nmps = 29, .nlps = 26, .sw = 0 },
    .{ .qe = 0x1101, .nmps = 30, .nlps = 27, .sw = 0 },
    .{ .qe = 0x0AC1, .nmps = 31, .nlps = 28, .sw = 0 },
    .{ .qe = 0x09C1, .nmps = 32, .nlps = 29, .sw = 0 },
    .{ .qe = 0x08A1, .nmps = 33, .nlps = 30, .sw = 0 },
    .{ .qe = 0x0521, .nmps = 34, .nlps = 31, .sw = 0 },
    .{ .qe = 0x0441, .nmps = 35, .nlps = 32, .sw = 0 },
    .{ .qe = 0x02A1, .nmps = 36, .nlps = 33, .sw = 0 },
    .{ .qe = 0x0221, .nmps = 37, .nlps = 34, .sw = 0 },
    .{ .qe = 0x0141, .nmps = 38, .nlps = 35, .sw = 0 },
    .{ .qe = 0x0111, .nmps = 39, .nlps = 36, .sw = 0 },
    .{ .qe = 0x0085, .nmps = 40, .nlps = 37, .sw = 0 },
    .{ .qe = 0x0049, .nmps = 41, .nlps = 38, .sw = 0 },
    .{ .qe = 0x0025, .nmps = 42, .nlps = 39, .sw = 0 },
    .{ .qe = 0x0015, .nmps = 43, .nlps = 40, .sw = 0 },
    .{ .qe = 0x0009, .nmps = 44, .nlps = 41, .sw = 0 },
    .{ .qe = 0x0005, .nmps = 45, .nlps = 42, .sw = 0 },
    .{ .qe = 0x0001, .nmps = 45, .nlps = 43, .sw = 0 },
    .{ .qe = 0x5601, .nmps = 46, .nlps = 46, .sw = 0 },
};

/// 확률 상태 한 칸은 (표 자리 << 1 | 우세 기호) 로 바이트 하나에 담는다.
pub const MQ = struct {
    d: []const u8,
    bp: usize,
    chigh: u32,
    clow: u32,
    a: u32,
    ct: i32,

    pub fn init(d: []const u8) MQ {
        var s = MQ{
            .d = d,
            .bp = 0,
            .chigh = if (d.len > 0) d[0] else 0xFF,
            .clow = 0,
            .a = 0,
            .ct = 0,
        };
        s.byteIn();
        s.chigh = ((s.chigh << 7) & 0xFFFF) | ((s.clow >> 9) & 0x7F);
        s.clow = (s.clow << 7) & 0xFFFF;
        s.ct -= 7;
        s.a = 0x8000;
        return s;
    }

    fn at(s: *const MQ, i: usize) u32 {
        return if (i < s.d.len) s.d[i] else 0xFF;
    }

    fn byteIn(s: *MQ) void {
        if (s.at(s.bp) == 0xFF) {
            if (s.at(s.bp + 1) > 0x8F) {
                s.clow += 0xFF00;
                s.ct = 8;
            } else {
                s.bp += 1;
                s.clow += s.at(s.bp) << 9;
                s.ct = 7;
            }
        } else {
            s.bp += 1;
            s.clow += if (s.bp < s.d.len) s.at(s.bp) << 8 else 0xFF00;
            s.ct = 8;
        }
        if (s.clow > 0xFFFF) {
            s.chigh += s.clow >> 16;
            s.clow &= 0xFFFF;
        }
    }

    pub fn bit(s: *MQ, cx: []u8, pos: usize) u32 {
        if (pos >= cx.len) return 0;
        var icx: u32 = cx[pos] >> 1;
        var mps: u32 = cx[pos] & 1;
        if (icx >= QE.len) icx = 0;
        const q = QE[icx];
        const qe: u32 = q.qe;
        var d: u32 = undefined;
        var a = s.a -% qe;
        if (s.chigh < qe) {
            if (a < qe) {
                a = qe;
                d = mps;
                icx = q.nmps;
            } else {
                a = qe;
                d = 1 ^ mps;
                if (q.sw == 1) mps = d;
                icx = q.nlps;
            }
        } else {
            s.chigh -= qe;
            if ((a & 0x8000) != 0) {
                s.a = a;
                return mps;
            }
            if (a < qe) {
                d = 1 ^ mps;
                if (q.sw == 1) mps = d;
                icx = q.nlps;
            } else {
                d = mps;
                icx = q.nmps;
            }
        }
        while (true) {
            if (s.ct == 0) s.byteIn();
            a <<= 1;
            s.chigh = ((s.chigh << 1) & 0xFFFF) | ((s.clow >> 15) & 1);
            s.clow = (s.clow << 1) & 0xFFFF;
            s.ct -= 1;
            if ((a & 0x8000) != 0) break;
        }
        s.a = a;
        cx[pos] = @intCast((icx << 1) | mps);
        return d;
    }
};

// ===== 정수 복호 (부록 A) =====

const INT_CX = 512;
/// IADH IADW IAEX IAAI IADT IAFS IADS IAIT IARI IARDW IARDH IARDX IARDY
const NPROC = 13;
var int_cx: [NPROC][INT_CX]u8 = undefined;

const OOB: i32 = -0x40000000;

fn decodeInt(mq: *MQ, proc: u32) i32 {
    const cx = int_cx[proc][0..];
    var prev: u32 = 1;
    const rd = struct {
        fn f(m: *MQ, c: []u8, p: *u32, n: u32) u32 {
            var v: u32 = 0;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const b = m.bit(c, p.*);
                p.* = if (p.* < 256) (p.* << 1) | b else ((((p.* << 1) | b) & 511) | 256);
                v = (v << 1) | b;
            }
            return v;
        }
    }.f;
    const sign = rd(mq, cx, &prev, 1);
    var value: u32 = 0;
    if (rd(mq, cx, &prev, 1) == 0) {
        value = rd(mq, cx, &prev, 2);
    } else if (rd(mq, cx, &prev, 1) == 0) {
        value = rd(mq, cx, &prev, 4) + 4;
    } else if (rd(mq, cx, &prev, 1) == 0) {
        value = rd(mq, cx, &prev, 6) + 20;
    } else if (rd(mq, cx, &prev, 1) == 0) {
        value = rd(mq, cx, &prev, 8) + 84;
    } else if (rd(mq, cx, &prev, 1) == 0) {
        value = rd(mq, cx, &prev, 12) + 340;
    } else {
        value = rd(mq, cx, &prev, 32) +% 4436;
    }
    if (sign == 0) return @intCast(@min(value, 0x3FFFFFFF));
    if (value > 0) return -@as(i32, @intCast(@min(value, 0x3FFFFFFF)));
    return OOB;
}

var iaid_cx: [1 << 17]u8 = undefined;

fn decodeIaid(mq: *MQ, code_len: u32) u32 {
    var prev: u32 = 1;
    var i: u32 = 0;
    while (i < code_len) : (i += 1) {
        const b = mq.bit(iaid_cx[0..], prev);
        prev = (prev << 1) | b;
    }
    if (code_len >= 31) return prev & 0x7FFFFFFF;
    return prev & ((@as(u32, 1) << @intCast(code_len)) - 1);
}

// ===== 낱장 그림 =====

/// 할 일 예산.
///
/// 망가진 파일은 5000×7000 짜리 영역을 수백 개 적어 놓을 수 있다. 하나에
/// 0.7 초씩 걸리므로 그대로 두면 탭이 멎는다. 푼 점 수를 세어 넘으면 그만둔다.
/// 실제 스캔 한 장(5188×6930, 글자 만 이천 자)이 1억 3천만쯤 쓴다.
/// 그 두 배를 준다 — 더 주면 망가진 파일 하나에 몇 초를 쓰게 된다.
const BUDGET: i64 = 260_000_000;
pub var work: i64 = 0;

pub const POOL = 8 * 1024 * 1024;
/// 낱장 그림을 담는 곳간. 바깥(pdf.zig)이 자리를 잡아 준다 — 여기서
/// 정적 배열로 두면 JBIG2 가 없는 문서도 8MB 를 들고 시작한다.
var pool_at: usize = 0;
var pool_used: u32 = 0;
pub fn setPool(at: usize) void { pool_at = at; }
fn pool() []u8 {
    if (pool_at == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(pool_at))[0..POOL];
}

/// 낱장 그림. 자기 자리를 들고 다닌다 — 쪽 그림은 부른 쪽 버퍼를 그대로
/// 가리켜, 스캔 한 장이 4MB 를 넘어도 곳간을 두 번 쓰지 않는다.
pub const BM = struct {
    w: u32 = 0,
    h: u32 = 0,
    stride: u32 = 0,
    d: []u8 = &[_]u8{},

    fn get(s: BM, x: i32, y: i32) u32 {
        if (x < 0 or y < 0) return 0;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= s.w or uy >= s.h) return 0;
        const at = uy * s.stride + (ux >> 3);
        if (at >= s.d.len) return 0;
        return (s.d[at] >> @intCast(7 - (ux & 7))) & 1;
    }
    fn put(s: BM, x: u32, y: u32, v: u32) void {
        if (x >= s.w or y >= s.h) return;
        const at = y * s.stride + (x >> 3);
        if (at >= s.d.len) return;
        const m: u8 = @as(u8, 1) << @intCast(7 - (x & 7));
        if (v != 0) s.d[at] |= m else s.d[at] &= ~m;
    }
};

fn wrap(w: u32, h: u32, d: []u8) BM {
    return .{ .w = w, .h = h, .stride = (w + 7) / 8, .d = d };
}

fn alloc(w: u32, h: u32) ?BM {
    if (w == 0 or h == 0 or w > 1 << 16 or h > 1 << 16) return null;
    const stride = (w + 7) / 8;
    const need = stride * h;
    if (pool_at == 0 or need > POOL - pool_used) return null;
    const at = pool_used;
    @memset(pool()[at..][0..need], 0);
    pool_used += need;
    return BM{ .w = w, .h = h, .stride = stride, .d = pool()[at..][0..need] };
}

// ===== 보통 영역 (6.2) =====

const Pt = struct { x: i8, y: i8 };
const TEMPL = [4][]const Pt{
    &[_]Pt{
        .{ .x = -1, .y = -2 }, .{ .x = 0, .y = -2 }, .{ .x = 1, .y = -2 },
        .{ .x = -2, .y = -1 }, .{ .x = -1, .y = -1 }, .{ .x = 0, .y = -1 },
        .{ .x = 1, .y = -1 },  .{ .x = 2, .y = -1 },  .{ .x = -4, .y = 0 },
        .{ .x = -3, .y = 0 },  .{ .x = -2, .y = 0 },  .{ .x = -1, .y = 0 },
    },
    &[_]Pt{
        .{ .x = -1, .y = -2 }, .{ .x = 0, .y = -2 },  .{ .x = 1, .y = -2 },
        .{ .x = 2, .y = -2 },  .{ .x = -2, .y = -1 }, .{ .x = -1, .y = -1 },
        .{ .x = 0, .y = -1 },  .{ .x = 1, .y = -1 },  .{ .x = 2, .y = -1 },
        .{ .x = -3, .y = 0 },  .{ .x = -2, .y = 0 },  .{ .x = -1, .y = 0 },
    },
    &[_]Pt{
        .{ .x = -1, .y = -2 }, .{ .x = 0, .y = -2 },  .{ .x = 1, .y = -2 },
        .{ .x = -2, .y = -1 }, .{ .x = -1, .y = -1 }, .{ .x = 0, .y = -1 },
        .{ .x = 1, .y = -1 },  .{ .x = -2, .y = 0 },  .{ .x = -1, .y = 0 },
    },
    &[_]Pt{
        .{ .x = -3, .y = -1 }, .{ .x = -2, .y = -1 }, .{ .x = -1, .y = -1 },
        .{ .x = 0, .y = -1 },  .{ .x = 1, .y = -1 },  .{ .x = -4, .y = 0 },
        .{ .x = -3, .y = 0 },  .{ .x = -2, .y = 0 },  .{ .x = -1, .y = 0 },
    },
};
/// 줄이 앞줄과 같을 때 쓰는 자리표 (규격 값)
const SLTP_CX = [4]u32{ 0x9B25, 0x0795, 0x00E5, 0x0195 };

var gb_cx: [1 << 16]u8 = undefined;

/// 보통 영역 하나를 푼다. cx 를 넘기면 사전 안에서 이어 쓴다.
fn decodeGeneric(
    mq: *MQ, bm: BM, tmpl: u32, at: []const Pt, tpgdon: bool, cx: []u8,
) void {
    // 밑틀과 AT 점을 합쳐 위에서 아래로, 왼쪽에서 오른쪽으로 세운다.
    // 자리표 번호가 규격과 같아지도록 이 차례를 지킨다.
    var pts: [16]Pt = undefined;
    var n: u32 = 0;
    const base = TEMPL[@min(tmpl, 3)];
    for (base) |p| {
        if (n < 16) { pts[n] = p; n += 1; }
    }
    for (at) |p| {
        if (n < 16) { pts[n] = p; n += 1; }
    }
    // 삽입 정렬 — 열여섯 개뿐이다
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const key = pts[i];
        var j: i32 = @as(i32, @intCast(i)) - 1;
        while (j >= 0) : (j -= 1) {
            const q = pts[@intCast(j)];
            if (q.y < key.y or (q.y == key.y and q.x <= key.x)) break;
            pts[@intCast(j + 1)] = q;
        }
        pts[@intCast(j + 1)] = key;
    }

    // 여기 한 점은 이웃 열여섯 칸을 보고 산술 복호까지 한다. 그림을 얹는
    // 일보다 훨씬 비싸므로 값을 더 쳐서 뺀다.
    work -= @as(i64, bm.w) * @as(i64, bm.h) * 4;
    if (work < 0) return;
    var ltp: u32 = 0;
    var y: u32 = 0;
    while (y < bm.h) : (y += 1) {
        if (tpgdon) {
            ltp ^= mq.bit(cx, SLTP_CX[@min(tmpl, 3)]);
            if (ltp != 0) {
                // 앞줄을 그대로 베낀다
                if (y > 0) {
                    const src = (y - 1) * bm.stride;
                    const dst2 = y * bm.stride;
                    if (dst2 + bm.stride <= bm.d.len)
                        @memcpy(bm.d[dst2..][0..bm.stride], bm.d[src..][0..bm.stride]);
                }
                continue;
            }
        }
        var x: u32 = 0;
        while (x < bm.w) : (x += 1) {
            var ctx: u32 = 0;
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                ctx = (ctx << 1) | bm.get(
                    @as(i32, @intCast(x)) + pts[k].x,
                    @as(i32, @intCast(y)) + pts[k].y,
                );
            }
            bm.put(x, y, mq.bit(cx, ctx));
        }
    }
}

// ===== 허프만 (부록 B) =====
//
// 산술 부호 대신 표를 쓰는 판이다. 규격이 정해 둔 표 열다섯 개가 있고,
// 줄마다 "앞자리 길이·범위 비트 수·범위 시작" 이 적혀 있다. 앞자리는
// 길이만 주어지므로 규격의 차례(B.3)대로 번호를 매겨 쓴다.
const HL = struct { pre: u8, rlen: u8, low: i32, kind: u8 = 0 }; // kind 1 아래범위 2 OOB

const HT1 = [_]HL{ .{ .pre = 1, .rlen = 4, .low = 0 }, .{ .pre = 2, .rlen = 8, .low = 16 }, .{ .pre = 3, .rlen = 16, .low = 272 }, .{ .pre = 3, .rlen = 32, .low = 65808 } };
const HT2 = [_]HL{ .{ .pre = 1, .rlen = 0, .low = 0 }, .{ .pre = 2, .rlen = 0, .low = 1 }, .{ .pre = 3, .rlen = 0, .low = 2 }, .{ .pre = 4, .rlen = 3, .low = 3 }, .{ .pre = 5, .rlen = 6, .low = 11 }, .{ .pre = 6, .rlen = 32, .low = 75 }, .{ .pre = 6, .rlen = 0, .low = 0, .kind = 2 } };
const HT3 = [_]HL{ .{ .pre = 8, .rlen = 8, .low = -256 }, .{ .pre = 1, .rlen = 0, .low = 0 }, .{ .pre = 2, .rlen = 0, .low = 1 }, .{ .pre = 3, .rlen = 0, .low = 2 }, .{ .pre = 4, .rlen = 3, .low = 3 }, .{ .pre = 5, .rlen = 6, .low = 11 }, .{ .pre = 8, .rlen = 32, .low = -257, .kind = 1 }, .{ .pre = 7, .rlen = 32, .low = 75 }, .{ .pre = 6, .rlen = 0, .low = 0, .kind = 2 } };
const HT4 = [_]HL{ .{ .pre = 1, .rlen = 0, .low = 1 }, .{ .pre = 2, .rlen = 0, .low = 2 }, .{ .pre = 3, .rlen = 0, .low = 3 }, .{ .pre = 4, .rlen = 3, .low = 4 }, .{ .pre = 5, .rlen = 6, .low = 12 }, .{ .pre = 5, .rlen = 32, .low = 76 } };
const HT5 = [_]HL{ .{ .pre = 7, .rlen = 8, .low = -255 }, .{ .pre = 1, .rlen = 0, .low = 1 }, .{ .pre = 2, .rlen = 0, .low = 2 }, .{ .pre = 3, .rlen = 0, .low = 3 }, .{ .pre = 4, .rlen = 3, .low = 4 }, .{ .pre = 5, .rlen = 6, .low = 12 }, .{ .pre = 7, .rlen = 32, .low = -256, .kind = 1 }, .{ .pre = 6, .rlen = 32, .low = 76 } };
const HT6 = [_]HL{ .{ .pre = 5, .rlen = 10, .low = -2048 }, .{ .pre = 4, .rlen = 9, .low = -1024 }, .{ .pre = 4, .rlen = 8, .low = -512 }, .{ .pre = 4, .rlen = 7, .low = -256 }, .{ .pre = 5, .rlen = 6, .low = -128 }, .{ .pre = 5, .rlen = 5, .low = -64 }, .{ .pre = 4, .rlen = 5, .low = -32 }, .{ .pre = 2, .rlen = 7, .low = 0 }, .{ .pre = 3, .rlen = 7, .low = 128 }, .{ .pre = 3, .rlen = 8, .low = 256 }, .{ .pre = 4, .rlen = 9, .low = 512 }, .{ .pre = 4, .rlen = 10, .low = 1024 }, .{ .pre = 6, .rlen = 32, .low = -2049, .kind = 1 }, .{ .pre = 6, .rlen = 32, .low = 2048 } };
const HT7 = [_]HL{ .{ .pre = 4, .rlen = 9, .low = -1024 }, .{ .pre = 3, .rlen = 8, .low = -512 }, .{ .pre = 4, .rlen = 7, .low = -256 }, .{ .pre = 5, .rlen = 6, .low = -128 }, .{ .pre = 5, .rlen = 5, .low = -64 }, .{ .pre = 4, .rlen = 5, .low = -32 }, .{ .pre = 4, .rlen = 9, .low = 0 }, .{ .pre = 5, .rlen = 10, .low = 512 }, .{ .pre = 3, .rlen = 10, .low = 1536 }, .{ .pre = 6, .rlen = 32, .low = -1025, .kind = 1 }, .{ .pre = 6, .rlen = 32, .low = 2560 } };
const HT8 = [_]HL{ .{ .pre = 8, .rlen = 3, .low = -15 }, .{ .pre = 9, .rlen = 1, .low = -7 }, .{ .pre = 8, .rlen = 1, .low = -5 }, .{ .pre = 9, .rlen = 0, .low = -3 }, .{ .pre = 7, .rlen = 0, .low = -2 }, .{ .pre = 4, .rlen = 0, .low = -1 }, .{ .pre = 2, .rlen = 1, .low = 0 }, .{ .pre = 5, .rlen = 0, .low = 2 }, .{ .pre = 6, .rlen = 0, .low = 3 }, .{ .pre = 3, .rlen = 4, .low = 4 }, .{ .pre = 6, .rlen = 1, .low = 20 }, .{ .pre = 4, .rlen = 4, .low = 22 }, .{ .pre = 4, .rlen = 5, .low = 38 }, .{ .pre = 5, .rlen = 6, .low = 70 }, .{ .pre = 5, .rlen = 7, .low = 134 }, .{ .pre = 6, .rlen = 7, .low = 262 }, .{ .pre = 7, .rlen = 8, .low = 390 }, .{ .pre = 6, .rlen = 10, .low = 646 }, .{ .pre = 9, .rlen = 32, .low = -16, .kind = 1 }, .{ .pre = 9, .rlen = 32, .low = 1670 }, .{ .pre = 2, .rlen = 0, .low = 0, .kind = 2 } };
const HT9 = [_]HL{ .{ .pre = 8, .rlen = 4, .low = -31 }, .{ .pre = 9, .rlen = 2, .low = -15 }, .{ .pre = 8, .rlen = 2, .low = -11 }, .{ .pre = 9, .rlen = 1, .low = -7 }, .{ .pre = 7, .rlen = 1, .low = -5 }, .{ .pre = 4, .rlen = 1, .low = -3 }, .{ .pre = 3, .rlen = 1, .low = -1 }, .{ .pre = 3, .rlen = 1, .low = 1 }, .{ .pre = 5, .rlen = 1, .low = 3 }, .{ .pre = 6, .rlen = 1, .low = 5 }, .{ .pre = 3, .rlen = 5, .low = 7 }, .{ .pre = 6, .rlen = 2, .low = 39 }, .{ .pre = 4, .rlen = 5, .low = 43 }, .{ .pre = 4, .rlen = 6, .low = 75 }, .{ .pre = 5, .rlen = 7, .low = 139 }, .{ .pre = 5, .rlen = 8, .low = 267 }, .{ .pre = 6, .rlen = 8, .low = 523 }, .{ .pre = 7, .rlen = 9, .low = 779 }, .{ .pre = 6, .rlen = 11, .low = 1291 }, .{ .pre = 9, .rlen = 32, .low = -32, .kind = 1 }, .{ .pre = 9, .rlen = 32, .low = 3339 }, .{ .pre = 2, .rlen = 0, .low = 0, .kind = 2 } };
const HT10 = [_]HL{ .{ .pre = 7, .rlen = 4, .low = -21 }, .{ .pre = 8, .rlen = 0, .low = -5 }, .{ .pre = 7, .rlen = 0, .low = -4 }, .{ .pre = 5, .rlen = 0, .low = -3 }, .{ .pre = 2, .rlen = 2, .low = -2 }, .{ .pre = 5, .rlen = 0, .low = 2 }, .{ .pre = 6, .rlen = 0, .low = 3 }, .{ .pre = 7, .rlen = 0, .low = 4 }, .{ .pre = 8, .rlen = 0, .low = 5 }, .{ .pre = 2, .rlen = 6, .low = 6 }, .{ .pre = 5, .rlen = 5, .low = 70 }, .{ .pre = 6, .rlen = 5, .low = 102 }, .{ .pre = 7, .rlen = 6, .low = 134 }, .{ .pre = 8, .rlen = 7, .low = 198 }, .{ .pre = 9, .rlen = 8, .low = 326 }, .{ .pre = 9, .rlen = 9, .low = 582 }, .{ .pre = 9, .rlen = 10, .low = 1094 }, .{ .pre = 6, .rlen = 32, .low = -22, .kind = 1 }, .{ .pre = 9, .rlen = 32, .low = 2118 }, .{ .pre = 2, .rlen = 0, .low = 0, .kind = 2 } };
const HT11 = [_]HL{ .{ .pre = 1, .rlen = 0, .low = 1 }, .{ .pre = 2, .rlen = 1, .low = 2 }, .{ .pre = 4, .rlen = 0, .low = 4 }, .{ .pre = 4, .rlen = 1, .low = 5 }, .{ .pre = 5, .rlen = 1, .low = 7 }, .{ .pre = 5, .rlen = 2, .low = 9 }, .{ .pre = 6, .rlen = 2, .low = 13 }, .{ .pre = 7, .rlen = 2, .low = 17 }, .{ .pre = 7, .rlen = 3, .low = 21 }, .{ .pre = 7, .rlen = 4, .low = 29 }, .{ .pre = 7, .rlen = 5, .low = 45 }, .{ .pre = 7, .rlen = 6, .low = 77 }, .{ .pre = 7, .rlen = 32, .low = 141 } };
const HT12 = [_]HL{ .{ .pre = 1, .rlen = 0, .low = 1 }, .{ .pre = 2, .rlen = 0, .low = 2 }, .{ .pre = 3, .rlen = 1, .low = 3 }, .{ .pre = 5, .rlen = 0, .low = 5 }, .{ .pre = 5, .rlen = 1, .low = 6 }, .{ .pre = 6, .rlen = 1, .low = 8 }, .{ .pre = 7, .rlen = 0, .low = 10 }, .{ .pre = 7, .rlen = 1, .low = 11 }, .{ .pre = 7, .rlen = 2, .low = 13 }, .{ .pre = 7, .rlen = 3, .low = 17 }, .{ .pre = 7, .rlen = 4, .low = 25 }, .{ .pre = 8, .rlen = 5, .low = 41 }, .{ .pre = 8, .rlen = 32, .low = 73 } };
const HT13 = [_]HL{ .{ .pre = 1, .rlen = 0, .low = 1 }, .{ .pre = 3, .rlen = 0, .low = 2 }, .{ .pre = 4, .rlen = 0, .low = 3 }, .{ .pre = 5, .rlen = 0, .low = 4 }, .{ .pre = 4, .rlen = 1, .low = 5 }, .{ .pre = 3, .rlen = 3, .low = 7 }, .{ .pre = 6, .rlen = 1, .low = 15 }, .{ .pre = 6, .rlen = 2, .low = 17 }, .{ .pre = 6, .rlen = 3, .low = 21 }, .{ .pre = 6, .rlen = 4, .low = 29 }, .{ .pre = 6, .rlen = 5, .low = 45 }, .{ .pre = 7, .rlen = 6, .low = 77 }, .{ .pre = 7, .rlen = 32, .low = 141 } };
const HT14 = [_]HL{ .{ .pre = 3, .rlen = 0, .low = -2 }, .{ .pre = 3, .rlen = 0, .low = -1 }, .{ .pre = 1, .rlen = 0, .low = 0 }, .{ .pre = 3, .rlen = 0, .low = 1 }, .{ .pre = 3, .rlen = 0, .low = 2 } };
const HT15 = [_]HL{ .{ .pre = 7, .rlen = 4, .low = -24 }, .{ .pre = 6, .rlen = 2, .low = -8 }, .{ .pre = 5, .rlen = 1, .low = -4 }, .{ .pre = 4, .rlen = 0, .low = -2 }, .{ .pre = 3, .rlen = 0, .low = -1 }, .{ .pre = 1, .rlen = 0, .low = 0 }, .{ .pre = 3, .rlen = 0, .low = 1 }, .{ .pre = 4, .rlen = 0, .low = 2 }, .{ .pre = 5, .rlen = 1, .low = 3 }, .{ .pre = 6, .rlen = 2, .low = 5 }, .{ .pre = 7, .rlen = 4, .low = 9 }, .{ .pre = 7, .rlen = 32, .low = -25, .kind = 1 }, .{ .pre = 7, .rlen = 32, .low = 25 } };

fn stdTable(n: u32) []const HL {
    return switch (n) {
        1 => &HT1, 2 => &HT2, 3 => &HT3, 4 => &HT4, 5 => &HT5,
        6 => &HT6, 7 => &HT7, 8 => &HT8, 9 => &HT9, 10 => &HT10,
        11 => &HT11, 12 => &HT12, 13 => &HT13, 14 => &HT14, else => &HT15,
    };
}

/// 앞자리 번호를 길이순으로 매긴다 (B.3).
fn assignCodes(pre: []const u8, codes: []u32) void {
    var cnt: [33]u32 = .{0} ** 33;
    for (pre) |v| if (v > 0 and v <= 32) { cnt[v] += 1; };
    var first: [34]u32 = .{0} ** 34;
    var curcode: u32 = 0;
    var len: u32 = 1;
    while (len <= 32) : (len += 1) {
        curcode = (curcode + cnt[len - 1]) << 1;
        first[len] = curcode;
        var i: u32 = 0;
        while (i < pre.len) : (i += 1) {
            if (pre[i] == len) {
                codes[i] = first[len];
                first[len] += 1;
            }
        }
    }
}

const BitR = struct {
    d: []const u8,
    bit: u64 = 0,

    fn get1(s: *BitR) u32 {
        const byte: usize = @intCast(s.bit >> 3);
        const v: u32 = if (byte < s.d.len) (s.d[byte] >> @intCast(7 - (s.bit & 7))) & 1 else 0;
        s.bit += 1;
        return v;
    }
    fn getn(s: *BitR, n: u32) u32 {
        var v: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) v = (v << 1) | s.get1();
        return v;
    }
    fn byteAlign(s: *BitR) void { s.bit = (s.bit + 7) & ~@as(u64, 7); }
    fn pos(s: *const BitR) usize { return @intCast((s.bit + 7) >> 3); }
    fn done(s: *const BitR) bool { return (s.bit >> 3) >= s.d.len; }
};

/// 표 하나로 값을 읽는다. OOB 면 false.
fn hRead(lines: []const HL, codes: []const u32, r: *BitR, out: *i32) bool {
    var len: u32 = 0;
    var code: u32 = 0;
    while (len < 32) {
        code = (code << 1) | r.get1();
        len += 1;
        var i: u32 = 0;
        while (i < lines.len) : (i += 1) {
            if (lines[i].pre != len or codes[i] != code) continue;
            if (lines[i].kind == 2) return false; // OOB
            const n = lines[i].rlen;
            const v: i64 = @intCast(r.getn(n));
            out.* = @intCast(@max(-1000000000, @min(1000000000,
                if (lines[i].kind == 1) @as(i64, lines[i].low) - v else @as(i64, lines[i].low) + v)));
            return true;
        }
        if (r.done() and len > 24) break;
    }
    out.* = 0;
    return false;
}

var hcodes: [8][64]u32 = undefined;

fn prepTable(slot: u32, lines: []const HL) void {
    var pre: [64]u8 = undefined;
    var i: u32 = 0;
    while (i < lines.len and i < 64) : (i += 1) pre[i] = lines[i].pre;
    assignCodes(pre[0..@min(lines.len, 64)], hcodes[slot][0..@min(lines.len, 64)]);
}

// ===== 문서가 제 표를 싣는 꼴 (B.2.3) =====
//
// 규격의 표 열다섯 개로 모자라면 문서가 표를 직접 담아 온다(세그먼트 53).
// "낮은 값부터 범위를 몇 비트로 적는다" 를 줄줄이 늘어놓은 꼴이라,
// 읽으면서 low 를 더해 가면 규격 표와 같은 모양이 된다.
const MAX_CTAB = 12;
var ctab_num: [MAX_CTAB]u32 = undefined;
var ctab_line: [MAX_CTAB][64]HL = undefined;
var ctab_len: [MAX_CTAB]u32 = undefined;
var ctab_n: u32 = 0;

fn resetTables() void {
    ctab_n = 0;
    tsel_n = 0;
    tsel_at = 0;
}

fn readTableSeg(d: []const u8, num: u32) bool {
    if (d.len < 9 or ctab_n >= MAX_CTAB) return false;
    const flags = d[0];
    const oob = (flags & 1) != 0;
    const ps: u32 = ((flags >> 1) & 7) + 1;
    const rs: u32 = ((flags >> 4) & 7) + 1;
    const low: i32 = @bitCast(be32(d, 1));
    const high: i32 = @bitCast(be32(d, 5));
    if (high <= low) return false;
    var r = BitR{ .d = d[9..] };
    var n: u32 = 0;
    var cur: i64 = low;
    while (cur < high and n < 60 and !r.done()) {
        const pre = r.getn(ps);
        const rlen = r.getn(rs);
        ctab_line[ctab_n][n] = .{
            .pre = @intCast(@min(pre, 32)),
            .rlen = @intCast(@min(rlen, 32)),
            .low = @intCast(cur),
        };
        n += 1;
        if (rlen >= 32) break;
        cur += @as(i64, 1) << @intCast(rlen);
    }
    // 범위 아래·위로 벗어나는 줄, 그리고 있으면 OOB 줄
    if (n + 3 > 60) return false;
    ctab_line[ctab_n][n] = .{ .pre = @intCast(@min(r.getn(ps), 32)), .rlen = 32, .low = low - 1, .kind = 1 };
    n += 1;
    ctab_line[ctab_n][n] = .{ .pre = @intCast(@min(r.getn(ps), 32)), .rlen = 32, .low = high };
    n += 1;
    if (oob) {
        ctab_line[ctab_n][n] = .{ .pre = @intCast(@min(r.getn(ps), 32)), .rlen = 0, .low = 0, .kind = 2 };
        n += 1;
    }
    ctab_num[ctab_n] = num;
    ctab_len[ctab_n] = n;
    ctab_n += 1;
    return true;
}

/// 이 세그먼트가 가리키는 표들을 적힌 차례대로 줄 세운다.
/// 고름값 3(직접 실은 표)이 나올 때마다 앞에서부터 하나씩 꺼내 쓴다.
var tsel: [MAX_CTAB]u32 = undefined;
var tsel_n: u32 = 0;
var tsel_at: u32 = 0;

fn gatherTables(refs: []const u32) void {
    tsel_n = 0;
    tsel_at = 0;
    for (refs) |rf| {
        var i: u32 = 0;
        while (i < ctab_n) : (i += 1) {
            if (ctab_num[i] == rf and tsel_n < tsel.len) {
                tsel[tsel_n] = i;
                tsel_n += 1;
            }
        }
    }
}

/// 고름값대로 표를 고른다. 3 이면 실려 온 표를 차례로 꺼낸다.
fn pickTable(sel: u32, a: u32, b: u32, c: u32) ?[]const HL {
    return switch (sel) {
        0 => stdTable(a),
        1 => stdTable(b),
        2 => if (c == 0) null else stdTable(c),
        else => blk: {
            if (tsel_at >= tsel_n) break :blk null;
            const i = tsel[tsel_at];
            tsel_at += 1;
            break :blk ctab_line[i][0..ctab_len[i]];
        },
    };
}

// ===== 세밀화 (6.3) =====
//
// 이미 있는 그림을 밑그림 삼아 조금씩 고쳐 그린다. 같은 글자가 살짝
// 다르게 찍힌 스캔 문서에서, 사전의 글자를 가져다 다듬는 데 쓴다.
const RTEMPL_C = [2][]const Pt{
    &[_]Pt{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = -1, .y = 0 } },
    &[_]Pt{ .{ .x = -1, .y = -1 }, .{ .x = 0, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = -1, .y = 0 } },
};
const RTEMPL_R = [2][]const Pt{
    &[_]Pt{
        .{ .x = 0, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = -1, .y = 0 }, .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },  .{ .x = -1, .y = 1 }, .{ .x = 0, .y = 1 },  .{ .x = 1, .y = 1 },
    },
    &[_]Pt{
        .{ .x = 0, .y = -1 }, .{ .x = -1, .y = 0 }, .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },  .{ .x = 0, .y = 1 },  .{ .x = 1, .y = 1 },
    },
};
const RSLTP_CX = [2]u32{ 0x0020, 0x0008 };
var gr_cx: [1 << 13]u8 = undefined;

fn decodeRefine(
    mq: *MQ, bm: BM, ref: BM, dx: i32, dy: i32,
    tmpl: u32, at: []const Pt, tpgron: bool, cx: []u8,
) void {
    work -= @as(i64, bm.w) * @as(i64, bm.h) * 4;
    if (work < 0) return;
    const t = @min(tmpl, 1);
    var cod: [8]Pt = undefined;
    var cn: u32 = 0;
    for (RTEMPL_C[t]) |q| { cod[cn] = q; cn += 1; }
    if (t == 0 and at.len >= 1) { cod[cn] = at[0]; cn += 1; }
    var rf: [12]Pt = undefined;
    var rn: u32 = 0;
    for (RTEMPL_R[t]) |q| { rf[rn] = q; rn += 1; }
    if (t == 0 and at.len >= 2) { rf[rn] = at[1]; rn += 1; }

    var ltp: u32 = 0;
    var y: u32 = 0;
    while (y < bm.h) : (y += 1) {
        if (tpgron) ltp ^= mq.bit(cx, RSLTP_CX[t]);
        var x: u32 = 0;
        while (x < bm.w) : (x += 1) {
            const ix: i32 = @intCast(x);
            const iy: i32 = @intCast(y);
            if (ltp != 0) {
                // 밑그림의 둘레 아홉 칸이 한 색이면 그대로 베낀다
                var all1: u32 = 1;
                var any1: u32 = 0;
                var oy: i32 = -1;
                while (oy <= 1) : (oy += 1) {
                    var ox: i32 = -1;
                    while (ox <= 1) : (ox += 1) {
                        const v = ref.get(ix - dx + ox, iy - dy + oy);
                        all1 &= v;
                        any1 |= v;
                    }
                }
                if (all1 == 1 or any1 == 0) {
                    bm.put(x, y, all1);
                    continue;
                }
            }
            var ctx: u32 = 0;
            var k: u32 = 0;
            while (k < cn) : (k += 1) ctx = (ctx << 1) | bm.get(ix + cod[k].x, iy + cod[k].y);
            k = 0;
            while (k < rn) : (k += 1) ctx = (ctx << 1) | ref.get(ix - dx + rf[k].x, iy - dy + rf[k].y);
            bm.put(x, y, mq.bit(cx, ctx));
        }
    }
}

// ===== 무늬 사전과 하프톤 (6.6·6.7) =====
//
// 하프톤은 사진을 점 크기로 나타낸다. 무늬 사전에 짙기별 점 모양을 담고,
// 쪽에는 칸마다 "몇 번 짙기" 만 적는다. 짙기는 회색 그림을 비트평면으로
// 쪼개 그레이 코드로 담는다.
const MAX_PATS = 256;
var pats: [MAX_PATS]BM = undefined;
var pat_n: u32 = 0;

fn readPatternDict(d: []const u8) bool {
    if (d.len < 7) return false;
    const flags = d[0];
    const mmr = (flags & 1) != 0;
    const tmpl = (flags >> 1) & 3;
    const pw = d[1];
    const ph = d[2];
    const gmax = be32(d, 3);
    if (pw == 0 or ph == 0 or gmax > MAX_PATS - 1) return false;
    const total = (@as(u32, gmax) + 1) * pw;
    const col = alloc(total, ph) orelse return false;
    if (mmr) {
        if (!ccitt.decode(d[7..], total, ph, -1, false, col.d)) return false;
    } else {
        const at = [_]Pt{
            .{ .x = @intCast(-@as(i32, @intCast(@min(pw, 127)))), .y = 0 },
            .{ .x = -3, .y = -1 }, .{ .x = 2, .y = -2 }, .{ .x = -2, .y = -2 },
        };
        @memset(gb_cx[0..], 0);
        var mq = MQ.init(d[7..]);
        // 밑틀 0 만 AT 점이 넷이다. 나머지는 하나만 쓴다 — 넷을 넘기면
        // 자리표 크기가 달라져 통째로 어긋난다.
        decodeGeneric(&mq, col, tmpl, at[0 .. if (tmpl == 0) @as(usize, 4) else 1], false, gb_cx[0..]);
    }
    // 붙어 있는 것을 낱개로 자른다
    pat_n = 0;
    var i: u32 = 0;
    while (i <= gmax and pat_n < MAX_PATS) : (i += 1) {
        const one = alloc(pw, ph) orelse return false;
        var y: u32 = 0;
        while (y < ph) : (y += 1) {
            var x: u32 = 0;
            while (x < pw) : (x += 1) one.put(x, y, col.get(@intCast(i * pw + x), @intCast(y)));
        }
        pats[pat_n] = one;
        pat_n += 1;
    }
    return pat_n > 0;
}

var gray: [1 << 16]u8 = undefined;

fn readHalftone(d: []const u8) bool {
    if (d.len < 18 + 16 or pat_n == 0) return false;
    const rw = be32(d, 0);
    const rh = be32(d, 4);
    const rx = be32(d, 8);
    const ry = be32(d, 12);
    const rop = d[16] & 7;
    const flags = d[17];
    const mmr = (flags & 1) != 0;
    const tmpl = (flags >> 1) & 3;
    const defpix = (flags >> 7) & 1;
    const gw = be32(d, 18);
    const gh = be32(d, 22);
    const gx: i32 = @bitCast(be32(d, 26));
    const gy: i32 = @bitCast(be32(d, 30));
    const rvx: i32 = @intCast(be16(d, 34));
    const rvy: i32 = @intCast(be16(d, 36));
    if (!regionSane(rw, rh)) return false;
    if (gw == 0 or gh == 0 or gw * gh > gray.len) return false;

    const bm = alloc(rw, rh) orelse return false;
    if (defpix != 0) @memset(bm.d, 0xFF);

    // 짙기 값을 비트평면으로 읽는다. 위 자리부터 오고 그레이 코드다.
    var bits: u32 = 0;
    while ((@as(u32, 1) << @intCast(bits)) < pat_n) bits += 1;
    if (bits == 0) bits = 1;
    if (bits > 8) return false;
    @memset(gray[0 .. gw * gh], 0);
    var prev = alloc(gw, gh) orelse return false;
    var cur = alloc(gw, gh) orelse return false;
    @memset(gb_cx[0..], 0);
    var mq = MQ.init(d[38..]);
    const at = [_]Pt{
        .{ .x = if (tmpl <= 1) 3 else 2, .y = -1 },
        .{ .x = -3, .y = -1 }, .{ .x = 2, .y = -2 }, .{ .x = -2, .y = -2 },
    };
    var mmr_bit: usize = 0;
    var j: i32 = @as(i32, @intCast(bits)) - 1;
    var first = true;
    while (j >= 0) : (j -= 1) {
        if (mmr) {
            // 평면들이 한 흐름에 이어져 있고 판마다 EOFB 로 끊어 놓았다
            if (!ccitt.decodeFrom(d[38..], gw, gh, -1, false, cur.d, &mmr_bit)) return false;
        } else {
            decodeGeneric(&mq, cur, tmpl, at[0 .. if (tmpl == 0) @as(usize, 4) else 1], false, gb_cx[0..]);
        }
        var yy: u32 = 0;
        while (yy < gh) : (yy += 1) {
            var xx: u32 = 0;
            while (xx < gw) : (xx += 1) {
                var v = cur.get(@intCast(xx), @intCast(yy));
                // 그레이 코드 — 위 자리와 뒤집어 더한다
                if (!first) v ^= prev.get(@intCast(xx), @intCast(yy));
                cur.put(xx, yy, v);
                gray[yy * gw + xx] |= @intCast(v << @intCast(j));
            }
        }
        const t2 = prev;
        prev = cur;
        cur = t2;
        first = false;
    }

    // 칸마다 무늬를 찍는다
    var mg: u32 = 0;
    while (mg < gh and work > 0) : (mg += 1) {
        var ng: u32 = 0;
        while (ng < gw) : (ng += 1) {
            const px = gx + @as(i32, @intCast(mg)) * rvy + @as(i32, @intCast(ng)) * rvx;
            const py = gy + @as(i32, @intCast(mg)) * rvx - @as(i32, @intCast(ng)) * rvy;
            const v = @min(gray[mg * gw + ng], pat_n - 1);
            drawOn(bm, pats[v], px >> 8, py >> 8, 0);
        }
    }
    drawOn(page, bm, @intCast(rx), @intCast(ry), rop);
    return true;
}

// ===== 세그먼트 읽기 =====

fn be32(d: []const u8, at: usize) u32 {
    if (at + 4 > d.len) return 0;
    return (@as(u32, d[at]) << 24) | (@as(u32, d[at + 1]) << 16) |
        (@as(u32, d[at + 2]) << 8) | d[at + 3];
}
fn be16(d: []const u8, at: usize) u32 {
    if (at + 2 > d.len) return 0;
    return (@as(u32, d[at]) << 8) | d[at + 1];
}

/// 들여다보기용 기록 — 시험에서만 쓴다
pub var dbg: [64][5]i32 = undefined;
pub var dbg_n: u32 = 0;

// 스캔한 쪽 하나가 글자 만 개를 넘기도 한다. 4096 으로 잡았더니 실제
// 문서의 사전이 통째로 튕겨 나가 글자 번호가 어긋났다.
const MAX_SYMS = 16384;
/// 사전들이 내보낸 글자를 차례로 이어 담는다.
pub var syms: [MAX_SYMS]BM = undefined;
pub var sym_n: u32 = 0;
/// 세그먼트마다 어디부터 몇 개를 내보냈는지.
///
/// 글자 영역은 "가리키는 세그먼트들이 내보낸 목록" 을 차례로 이어 쓴다.
/// 지금까지 모인 것을 다 쓰면 글자 수가 달라져 번호 길이가 어긋난다.
const SegExp = struct { num: u32, start: u32, count: u32 };
var seg_exp: [128]SegExp = undefined;
var seg_exp_n: u32 = 0;
/// 이번 세그먼트가 물려받는 글자
var inlist: [MAX_SYMS]BM = undefined;
var inlist_n: u32 = 0;
var newsym: [MAX_SYMS]BM = undefined;
/// 사전 안에서 글자를 겹쳐 만들 때 쓰는 목록
var agg: [MAX_SYMS]BM = undefined;

fn gatherRefs(refs: []const u32) void {
    inlist_n = 0;
    for (refs) |r| {
        var i: u32 = 0;
        while (i < seg_exp_n) : (i += 1) {
            if (seg_exp[i].num != r) continue;
            var k: u32 = 0;
            while (k < seg_exp[i].count and inlist_n < MAX_SYMS) : (k += 1) {
                inlist[inlist_n] = syms[seg_exp[i].start + k];
                inlist_n += 1;
            }
        }
    }
    // 가리키는 것을 못 찾으면 지금까지 모인 것을 다 쓴다
    if (inlist_n == 0) {
        var k: u32 = 0;
        while (k < sym_n) : (k += 1) inlist[k] = syms[k];
        inlist_n = sym_n;
    }
}

fn ceilLog2(v: u32) u32 {
    var n: u32 = 0;
    while ((@as(u32, 1) << @intCast(n)) < v and n < 31) n += 1;
    return n;
}

/// 쪽 그림. 여기에 영역들을 얹는다.
var page: BM = .{};

/// 쪽보다 큰 영역은 규격에 어긋난다. 망가진 파일이 4000×4000 짜리를
/// 수백 개 적어 놓으면 예산만으로는 초 단위가 걸리므로 여기서 먼저 막는다.
fn regionSane(w: u32, h: u32) bool {
    return w > 0 and h > 0 and w <= page.w + 8 and h <= page.h + 8;
}

fn drawOn(dst: BM, src: BM, x0: i32, y0: i32, op: u32) void {
    work -= @as(i64, src.w) * @as(i64, src.h);
    if (work < 0) return;
    var y: u32 = 0;
    while (y < src.h) : (y += 1) {
        var x: u32 = 0;
        while (x < src.w) : (x += 1) {
            const px = x0 + @as(i32, @intCast(x));
            const py = y0 + @as(i32, @intCast(y));
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= dst.w or uy >= dst.h) continue;
            const v = src.get(@intCast(x), @intCast(y));
            const old = dst.get(px, py);
            const nv = switch (op) {
                0 => old | v,
                1 => old & v,
                2 => old ^ v,
                3 => 1 - (old ^ v),
                else => v,
            };
            dst.put(ux, uy, nv);
        }
    }
}

/// 글자 사전 하나를 푼다. 푼 글자를 syms 에 이어 붙인다.
var pick: [MAX_SYMS]BM = undefined;

fn readSymbolDict(d: []const u8, num: u32, inp: []const BM) bool {
    if (d.len < 12) return false;
    const flags = be16(d, 0);
    const sdhuff = (flags & 1) != 0;
    const refagg = (flags & 2) != 0;
    const tmpl = (flags >> 10) & 3;
    const rtmpl = (flags >> 12) & 1;
    if (sdhuff) return readSymbolDictH(d, num, inp, flags);
    var p: usize = 2;
    var at: [4]Pt = undefined;
    const nat: u32 = if (tmpl == 0) 4 else 1;
    var i: u32 = 0;
    while (i < nat) : (i += 1) {
        if (p + 2 > d.len) return false;
        at[i] = .{ .x = @bitCast(d[p]), .y = @bitCast(d[p + 1]) };
        p += 2;
    }
    var rat: [2]Pt = .{ .{ .x = -1, .y = -1 }, .{ .x = -1, .y = -1 } };
    if (refagg and rtmpl == 0) {
        if (p + 4 > d.len) return false;
        rat[0] = .{ .x = @bitCast(d[p]), .y = @bitCast(d[p + 1]) };
        rat[1] = .{ .x = @bitCast(d[p + 2]), .y = @bitCast(d[p + 3]) };
        p += 4;
    }
    const n_ex = be32(d, p);
    const n_new = be32(d, p + 4);
    p += 8;
    if (n_new > MAX_SYMS or n_ex > MAX_SYMS) return false;

    @memset(gb_cx[0..], 0);
    @memset(gr_cx[0..], 0);
    for (&int_cx) |*row| @memset(row, 0);
    // 세밀화로 만드는 글자는 앞선 글자를 번호로 집는다
    const code_len = ceilLog2(@as(u32, @intCast(inp.len)) + n_new);
    if (code_len > 16) return false;
    if (refagg) @memset(iaid_cx[0 .. @as(usize, 2) << @intCast(code_len)], 0);
    var mq = MQ.init(d[@min(p, d.len)..]);

    var made_at: u32 = 0;
    var h_class: i32 = 0;
    var made: u32 = 0;
    while (made < n_new and work > 0) {
        const dh = decodeInt(&mq, 0); // IADH
        if (dh == OOB) break;
        h_class += dh;
        if (h_class <= 0 or h_class > 1 << 14) break;
        var sw: i32 = 0;
        while (true) {
            const dw = decodeInt(&mq, 1); // IADW
            if (dw == OOB) break;
            sw += dw;
            if (sw <= 0 or sw > 1 << 14 or made >= n_new or made_at >= MAX_SYMS) return false;
            const bm = alloc(@intCast(sw), @intCast(h_class)) orelse return false;
            if (refagg) {
                // 몇 개를 겹쳐 만드는가. 하나면 앞선 글자를 다듬어 쓴다.
                // 몇 개를 겹쳐 만드는가
                const nref = decodeInt(&mq, 3); // IAAI
                if (nref == 1) {
                    // 하나면 앞선 글자를 다듬어 쓴다
                    const rid = decodeIaid(&mq, code_len);
                    const rdx = decodeInt(&mq, 11); // IARDX
                    const rdy = decodeInt(&mq, 12); // IARDY
                    if (rdx == OOB or rdy == OOB) return false;
                    const src = if (rid < inp.len) inp[rid]
                        else if (rid - inp.len < made_at) newsym[rid - inp.len]
                        else BM{};
                    decodeRefine(&mq, bm, src, rdx, rdy, rtmpl, rat[0..2], false, gr_cx[0..]);
                } else if (nref > 1 and nref < 1000) {
                    // 여럿이면 작은 글자 영역으로 찍는다 (6.5.8.2.1)
                    var sn2: u32 = 0;
                    while (sn2 < inp.len and sn2 < MAX_SYMS) : (sn2 += 1) agg[sn2] = inp[sn2];
                    var k2: u32 = 0;
                    while (k2 < made_at and sn2 < MAX_SYMS) : (k2 += 1) { agg[sn2] = newsym[k2]; sn2 += 1; }
                    textCore(&mq, bm, agg[0..sn2], .{
                        .strips = 1, .refcorner = 1, .transposed = 0, .comb = 0,
                        .dsoffset = 0, .refine = true, .rtmpl = rtmpl, .rat = rat,
                        .n_inst = @intCast(nref), .code_len = code_len,
                    });
                } else return false;
            } else {
                decodeGeneric(&mq, bm, tmpl, at[0..nat], false, gb_cx[0..]);
            }
            newsym[made_at] = bm;
            made_at += 1;
            made += 1;
        }
    }

    // 내보낼 글자 고르기 — 물려받은 것과 새로 만든 것을 이어 훑는다.
    // 자리는 정적으로 잡는다 — 만 육천 개를 스택에 두면 넘친다.
    var pn: u32 = 0;
    const total = @as(u32, @intCast(inp.len)) + made;
    var idx: u32 = 0;
    var on = false;
    var spin: u32 = 0;
    while (idx < total and pn < MAX_SYMS and spin < 8) {
        const run = decodeInt(&mq, 2); // IAEX
        if (run == OOB or run < 0) break;
        const r: u32 = @intCast(run);
        if (r == 0) spin += 1 else spin = 0;
        if (on) {
            var k: u32 = 0;
            while (k < r and idx + k < total and pn < MAX_SYMS) : (k += 1) {
                const g = idx + k;
                pick[pn] = if (g < inp.len) inp[g] else newsym[g - inp.len];
                pn += 1;
            }
        }
        idx += r;
        on = !on;
    }
    // 내보낸 목록을 뒤에 잇고, 이 세그먼트 몫으로 적어 둔다
    if (sym_n + pn > MAX_SYMS or seg_exp_n >= seg_exp.len) return false;
    var k: u32 = 0;
    while (k < pn) : (k += 1) syms[sym_n + k] = pick[k];
    seg_exp[seg_exp_n] = .{ .num = num, .start = sym_n, .count = pn };
    seg_exp_n += 1;
    sym_n += pn;
    return true;
}

/// 글자 하나를 제자리에 얹는다. 산술·허프만 두 길이 함께 쓴다.
fn placeSym(bm: BM, sb: BM, curs: *i32, t: i32, refcorner: u32, transposed: u32, comb: u32) void {
    const sw: i32 = @intCast(sb.w);
    const sh: i32 = @intCast(sb.h);
    if (transposed == 0) {
        if (refcorner == 2 or refcorner == 3) curs.* += sw - 1;
        const px = if (refcorner == 2 or refcorner == 3) curs.* - sw + 1 else curs.*;
        const py = if (refcorner == 0 or refcorner == 2) t - sh + 1 else t;
        drawOn(bm, sb, px, py, comb);
        if (refcorner == 0 or refcorner == 1) curs.* += sw - 1;
    } else {
        if (refcorner == 0 or refcorner == 2) curs.* += sh - 1;
        const py = if (refcorner == 0 or refcorner == 2) curs.* - sh + 1 else curs.*;
        const px = if (refcorner == 2 or refcorner == 3) t - sw + 1 else t;
        drawOn(bm, sb, px, py, comb);
        if (refcorner == 1 or refcorner == 3) curs.* += sh - 1;
    }
}

/// 허프만으로 담긴 글자 사전 (6.5.9).
///
/// 산술 판과 달리 글자를 하나씩 풀지 않는다. 같은 높이끼리 묶어 폭만
/// 늘어놓고, 그 줄의 그림은 통째로 한 판에 담아 MMR 로(또는 날것으로)
/// 부호화한다. 다 풀고 나서 폭대로 잘라 낸다.
fn readSymbolDictH(d: []const u8, num: u32, inp: []const BM, flags: u32) bool {
    const sel_dh = (flags >> 2) & 3;
    const sel_dw = (flags >> 4) & 3;
    const sel_bm = (flags >> 6) & 1;
    const sel_ag = (flags >> 7) & 1;
    const refagg = (flags & 2) != 0;
    const rtmpl = (flags >> 12) & 1;
    const t_dh = pickTable(sel_dh, 4, 5, 0) orelse return false;
    const t_dw = pickTable(sel_dw, 2, 3, 0) orelse return false;
    const t_bm = pickTable(if (sel_bm == 1) 3 else 0, 1, 1, 0) orelse return false;
    const t_ag = pickTable(if (sel_ag == 1) 3 else 0, 1, 1, 0) orelse return false;
    const t_ex = stdTable(1);
    const t_rd = stdTable(15);
    prepTable(0, t_dh);
    prepTable(1, t_dw);
    prepTable(2, t_bm);
    prepTable(3, t_ex);
    prepTable(4, t_ag);
    prepTable(5, t_rd);

    if (d.len < 10) return false;
    // 세밀화 자리표는 개수 앞에 온다 (7.4.3.1.2)
    var p0: usize = 2;
    var rat: [2]Pt = .{ .{ .x = -1, .y = -1 }, .{ .x = -1, .y = -1 } };
    if (refagg and rtmpl == 0) {
        if (p0 + 4 > d.len) return false;
        rat[0] = .{ .x = @bitCast(d[p0]), .y = @bitCast(d[p0 + 1]) };
        rat[1] = .{ .x = @bitCast(d[p0 + 2]), .y = @bitCast(d[p0 + 3]) };
        p0 += 4;
    }
    if (p0 + 8 > d.len) return false;
    const n_ex = be32(d, p0);
    const n_new = be32(d, p0 + 4);
    p0 += 8;
    if (n_new > MAX_SYMS or n_ex > MAX_SYMS) return false;
    var r = BitR{ .d = d[p0..] };

    // 세밀화로 만드는 글자는 앞선 글자를 번호로 집는다. 허프만 판에서는
    // 번호를 산술 부호가 아니라 고정 길이 비트로 적는다 (6.5.8.2.3).
    const code_len = ceilLog2(@as(u32, @intCast(inp.len)) + n_new);
    if (code_len > 16) return false;

    var widths: [1024]u32 = undefined;
    var made: u32 = 0;
    var h_class: i32 = 0;
    while (made < n_new and work > 0) {
        var v: i32 = 0;
        if (!hRead(t_dh, hcodes[0][0..t_dh.len], &r, &v)) break;
        h_class += v;
        if (h_class <= 0 or h_class > 1 << 14) return false;
        var sw: i32 = 0;
        var tot: u32 = 0;
        const first = made;
        var cnt: u32 = 0;
        while (true) {
            if (!hRead(t_dw, hcodes[1][0..t_dw.len], &r, &v)) break; // OOB — 줄 끝
            sw += v;
            if (sw <= 0 or sw > 1 << 14 or made >= n_new or cnt >= widths.len) return false;
            widths[cnt] = @intCast(sw);
            cnt += 1;
            tot += @intCast(sw);
            made += 1;
            // 세밀화·모으기 판은 줄 그림을 통째로 담지 않는다. 글자마다
            // 앞선 글자를 밑그림 삼아 그 자리에서 다듬어 만든다 (6.5.8.2).
            if (!refagg) continue;
            var ninst: i32 = 0;
            if (!hRead(t_ag, hcodes[4][0..t_ag.len], &r, &ninst)) return false;
            if (ninst != 1) return false; // 여럿 겹쳐 만드는 꼴은 다루지 않는다
            const id = r.getn(code_len);
            var rdx: i32 = 0;
            var rdy: i32 = 0;
            var bmsize: i32 = 0;
            if (!hRead(t_rd, hcodes[5][0..t_rd.len], &r, &rdx)) return false;
            if (!hRead(t_rd, hcodes[5][0..t_rd.len], &r, &rdy)) return false;
            if (!hRead(t_bm, hcodes[2][0..t_bm.len], &r, &bmsize) or bmsize < 0) return false;
            r.byteAlign();
            const at2 = r.pos();
            if (at2 > r.d.len) return false;
            const total_in = @as(u32, @intCast(inp.len));
            const ref = if (id < total_in) inp[id] else
                (if (id - total_in < first + cnt - 1) newsym[id - total_in] else return false);
            const one = alloc(@intCast(sw), @intCast(h_class)) orelse return false;
            @memset(gr_cx[0..], 0);
            const room: usize = if (bmsize > 0)
                @min(@as(usize, @intCast(bmsize)), r.d.len - at2)
            else
                r.d.len - at2;
            var mq = MQ.init(r.d[at2..][0..room]);
            decodeRefine(&mq, one, ref, rdx, rdy, rtmpl, rat[0..2], false, gr_cx[0..]);
            if (first + cnt - 1 < MAX_SYMS) newsym[first + cnt - 1] = one;
            if (bmsize == 0) return false; // 길이를 모르면 이어 읽을 수 없다
            r.bit = @as(u64, at2 + @as(usize, @intCast(bmsize))) * 8;
        }
        if (cnt == 0) continue;
        if (refagg) continue; // 글자를 이미 다 만들었다
        var bmsize: i32 = 0;
        if (!hRead(t_bm, hcodes[2][0..t_bm.len], &r, &bmsize)) return false;
        r.byteAlign();
        const col = alloc(tot, @intCast(h_class)) orelse return false;
        const at = r.pos();
        if (bmsize == 0) {
            // 날것 — 줄마다 바이트로 끊어 담겨 있다
            const stride = (tot + 7) / 8;
            const need = stride * @as(u32, @intCast(h_class));
            if (at + need > r.d.len) return false;
            @memcpy(col.d[0..need], r.d[at..][0..need]);
            r.bit = @as(u64, at + need) * 8;
        } else {
            const bs: usize = @intCast(bmsize);
            if (at + bs > r.d.len) return false;
            if (!ccitt.decode(r.d[at..][0..bs], tot, @intCast(h_class), -1, false, col.d)) return false;
            r.bit = @as(u64, at + bs) * 8;
        }
        // 폭대로 잘라 낸다
        var x0: u32 = 0;
        var k: u32 = 0;
        while (k < cnt) : (k += 1) {
            const one = alloc(widths[k], @intCast(h_class)) orelse return false;
            var y: u32 = 0;
            while (y < one.h) : (y += 1) {
                var x: u32 = 0;
                while (x < one.w) : (x += 1) one.put(x, y, col.get(@intCast(x0 + x), @intCast(y)));
            }
            if (first + k < MAX_SYMS) newsym[first + k] = one;
            x0 += widths[k];
        }
    }

    // 내보낼 글자 고르기
    var pn: u32 = 0;
    const total = @as(u32, @intCast(inp.len)) + made;
    var idx: u32 = 0;
    var on = false;
    // 길이 0 인 묶음이 이어지면 자리도 개수도 안 늘어 제자리를 돈다.
    // 실제로 26 억 번을 돌아 45 초를 잡아먹은 적이 있다.
    var spin: u32 = 0;
    while (idx < total and pn < MAX_SYMS and spin < 8 and !r.done()) {
        var run: i32 = 0;
        if (!hRead(t_ex, hcodes[3][0..t_ex.len], &r, &run) or run < 0) break;
        const rr: u32 = @intCast(run);
        if (rr == 0) spin += 1 else spin = 0;
        if (on) {
            var k: u32 = 0;
            while (k < rr and idx + k < total and pn < MAX_SYMS) : (k += 1) {
                const g = idx + k;
                pick[pn] = if (g < inp.len) inp[g] else newsym[g - inp.len];
                pn += 1;
            }
        }
        idx += rr;
        on = !on;
    }
    if (sym_n + pn > MAX_SYMS or seg_exp_n >= seg_exp.len) return false;
    var k2: u32 = 0;
    while (k2 < pn) : (k2 += 1) syms[sym_n + k2] = pick[k2];
    seg_exp[seg_exp_n] = .{ .num = num, .start = sym_n, .count = pn };
    seg_exp_n += 1;
    sym_n += pn;
    return true;
}

/// 허프만으로 담긴 글자 영역 (6.4, SBHUFF=1).
fn readTextRegionH(d: []const u8, sy: []const BM) bool {
    if (d.len < 25) return false;
    const rw = be32(d, 0);
    const rh = be32(d, 4);
    const rx = be32(d, 8);
    const ry = be32(d, 12);
    const rop = d[16] & 7;
    var p: usize = 17;
    const flags = be16(d, p);
    p += 2;
    const refine = (flags & 2) != 0;
    const log_strips = (flags >> 2) & 3;
    const strips: i32 = @as(i32, 1) << @intCast(log_strips);
    const refcorner = (flags >> 4) & 3;
    const transposed = (flags >> 6) & 1;
    const comb = (flags >> 7) & 3;
    const defpix = (flags >> 9) & 1;
    var dsoffset: i32 = @intCast((flags >> 10) & 0x1F);
    if (dsoffset > 15) dsoffset -= 32;
    const rtmpl = (flags >> 15) & 1;
    const hf = be16(d, p);
    p += 2;
    const t_fs = pickTable(hf & 3, 6, 7, 0) orelse return false;
    const t_ds = pickTable((hf >> 2) & 3, 8, 9, 10) orelse return false;
    const t_dt = pickTable((hf >> 4) & 3, 11, 12, 13) orelse return false;
    const t_rdw = pickTable((hf >> 6) & 3, 14, 15, 0) orelse return false;
    const t_rdh = pickTable((hf >> 8) & 3, 14, 15, 0) orelse return false;
    const t_rdx = pickTable((hf >> 10) & 3, 14, 15, 0) orelse return false;
    const t_rdy = pickTable((hf >> 12) & 3, 14, 15, 0) orelse return false;
    const t_rs = pickTable(if ((hf >> 14) & 1 == 1) 3 else 0, 1, 1, 0) orelse return false;
    prepTable(0, t_fs);
    prepTable(1, t_ds);
    prepTable(2, t_dt);
    prepTable(3, t_rdw);
    prepTable(4, t_rdh);
    prepTable(5, t_rdx);
    prepTable(6, t_rdy);
    prepTable(7, t_rs);

    // 세밀화 자리표는 개수 앞에 온다 (7.4.4.1.2)
    var rat: [2]Pt = .{ .{ .x = -1, .y = -1 }, .{ .x = -1, .y = -1 } };
    if (refine and rtmpl == 0) {
        if (p + 4 > d.len) return false;
        rat[0] = .{ .x = @bitCast(d[p]), .y = @bitCast(d[p + 1]) };
        rat[1] = .{ .x = @bitCast(d[p + 2]), .y = @bitCast(d[p + 3]) };
        p += 4;
    }
    const n_inst = be32(d, p);
    p += 4;
    if (n_inst > 1 << 20) return false;
    if (!regionSane(rw, rh)) return false;
    const nsym: u32 = @intCast(sy.len);
    if (nsym == 0 or nsym > 4096) return false;

    var r = BitR{ .d = d[p..] };
    // 글자 번호표 — 길이를 다시 허프만으로 담아 놓았다 (6.4.5.1)
    var rl: [35]HL = undefined;
    var i: u32 = 0;
    while (i < 35) : (i += 1) rl[i] = .{ .pre = @intCast(r.getn(4)), .rlen = 0, .low = @intCast(i) };
    var rcodes: [64]u32 = undefined;
    {
        var pre: [35]u8 = undefined;
        var k: u32 = 0;
        while (k < 35) : (k += 1) pre[k] = rl[k].pre;
        assignCodes(pre[0..35], rcodes[0..35]);
    }
    var slen: [4096]u8 = undefined;
    var prev: u8 = 0;
    i = 0;
    while (i < nsym) {
        var c: i32 = 0;
        if (!hRead(rl[0..35], rcodes[0..35], &r, &c)) return false;
        if (c < 32) {
            slen[i] = @intCast(c);
            prev = @intCast(c);
            i += 1;
        } else if (c == 32) {
            const n = 3 + r.getn(2);
            var k: u32 = 0;
            while (k < n and i < nsym) : (k += 1) { slen[i] = prev; i += 1; }
        } else if (c == 33) {
            const n = 3 + r.getn(3);
            var k: u32 = 0;
            while (k < n and i < nsym) : (k += 1) { slen[i] = 0; i += 1; }
        } else {
            const n = 11 + r.getn(7);
            var k: u32 = 0;
            while (k < n and i < nsym) : (k += 1) { slen[i] = 0; i += 1; }
        }
        if (r.done()) break;
    }
    var sl: [4096]HL = undefined;
    var scodes: [4096]u32 = undefined;
    i = 0;
    while (i < nsym) : (i += 1) sl[i] = .{ .pre = slen[i], .rlen = 0, .low = @intCast(i) };
    assignCodes(slen[0..nsym], scodes[0..nsym]);
    r.byteAlign();

    const bm = alloc(rw, rh) orelse return false;
    if (defpix != 0) @memset(bm.d, 0xFF);

    var v: i32 = 0;
    if (!hRead(t_dt, hcodes[2][0..t_dt.len], &r, &v)) return false;
    var stript: i32 = -v * strips;
    var firsts: i32 = 0;
    var done: u32 = 0;
    var guard: u32 = 0;
    while (done < n_inst and guard < (1 << 20) and work > 0) {
        guard += 1;
        if (!hRead(t_dt, hcodes[2][0..t_dt.len], &r, &v)) break;
        stript += v * strips;
        if (!hRead(t_fs, hcodes[0][0..t_fs.len], &r, &v)) break;
        firsts += v;
        var curs: i32 = firsts;
        while (guard < (1 << 20)) {
            guard += 1;
            const curt: i32 = if (strips == 1) 0 else @intCast(r.getn(log_strips));
            const t = stript + curt;
            var id: i32 = 0;
            if (!hRead(sl[0..nsym], scodes[0..nsym], &r, &id)) break;
            const uid: u32 = @intCast(@max(0, @min(@as(i32, @intCast(nsym)) - 1, id)));
            var sb = sy[uid];
            // 이 자리만 조금 다르게 찍힌 글자다 — 밑그림을 다듬는다.
            // 다듬는 일 자체는 허프만 판에서도 산술 부호로 한다 (6.4.11).
            if (refine and r.get1() != 0) {
                var rdw: i32 = 0;
                var rdh: i32 = 0;
                var rdx: i32 = 0;
                var rdy: i32 = 0;
                var bmsize: i32 = 0;
                if (!hRead(t_rdw, hcodes[3][0..t_rdw.len], &r, &rdw)) break;
                if (!hRead(t_rdh, hcodes[4][0..t_rdh.len], &r, &rdh)) break;
                if (!hRead(t_rdx, hcodes[5][0..t_rdx.len], &r, &rdx)) break;
                if (!hRead(t_rdy, hcodes[6][0..t_rdy.len], &r, &rdy)) break;
                if (!hRead(t_rs, hcodes[7][0..t_rs.len], &r, &bmsize) or bmsize <= 0) break;
                r.byteAlign();
                const at2 = r.pos();
                if (at2 >= r.d.len) break;
                const nw = @as(i32, @intCast(sb.w)) + rdw;
                const nh = @as(i32, @intCast(sb.h)) + rdh;
                if (nw <= 0 or nh <= 0 or nw > 1 << 14 or nh > 1 << 14) break;
                const nb = alloc(@intCast(nw), @intCast(nh)) orelse break;
                @memset(gr_cx[0..], 0);
                const room = @min(@as(usize, @intCast(bmsize)), r.d.len - at2);
                var mq = MQ.init(r.d[at2..][0..room]);
                decodeRefine(&mq, nb, sb, (rdw >> 1) + rdx, (rdh >> 1) + rdy,
                    rtmpl, rat[0..2], false, gr_cx[0..]);
                sb = nb;
                r.bit = @as(u64, at2 + @as(usize, @intCast(bmsize))) * 8;
            }
            if (dbg_n < 60) dbg[dbg_n] = .{ id, curs, t, @intCast(sb.w), @intCast(sb.h) };
            dbg_n += 1;
            placeSym(bm, sb, &curs, t, refcorner, transposed, comb);
            done += 1;
            if (!hRead(t_ds, hcodes[1][0..t_ds.len], &r, &v)) break; // OOB — 줄 끝
            if (done >= n_inst) break;
            curs += v + dsoffset;
        }
        if (r.done()) break;
    }
    drawOn(page, bm, @intCast(rx), @intCast(ry), rop);
    return true;
}

/// 글자 영역을 그리는 속살.
///
/// 세그먼트로 오기도 하고, 글자 사전 안에서 "글자 두 개를 겹쳐 만든다" 는
/// 뜻으로 불리기도 한다(6.5.8.2). 그래서 산술 복호기와 자리표를 밖에서
/// 받아 이어 쓴다.
const TRParams = struct {
    strips: i32,
    refcorner: u32,
    transposed: u32,
    comb: u32,
    dsoffset: i32,
    refine: bool,
    rtmpl: u32,
    rat: [2]Pt,
    n_inst: u32,
    code_len: u32,
};

fn textCore(mq: *MQ, bm: BM, sy: []const BM, pr: TRParams) void {
    const nsym: u32 = @intCast(sy.len);
    if (nsym == 0) return;
    var stript: i32 = -decodeInt(mq, 4) * pr.strips; // IADT
    var firsts: i32 = 0;
    var done: u32 = 0;
    var guard: u32 = 0;
    while (done < pr.n_inst and guard < (1 << 22) and work > 0) {
        guard += 1;
        const dt = decodeInt(mq, 4);
        if (dt == OOB) break;
        stript += dt * pr.strips;
        const dfs = decodeInt(mq, 5); // IAFS
        if (dfs == OOB) break;
        firsts += dfs;
        var curs: i32 = firsts;
        while (guard < (1 << 22)) {
            guard += 1;
            const curt: i32 = if (pr.strips == 1) 0 else decodeInt(mq, 6); // IAIT
            const t = stript + curt;
            const id = decodeIaid(mq, pr.code_len);
            var sb = sy[@min(id, nsym - 1)];
            if (pr.refine) {
                const ri = decodeInt(mq, 8); // IARI
                if (ri == OOB) break;
                if (ri != 0) {
                    // 이 자리만 조금 다르게 찍힌 글자다 — 밑그림을 다듬는다
                    const rdw = decodeInt(mq, 9);
                    const rdh = decodeInt(mq, 10);
                    const rdx = decodeInt(mq, 11);
                    const rdy = decodeInt(mq, 12);
                    if (rdw == OOB or rdh == OOB or rdx == OOB or rdy == OOB) break;
                    const nw = @as(i32, @intCast(sb.w)) + rdw;
                    const nh = @as(i32, @intCast(sb.h)) + rdh;
                    if (nw <= 0 or nh <= 0 or nw > 1 << 14 or nh > 1 << 14) break;
                    const nb = alloc(@intCast(nw), @intCast(nh)) orelse break;
                    decodeRefine(mq, nb, sb, (rdw >> 1) + rdx, (rdh >> 1) + rdy,
                        pr.rtmpl, pr.rat[0..2], false, gr_cx[0..]);
                    sb = nb;
                }
            }
            if (dbg_n < 60) dbg[dbg_n] = .{ @intCast(id), curs, t, @intCast(sb.w), @intCast(sb.h) };
            dbg_n += 1;
            placeSym(bm, sb, &curs, t, pr.refcorner, pr.transposed, pr.comb);
            done += 1;
            // 줄이 끝났다는 표시(OOB)는 마지막 글자 뒤에도 온다. 개수를 다
            // 채웠다고 먼저 빠져나오면 그 한 번을 안 읽어, 사전 안에서
            // 이어 쓰는 경우 뒤가 통째로 어긋난다.
            const ids = decodeInt(mq, 7); // IADS
            if (ids == OOB or done >= pr.n_inst) break;
            curs += ids + pr.dsoffset;
        }
    }
}

/// 글자 영역 세그먼트 하나를 푼다.
fn readTextRegion(d: []const u8, sy: []const BM) bool {
    if (d.len < 17 + 2) return false;
    const rw = be32(d, 0);
    const rh = be32(d, 4);
    const rx = be32(d, 8);
    const ry = be32(d, 12);
    const rop = d[16] & 7;
    var p: usize = 17;
    const flags = be16(d, p);
    p += 2;
    const sbhuff = (flags & 1) != 0;
    const refine = (flags & 2) != 0;
    const log_strips = (flags >> 2) & 3;
    const refcorner = (flags >> 4) & 3;
    const transposed = (flags >> 6) & 1;
    const comb = (flags >> 7) & 3;
    const defpix = (flags >> 9) & 1;
    var dsoffset: i32 = @intCast((flags >> 10) & 0x1F);
    if (dsoffset > 15) dsoffset -= 32;
    const rtmpl = (flags >> 15) & 1;
    if (sbhuff) return readTextRegionH(d, sy);
    var rat: [2]Pt = .{ .{ .x = -1, .y = -1 }, .{ .x = -1, .y = -1 } };
    if (refine and rtmpl == 0) {
        if (p + 4 > d.len) return false;
        rat[0] = .{ .x = @bitCast(d[p]), .y = @bitCast(d[p + 1]) };
        rat[1] = .{ .x = @bitCast(d[p + 2]), .y = @bitCast(d[p + 3]) };
        p += 4;
    }
    const n_inst = be32(d, p);
    p += 4;
    if (n_inst > 1 << 20) return false;
    if (!regionSane(rw, rh)) return false;

    const nsym: u32 = @intCast(sy.len);
    if (nsym == 0) return false;
    const code_len = ceilLog2(nsym);
    if (code_len > 16) return false;

    const bm = alloc(rw, rh) orelse return false;
    if (defpix != 0) @memset(bm.d, 0xFF);

    for (&int_cx) |*row| @memset(row, 0);
    @memset(iaid_cx[0 .. @as(usize, 2) << @intCast(code_len)], 0);
    @memset(gr_cx[0..], 0);
    var mq = MQ.init(d[@min(p, d.len)..]);
    textCore(&mq, bm, sy, .{
        .strips = @as(i32, 1) << @intCast(log_strips),
        .refcorner = refcorner,
        .transposed = transposed,
        .comb = comb,
        .dsoffset = dsoffset,
        .refine = refine,
        .rtmpl = rtmpl,
        .rat = rat,
        .n_inst = n_inst,
        .code_len = code_len,
    });
    drawOn(page, bm, @intCast(rx), @intCast(ry), rop);
    return true;
}

/// 보통 영역 세그먼트 하나.
fn readGenericRegion(d: []const u8) bool {
    if (d.len < 18) return false;
    const rw = be32(d, 0);
    const rh = be32(d, 4);
    const rx = be32(d, 8);
    const ry = be32(d, 12);
    const rop = d[16] & 7;
    const gflags = d[17];
    const mmr = (gflags & 1) != 0;
    const tmpl = (gflags >> 1) & 3;
    const tpgdon = (gflags & 8) != 0;
    var p: usize = 18;
    var at: [4]Pt = undefined;
    var nat: u32 = 0;
    if (!mmr) {
        nat = if (tmpl == 0) 4 else 1;
        var i: u32 = 0;
        while (i < nat) : (i += 1) {
            if (p + 2 > d.len) return false;
            at[i] = .{ .x = @bitCast(d[p]), .y = @bitCast(d[p + 1]) };
            p += 2;
        }
    }
    if (!regionSane(rw, rh)) return false;
    // 스캔 한 장은 쪽을 통째로 덮는 영역 하나가 전부다. 그럴 때는 쪽
    // 그림에 바로 푼다 — 4MB 짜리를 두 벌 들고 있지 않아도 된다.
    const whole = rx == 0 and ry == 0 and rw == page.w and rh == page.h;
    const bm = if (whole) page else (alloc(rw, rh) orelse return false);
    if (mmr) {
        // MMR 은 팩스(T.6)와 같은 부호다. 이미 가진 것을 쓴다.
        if (!ccitt.decode(d[@min(p, d.len)..], rw, rh, -1, false, bm.d))
            return false;
    } else {
        @memset(gb_cx[0..], 0);
        var mq = MQ.init(d[@min(p, d.len)..]);
        decodeGeneric(&mq, bm, tmpl, at[0..nat], tpgdon, gb_cx[0..]);
    }
    if (!whole) drawOn(page, bm, @intCast(rx), @intCast(ry), rop);
    return true;
}

/// 세그먼트를 차례로 훑는다.
fn runSegments(d: []const u8, embedded: bool) bool {
    _ = embedded;
    var p: usize = 0;
    var any = false;
    var guard: u32 = 0;
    while (p + 11 <= d.len and guard < 4096 and work > 0) {
        guard += 1;
        const num = be32(d, p);
        const flags = d[p + 4];
        const kind = flags & 0x3F;
        const big_page = (flags & 0x40) != 0;
        var q = p + 5;
        // 참조 세그먼트 — 글자 영역이 어느 사전을 쓰는지가 여기 있다
        const rt = d[q];
        var nref: u32 = rt >> 5;
        if (nref == 7) {
            nref = be32(d, q) & 0x1FFFFFFF;
            if (nref > 1000) return any;
            q += 4 + (nref + 8) / 8;
        } else {
            q += 1;
        }
        const ref_size: u32 = if (num <= 256) 1 else if (num <= 65536) 2 else 4;
        var refs: [64]u32 = undefined;
        var rn: u32 = 0;
        {
            var ri: u32 = 0;
            while (ri < nref and rn < refs.len) : (ri += 1) {
                const at = q + ri * ref_size;
                if (at + ref_size > d.len) break;
                refs[rn] = switch (ref_size) {
                    1 => d[at],
                    2 => be16(d, at),
                    else => be32(d, at),
                };
                rn += 1;
            }
        }
        q += nref * ref_size;
        q += if (big_page) @as(usize, 4) else 1;
        if (q + 4 > d.len) break;
        const dlen = be32(d, q);
        q += 4;
        if (dlen == 0xFFFFFFFF) break; // 길이를 모르는 꼴은 다루지 않는다
        const end = q + dlen;
        if (end > d.len) break;
        const body = d[q..end];

        switch (kind) {
            0 => { // 글자 사전
                const before = sym_n;
                gatherRefs(refs[0..rn]);
                gatherTables(refs[0..rn]);
                const okd = readSymbolDict(body, num, inlist[0..inlist_n]);
                if (dbg_n < 60) {
                    dbg[dbg_n] = .{ -1, @intCast(before), @intCast(sym_n), if (okd) 1 else 0, @intCast(body.len) };
                    dbg_n += 1;
                }
            },
            4, 6, 7 => { // 글자 영역
                gatherRefs(refs[0..rn]);
                gatherTables(refs[0..rn]);
                if (readTextRegion(body, inlist[0..inlist_n])) any = true;
            },
            36, 38, 39 => { // 보통 영역
                if (readGenericRegion(body)) any = true;
            },
            16 => { _ = readPatternDict(body); }, // 무늬 사전
            20, 22, 23 => { if (readHalftone(body)) any = true; }, // 하프톤
            53 => { _ = readTableSeg(body, num); }, // 문서가 실어 온 허프만 표
            48 => {}, // 쪽 정보 — 크기는 PDF 가 알려 준다
            else => {},
        }
        p = end;
    }
    return any;
}

/// PDF 안의 JBIG2 그림 하나를 푼다. dst 는 1 이 검정인 1비트 그림이다.
pub fn decode(data: []const u8, globals: []const u8, w: u32, h: u32, dst: []u8) bool {
    const stride = (w + 7) / 8;
    if (dst.len < stride * h) return false;
    @memset(dst[0 .. stride * h], 0);
    pool_used = 0;
    sym_n = 0;
    seg_exp_n = 0;
    pat_n = 0;
    dbg_n = 0;
    resetTables();
    work = BUDGET;
    page = wrap(w, h, dst[0 .. stride * h]);
    if (globals.len > 0) _ = runSegments(globals, true);
    return runSegments(data, true);
}
