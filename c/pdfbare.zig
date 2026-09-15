// 겉모습(/AP)이 없는 주석을 규격의 기본 모양으로 그린다.
//
// 주석은 보통 /AP /N 에 제 모습을 그려 두고, 뷰어는 그것을 그대로 그린다.
// 그런데 겉모습 없이 자리와 색만 적어 둔 주석도 흔하다 — 어떤 만들기 도구는
// "뷰어가 알아서 그리라" 고 /AP 를 아예 안 넣는다. pdf.js 도 poppler 도
// 그런 주석을 종류마다 기본 모양으로 그린다(둘이 1% 안에서 같다). 우리만
// 빈자리로 두면 형광펜·네모·잉크가 통째로 사라진다.
//
// 그리는 것: 네모·동그라미·선·잉크·형광펜·밑줄·취소선·물결·다각형·꺾은선.
// 안 그리는 것: 글자가 드는 /FreeText 와 아이콘인 /Text — 글꼴과 아이콘 그림은
// 뷰어마다 달라 맞댈 기준이 없다. 위젯은 양식 층이 맡는다.
//
// 값은 규격 12.5.6 대로다. 테두리 색 /C, 속 색 /IC(둘 다 빈 배열이면 안
// 칠함), 굵기·점선 /BS(없으면 /Border, 그것도 없으면 1), 투명도 /CA.
// 모양은 pdf.js 의 기본 겉모습을 따랐다 — 밑줄은 바닥에서 1.3 위, 취소선은
// 한가운데, 물결은 높이의 1/6 을 폭으로 하는 톱니.
const core = @import("pdf.zig");

const Color = struct { rgb: [3]f32 = .{ 0, 0, 0 }, on: bool = false };

/// /C [..] 꼴의 색. 회색 하나·RGB 셋·CMYK 넷. 빈 배열은 "칠하지 않음".
fn colorAt(b: []const u8, from: usize, to: usize, key: []const u8) Color {
    const ca = core.keyPos(b, from, to, key) orelse return .{};
    var cp = ca + key.len;
    while (cp < to and core.isSpace(b[cp])) cp += 1;
    if (cp >= to or b[cp] != '[') return .{};
    cp += 1;
    var vals: [4]f32 = .{ 0, 0, 0, 0 };
    var n: u32 = 0;
    while (n < 4 and cp < to) {
        while (cp < to and core.isSpace(b[cp])) cp += 1;
        if (cp >= to or b[cp] == ']') break;
        vals[n] = core.readFloat(b, &cp);
        n += 1;
    }
    return switch (n) {
        1 => .{ .rgb = .{ vals[0], vals[0], vals[0] }, .on = true },
        3 => .{ .rgb = .{ vals[0], vals[1], vals[2] }, .on = true },
        4 => blk: {
            var rgb: [3]f32 = .{ 0, 0, 0 };
            core.cmykRgb(vals[0], vals[1], vals[2], vals[3], &rgb);
            break :blk .{ .rgb = rgb, .on = true };
        },
        else => .{},
    };
}

/// /Key [n n n …] 의 수들을 out 에 담고 개수를 돌려준다.
fn numsAt(b: []const u8, from: usize, to: usize, key: []const u8, out: []f32) u32 {
    const ka = core.keyPos(b, from, to, key) orelse return 0;
    var p = ka + key.len;
    while (p < to and core.isSpace(b[p])) p += 1;
    if (p >= to or b[p] != '[') return 0;
    const e = core.arrayEnd(b, p, to);
    p += 1;
    var n: u32 = 0;
    while (n < out.len and p < e) {
        while (p < e and (core.isSpace(b[p]) or b[p] == '[' or b[p] == ']')) p += 1;
        if (p >= e) break;
        if (!(core.isDigit(b[p]) or b[p] == '-' or b[p] == '.' or b[p] == '+')) { p += 1; continue; }
        out[n] = core.readFloat(b, &p);
        n += 1;
    }
    return n;
}

/// 획 굵기와 점선. /BS << /W 2 /S /D /D [3 2] >> 가 먼저, 없으면 /Border [h v w [d]].
///
/// 둘 다 없으면 1 이다 — 규격 12.5.2 의 /Border 기본값 [0 0 1]. pdf.js 는 이때
/// 0 으로 보고 안 그리지만 poppler 는 1pt 로 그린다(annots.pdf 의 네모:
/// poppler 파란 화소 1,251 ≈ 둘레). 규격과 poppler 를 따른다.
fn strokeStyle(b: []const u8, from: usize, to: usize, dash: *[6]f32, dash_n: *u32) f32 {
    var w: f32 = 1;
    if (core.keyPos(b, from, to, "/BS")) |bs| {
        var p = bs + 3;
        while (p < to and core.isSpace(b[p])) p += 1;
        if (p < to and b[p] == '<') {
            const e = core.dictEnd(b, p, to);
            if (core.keyPos(b, p, e, "/W")) |wa| {
                var q = wa + 2;
                while (q < e and core.isSpace(b[q])) q += 1;
                if (q < e) w = core.readFloat(b, &q);
            }
            var st: [8]u8 = undefined;
            const sn = core.nameAfter(b, p, e, "/S", &st);
            if (sn == 1 and st[0] == 'D') {
                // /S /D /D [4 2] — 앞의 /D 는 /S 의 값이다. 뒤에 [ 가 오는 /D 를 찾는다.
                var at = p;
                dash_n.* = 0;
                while (core.keyPos(b, at, e, "/D")) |da| {
                    var q = da + 2;
                    while (q < e and core.isSpace(b[q])) q += 1;
                    if (q < e and b[q] == '[') { dash_n.* = numsAt(b, da, e, "/D", dash); break; }
                    at = da + 2;
                }
                if (dash_n.* == 0) { dash[0] = 3; dash_n.* = 1; }
            }
        }
    } else if (core.keyPos(b, from, to, "/Border")) |ba| {
        var v: [3]f32 = .{ 0, 0, 1 };
        if (numsAt(b, ba, to, "/Border", &v) >= 3) w = v[2];
    }
    return if (w < 0) 0 else w;
}

fn move(x: f32, y: f32) void { core.emitOp(1, &[_]f32{ x, y }); }
fn line(x: f32, y: f32) void { core.emitOp(2, &[_]f32{ x, y }); }

/// 네 점 베지에로 타원. k = 4(√2−1)/3.
fn ellipse(x0: f32, y0: f32, x1: f32, y1: f32) void {
    const k: f32 = 0.5523;
    const cx = (x0 + x1) / 2;
    const cy = (y0 + y1) / 2;
    const rx = (x1 - x0) / 2;
    const ry = (y1 - y0) / 2;
    move(cx + rx, cy);
    core.emitOp(3, &[_]f32{ cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry });
    core.emitOp(3, &[_]f32{ cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy });
    core.emitOp(3, &[_]f32{ cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry });
    core.emitOp(3, &[_]f32{ cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy });
    core.emitOp(4, &[_]f32{});
}

/// 속과 테두리 가운데 켜진 것으로 지금 경로를 칠한다.
fn paint(fill: Color, stroke: Color, w: f32) void {
    const s = stroke.on and w > 0;
    if (fill.on and s) core.emitOp(8, &[_]f32{0})
    else if (fill.on) core.emitOp(6, &[_]f32{0})
    else if (s) core.emitOp(7, &[_]f32{})
    else core.emitOp(9, &[_]f32{});
}

/// 주석 딕셔너리 [ab, abe) 를 기본 모양으로 그린다. 아는 종류가 아니면 false.
pub fn draw(b: []const u8, ab: usize, abe: usize, rect: [4]f32) bool {
    var st: [16]u8 = undefined;
    const sn = core.nameAfter(b, ab, abe, "/Subtype", &st);
    const sub = st[0..sn];
    const K = enum { square, circle, line_, ink, highlight, underline, strikeout, squiggly, polygon, polyline, none };
    const kind: K = if (core.std_mem_eq(sub, "Square")) .square
        else if (core.std_mem_eq(sub, "Circle")) .circle
        else if (core.std_mem_eq(sub, "Line")) .line_
        else if (core.std_mem_eq(sub, "Ink")) .ink
        else if (core.std_mem_eq(sub, "Highlight")) .highlight
        else if (core.std_mem_eq(sub, "Underline")) .underline
        else if (core.std_mem_eq(sub, "StrikeOut")) .strikeout
        else if (core.std_mem_eq(sub, "Squiggly")) .squiggly
        else if (core.std_mem_eq(sub, "Polygon")) .polygon
        else if (core.std_mem_eq(sub, "PolyLine")) .polyline
        else .none;
    if (kind == .none) return false;

    const stroke = colorAt(b, ab, abe, "/C");
    const fill = colorAt(b, ab, abe, "/IC");
    var dash: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
    var dash_n: u32 = 0;
    const w = strokeStyle(b, ab, abe, &dash, &dash_n);
    var alpha: f32 = 1;
    if (core.keyPos(b, ab, abe, "/CA")) |ca| {
        var q = ca + 3;
        while (q < abe and core.isSpace(b[q])) q += 1;
        if (q < abe and (core.isDigit(b[q]) or b[q] == '.')) alpha = core.readFloat(b, &q);
    }

    core.emitOp(14, &[_]f32{});
    // 깨끗한 상태에서 — 앞의 투명도·섞기·점선이 남아 있으면 엉뚱하게 나온다
    core.emitOp(21, &[_]f32{alpha});
    core.emitOp(23, &[_]f32{alpha});
    core.emitOp(26, &[_]f32{0});
    core.emitOp(24, &[_]f32{ @floatFromInt(dash_n), dash[0], dash[1], dash[2], dash[3], dash[4], dash[5], 0 });
    core.emitOp(19, &[_]f32{0});
    core.emitOp(20, &[_]f32{0});
    core.emitOp(13, &[_]f32{w});
    core.emitOp(12, &[_]f32{ stroke.rgb[0], stroke.rgb[1], stroke.rgb[2] });
    core.emitOp(11, &[_]f32{ fill.rgb[0], fill.rgb[1], fill.rgb[2] });
    core.emitOp(9, &[_]f32{});

    switch (kind) {
        .square => {
            // 테두리는 /Rect 안쪽에 들어와야 한다 — 반 굵기만큼 들여 그린다
            const h = w / 2;
            core.emitOp(5, &[_]f32{ rect[0] + h, rect[1] + h, rect[2] - rect[0] - w, rect[3] - rect[1] - w });
            paint(fill, stroke, w);
        },
        .circle => {
            const h = w / 2;
            ellipse(rect[0] + h, rect[1] + h, rect[2] - h, rect[3] - h);
            paint(fill, stroke, w);
        },
        .line_ => {
            var l: [4]f32 = .{ 0, 0, 0, 0 };
            if (numsAt(b, ab, abe, "/L", &l) == 4) {
                move(l[0], l[1]);
                line(l[2], l[3]);
                paint(.{}, stroke, w);
            }
        },
        .ink => {
            // /InkList [[x y x y …] [ … ]] — 획마다 배열 하나
            if (core.keyPos(b, ab, abe, "/InkList")) |ia| {
                var p = ia + 8;
                while (p < abe and core.isSpace(b[p])) p += 1;
                if (p < abe and b[p] == '[') {
                    const e = core.arrayEnd(b, p, abe);
                    p += 1;
                    core.emitOp(19, &[_]f32{1});
                    core.emitOp(20, &[_]f32{1});
                    while (p < e) {
                        while (p < e and b[p] != '[') p += 1;
                        if (p >= e) break;
                        const se = core.arrayEnd(b, p, e);
                        p += 1;
                        var n: u32 = 0;
                        while (p < se) {
                            while (p < se and core.isSpace(b[p])) p += 1;
                            if (p >= se or b[p] == ']') break;
                            const x = core.readFloat(b, &p);
                            while (p < se and core.isSpace(b[p])) p += 1;
                            if (p >= se or b[p] == ']') break;
                            const y = core.readFloat(b, &p);
                            if (n == 0) move(x, y) else line(x, y);
                            n += 1;
                        }
                        if (n > 0) paint(.{}, stroke, w);
                        p = se;
                    }
                }
            }
        },
        .highlight, .underline, .strikeout, .squiggly => {
            // /QuadPoints — 넷씩 한 칸: (x1,y1) 왼위 (x2,y2) 오른위 (x3,y3) 왼아래 (x4,y4) 오른아래
            var q: [8 * 64]f32 = undefined;
            const n = numsAt(b, ab, abe, "/QuadPoints", &q) / 8;
            var i: u32 = 0;
            if (kind == .highlight) {
                // 형광펜은 글자 위에 곱해 얹는다 — 안 그러면 글자가 덮인다
                core.emitOp(26, &[_]f32{1});
                core.emitOp(11, &[_]f32{ stroke.rgb[0], stroke.rgb[1], stroke.rgb[2] });
            } else core.emitOp(13, &[_]f32{1});
            while (i < n) : (i += 1) {
                const x1 = q[i * 8];
                const y1 = q[i * 8 + 1];
                const x2 = q[i * 8 + 2];
                const y2 = q[i * 8 + 3];
                const x3 = q[i * 8 + 4];
                const y3 = q[i * 8 + 5];
                const x4 = q[i * 8 + 6];
                const y4 = q[i * 8 + 7];
                switch (kind) {
                    .highlight => {
                        move(x1, y1);
                        line(x2, y2);
                        line(x4, y4);
                        line(x3, y3);
                        core.emitOp(4, &[_]f32{});
                        core.emitOp(6, &[_]f32{0});
                    },
                    .underline => {
                        move(x3, y3 + 1.3);
                        line(x4, y4 + 1.3);
                        core.emitOp(7, &[_]f32{});
                    },
                    .strikeout => {
                        move(x1, (y1 + y3) / 2);
                        line(x2, (y2 + y4) / 2);
                        core.emitOp(7, &[_]f32{});
                    },
                    .squiggly => {
                        const dy = (y1 - y3) / 6;
                        if (dy <= 0.01) continue;
                        var x = x3;
                        var up = false;
                        move(x, y3 + dy);
                        while (x < x4) {
                            x += dy;
                            line(@min(x, x4), if (up) y3 + dy else y3);
                            up = !up;
                        }
                        core.emitOp(7, &[_]f32{});
                    },
                    else => {},
                }
            }
        },
        .polygon, .polyline => {
            var v: [2 * 128]f32 = undefined;
            const n = numsAt(b, ab, abe, "/Vertices", &v) / 2;
            if (n >= 2) {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    if (i == 0) move(v[0], v[1]) else line(v[i * 2], v[i * 2 + 1]);
                }
                if (kind == .polygon) {
                    core.emitOp(4, &[_]f32{});
                    paint(fill, stroke, w);
                } else paint(.{}, stroke, w);
            }
        },
        .none => {},
    }
    core.emitOp(15, &[_]f32{});
    return true;
}
