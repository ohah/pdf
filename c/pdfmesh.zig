//! 그물 셰이딩(4~7형) — 꼭짓점 삼각형·좌표 격자
//!
//! pdf.zig 가 14,000 줄을 넘어 한 파일에서 다루기 어려워졌다. 안팎으로 얽힌
//! 정도를 재서 바깥이 거의 안 쓰는 덩이부터 떼어 낸다. 여기서 바깥이 쓰는
//! 것은 1개다.
//!
//! 반대로 이쪽은 pdf.zig 의 도구를 11개 쓴다. 그것들은 아직 옮길 자리가
//! 마땅치 않아 root. 을 붙여 부른다.

const std = @import("std");
const root = @import("pdf.zig");
const pdfform = @import("pdfform.zig");

// ===== 그물 셰이딩 =====
//
// 4~7형은 색이 면 위에서 이어져 흐른다. 캔버스에는 그런 칠이 없다 —
// 선형·방사형 그라데이션뿐이다. 그래서 잘게 쪼개 단색으로 메운다.
// 충분히 잘게 쪼개면 눈으로는 이어져 보인다. PDF.js 도 결국 같은 일을
// 픽셀 단위로 한다.

/// 그물 스트림에서 비트를 꺼내는 읽개.
const MeshR = struct {
    d: []const u8,
    bit: u64 = 0,

    fn get(self: *MeshR, n: u32) u32 {
        const v = root.bitsAt(self.d, self.bit, n);
        self.bit += n;
        return v;
    }
    /// 꼭짓점·조각 하나는 바이트 경계에서 시작한다
    fn byteAlign(self: *MeshR) void {
        self.bit = (self.bit + 7) & ~@as(u64, 7);
    }
    fn left(self: *const MeshR) u64 {
        const tot = @as(u64, self.d.len) * 8;
        return if (self.bit >= tot) 0 else tot - self.bit;
    }
};

/// 비트로 담긴 값을 Decode 범위로 편다.
fn meshVal(raw: u32, bits: u32, lo: f32, hi: f32) f32 {
    const maxv: f32 = @floatFromInt((@as(u64, 1) << @intCast(bits)) - 1);
    if (maxv <= 0) return lo;
    return lo + (@as(f32, @floatFromInt(raw)) / maxv) * (hi - lo);
}

/// 꼭짓점 색 하나를 읽는다.
fn meshColor(sh: *const root.Shade, r: *MeshR, bpc: u32, dec: []const f32, nd: u32) [3]f32 {
    var out: [3]f32 = .{ 0, 0, 0 };
    if (sh.fe > sh.fs) {
        // 함수를 쓰면 값 하나가 곧 매개변수다
        const lo: f32 = if (nd >= 6) dec[4] else 0;
        const hi: f32 = if (nd >= 6) dec[5] else 1;
        const t = meshVal(r.get(bpc), bpc, lo, hi);
        var v: [4]f32 = .{ 0, 0, 0, 0 };
        const nc = root.shadeFn(root.doc, sh, t, &v);
        root.rgbFrom(nc, v, &out);
        return out;
    }
    var v: [4]f32 = .{ 0, 0, 0, 0 };
    var c: u32 = 0;
    while (c < sh.ncomp and c < 4) : (c += 1) {
        const lo: f32 = if (nd >= 4 + (c + 1) * 2) dec[4 + c * 2] else 0;
        const hi: f32 = if (nd >= 4 + (c + 1) * 2) dec[5 + c * 2] else 1;
        v[c] = meshVal(r.get(bpc), bpc, lo, hi);
    }
    root.rgbFrom(sh.ncomp, v, &out);
    return out;
}

/// 삼각형 하나를 색이 고르게 보일 만큼 쪼개 칠한다.
fn meshTri(p: [3][2]f32, c: [3][3]f32, depth: u32) void {
    if (root.opsRoomLow()) return;
    var diff: f32 = 0;
    var k: u32 = 0;
    while (k < 3) : (k += 1) {
        diff = @max(diff, @abs(c[0][k] - c[1][k]));
        diff = @max(diff, @abs(c[1][k] - c[2][k]));
        diff = @max(diff, @abs(c[0][k] - c[2][k]));
    }
    if (depth < 4 and diff > 0.05) {
        // 변의 가운데를 잡아 넷으로 나눈다
        const m01: [2]f32 = .{ (p[0][0] + p[1][0]) / 2, (p[0][1] + p[1][1]) / 2 };
        const m12: [2]f32 = .{ (p[1][0] + p[2][0]) / 2, (p[1][1] + p[2][1]) / 2 };
        const m20: [2]f32 = .{ (p[2][0] + p[0][0]) / 2, (p[2][1] + p[0][1]) / 2 };
        var k01: [3]f32 = undefined;
        var k12: [3]f32 = undefined;
        var k20: [3]f32 = undefined;
        k = 0;
        while (k < 3) : (k += 1) {
            k01[k] = (c[0][k] + c[1][k]) / 2;
            k12[k] = (c[1][k] + c[2][k]) / 2;
            k20[k] = (c[2][k] + c[0][k]) / 2;
        }
        meshTri(.{ p[0], m01, m20 }, .{ c[0], k01, k20 }, depth + 1);
        meshTri(.{ m01, p[1], m12 }, .{ k01, c[1], k12 }, depth + 1);
        meshTri(.{ m20, m12, p[2] }, .{ k20, k12, c[2] }, depth + 1);
        meshTri(.{ m01, m12, m20 }, .{ k01, k12, k20 }, depth + 1);
        return;
    }
    // 가운데 색으로 메운다. 이음매가 비지 않게 아주 살짝 넓힌다.
    var avg: [3]f32 = .{ 0, 0, 0 };
    k = 0;
    while (k < 3) : (k += 1) avg[k] = (c[0][k] + c[1][k] + c[2][k]) / 3;
    const cx = (p[0][0] + p[1][0] + p[2][0]) / 3;
    const cy = (p[0][1] + p[1][1] + p[2][1]) / 3;
    const g: f32 = 1.04;
    root.emitOp(11, &[_]f32{ avg[0], avg[1], avg[2] });
    root.emitOp(1, &[_]f32{ cx + (p[0][0] - cx) * g, cy + (p[0][1] - cy) * g });
    root.emitOp(2, &[_]f32{ cx + (p[1][0] - cx) * g, cy + (p[1][1] - cy) * g });
    root.emitOp(2, &[_]f32{ cx + (p[2][0] - cx) * g, cy + (p[2][1] - cy) * g });
    root.emitOp(4, &[_]f32{});
    root.emitOp(6, &[_]f32{0});
}

/// 4·5형 — 삼각형 그물
fn paintTriMesh(sh: *const root.Shade) void {
    const b = root.doc;
    const ds = sh.ds;
    const de = sh.de;
    const bpco = root.intAfter(b, ds, de, "/BitsPerCoordinate") orelse return;
    const bpc = root.intAfter(b, ds, de, "/BitsPerComponent") orelse return;
    if (bpco == 0 or bpco > 32 or bpc == 0 or bpc > 16) return;
    const bpf = root.intAfter(b, ds, de, "/BitsPerFlag") orelse 8;
    var dec: [16]f32 = undefined;
    const nd = root.readArr(b, ds, de, "/Decode", &dec);
    if (nd < 4) return;
    const data = pdfform.streamFrom(b, ds) orelse return;
    var r = MeshR{ .d = data };

    const rowlen = root.intAfter(b, ds, de, "/VerticesPerRow") orelse 0;
    const lattice = sh.kind == 5 and rowlen >= 2 and rowlen <= 4096;

    const readPt = struct {
        fn f(rr: *MeshR, bc: u32, d2: []const f32) [2]f32 {
            const x = meshVal(rr.get(bc), bc, d2[0], d2[1]);
            const y = meshVal(rr.get(bc), bc, d2[2], d2[3]);
            return .{ x, y };
        }
    }.f;

    var made: u32 = 0;
    if (lattice) {
        // 격자 — 줄마다 꼭짓점이 rowlen 개, 이웃한 두 줄로 삼각형을 만든다
        var prev_p: [4096][2]f32 = undefined;
        var prev_c: [4096][3]f32 = undefined;
        var cur_p: [4096][2]f32 = undefined;
        var cur_c: [4096][3]f32 = undefined;
        var row: u32 = 0;
        while (r.left() >= (bpco * 2 + bpc) and made < 8000 and !root.opsRoomLow()) : (row += 1) {
            var i: u32 = 0;
            while (i < rowlen and r.left() >= bpco * 2) : (i += 1) {
                cur_p[i] = readPt(&r, bpco, &dec);
                cur_c[i] = meshColor(sh, &r, bpc, &dec, nd);
            }
            if (i < rowlen) break;
            if (row > 0) {
                var j: u32 = 0;
                while (j + 1 < rowlen and made < 8000 and !root.opsRoomLow()) : (j += 1) {
                    meshTri(.{ prev_p[j], prev_p[j + 1], cur_p[j] },
                        .{ prev_c[j], prev_c[j + 1], cur_c[j] }, 0);
                    meshTri(.{ prev_p[j + 1], cur_p[j + 1], cur_p[j] },
                        .{ prev_c[j + 1], cur_c[j + 1], cur_c[j] }, 0);
                    made += 2;
                }
            }
            var k: u32 = 0;
            while (k < rowlen) : (k += 1) { prev_p[k] = cur_p[k]; prev_c[k] = cur_c[k]; }
        }
        return;
    }

    // 자유 그물 — 꼭짓점마다 깃발이 앞선다
    var vp: [3][2]f32 = undefined;
    var vc: [3][3]f32 = undefined;
    var have: u32 = 0;
    while (r.left() >= bpf + bpco * 2 and made < 8000 and !root.opsRoomLow()) {
        const flag = r.get(bpf);
        const pt = readPt(&r, bpco, &dec);
        const col = meshColor(sh, &r, bpc, &dec, nd);
        r.byteAlign();
        if (flag == 0 or have < 2) {
            if (flag == 0 and have >= 3) have = 0;
            if (have >= 3) have = 0;
            vp[have] = pt;
            vc[have] = col;
            have += 1;
            if (have == 3) { meshTri(vp, vc, 0); made += 1; }
            continue;
        }
        if (flag == 1) { vp[0] = vp[1]; vc[0] = vc[1]; }
        vp[1] = vp[2];
        vc[1] = vc[2];
        vp[2] = pt;
        vc[2] = col;
        meshTri(vp, vc, 0);
        made += 1;
    }
}

/// 세제곱 베지에 밑값
fn bez(t: f32) [4]f32 {
    const u = 1 - t;
    return .{ u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t };
}

/// 6·7형 — 이음 조각(Coons·텐서). 조각 하나를 격자로 훑어 칠한다.
fn paintPatchMesh(sh: *const root.Shade) void {
    const b = root.doc;
    const ds = sh.ds;
    const de = sh.de;
    const bpco = root.intAfter(b, ds, de, "/BitsPerCoordinate") orelse return;
    const bpc = root.intAfter(b, ds, de, "/BitsPerComponent") orelse return;
    if (bpco == 0 or bpco > 32 or bpc == 0 or bpc > 16) return;
    const bpf = root.intAfter(b, ds, de, "/BitsPerFlag") orelse 8;
    var dec: [16]f32 = undefined;
    const nd = root.readArr(b, ds, de, "/Decode", &dec);
    if (nd < 4) return;
    const data = pdfform.streamFrom(b, ds) orelse return;
    var r = MeshR{ .d = data };
    const tensor = sh.kind == 7;
    const npt: u32 = if (tensor) 16 else 12;

    // 테두리 점 12 개를 4×4 격자에 놓는 자리 (규격 표 그대로)
    const RC = [12][2]u8{
        .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 },
        .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 }, .{ 3, 2 },
        .{ 3, 1 }, .{ 3, 0 }, .{ 2, 0 }, .{ 1, 0 },
    };
    const IC = [4][2]u8{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 2 }, .{ 2, 1 } };

    var P: [4][4][2]f32 = undefined;
    var C: [4][3]f32 = undefined;
    var first = true;
    var made: u32 = 0;

    while (r.left() >= bpf and made < 512 and !root.opsRoomLow()) {
        const flag = r.get(bpf);
        const nnew: u32 = if (flag == 0 or first) npt else npt - 4;
        const ncol: u32 = if (flag == 0 or first) 4 else 2;
        if (r.left() < nnew * bpco * 2) break;

        var pts: [16][2]f32 = undefined;
        var i: u32 = 0;
        while (i < nnew) : (i += 1) {
            pts[i][0] = meshVal(r.get(bpco), bpco, dec[0], dec[1]);
            pts[i][1] = meshVal(r.get(bpco), bpco, dec[2], dec[3]);
        }
        var cols: [4][3]f32 = undefined;
        i = 0;
        while (i < ncol) : (i += 1) cols[i] = meshColor(sh, &r, bpc, &dec, nd);
        r.byteAlign();

        var NP: [4][4][2]f32 = undefined;
        var NC: [4][3]f32 = undefined;
        if (flag == 0 or first) {
            i = 0;
            while (i < 12) : (i += 1) NP[RC[i][0]][RC[i][1]] = pts[i];
            if (tensor) {
                i = 0;
                while (i < 4) : (i += 1) NP[IC[i][0]][IC[i][1]] = pts[12 + i];
            }
            i = 0;
            while (i < 4) : (i += 1) NC[i] = cols[i];
        } else {
            // 앞 조각의 한 변을 그대로 물려받는다
            const E = switch (flag) {
                1 => [4][2]u8{ .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 } },
                2 => [4][2]u8{ .{ 3, 3 }, .{ 3, 2 }, .{ 3, 1 }, .{ 3, 0 } },
                else => [4][2]u8{ .{ 3, 0 }, .{ 2, 0 }, .{ 1, 0 }, .{ 0, 0 } },
            };
            const EC: [2]u8 = switch (flag) {
                1 => .{ 1, 2 },
                2 => .{ 2, 3 },
                else => .{ 3, 0 },
            };
            i = 0;
            while (i < 4) : (i += 1) NP[RC[i][0]][RC[i][1]] = P[E[i][0]][E[i][1]];
            i = 0;
            while (i < 8) : (i += 1) NP[RC[4 + i][0]][RC[4 + i][1]] = pts[i];
            if (tensor) {
                i = 0;
                while (i < 4) : (i += 1) NP[IC[i][0]][IC[i][1]] = pts[8 + i];
            }
            NC[0] = C[EC[0]];
            NC[1] = C[EC[1]];
            NC[2] = cols[0];
            NC[3] = cols[1];
        }
        if (!tensor) {
            // Coons 조각은 안쪽 점 넷을 테두리에서 계산한다.
            // 표는 모서리 하나마다 [c00 c01 c10 d03 d30 d31 d13 d33] 자리다.
            const CO = [4][8][2]u8{
                .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 0, 3 }, .{ 3, 0 }, .{ 3, 1 }, .{ 1, 3 }, .{ 3, 3 } },
                .{ .{ 0, 3 }, .{ 0, 2 }, .{ 1, 3 }, .{ 0, 0 }, .{ 3, 3 }, .{ 3, 2 }, .{ 1, 0 }, .{ 3, 0 } },
                .{ .{ 3, 3 }, .{ 3, 2 }, .{ 2, 3 }, .{ 3, 0 }, .{ 0, 3 }, .{ 0, 2 }, .{ 2, 0 }, .{ 0, 0 } },
                .{ .{ 3, 0 }, .{ 3, 1 }, .{ 2, 0 }, .{ 3, 3 }, .{ 0, 0 }, .{ 0, 1 }, .{ 2, 3 }, .{ 0, 3 } },
            };
            var e: u32 = 0;
            while (e < 4) : (e += 1) {
                const t2 = CO[e];
                var k2: u32 = 0;
                while (k2 < 2) : (k2 += 1) {
                    const g = &NP;
                    const v = -4 * g[t2[0][0]][t2[0][1]][k2] +
                        6 * (g[t2[1][0]][t2[1][1]][k2] + g[t2[2][0]][t2[2][1]][k2]) -
                        2 * (g[t2[3][0]][t2[3][1]][k2] + g[t2[4][0]][t2[4][1]][k2]) +
                        3 * (g[t2[5][0]][t2[5][1]][k2] + g[t2[6][0]][t2[6][1]][k2]) -
                        g[t2[7][0]][t2[7][1]][k2];
                    NP[IC[e][0]][IC[e][1]][k2] = v / 9;
                }
            }
        }

        // 조각을 N×N 으로 훑어 네모마다 단색으로 메운다
        const N: u32 = 10;
        var a: u32 = 0;
        while (a < N and !root.opsRoomLow()) : (a += 1) {
            var bq: u32 = 0;
            while (bq < N) : (bq += 1) {
                const ua = @as(f32, @floatFromInt(a)) / @as(f32, @floatFromInt(N));
                const ub = @as(f32, @floatFromInt(a + 1)) / @as(f32, @floatFromInt(N));
                const va = @as(f32, @floatFromInt(bq)) / @as(f32, @floatFromInt(N));
                const vb = @as(f32, @floatFromInt(bq + 1)) / @as(f32, @floatFromInt(N));
                const at = struct {
                    fn f(pp: *const [4][4][2]f32, u: f32, v: f32) [2]f32 {
                        const bu = bez(u);
                        const bv = bez(v);
                        var x: f32 = 0;
                        var y: f32 = 0;
                        var ii: u32 = 0;
                        while (ii < 4) : (ii += 1) {
                            var jj: u32 = 0;
                            while (jj < 4) : (jj += 1) {
                                const w = bu[ii] * bv[jj];
                                x += w * pp[ii][jj][0];
                                y += w * pp[ii][jj][1];
                            }
                        }
                        return .{ x, y };
                    }
                }.f;
                // 모서리 색을 두 방향으로 섞는다
                const mix = struct {
                    fn f(cc: *const [4][3]f32, u: f32, v: f32) [3]f32 {
                        var o: [3]f32 = undefined;
                        var k: u32 = 0;
                        while (k < 3) : (k += 1) {
                            const top = cc[0][k] + (cc[1][k] - cc[0][k]) * v;
                            const bot = cc[3][k] + (cc[2][k] - cc[3][k]) * v;
                            o[k] = top + (bot - top) * u;
                        }
                        return o;
                    }
                }.f;
                const p00 = at(&NP, ua, va);
                const p01 = at(&NP, ua, vb);
                const p11 = at(&NP, ub, vb);
                const p10 = at(&NP, ub, va);
                const cm = mix(&NC, (ua + ub) / 2, (va + vb) / 2);
                const gx = (p00[0] + p01[0] + p11[0] + p10[0]) / 4;
                const gy = (p00[1] + p01[1] + p11[1] + p10[1]) / 4;
                const g: f32 = 1.06;
                root.emitOp(11, &[_]f32{ cm[0], cm[1], cm[2] });
                root.emitOp(1, &[_]f32{ gx + (p00[0] - gx) * g, gy + (p00[1] - gy) * g });
                root.emitOp(2, &[_]f32{ gx + (p01[0] - gx) * g, gy + (p01[1] - gy) * g });
                root.emitOp(2, &[_]f32{ gx + (p11[0] - gx) * g, gy + (p11[1] - gy) * g });
                root.emitOp(2, &[_]f32{ gx + (p10[0] - gx) * g, gy + (p10[1] - gy) * g });
                root.emitOp(4, &[_]f32{});
                root.emitOp(6, &[_]f32{0});
            }
        }
        P = NP;
        C = NC;
        first = false;
        made += 1;
    }
}

/// 1형 — x·y 를 받는 함수. 정의역을 격자로 훑어 칠한다.
fn paintFnShade(sh: *const root.Shade) void {
    if (sh.fe <= sh.fs) return;
    const b = root.doc;
    root.emitOp(14, &[_]f32{});
    root.emitOp(16, &[_]f32{ sh.mat[0], sh.mat[1], sh.mat[2], sh.mat[3], sh.mat[4], sh.mat[5] });
    const N: u32 = 24;
    const fx = @as(f32, @floatFromInt(N));
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        var j: u32 = 0;
        while (j < N) : (j += 1) {
            const x0 = sh.dom[0] + (sh.dom[1] - sh.dom[0]) * @as(f32, @floatFromInt(i)) / fx;
            const x1 = sh.dom[0] + (sh.dom[1] - sh.dom[0]) * @as(f32, @floatFromInt(i + 1)) / fx;
            const y0 = sh.dom[2] + (sh.dom[3] - sh.dom[2]) * @as(f32, @floatFromInt(j)) / fx;
            const y1 = sh.dom[2] + (sh.dom[3] - sh.dom[2]) * @as(f32, @floatFromInt(j + 1)) / fx;
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            const nc = root.evalFnN(b, sh.fs, sh.fe, &[_]f32{ (x0 + x1) / 2, (y0 + y1) / 2 }, &v);
            if (nc == 0) continue;
            var rgb3: [3]f32 = .{ 0, 0, 0 };
            root.rgbFrom(nc, v, &rgb3);
            root.emitOp(11, &[_]f32{ rgb3[0], rgb3[1], rgb3[2] });
            root.emitOp(5, &[_]f32{ x0, y0, (x1 - x0) * 1.02, (y1 - y0) * 1.02 });
            root.emitOp(6, &[_]f32{0});
        }
    }
    root.emitOp(15, &[_]f32{});
}

/// 그물의 대표 색 — 무늬를 칠하기 색으로 쓸 때 쓴다.
fn shadeAvg(sh: *const root.Shade, out: *[3]f32) bool {
    if (sh.fe > sh.fs) {
        var acc: [3]f32 = .{ 0, 0, 0 };
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            const nc = root.shadeFn(root.doc, sh, @as(f32, @floatFromInt(i)) / 4, &v);
            if (nc == 0) return false;
            var c3: [3]f32 = .{ 0, 0, 0 };
            root.rgbFrom(nc, v, &c3);
            acc[0] += c3[0] / 5;
            acc[1] += c3[1] / 5;
            acc[2] += c3[2] / 5;
        }
        out.* = acc;
        return true;
    }
    return false;
}

/// 셰이딩을 그리기 명령으로 낸다. code 27 = 영역 칠하기, 28 = 채우기 색으로 삼기
pub fn emitShade(sh: *const root.Shade, code: f32) void {
    if (sh.kind == 1 or sh.kind >= 4) {
        // 캔버스 그라데이션으로는 못 그린다. 잘게 쪼개 메운다.
        if (code == 28) {
            // 칠하기 색 자리에는 대표 색만 놓는다
            var c3: [3]f32 = .{ 0.5, 0.5, 0.5 };
            _ = shadeAvg(sh, &c3);
            root.emitOp(11, &[_]f32{ c3[0], c3[1], c3[2] });
            return;
        }
        if (sh.kind == 1) paintFnShade(sh)
        else if (sh.kind == 4 or sh.kind == 5) paintTriMesh(sh)
        else paintPatchMesh(sh);
        return;
    }
    emitShadeGrad(sh, code);
}

fn emitShadeGrad(sh: *const root.Shade, code: f32) void {
    // 10 + 마디 8개 × 4 = 42 칸이 필요하다. 40 으로 두었더니 마지막 마디의
    // 뒤 두 칸이 배열 밖이었고(ReleaseSmall 이라 경계 검사도 없다), 자르는
    // 길이도 arg[0..42] 라 스택 8바이트를 그대로 실어 보냈다.
    var arg: [10 + 8 * 4]f32 = undefined;
    arg[0] = @floatFromInt(sh.kind);
    var i: u32 = 0;
    while (i < 6) : (i += 1) arg[1 + i] = sh.coords[i];
    arg[7] = if (sh.ext0) 1 else 0;
    arg[8] = if (sh.ext1) 1 else 0;
    arg[9] = @floatFromInt(sh.stop_n);
    var k: u32 = 0;
    while (k < sh.stop_n and k < 8) : (k += 1) {
        arg[10 + k * 4] = sh.stops[k * 4];
        arg[11 + k * 4] = sh.stops[k * 4 + 1];
        arg[12 + k * 4] = sh.stops[k * 4 + 2];
        arg[13 + k * 4] = sh.stops[k * 4 + 3];
    }
    root.emitOp(code, arg[0 .. 10 + @as(usize, sh.stop_n) * 4]);
}

