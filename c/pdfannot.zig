//! 주석(하이라이트·메모·도형)을 읽고 쓴다
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 3개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 31개다.
//!
//! JS 에 내보내는 함수(15개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");

// ===== 주석 =====
//
// 링크·위젯만 따로 걷던 것을 넘어, 쪽에 달린 주석을 종류 가리지 않고 모은다.
// 뷰어가 주석 목록을 만들고 마우스를 올리면 내용을 보여 줄 수 있게 —
// pdf.js 의 getAnnotations 자리다.
const Ann = struct {
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    flags: u32 = 0,
    color: [3]f32 = .{ 0, 0, 0 },
    has_color: bool = false,
    sub_off: u32 = 0,
    sub_len: u32 = 0,
    txt_off: u32 = 0,
    txt_len: u32 = 0,
    au_off: u32 = 0,
    au_len: u32 = 0,
    dt_off: u32 = 0,
    dt_len: u32 = 0,
    obj: u32 = 0,
};
/// 쪽 하나의 주석. 세는 상한은 없다.
var ann: core.Table(Ann) = .{};
var ann_n: u32 = 0;
/// ann_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var ann_buf: core.Table(u8) = .{};
var ann_used: u32 = 0;

pub fn annCount() u32 { return ann_n; }
pub fn annObj(i: u32) u32 { return if (i < ann_n) ann.all()[i].obj else 0; }
pub fn annFlags(i: u32) u32 { return if (i < ann_n) ann.all()[i].flags else 0; }
pub fn annRect(i: u32, k: u32) f32 { return if (i < ann_n and k < 4) ann.all()[i].rect[k] else 0; }
pub fn annHasColor(i: u32) u32 { return if (i < ann_n and ann.all()[i].has_color) 1 else 0; }
pub fn annColor(i: u32, k: u32) f32 { return if (i < ann_n and k < 3) ann.all()[i].color[k] else 0; }
pub fn annTextPtr() [*]u8 { return @ptrFromInt(if (ann_buf.at == 0) core.heapBase() else ann_buf.at); }
pub fn annSubOff(i: u32) u32 { return if (i < ann_n) ann.all()[i].sub_off else 0; }
pub fn annSubLen(i: u32) u32 { return if (i < ann_n) ann.all()[i].sub_len else 0; }
pub fn annBodyOff(i: u32) u32 { return if (i < ann_n) ann.all()[i].txt_off else 0; }
pub fn annBodyLen(i: u32) u32 { return if (i < ann_n) ann.all()[i].txt_len else 0; }
pub fn annAuthorOff(i: u32) u32 { return if (i < ann_n) ann.all()[i].au_off else 0; }
pub fn annAuthorLen(i: u32) u32 { return if (i < ann_n) ann.all()[i].au_len else 0; }
pub fn annDateOff(i: u32) u32 { return if (i < ann_n) ann.all()[i].dt_off else 0; }
pub fn annDateLen(i: u32) u32 { return if (i < ann_n) ann.all()[i].dt_len else 0; }


/// 쪽에 달린 주석을 모두 걷는다. 링크·위젯도 포함한다 — 쓰는 쪽이 가린다.
pub fn collectAnnots(b: []const u8, body: usize, end: usize) void {
    ann_n = 0;
    ann_used = 0;
    const aa = core.find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and core.isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') {
        as2 = p + 1;
        ae = core.arrayEnd(b, p, end);
    } else if (p < end and core.isDigit(b[p])) {
        const an = core.readUint(b, &p);
        if (core.findObj(b, an)) |ab| {
            const abe = core.find(b, "endobj", ab) orelse b.len;
            var q = ab;
            while (q < abe and b[q] != '[') q += 1;
            as2 = q + 1;
            ae = core.arrayEnd(b, q, abe);
        } else return;
    } else return;

    var q = as2;
    while (q < ae) {
        if (!core.growTable(&ann.at, &ann.cap, ann_n, @sizeOf(Ann), 128)) break;
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!core.isDigit(b[q])) { q += 1; continue; }
        const num = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and core.isDigit(b[q])) _ = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;

        const ab = core.findObj(b, num) orelse continue;
        const abe = core.objDictEnd(b, ab);
        var a: Ann = .{};
        a.obj = num;

        var name: [32]u8 = undefined;
        const nn = core.nameAfter(b, ab, abe, "/Subtype", &name);
        _ = ann_buf.room(ann_used + nn + 64, 65536);
        if (nn > 0 and ann_used + nn <= ann_buf.all().len) {
            a.sub_off = ann_used;
            a.sub_len = nn;
            @memcpy(ann_buf.all()[ann_used..][0..nn], name[0..nn]);
            ann_used += nn;
        }
        if (core.find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) a.rect[i] = core.readFloat(b, &rp);
            if (a.rect[2] < a.rect[0]) { const t = a.rect[0]; a.rect[0] = a.rect[2]; a.rect[2] = t; }
            if (a.rect[3] < a.rect[1]) { const t = a.rect[1]; a.rect[1] = a.rect[3]; a.rect[3] = t; }
        }
        if (core.intAfter(b, ab, abe, "/F")) |fl| a.flags = fl;
        // /C [r g b] — 회색 하나나 CMYK 넷으로 적히기도 한다
        if (core.keyPos(b, ab, abe, "/C")) |ca| {
            var cp = ca + 2;
            {
                while (cp < abe and b[cp] != '[' and b[cp] != '/' and b[cp] != '>') cp += 1;
                if (cp < abe and b[cp] == '[') {
                    cp += 1;
                    var vals: [4]f32 = .{ 0, 0, 0, 0 };
                    var n2: u32 = 0;
                    while (n2 < 4 and cp < abe) {
                        while (cp < abe and core.isSpace(b[cp])) cp += 1;
                        if (cp >= abe or b[cp] == ']') break;
                        vals[n2] = core.readFloat(b, &cp);
                        n2 += 1;
                    }
                    if (n2 == 1) { a.color = .{ vals[0], vals[0], vals[0] }; a.has_color = true; }
                    if (n2 == 3) { a.color = .{ vals[0], vals[1], vals[2] }; a.has_color = true; }
                    if (n2 == 4) {
                        var rgb6: [3]f32 = .{ 0, 0, 0 };
                        core.cmykRgb(vals[0], vals[1], vals[2], vals[3], &rgb6);
                        a.color = rgb6;
                        a.has_color = true;
                    }
                }
            }
        }
        // 글(/Contents) · 쓴 이(/T) · 날짜(/M)
        if (core.find(b[ab..abe], "/Contents", 0)) |ta| {
            _ = ann_buf.room(ann_used + 8192, 65536);
            const n2 = core.copyPdfText(b, ab + ta + 9, abe, ann_buf.all(), ann_used);
            if (n2 > 0) { a.txt_off = ann_used; a.txt_len = n2; ann_used += n2; }
        }
        if (core.keyPos(b, ab, abe, "/T")) |ta| {
            _ = ann_buf.room(ann_used + 8192, 65536);
            const n2 = core.copyPdfText(b, ta + 2, abe, ann_buf.all(), ann_used);
            if (n2 > 0) { a.au_off = ann_used; a.au_len = n2; ann_used += n2; }
        }
        if (core.keyPos(b, ab, abe, "/M")) |da| {
            _ = ann_buf.room(ann_used + 8192, 65536);
            const n2 = core.copyPdfText(b, da + 2, abe, ann_buf.all(), ann_used);
            if (n2 > 0) { a.dt_off = ann_used; a.dt_len = n2; ann_used += n2; }
        }
        ann.all()[ann_n] = a;
        ann_n += 1;
    }
}

pub fn collectLinks(b: []const u8, body: usize, end: usize) void {
    core.link.n = 0;
    core.link.buf_n = 0;
    const aa = core.find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and core.isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') { as2 = p + 1; ae = core.arrayEnd(b, p, end); }
    else if (p < end and core.isDigit(b[p])) {
        const an = core.readUint(b, &p);
        if (core.findObj(b, an)) |ab| {
            const abe = core.find(b, "endobj", ab) orelse b.len;
            var q2 = ab;
            while (q2 < abe and b[q2] != '[') q2 += 1;
            as2 = q2 + 1;
            ae = core.arrayEnd(b, q2, abe);
        } else return;
    } else return;

    var q = as2;
    while (q < ae) {
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!core.isDigit(b[q])) { q += 1; continue; }
        const num = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and core.isDigit(b[q])) _ = core.readUint(b, &q);
        while (q < ae and core.isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;

        const ab = core.findObj(b, num) orelse continue;
        const abe = core.find(b, "endobj", ab) orelse b.len;
        if (core.find(b[ab..abe], "/Link", 0) == null) continue;
        var rect: [4]f32 = .{ 0, 0, 0, 0 };
        if (core.find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) rect[i] = core.readFloat(b, &rp);
        } else continue;
        if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
        if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }

        var uoff: u32 = 0;
        var ulen: u32 = 0;
        var pg: i32 = -1;
        // /S /URI 처럼 이름으로 쓰인 것 말고, 값이 문자열인 /URI 를 찾는다
        var ufrom: usize = 0;
        while (core.find(b[ab..abe], "/URI", ufrom)) |ua| {
            var up = ab + ua + 4;
            while (up < abe and core.isSpace(b[up])) up += 1;
            if (up < abe and (b[up] == '(' or b[up] == '<')) {
                uoff = core.link.buf_n;
                _ = core.link.buf.room(core.link.buf_n + 8192, 16384);
                ulen = core.copyPdfText(b, up, abe, core.link.buf.all(), core.link.buf_n);
                core.link.buf_n += ulen;
                break;
            }
            ufrom = ua + 4;
        }
        if (ulen > 0) {} else if (core.find(b[ab..abe], "/Dest", 0)) |da| {
            pg = core.destPage(b, ab + da + 5, abe);
        } else if (core.find(b[ab..abe], "/D", 0)) |da| {
            pg = core.destPage(b, ab + da + 2, abe);
        }
        if (ulen == 0 and pg < 0) continue;
        if (!core.growTable(&core.link.items.at, &core.link.items.cap, core.link.n, @sizeOf(core.Link), 128)) break;
        core.link.items.all()[core.link.n] = .{ .rect = rect, .off = uoff, .len = ulen, .page = pg };
        core.link.n += 1;
    }
}

/// 목차를 훑는다.
fn walkOutline(b: []const u8, first: u32, depth: u8) void {
    var num = first;
    var guard: u32 = 0;
    while (num != 0 and guard < 1 << 16) : (guard += 1) {
        const ob = core.findObj(b, num) orelse return;
        const oe = core.objDictEnd(b, ob);
        var off: u32 = 0;
        var len: u32 = 0;
        if (core.find(b[ob..oe], "/Title", 0)) |ta| {
            off = core.mark.buf_n;
            _ = core.mark.buf.room(core.mark.buf_n + 8192, 32768);
            len = core.copyPdfText(b, ob + ta + 6, oe, core.mark.buf.all(), core.mark.buf_n);
            core.mark.buf_n += len;
        }
        var pg: i32 = -1;
        if (core.find(b[ob..oe], "/Dest", 0)) |da| pg = core.destPage(b, ob + da + 5, oe);
        if (pg < 0) {
            if (core.find(b[ob..oe], "/A", 0)) |aa| {
                var ap = ob + aa + 2;
                while (ap < oe and core.isSpace(b[ap])) ap += 1;
                var ds = ap;
                var de2 = oe;
                if (ap < oe and b[ap] == '<') { de2 = core.dictEnd(b, ap, oe); }
                else if (ap < oe and core.isDigit(b[ap])) {
                    const an2 = core.readUint(b, &ap);
                    if (core.findObj(b, an2)) |ab2| { ds = ab2; de2 = core.objDictEnd(b, ab2); }
                }
                if (core.find(b[ds..de2], "/D", 0)) |dd| pg = core.destPage(b, ds + dd + 2, de2);
            }
        }
        if (len > 0) {
            // 자리를 잡고 쓴다. 잡지 않고 쓰고 있었다 — marks() 가 늘 빈
            // 슬라이스라 목차 제목 자리에 PDF 원문 조각이 나왔다.
            if (!core.growTable(&core.mark.items.at, &core.mark.items.cap, core.mark.n, @sizeOf(core.Bookmark), 64)) return;
            core.mark.items.all()[core.mark.n] = .{ .depth = depth, .off = off, .len = len, .page = pg };
            core.mark.n += 1;
        }
        // 자식
        if (core.find(b[ob..oe], "/First", 0)) |fa| {
            var fp = ob + fa + 6;
            while (fp < oe and core.isSpace(b[fp])) fp += 1;
            if (fp < oe and core.isDigit(b[fp]) and depth < 4) walkOutline(b, core.readUint(b, &fp), depth + 1);
        }
        // 다음 형제
        var nxt: u32 = 0;
        if (core.find(b[ob..oe], "/Next", 0)) |na| {
            var np = ob + na + 5;
            while (np < oe and core.isSpace(b[np])) np += 1;
            if (np < oe and core.isDigit(b[np])) nxt = core.readUint(b, &np);
        }
        if (nxt == num) return;
        num = nxt;
    }
}

pub fn collectOutline(b: []const u8, root: u32) void {
    core.mark.n = 0;
    core.mark.buf_n = 0;
    const rb = core.findObj(b, root) orelse return;
    const re2 = core.objDictEnd(b, rb);
    const oa = core.find(b[rb..re2], "/Outlines", 0) orelse return;
    var p = rb + oa + 9;
    while (p < re2 and core.isSpace(b[p])) p += 1;
    if (p >= re2 or !core.isDigit(b[p])) return;
    const on = core.readUint(b, &p);
    const ob = core.findObj(b, on) orelse return;
    const oe = core.objDictEnd(b, ob);
    if (core.find(b[ob..oe], "/First", 0)) |fa| {
        var fp = ob + fa + 6;
        while (fp < oe and core.isSpace(b[fp])) fp += 1;
        if (fp < oe and core.isDigit(b[fp])) walkOutline(b, core.readUint(b, &fp), 0);
    }
}

