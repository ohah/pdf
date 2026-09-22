// 겉모습(/AP)이 없는 주석을 규격의 기본 모양으로 그린다.
//
// 주석은 보통 /AP /N 에 제 모습을 그려 두고, 뷰어는 그것을 그대로 그린다.
// 그런데 겉모습 없이 자리와 색만 적어 둔 주석도 흔하다 — 어떤 만들기 도구는
// "뷰어가 알아서 그리라" 고 /AP 를 아예 안 넣는다. pdf.js 도 poppler 도
// 그런 주석을 종류마다 기본 모양으로 그린다(둘이 1% 안에서 같다). 우리만
// 빈자리로 두면 형광펜·네모·잉크가 통째로 사라진다.
//
// 그리는 것: 네모·동그라미·선·잉크·형광펜·밑줄·취소선·물결·다각형·꺾은선,
// 글상자(/FreeText — 시스템 글꼴로), 위젯의 틀(/MK·/BS).
// 안 그리는 것: 메모 아이콘 /Text — 아이콘 그림이 뷰어마다 다르다.
//
// 값은 규격 12.5.6 대로다. 테두리 색 /C, 속 색 /IC(둘 다 빈 배열이면 안
// 칠함), 굵기·점선 /BS(없으면 /Border, 그것도 없으면 1), 투명도 /CA.
// 모양은 pdf.js 의 기본 겉모습을 따랐다 — 밑줄은 바닥에서 1.3 위, 취소선은
// 한가운데, 물결은 높이의 1/6 을 폭으로 하는 톱니.
const core = @import("pdf.zig");

const Color = struct { rgb: [3]f32 = .{ 0, 0, 0 }, on: bool = false };

/// /Key [..] 꼴의 색 배열 성분을 out 에 담고 개수를 준다 — 1 회색 · 3 RGB · 4 CMYK.
/// 없거나 빈 배열이면 0. 주석 목록(pdfannot)·기본 모양·칸 틀이 다 이걸 쓴다.
pub fn colorArray(b: []const u8, from: usize, to: usize, key: []const u8, out: *[4]f32) u32 {
    const ca = core.keyPos(b, from, to, key) orelse return 0;
    var cp = ca + key.len;
    while (cp < to and core.isSpace(b[cp])) cp += 1;
    if (cp >= to or b[cp] != '[') return 0;
    cp += 1;
    var n: u32 = 0;
    while (n < 4 and cp < to) {
        while (cp < to and core.isSpace(b[cp])) cp += 1;
        if (cp >= to or b[cp] == ']') break;
        out[n] = core.readFloat(b, &cp);
        n += 1;
    }
    return if (n == 1 or n == 3 or n == 4) n else 0;
}

/// 색 배열 성분을 RGB 로. n 이 0 이면 "칠하지 않음".
pub fn toRgb(vals: [4]f32, n: u32) [3]f32 {
    if (n == 1) return .{ vals[0], vals[0], vals[0] };
    if (n == 4) {
        var rgb: [3]f32 = .{ 0, 0, 0 };
        core.cmykRgb(vals[0], vals[1], vals[2], vals[3], &rgb);
        return rgb;
    }
    return .{ vals[0], vals[1], vals[2] };
}

fn colorAt(b: []const u8, from: usize, to: usize, key: []const u8) Color {
    var vals: [4]f32 = .{ 0, 0, 0, 0 };
    const n = colorArray(b, from, to, key, &vals);
    return .{ .rgb = toRgb(vals, n), .on = n != 0 };
}

/// /Key [n n n …] 의 수들을 out 에 담고 개수를 돌려준다.
fn numsAt(b: []const u8, from: usize, to: usize, key: []const u8, out: []f32) u32 {
    // keyPos 로 찾는다 — find 는 /L 을 /LE 에서도 잡는다
    const ka = core.keyPos(b, from, to, key) orelse return 0;
    return core.readArrFrom(b, ka + key.len, to, out);
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

/// 콘텐츠 스트림 글자를 쌓는 작은 붓.
const Pen = struct {
    d: []u8,
    n: usize = 0,
    fn s(self: *Pen, t: []const u8) void {
        if (self.n + t.len > self.d.len) return;
        @memcpy(self.d[self.n..][0..t.len], t);
        self.n += t.len;
    }
    /// 소수 둘째 자리까지. 음수도 된다.
    fn f(self: *Pen, v: f32) void {
        if (self.n + 16 > self.d.len) return;
        var x = v;
        if (x < 0) { self.d[self.n] = '-'; self.n += 1; x = -x; }
        const c: u32 = @intFromFloat(@min(1.0e8, x * 100 + 0.5));
        self.n += core.putNum(self.d[self.n..], c / 100);
        self.d[self.n] = '.';
        self.n += 1;
        const r = c % 100;
        self.d[self.n] = @intCast('0' + r / 10);
        self.d[self.n + 1] = @intCast('0' + r % 10);
        self.n += 2;
        self.d[self.n] = ' ';
        self.n += 1;
    }
    /// /MK 의 색 배열을 rg·g·k 연산자로. 빈 배열이면 false.
    fn color(self: *Pen, b: []const u8, from: usize, to: usize, key: []const u8, fill: bool) bool {
        var vals: [4]f32 = .{ 0, 0, 0, 0 };
        const n = colorArray(b, from, to, key, &vals);
        if (n == 0) return false;
        var i: u32 = 0;
        while (i < n) : (i += 1) self.f(vals[i]);
        self.s(if (n == 1) (if (fill) "g " else "G ") else if (n == 3) (if (fill) "rg " else "RG ") else (if (fill) "k " else "K "));
        return true;
    }
};

/// 입력 칸의 틀 — 바탕(/MK /BG)과 테두리(/MK /BC, /BS 의 굵기·모양)를 콘텐츠
/// 스트림 글자로 낸다. 자리는 (0,0)–(w,h). 규격 12.5.4·12.7.3.3, poppler 의
/// AnnotWidget 과 같은 꼴: S 실선 · D 점선 · U 밑줄 · B 도드라짐 · I 파임.
///
/// 저장 때 새 겉모습에 앞세우고(pdfapply), 겉모습 없는 위젯을 그릴 때도 쓴다.
/// 안 하면 채운 칸의 테두리가 다른 뷰어에서 사라진다.
pub fn widgetFrame(b: []const u8, ab: usize, abe: usize, w: f32, h: f32, out: []u8) usize {
    var pen = Pen{ .d = out };
    var mk_s: usize = 0;
    var mk_e: usize = 0;
    if (core.keyPos(b, ab, abe, "/MK")) |ma| {
        var p = ma + 3;
        while (p < abe and core.isSpace(b[p])) p += 1;
        if (p < abe and b[p] == '<') { mk_s = p; mk_e = core.dictEnd(b, p, abe); }
    }
    var dash: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
    var dash_n: u32 = 0;
    const bw = strokeStyle(b, ab, abe, &dash, &dash_n);
    var st: [8]u8 = .{ 'S', 0, 0, 0, 0, 0, 0, 0 };
    if (core.keyPos(b, ab, abe, "/BS")) |bs| {
        var p = bs + 3;
        while (p < abe and core.isSpace(b[p])) p += 1;
        if (p < abe and b[p] == '<') {
            var tmp: [8]u8 = undefined;
            if (core.nameAfter(b, p, core.dictEnd(b, p, abe), "/S", &tmp) >= 1) st[0] = tmp[0];
        }
    }
    pen.s("q ");
    // 바탕
    if (mk_e > mk_s and pen.color(b, mk_s, mk_e, "/BG", true)) {
        pen.s("0 0 "); pen.f(w); pen.f(h); pen.s("re f\n");
    }
    // 테두리
    if (mk_e > mk_s and bw > 0 and pen.color(b, mk_s, mk_e, "/BC", false)) {
        pen.f(bw); pen.s("w ");
        if (st[0] == 'D') {
            pen.s("[");
            var i: u32 = 0;
            while (i < dash_n) : (i += 1) pen.f(dash[i]);
            pen.s("] 0 d ");
        }
        const hw = bw / 2;
        if (st[0] == 'U') {
            pen.s("0 "); pen.f(hw); pen.s("m "); pen.f(w); pen.f(hw); pen.s("l S\n");
        } else {
            pen.f(hw); pen.f(hw); pen.f(w - bw); pen.f(h - bw); pen.s("re S\n");
        }
        // 도드라짐·파임 — 테두리 안쪽에 굵기만큼의 비스듬한 띠. 왼쪽 위와
        // 오른쪽 아래가 밝기가 다르다(B: 흰·회색, I: 회색·밝은 회색).
        if (st[0] == 'B' or st[0] == 'I') {
            const lt: []const u8 = if (st[0] == 'B') "1 g " else "0.5 g ";
            const rb: []const u8 = if (st[0] == 'B') "0.5 g " else "0.75 g ";
            const o = bw; // 바깥 테두리 안쪽부터
            const inn = bw * 2; // 띠 안쪽
            pen.s(lt);
            pen.f(o); pen.f(o); pen.s("m "); pen.f(o); pen.f(h - o); pen.s("l ");
            pen.f(w - o); pen.f(h - o); pen.s("l "); pen.f(w - inn); pen.f(h - inn); pen.s("l ");
            pen.f(inn); pen.f(h - inn); pen.s("l "); pen.f(inn); pen.f(inn); pen.s("l f\n");
            pen.s(rb);
            pen.f(w - o); pen.f(h - o); pen.s("m "); pen.f(w - o); pen.f(o); pen.s("l ");
            pen.f(o); pen.f(o); pen.s("l "); pen.f(inn); pen.f(inn); pen.s("l ");
            pen.f(w - inn); pen.f(inn); pen.s("l "); pen.f(w - inn); pen.f(h - inn); pen.s("l f\n");
        }
    }
    pen.s("Q\n");
    return pen.n;
}

/// 겉모습 없는 위젯 — 틀만 그린다. 값 글자는 글꼴이 없어 못 그린다(양식 층이 맡는다).
fn drawWidget(b: []const u8, ab: usize, abe: usize, rect: [4]f32) void {
    var buf: [1024]u8 = undefined;
    const n = widgetFrame(b, ab, abe, rect[2] - rect[0], rect[3] - rect[1], &buf);
    if (n <= 4) return; // "q Q" 뿐
    core.emitOp(14, &[_]f32{});
    core.emitOp(21, &[_]f32{1});
    core.emitOp(23, &[_]f32{1});
    core.emitOp(26, &[_]f32{0});
    core.emitOp(24, &[_]f32{ 0, 0, 0, 0, 0, 0, 0, 0 });
    core.emitOp(16, &[_]f32{ 1, 0, 0, 1, rect[0], rect[1] });
    core.runOps(buf[0..n], 1);
    core.emitOp(15, &[_]f32{});
}

/// /DA "0 0 1 rg /Helv 12 Tf" 에서 글자 크기와 색을 읽는다. 크기 0(자동)은 10.
fn parseDA(da: []const u8, size: *f32, rgb: *[3]f32) void {
    var nums: [4]f32 = .{ 0, 0, 0, 0 };
    var nn: u32 = 0;
    var p: usize = 0;
    while (p < da.len) {
        while (p < da.len and core.isSpace(da[p])) p += 1;
        if (p >= da.len) break;
        const c = da[p];
        if (core.isDigit(c) or c == '-' or c == '.') {
            const v = core.readFloat(da, &p);
            if (nn < 4) { nums[nn] = v; nn += 1; } else { nums[0] = nums[1]; nums[1] = nums[2]; nums[2] = nums[3]; nums[3] = v; }
            continue;
        }
        var q = p;
        while (q < da.len and !core.isSpace(da[q])) q += 1;
        const tok = da[p..q];
        if (core.std_mem_eq(tok, "Tf") and nn >= 1) size.* = nums[nn - 1]
        else if (core.std_mem_eq(tok, "g") and nn >= 1) rgb.* = .{ nums[nn - 1], nums[nn - 1], nums[nn - 1] }
        else if (core.std_mem_eq(tok, "rg") and nn >= 3) rgb.* = .{ nums[nn - 3], nums[nn - 2], nums[nn - 1] }
        else if (core.std_mem_eq(tok, "k") and nn >= 4) core.cmykRgb(nums[0], nums[1], nums[2], nums[3], rgb);
        if (tok.len > 0 and tok[0] != '/') nn = 0;
        p = q;
    }
    if (size.* <= 0) size.* = 10;
}

/// 겉모습 없는 글상자 주석(/FreeText). poppler·Acrobat 꼴: /C 로 바탕을 칠하고,
/// /DA 의 색으로 테두리(/BS 굵기, 기본 1)와 글을 그린다. 글은 왼쪽 위부터
/// 줄바꿈대로 — 줄 간격은 크기의 1.15 (poppler 1.0 과 pdf.js 1.35 사이).
/// pdf.js 는 바탕·테두리를 안 그리지만 규격의 /C 는 FreeText 의 채움색이다.
fn drawFreeText(b: []const u8, ab: usize, abe: usize, rect: [4]f32) void {
    var size: f32 = 0;
    var rgb: [3]f32 = .{ 0, 0, 0 };
    var da: [256]u8 = undefined;
    if (core.keyPos(b, ab, abe, "/DA")) |d| {
        const n = core.copyPdfText(b, d + 3, abe, &da, 0);
        parseDA(da[0..n], &size, &rgb);
    } else size = 10;
    const bg = colorAt(b, ab, abe, "/C");
    var dash: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
    var dash_n: u32 = 0;
    const bw = strokeStyle(b, ab, abe, &dash, &dash_n);

    core.emitOp(14, &[_]f32{});
    core.emitOp(21, &[_]f32{1});
    core.emitOp(23, &[_]f32{1});
    core.emitOp(26, &[_]f32{0});
    core.emitOp(24, &[_]f32{ @floatFromInt(dash_n), dash[0], dash[1], dash[2], dash[3], dash[4], dash[5], 0 });
    core.emitOp(9, &[_]f32{});
    const w = rect[2] - rect[0];
    const h = rect[3] - rect[1];
    if (bg.on) {
        core.emitOp(11, &[_]f32{ bg.rgb[0], bg.rgb[1], bg.rgb[2] });
        core.emitOp(5, &[_]f32{ rect[0], rect[1], w, h });
        core.emitOp(6, &[_]f32{0});
    }
    if (bw > 0) {
        core.emitOp(12, &[_]f32{ rgb[0], rgb[1], rgb[2] });
        core.emitOp(13, &[_]f32{bw});
        core.emitOp(5, &[_]f32{ rect[0] + bw / 2, rect[1] + bw / 2, w - bw, h - bw });
        core.emitOp(7, &[_]f32{});
    }
    // 글은 상자 안으로 자른다
    core.emitOp(5, &[_]f32{ rect[0], rect[1], w, h });
    core.emitOp(10, &[_]f32{0});
    core.emitOp(9, &[_]f32{});
    core.emitOp(11, &[_]f32{ rgb[0], rgb[1], rgb[2] });
    var txt: [1024]u8 = undefined;
    var tn: u32 = 0;
    if (core.keyPos(b, ab, abe, "/Contents")) |c| tn = core.copyPdfText(b, c + 9, abe, &txt, 0);
    const pad = bw + 2;
    var y = rect[3] - pad - size * 0.9;
    var s0: usize = 0;
    var i: usize = 0;
    while (i <= tn) : (i += 1) {
        if (i < tn and txt[i] != '\n' and txt[i] != '\r') continue;
        if (i > s0) core.emitText(rect[0] + pad, y, size, txt[s0..i]);
        if (i < tn and txt[i] == '\r' and i + 1 < tn and txt[i + 1] == '\n') i += 1;
        s0 = i + 1;
        y -= size * 1.15;
        if (y < rect[1] - size) break;
    }
    core.emitOp(15, &[_]f32{});
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
    if (kind == .none) {
        if (core.std_mem_eq(sub, "Widget")) { drawWidget(b, ab, abe, rect); return true; }
        if (core.std_mem_eq(sub, "FreeText")) { drawFreeText(b, ab, abe, rect); return true; }
        return false;
    }

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
                        // 마디 수를 못박는다 — /QuadPoints 가 4294967295(퍼저)면 끝없이 돌았고,
                        // f32 라 x += dy 가 제자리를 맴돌기도 한다
                        var seg: u32 = 0;
                        while (x < x4 and seg < 4000) : (seg += 1) {
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
