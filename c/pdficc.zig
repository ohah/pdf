// ICC 색 프로파일을 읽어 색을 옮긴다.
//
// PDF 에 `1 0 0 rg` 라고 적으면 그 빨강이 **어떤 빨강인지**는 안 적혀 있다.
// 화면마다·인쇄기마다 다른 빨강이 나온다. 그래서 인쇄용 문서는
// /ICCBased 로 색 프로파일을 함께 넣는다 — "이 CMYK 값은 이 프로파일
// 기준이다" 라고.
//
// 그 프로파일을 안 쓰고 (255-c)(255-k)/255 같은 식으로 넘기면 색이 어긋난다.
// 실제로 재 보니 littleCMS 가 낸 참값과 평균 53/255, 마젠타는 129 까지
// 벌어졌다 — 참값 #D7157E 자리에 형광 마젠타 #FF00FF 를 찍고 있었다.
//
// 여기서 다루는 것은 실제 프로파일이 쓰는 세 꼴이다.
//
//   A2B0 (mft1·mft2)  CMYK·RGB → PCS. 입력 곡선 → 격자표(CLUT) → 출력 곡선.
//                     인쇄용 CMYK 프로파일이 거의 다 이것이다.
//   matrix/TRC        RGB → XYZ. 채널 곡선 뒤 3×3 행렬. sRGB·AdobeRGB 가 이것.
//   kTRC              회색 → XYZ.
//
// PCS(프로파일이 거치는 중간 색 공간)는 Lab 이거나 XYZ 다. 둘 다 D50
// 기준이라 sRGB(D65)로 옮길 때 Bradford 로 눈을 맞춘다.
const std = @import("std");

pub const Kind = enum(u8) { none = 0, lut = 1, matrix = 2, gray = 3 };

const Curve = struct {
    /// 0 없음(항등) · 1 감마 하나 · 2 표
    kind: u8 = 0,
    gamma: f32 = 1,
    off: u32 = 0,
    n: u32 = 0,
    /// 표 한 칸이 몇 바이트인가 (1 또는 2)
    wide: bool = true,
};

pub const Profile = struct {
    kind: Kind = .none,
    ncomp: u8 = 0,
    pcs_lab: bool = false,
    // matrix/TRC
    m: [9]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    trc: [3]Curve = .{ Curve{}, Curve{}, Curve{} },
    // A2B0
    grid: u8 = 0,
    out_ch: u8 = 3,
    in_tab: u32 = 0,
    in_n: u32 = 0,
    clut: u32 = 0,
    out_tab: u32 = 0,
    out_n: u32 = 0,
    wide: bool = false,
    /// 프로파일 바이트 (밖에서 들고 있는다)
    data: []const u8 = &[_]u8{},
};

fn be16(d: []const u8, o: usize) u32 {
    if (o + 2 > d.len) return 0;
    return (@as(u32, d[o]) << 8) | d[o + 1];
}
fn be32(d: []const u8, o: usize) u32 {
    if (o + 4 > d.len) return 0;
    return (@as(u32, d[o]) << 24) | (@as(u32, d[o + 1]) << 16) |
        (@as(u32, d[o + 2]) << 8) | d[o + 3];
}
/// s15Fixed16 — 위 16비트가 정수부다
fn s15(d: []const u8, o: usize) f32 {
    const v: i32 = @bitCast(be32(d, o));
    return @as(f32, @floatFromInt(v)) / 65536.0;
}

fn tagAt(d: []const u8, want: []const u8) ?struct { off: u32, len: u32 } {
    if (d.len < 132) return null;
    const n = be32(d, 128);
    if (n > 256) return null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const at = 132 + @as(usize, i) * 12;
        if (at + 12 > d.len) return null;
        if (std.mem.eql(u8, d[at .. at + 4], want)) {
            const off = be32(d, at + 4);
            const len = be32(d, at + 8);
            if (off + len > d.len) return null;
            return .{ .off = off, .len = len };
        }
    }
    return null;
}

fn readCurve(d: []const u8, off: u32, len: u32) Curve {
    if (off + 12 > d.len) return Curve{};
    const sig = d[off .. off + 4];
    if (std.mem.eql(u8, sig, "curv")) {
        const n = be32(d, off + 8);
        if (n == 0) return Curve{ .kind = 0 };
        if (n == 1) {
            // u8Fixed8 감마
            return Curve{ .kind = 1, .gamma = @as(f32, @floatFromInt(be16(d, off + 12))) / 256.0 };
        }
        if (off + 12 + n * 2 > d.len) return Curve{};
        return Curve{ .kind = 2, .off = off + 12, .n = n, .wide = true };
    }
    if (std.mem.eql(u8, sig, "para")) {
        // 매개변수 곡선 — 형 0(감마만) 은 그대로, 나머지는 근사로 감마를 쓴다
        const g = s15(d, off + 12);
        return Curve{ .kind = 1, .gamma = if (g > 0.01 and g < 10) g else 2.2 };
    }
    _ = len;
    return Curve{};
}

fn curveAt(d: []const u8, c: Curve, x: f32) f32 {
    const v = @max(@as(f32, 0), @min(@as(f32, 1), x));
    switch (c.kind) {
        1 => return std.math.pow(f32, v, c.gamma),
        2 => {
            if (c.n < 2) return v;
            const f = v * @as(f32, @floatFromInt(c.n - 1));
            const lo: u32 = @intFromFloat(@floor(f));
            const hi = @min(c.n - 1, lo + 1);
            const t = f - @floor(f);
            const a = @as(f32, @floatFromInt(be16(d, c.off + lo * 2))) / 65535.0;
            const b = @as(f32, @floatFromInt(be16(d, c.off + hi * 2))) / 65535.0;
            return a + (b - a) * t;
        },
        else => return v,
    }
}

/// 프로파일을 읽는다. 못 읽으면 kind = .none.
pub fn parse(d: []const u8) Profile {
    var p = Profile{ .data = d };
    if (d.len < 132) return p;
    const space = d[16..20];
    const pcs = d[20..24];
    p.pcs_lab = std.mem.eql(u8, pcs, "Lab ");
    p.ncomp = if (std.mem.eql(u8, space, "CMYK")) 4
        else if (std.mem.eql(u8, space, "GRAY")) 1
        else 3;

    // 1) A2B0 — 격자표를 쓰는 프로파일 (인쇄용 CMYK 가 거의 다 이것)
    if (tagAt(d, "A2B0")) |t| {
        const o = t.off;
        if (o + 32 <= d.len) {
            const sig = d[o .. o + 4];
            const mft1 = std.mem.eql(u8, sig, "mft1");
            const mft2 = std.mem.eql(u8, sig, "mft2");
            if (mft1 or mft2) {
                const in_ch = d[o + 8];
                const out_ch = d[o + 9];
                const grid = d[o + 10];
                if (in_ch >= 1 and in_ch <= 4 and out_ch == 3 and grid >= 2) {
                    p.kind = .lut;
                    p.ncomp = in_ch;
                    p.out_ch = out_ch;
                    p.grid = grid;
                    p.wide = mft2;
                    var at: u32 = o + 48; // 머리 + 3x3 행렬
                    if (mft2) {
                        p.in_n = be16(d, o + 48);
                        p.out_n = be16(d, o + 50);
                        at = o + 52;
                    } else {
                        p.in_n = 256;
                        p.out_n = 256;
                    }
                    const wsz: u32 = if (mft2) 2 else 1;
                    p.in_tab = at;
                    at += @as(u32, in_ch) * p.in_n * wsz;
                    p.clut = at;
                    var pts: u32 = 1;
                    var i: u8 = 0;
                    while (i < in_ch) : (i += 1) pts *= grid;
                    at += pts * out_ch * wsz;
                    p.out_tab = at;
                    if (at + @as(u32, out_ch) * p.out_n * wsz <= d.len) return p;
                    p.kind = .none;
                }
            }
        }
    }
    // 2) matrix/TRC — RGB
    if (tagAt(d, "rXYZ")) |r| {
        if (tagAt(d, "gXYZ")) |g| {
            if (tagAt(d, "bXYZ")) |b| {
                p.kind = .matrix;
                p.ncomp = 3;
                p.pcs_lab = false;
                p.m[0] = s15(d, r.off + 8);
                p.m[3] = s15(d, r.off + 12);
                p.m[6] = s15(d, r.off + 16);
                p.m[1] = s15(d, g.off + 8);
                p.m[4] = s15(d, g.off + 12);
                p.m[7] = s15(d, g.off + 16);
                p.m[2] = s15(d, b.off + 8);
                p.m[5] = s15(d, b.off + 12);
                p.m[8] = s15(d, b.off + 16);
                if (tagAt(d, "rTRC")) |c| p.trc[0] = readCurve(d, c.off, c.len);
                if (tagAt(d, "gTRC")) |c| p.trc[1] = readCurve(d, c.off, c.len);
                if (tagAt(d, "bTRC")) |c| p.trc[2] = readCurve(d, c.off, c.len);
                return p;
            }
        }
    }
    // 3) 회색
    if (tagAt(d, "kTRC")) |c| {
        p.kind = .gray;
        p.ncomp = 1;
        p.pcs_lab = false;
        p.trc[0] = readCurve(d, c.off, c.len);
        return p;
    }
    return p;
}

fn tabAt(d: []const u8, base: u32, i: u32, wide: bool) f32 {
    if (wide) return @as(f32, @floatFromInt(be16(d, base + i * 2))) / 65535.0;
    if (base + i >= d.len) return 0;
    return @as(f32, @floatFromInt(d[base + i])) / 255.0;
}

/// 격자표를 여러 방향으로 사이에 끼워 읽는다 (다중 선형).
fn clutLookup(p: *const Profile, in: []const f32, out: *[3]f32) void {
    const d = p.data;
    const g: u32 = p.grid;
    const n = p.ncomp;
    const wsz: u32 = if (p.wide) 2 else 1;
    var base: [4]u32 = .{ 0, 0, 0, 0 };
    var frac: [4]f32 = .{ 0, 0, 0, 0 };
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const v = @max(@as(f32, 0), @min(@as(f32, 1), in[i])) * @as(f32, @floatFromInt(g - 1));
        const f0 = @floor(v);
        base[i] = @min(g - 1, @as(u32, @intFromFloat(f0)));
        frac[i] = v - f0;
    }
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    // 모서리 2^n 개를 무게로 섞는다
    const corners: u32 = @as(u32, 1) << @intCast(n);
    var c: u32 = 0;
    while (c < corners) : (c += 1) {
        var w: f32 = 1;
        var idx: u32 = 0;
        var k: u8 = 0;
        while (k < n) : (k += 1) {
            const up = (c >> @intCast(k)) & 1 == 1;
            const at = if (up) @min(g - 1, base[k] + 1) else base[k];
            w *= if (up) frac[k] else 1 - frac[k];
            idx = idx * g + at;
        }
        if (w == 0) continue;
        const cell = p.clut + idx * p.out_ch * wsz;
        var o: u8 = 0;
        while (o < 3) : (o += 1) {
            out[o] += w * tabAt(d, cell + @as(u32, o) * wsz, 0, p.wide);
        }
    }
}

/// D50 XYZ → sRGB (Bradford 로 D65 에 맞춘 뒤 감마)
fn xyzToSrgb(x: f32, y: f32, z: f32, out: *[3]f32) void {
    // D50 XYZ → 선형 sRGB (Bradford 적응이 들어 있는 행렬)
    const r = 3.1338561 * x - 1.6168667 * y - 0.4906146 * z;
    const g = -0.9787684 * x + 1.9161415 * y + 0.0334540 * z;
    const b = 0.0719453 * x - 0.2289914 * y + 1.4052427 * z;
    const enc = struct {
        fn f(v: f32) f32 {
            const c = @max(@as(f32, 0), @min(@as(f32, 1), v));
            return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
        }
    };
    out[0] = enc.f(r);
    out[1] = enc.f(g);
    out[2] = enc.f(b);
}

fn labToXyz(l: f32, a: f32, bb: f32, out: *[3]f32) void {
    const fy = (l + 16) / 116;
    const fx = fy + a / 500;
    const fz = fy - bb / 200;
    const inv = struct {
        fn f(t: f32) f32 {
            return if (t > 6.0 / 29.0) t * t * t else 3 * (6.0 / 29.0) * (6.0 / 29.0) * (t - 4.0 / 29.0);
        }
    };
    // D50 흰점
    out[0] = 0.9642 * inv.f(fx);
    out[1] = 1.0 * inv.f(fy);
    out[2] = 0.8249 * inv.f(fz);
}

/// 성분 값(0~1)을 sRGB(0~1)로 옮긴다. 못 하면 false.
pub fn toRgb(p: *const Profile, in: []const f32, out: *[3]f32) bool {
    const d = p.data;
    switch (p.kind) {
        .lut => {
            if (in.len < p.ncomp) return false;
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            const wsz: u32 = if (p.wide) 2 else 1;
            var i: u8 = 0;
            while (i < p.ncomp) : (i += 1) {
                // 입력 곡선
                const base = p.in_tab + @as(u32, i) * p.in_n * wsz;
                const x = @max(@as(f32, 0), @min(@as(f32, 1), in[i]));
                if (p.in_n < 2) { v[i] = x; continue; }
                const f = x * @as(f32, @floatFromInt(p.in_n - 1));
                const lo: u32 = @intFromFloat(@floor(f));
                const hi = @min(p.in_n - 1, lo + 1);
                const t = f - @floor(f);
                const a = tabAt(d, base, lo, p.wide);
                const b = tabAt(d, base, hi, p.wide);
                v[i] = a + (b - a) * t;
            }
            var pcs: [3]f32 = .{ 0, 0, 0 };
            clutLookup(p, v[0..p.ncomp], &pcs);
            // 출력 곡선
            var o: u8 = 0;
            while (o < 3) : (o += 1) {
                const base = p.out_tab + @as(u32, o) * p.out_n * wsz;
                if (p.out_n < 2) continue;
                const f = @max(@as(f32, 0), @min(@as(f32, 1), pcs[o])) *
                    @as(f32, @floatFromInt(p.out_n - 1));
                const lo: u32 = @intFromFloat(@floor(f));
                const hi = @min(p.out_n - 1, lo + 1);
                const t = f - @floor(f);
                const a = tabAt(d, base, lo, p.wide);
                const b = tabAt(d, base, hi, p.wide);
                pcs[o] = a + (b - a) * t;
            }
            if (p.pcs_lab) {
                // Lab 은 0~1 로 담겨 있다. 규격이 정한 범위로 편다.
                // mft1(8비트)과 mft2(16비트)의 범위가 다르다.
                const l = pcs[0] * 100;
                const aa = if (p.wide) pcs[1] * (255.0 * 65535.0 / 65280.0) - 128
                    else pcs[1] * 255 - 128;
                const bb = if (p.wide) pcs[2] * (255.0 * 65535.0 / 65280.0) - 128
                    else pcs[2] * 255 - 128;
                var xyz: [3]f32 = .{ 0, 0, 0 };
                labToXyz(l, aa, bb, &xyz);
                xyzToSrgb(xyz[0], xyz[1], xyz[2], out);
            } else {
                // XYZ 는 0~1.99997 로 담긴다
                xyzToSrgb(pcs[0] * 1.999969, pcs[1] * 1.999969, pcs[2] * 1.999969, out);
            }
            return true;
        },
        .matrix => {
            if (in.len < 3) return false;
            const r = curveAt(d, p.trc[0], in[0]);
            const g = curveAt(d, p.trc[1], in[1]);
            const b = curveAt(d, p.trc[2], in[2]);
            const x = p.m[0] * r + p.m[1] * g + p.m[2] * b;
            const y = p.m[3] * r + p.m[4] * g + p.m[5] * b;
            const z = p.m[6] * r + p.m[7] * g + p.m[8] * b;
            xyzToSrgb(x, y, z, out);
            return true;
        },
        .gray => {
            if (in.len < 1) return false;
            const v = curveAt(d, p.trc[0], in[0]);
            // 회색은 밝기만 있다 — 감마를 되돌린 값을 sRGB 로 다시 씌운다
            const xyz: [3]f32 = .{ 0.9642 * v, v, 0.8249 * v };
            xyzToSrgb(xyz[0], xyz[1], xyz[2], out);
            return true;
        },
        .none => return false,
    }
}
