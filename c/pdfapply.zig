//! 문서를 다시 써 내보낸다 — 라벨·워터마크를 얹고 xref 를 새로 적는다
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 6개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 72개다.
//!
//! JS 에 내보내는 함수(6개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");
const pdfform = @import("pdfform.zig");
const pdfenc = @import("pdfenc.zig");

// ===== 라벨 =====
//
// 쪽 위에 얹는 글상자. 화면에서 끌어 놓은 자리를 그대로 구워 넣는다.
//
// 주석(annotation)이 아니라 쪽 내용으로 넣는다. 주석으로 하면 겉모습
// 스트림을 따로 지어야 하고, 그러려면 글꼴 객체 번호를 알아야 한다.
// 쪽 내용으로 넣으면 쪽이 이미 가진 글꼴을 이름으로 그냥 쓸 수 있고,
// 겉모습을 만들 줄 모르는 뷰어에서도 똑같이 보인다.
const LabelT = struct {
    /// 원본 쪽 번호 (0부터)
    page: u32,
    /// PDF 좌표 (pt). 글자의 기준선 왼쪽 끝이다.
    x: f32,
    y: f32,
    size: f32,
    col: [3]f32,
    off: u16,
    n: u16,
    /// 표준 글꼴에 없는 글자는 화면 글꼴로 그린 1비트 그림을 심는다
    mw: u32 = 0,
    mh: u32 = 0,
    moff: u32 = 0,
    mlen: u32 = 0,
    /// 쪽에 놓을 크기 (pt)
    pw: f32 = 0,
    ph: f32 = 0,
    /// 이 그림에 준 객체 번호 (만들 때 채운다)
    mobj: u32 = 0,
};
/// 사용자가 더한 것 — 세는 상한은 없다(자리잡개에서 늘어난다)
var labs: core.Table(LabelT) = .{};
var lab_n: u32 = 0;
var lab_cp: [4096]u32 = undefined;
var lab_cn: u32 = 0;
var lab_body: [16384]u8 = undefined;

pub fn clearLabels() void { lab_n = 0; lab_cn = 0; }
pub fn addLabel(page: u32, x: f32, y: f32, size: f32, r: f32, g: f32, bb: f32) u32 {
    if (!core.growTable(&labs.at, &labs.cap, lab_n, @sizeOf(LabelT), 32)) return 0;
    labs.all()[lab_n] = .{
        .page = page, .x = x, .y = y, .size = size,
        .col = .{ r, g, bb }, .off = @intCast(lab_cn), .n = 0,
    };
    lab_n += 1;
    return 1;
}
/// 방금 만든 라벨에 화면 글꼴로 그린 그림을 붙인다.
pub fn setLabelMask(w: u32, h: u32, len: u32, pw: f32, ph: f32) u32 {
    if (lab_n == 0) return 0;
    const at = core.maskAlloc(len, w, h) orelse return 0;
    const L = &labs.all()[lab_n - 1];
    L.mw = w;
    L.mh = h;
    L.moff = at;
    L.mlen = len;
    L.pw = pw;
    L.ph = ph;
    return 1;
}

/// 워터마크에 그림을 붙인다.
var wm_mw: u32 = 0;
var wm_mh: u32 = 0;
var wm_moff: u32 = 0;
pub var wm_mlen: u32 = 0;
pub var wm_mobj: u32 = 0;
var wm_pw: f32 = 0;
var wm_ph: f32 = 0;
pub fn setWatermarkMask(w: u32, h: u32, len: u32, pw: f32, ph: f32) u32 {
    const at = core.maskAlloc(len, w, h) orelse return 0;
    wm_mw = w;
    wm_mh = h;
    wm_moff = at;
    wm_mlen = len;
    wm_pw = @max(1, pw);
    wm_ph = @max(1, ph);
    return 1;
}

/// 방금 만든 라벨에 글자 하나를 잇는다.
pub fn addLabelChar(c: u32) void {
    if (lab_n == 0 or lab_cn >= lab_cp.len) return;
    lab_cp[lab_cn] = c;
    lab_cn += 1;
    labs.all()[lab_n - 1].n += 1;
}

fn pageHasLabels(page: u32) bool {
    var i: u32 = 0;
    while (i < lab_n) : (i += 1) if (labs.all()[i].page == page and labs.all()[i].n > 0) return true;
    return false;
}

/// 한 쪽의 라벨을 그리는 콘텐츠 스트림을 짓는다.
///
/// 이 쪽의 글꼴이 core.fonts.all()[] 에 채워져 있어야 하므로 core.renderPage 를 먼저 부른다.
/// 한글은 표준 14종에 없어서, 그 글자를 다 가진 문서 글꼴을 찾아 쓴다.
/// 못 찾으면 우리가 얹은 Helvetica 로 아스키만 적는다.
fn buildLabelStream(page: u32) usize {
    const dst = &lab_body;
    var bl: usize = 0;
    // 앞 스트림이 q 하나를 눌러 두었다. 되돌려 원래 좌표계를 찾는다 —
    // 원본이 배율을 바꿔 놓은 채 끝나면 라벨까지 같이 줄어든다.
    @memcpy(dst[bl..][0..2], "Q\n");
    bl += 2;
    var li: u32 = 0;
    while (li < lab_n) : (li += 1) {
        const L = labs.all()[li];
        if (L.page != page or L.n == 0) continue;
        if (bl + 512 > dst.len) break;

        if (L.mlen > 0 and L.mobj != 0) {
            // 화면 글꼴로 그린 그림이 있으면 그걸 놓는다 — 문서에 그 글자를
            // 가진 글꼴이 없어도 한글이 나온다.
            const put0 = struct {
                fn f(d: []u8, at: *usize, t: []const u8) void {
                    if (at.* + t.len > d.len) return;
                    @memcpy(d[at.*..][0..t.len], t);
                    at.* += t.len;
                }
            }.f;
            put0(dst, &bl, "q ");
            bl += core.putFrac(dst[bl..], L.col[0]);
            put0(dst, &bl, " ");
            bl += core.putFrac(dst[bl..], L.col[1]);
            put0(dst, &bl, " ");
            bl += core.putFrac(dst[bl..], L.col[2]);
            put0(dst, &bl, " rg ");
            bl += core.putNum(dst[bl..], @intFromFloat(@max(1, L.pw)));
            put0(dst, &bl, " 0 0 ");
            bl += core.putNum(dst[bl..], @intFromFloat(@max(1, L.ph)));
            put0(dst, &bl, " ");
            bl += core.putNum(dst[bl..], @intFromFloat(@max(0, L.x)));
            put0(dst, &bl, " ");
            bl += core.putNum(dst[bl..], @intFromFloat(@max(0, L.y)));
            put0(dst, &bl, " cm /PdLb");
            bl += core.putNum(dst[bl..], li);
            put0(dst, &bl, " Do Q\n");
            continue;
        }
        // 이 글자들을 다 가진 문서 글꼴을 찾는다
        var use_doc = false;
        var doc_font: u8 = 0;
        var fi: u8 = 0;
        outer: while (fi < core.font_n) : (fi += 1) {
            if (core.fonts.all()[fi].n == 0 or core.fonts.all()[fi].name_len == 0) continue;
            var ci: u32 = 0;
            while (ci < L.n) : (ci += 1) {
                if (core.wmCode(&core.fonts.all()[fi], lab_cp[L.off + ci]) == null) continue :outer;
            }
            use_doc = true;
            doc_font = fi;
            break;
        }

        const put = struct {
            fn f(d: []u8, at: *usize, t: []const u8) void {
                if (at.* + t.len > d.len) return;
                @memcpy(d[at.*..][0..t.len], t);
                at.* += t.len;
            }
        }.f;

        put(dst, &bl, "q ");
        bl += core.putFrac(dst[bl..], L.col[0]);
        put(dst, &bl, " ");
        bl += core.putFrac(dst[bl..], L.col[1]);
        put(dst, &bl, " ");
        bl += core.putFrac(dst[bl..], L.col[2]);
        put(dst, &bl, " rg BT /");
        if (use_doc) {
            const nm = core.fonts.all()[doc_font].name[0..core.fonts.all()[doc_font].name_len];
            put(dst, &bl, nm);
        } else {
            put(dst, &bl, "WMF");
        }
        put(dst, &bl, " ");
        bl += core.putNum(dst[bl..], @intFromFloat(@max(1, @min(999, L.size))));
        put(dst, &bl, " Tf 1 0 0 1 ");
        bl += core.putNum(dst[bl..], @intFromFloat(@max(0, L.x)));
        put(dst, &bl, " ");
        bl += core.putNum(dst[bl..], @intFromFloat(@max(0, L.y)));
        put(dst, &bl, " Tm ");

        if (use_doc) {
            const two = core.fonts.all()[doc_font].two_byte;
            put(dst, &bl, "<");
            var ci: u32 = 0;
            while (ci < L.n and bl + 8 < dst.len) : (ci += 1) {
                const code = core.wmCode(&core.fonts.all()[doc_font], lab_cp[L.off + ci]) orelse 0;
                const digits: u32 = if (two) 4 else 2;
                var d: u32 = 0;
                while (d < digits) : (d += 1) {
                    const nib: u8 = @truncate((code >> @intCast(4 * (digits - 1 - d))) & 0xF);
                    dst[bl] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                    bl += 1;
                }
            }
            put(dst, &bl, ">");
        } else {
            // 아스키만 적는다. 괄호와 역슬래시는 문자열을 끊으므로 피한다.
            put(dst, &bl, "(");
            var ci: u32 = 0;
            while (ci < L.n and bl + 2 < dst.len) : (ci += 1) {
                const c = lab_cp[L.off + ci];
                if (c < 32 or c > 126) continue;
                if (c == '(' or c == ')' or c == '\\') { dst[bl] = '\\'; bl += 1; }
                dst[bl] = @truncate(c);
                bl += 1;
            }
            put(dst, &bl, ")");
        }
        put(dst, &bl, " Tj ET Q\n");
    }
    return bl;
}

/// 딕셔너리 열쇠가 정확히 이것인가 (뒤에 구분자가 와야 한다).
pub fn keyIs(b: []const u8, p: usize, end: usize, key: []const u8) bool {
    if (p + key.len > end) return false;
    if (!core.std_mem_eq(b[p..][0..key.len], key)) return false;
    const c = b[p + key.len];
    // 숫자를 구분자로 보면 /Length1 이 /Length 로 잡힌다 — 글꼴 스트림이
    // 통째로 망가진다. 이름과 숫자 사이에는 규격상 공백이 있어야 한다.
    return core.isSpace(c) or c == '/' or c == '(' or c == '<' or c == '[' or c == '>';
}

/// 값 하나를 건너뛴다 — 이름·수·문자열·배열·딕셔너리·참조를 다 받는다.
pub fn skipVal(b: []const u8, from: usize, end: usize) usize {
    var p = from;
    while (p < end and core.isSpace(b[p])) p += 1;
    if (p >= end) return end;
    if (b[p] == '/') {
        p += 1;
        while (p < end and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '>' and
            b[p] != ']' and b[p] != '[' and b[p] != '(') p += 1;
        return p;
    }
    if (b[p] == '(') {
        var d: u32 = 0;
        while (p < end) : (p += 1) {
            if (b[p] == '\\') { p += 1; continue; }
            if (b[p] == '(') d += 1;
            if (b[p] == ')') { d -= 1; if (d == 0) return p + 1; }
        }
        return end;
    }
    if (p + 1 < end and b[p] == '<' and b[p + 1] == '<') return pdfenc.dictEnd(b, p, end);
    if (b[p] == '<') {
        while (p < end and b[p] != '>') p += 1;
        return @min(p + 1, end);
    }
    if (b[p] == '[') return pdfenc.arrayEnd(b, p, end);
    if (core.isDigit(b[p]) or b[p] == '-' or b[p] == '.') {
        _ = core.readFloat(b, &p);
        // 참조인가 — "n g R"
        var q = p;
        while (q < end and core.isSpace(b[q])) q += 1;
        if (q < end and core.isDigit(b[q])) {
            const save = q;
            _ = core.readUint(b, &q);
            while (q < end and core.isSpace(b[q])) q += 1;
            if (q < end and b[q] == 'R') return q + 1;
            q = save;
        }
        return p;
    }
    // true·false·null
    while (p < end and !core.isSpace(b[p]) and b[p] != '/' and b[p] != '>') p += 1;
    return p;
}

/// 콘텐츠 스트림 하나를 출력에 적고 xref 목록에 올린다.
/// 새로 적은 객체의 자리·번호를 담을 표를 잡는다.
///
/// 예전에는 [4098]·[8192] 같은 고정 배열이었다. 4098 은 쪽이 [4096] 이던
/// 시절의 숫자인데, 쪽 상한을 없애면서 이 둘만 남았다 — 4100 쪽짜리를
/// 돌려 내면 표 밖으로 넘겨 써서 상호참조표에 엉뚱한 번호가 박혔다
/// (6000 쪽이면 3806 개). 이제 담을 만큼 잡는다.
pub fn xrefTables(want: usize) ?struct { offs: []usize, nums: []u32 } {
    const cap = @max(@as(usize, 64), @min(want, 1 << 20));
    const off_at = core.zoneAlloc(cap * @sizeOf(usize)) orelse return null;
    const num_at = core.zoneAlloc(cap * 4) orelse return null;
    return .{
        .offs = @as([*]usize, @ptrFromInt(off_at))[0..cap],
        .nums = @as([*]u32, @ptrFromInt(num_at))[0..cap],
    };
}

fn writeStream(pos: *usize, offs: []usize, nums: []u32, n: *usize,
    obj: u32, body: []const u8) void
{
    if (n.* >= nums.len or !core.outRoom(pos.*, body.len + 128)) return;
    offs[n.*] = pos.*;
    nums[n.*] = obj;
    n.* += 1;
    core.appendNum(pos, obj);
    core.appendStr(pos, " 0 obj\n<< /Length ");
    core.appendNum(pos, @intCast(body.len));
    core.appendStr(pos, " >>\nstream\n");
    @memcpy(core.outBuf()[pos.*..][0..body.len], body);
    pos.* += body.len;
    core.appendStr(pos, "\nendstream\nendobj\n");
}

/// 결과 파일에서 /Encrypt 참조를 지운다.
///
/// 우리는 스트림을 이미 풀어 두고 원본 바이트를 그대로 옮기므로, 트레일러에
/// /Encrypt 가 남아 있으면 읽는 쪽이 한 번 더 풀려다 내용을 망친다.
pub fn stripEncryptOut(len: usize) void {
    if (!core.enc_on) return;
    const o = core.outBuf();
    var i: usize = 0;
    while (i + 8 < len) : (i += 1) {
        if (o[i] != '/') continue;
        if (!core.std_mem_eq(o[i .. i + 8], "/Encrypt")) continue;
        var j = i + 8;
        // "N G R" 까지 지운다
        while (j < len and (core.isSpace(o[j]) or core.isDigit(o[j]) or o[j] == 'R')) j += 1;
        var k = i;
        while (k < j) : (k += 1) o[k] = ' ';
        i = j;
    }
}

/// 고른 페이지만 남긴 PDF 를 만든다. 증분 업데이트로 덧붙인다.


pub fn apply() usize {
    core.out_len = 0;
    if (core.pick_n == 0 or core.pages_obj == 0) return 0;
    // 페이지 객체가 ObjStm 안에 있을 수 있으므로 펼친 영역까지 훑는다.
    // 출력에 옮기는 원본은 core.in_len 까지다.
    const b = core.searchSlice();

    // 원본을 그대로 옮긴다 (펼친 영역은 우리가 만든 것이라 옮기지 않는다)
    if (!core.outRoom(0, core.in_len)) return 0;
    @memcpy(core.outBuf()[0..core.in_len], b[0..core.in_len]);
    var pos: usize = core.in_len;
    if (pos > 0 and core.outBuf()[pos - 1] != '\n') { core.outBuf()[pos] = '\n'; pos += 1; }

    // 새로 쓸 객체: Pages 하나 + (회전이면) 고른 페이지들
    // 쪽마다 하나씩, 라벨·주석·칸까지 더해 잡는다. 다 쓰면 되돌린다.
    const xr_keep = core.zoneTop();
    defer core.zoneShrink(xr_keep);
    // 하나가 객체 여럿을 낳는다 — 주석은 겉모습 스트림까지 둘, 새 칸도
    // 마찬가지다. 넉넉히 잡지 않으면 뒤가 조용히 빠진다(주석 2000개 중
    // 1038개만 나갔다).
    const xr = xrefTables(core.pick_n * 4 + @as(usize, core.edit.n) * 2 + core.note.n * 3 + core.newf_n * 3 + 128) orelse return 0;
    const new_offsets = xr.offs;
    const new_nums = xr.nums;
    var new_n: usize = 0;

    // 1) Pages 객체 — Kids 를 고른 순서로
    new_offsets[new_n] = pos;
    new_nums[new_n] = core.pages_obj;
    new_n += 1;
    core.appendNum(&pos, core.pages_obj);
    core.appendStr(&pos, " 0 obj\n<< /Type /Pages /Count ");
    core.appendNum(&pos, @intCast(core.pick_n));
    core.appendStr(&pos, " /Kids [");
    var i: usize = 0;
    while (i < core.pick_n) : (i += 1) {
        core.appendStr(&pos, " ");
        core.appendNum(&pos, core.page_objs()[core.pick.all()[i]]);
        core.appendStr(&pos, " 0 R");
    }
    core.appendStr(&pos, " ] >>\nendobj\n");

    // 2) 쪽 위에 얹을 것 — 워터마크와 라벨. 둘 다 같은 길을 탄다.
    const overlay = core.wm_n > 0 or lab_n > 0;
    const has_notes = core.note.n > 0;
    var wm_pre: u32 = 0;
    var wm_content: u32 = 0;
    var wm_font: u32 = 0;
    var wm_res_base: u32 = 0;
    var wm_res_n: u32 = 0;
    var lab_base: u32 = 0;
    var lab_used: u32 = 0;
    if (overlay) {
        wm_pre = core.max_obj + 1;
        wm_content = core.max_obj + 2;
        wm_font = core.max_obj + 3;
        wm_res_base = core.max_obj + 4;
        // 리소스 객체가 쪽마다 하나씩 나가므로 그 뒤부터 라벨 스트림을 준다
        lab_base = core.max_obj + 4 + @as(u32, @intCast(core.pick_n));

        // 글꼴 — 표준 14 종이라 파일에 심지 않아도 된다
        new_offsets[new_n] = pos;
        new_nums[new_n] = wm_font;
        new_n += 1;
        core.appendNum(&pos, wm_font);
        core.appendStr(&pos, " 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

        // 워터마크는 원본 위에 얹어야 한다. 스캔 문서는 쪽을 덮는 그림
        // 한 장이 전부라, 밑에 깔면 그림에 가려 보이지 않는다.
        //
        // 그런데 원본 콘텐츠는 좌표계를 제 마음대로 바꿔 놓고 끝난다 —
        // 크롬이 만든 PDF 는 맨 앞에서 .24 배로 줄인다. 그 뒤에 그냥 이으면
        // 워터마크도 같이 줄어든다. 그래서 원본을 q…Q 로 감싼다.
        // 앞 스트림이 q 하나, 뒤 스트림이 Q 로 시작해 원래 좌표계를 되찾는다.
        writeStream(&pos, new_offsets, new_nums, &new_n, wm_pre, "q\n");
    }
    // 라벨·워터마크가 쓸 그림을 먼저 적고 번호를 매긴다
    var mask_next = core.max_obj + 4 + 2 * @as(u32, @intCast(core.pick_n)) + 1;
    var any_mask = false;
    if (overlay) {
        const writeMask = struct {
            fn f(num: u32, w: u32, h: u32, off: u32, len: u32,
                offs: []usize, nums: []u32, n: *usize, pp: *usize) void
            {
                if (n.* >= nums.len or !core.outRoom(pp.*, len + 512)) return;
                offs[n.*] = pp.*;
                nums[n.*] = num;
                n.* += 1;
                core.appendNum(pp, num);
                core.appendStr(pp, " 0 obj\n<< /Type /XObject /Subtype /Image /Width ");
                core.appendNum(pp, w);
                core.appendStr(pp, " /Height ");
                core.appendNum(pp, h);
                core.appendStr(pp, " /ImageMask true /BitsPerComponent 1 /Decode [0 1] /Length ");
                core.appendNum(pp, len);
                core.appendStr(pp, " >>\nstream\n");
                if (!core.outRoom(pp.*, len)) return;
                @memcpy(core.outBuf()[pp.*..][0..len], core.maskBuf()[off..][0..len]);
                pp.* += len;
                core.appendStr(pp, "\nendstream\nendobj\n");
            }
        }.f;
        var mi: u32 = 0;
        while (mi < lab_n) : (mi += 1) {
            if (labs.all()[mi].mlen == 0) continue;
            labs.all()[mi].mobj = mask_next;
            mask_next += 1;
            any_mask = true;
            writeMask(labs.all()[mi].mobj, labs.all()[mi].mw, labs.all()[mi].mh, labs.all()[mi].moff, labs.all()[mi].mlen,
                new_offsets, new_nums, &new_n, &pos);
        }
        if (wm_mlen > 0) {
            wm_mobj = mask_next;
            mask_next += 1;
            any_mask = true;
            writeMask(wm_mobj, wm_mw, wm_mh, wm_moff, wm_mlen,
                new_offsets, new_nums, &new_n, &pos);
        }
    }

    var wm_done = false;
    if (core.wm_n > 0) {
        // 문서에 박힌 글꼴 중 이 글자들을 다 가진 것을 찾는다.
        // 한글 워터마크는 그래야 나온다 — 표준 14종에는 한글이 없다.
        var use_doc = false;
        var doc_font: u8 = 0;
        if (!core.wmIsAscii()) {
            _ = core.renderPage(core.pick.all()[0]);
            var fi: u8 = 0;
            outer: while (fi < core.font_n) : (fi += 1) {
                if (core.fonts.all()[fi].n == 0 or core.fonts.all()[fi].name_len == 0) continue;
                var ci: usize = 0;
                while (ci < core.wm_n) : (ci += 1) {
                    if (core.wmCode(&core.fonts.all()[fi], core.wm_cp[ci]) == null) continue :outer;
                }
                use_doc = true;
                doc_font = fi;
                break;
            }
        } else {
            _ = core.renderPage(core.pick.all()[0]);
        }

        // 쪽 한가운데에 비스듬히, 쪽 크기에 맞춰 얹는다
        const pw2 = if (core.page_w > 1) core.page_w else 612;
        const ph2 = if (core.page_h > 1) core.page_h else 792;
        const nch: f32 = @floatFromInt(@max(core.wm_n, 1));
        const kw: f32 = if (use_doc and core.fonts.all()[doc_font].two_byte) 1.0 else 0.55;
        const diag = @sqrt(pw2 * pw2 + ph2 * ph2);
        var fsize = 0.62 * diag / (nch * kw);
        if (fsize > 200) fsize = 200;
        if (fsize < 8) fsize = 8;
        const twid = nch * kw * fsize;
        const cx = pw2 / 2;
        const cy = ph2 / 2;
        const tx = cx - twid / 2 * 0.866;
        const ty = cy - twid / 2 * 0.5;

        var body: [768]u8 = undefined;
        var bl: usize = 0;
        if (wm_mlen > 0 and wm_mobj != 0) {
            // 화면 글꼴로 그린 그림을 비스듬히 얹는다 — 문서에 그 글자를
            // 가진 글꼴이 없어도 한글 워터마크가 나온다.
            const putw = struct {
                fn f(d: []u8, at: *usize, t: []const u8) void {
                    if (at.* + t.len > d.len) return;
                    @memcpy(d[at.*..][0..t.len], t);
                    at.* += t.len;
                }
            }.f;
            // 쪽 대각선의 0.62 만큼 넓게, 원래 비율 그대로 눕힌다
            const target = 0.62 * diag;
            const k = target / wm_pw;
            const iw2 = wm_pw * k;
            const ih2 = wm_ph * k;
            const ix2 = cx - iw2 / 2 * 0.866 + ih2 / 2 * 0.5;
            const iy2 = cy - iw2 / 2 * 0.5 - ih2 / 2 * 0.866;
            putw(&body, &bl, "Q q 0.85 g 0.866 0.5 -0.5 0.866 ");
            bl += core.putNum(body[bl..], @intFromFloat(@max(0, ix2)));
            putw(&body, &bl, " ");
            bl += core.putNum(body[bl..], @intFromFloat(@max(0, iy2)));
            putw(&body, &bl, " cm ");
            bl += core.putNum(body[bl..], @intFromFloat(@max(1, iw2)));
            putw(&body, &bl, " 0 0 ");
            bl += core.putNum(body[bl..], @intFromFloat(@max(1, ih2)));
            putw(&body, &bl, " 0 0 cm /PdWm Do Q\n");
            writeStream(&pos, new_offsets, new_nums, &new_n, wm_content, body[0..bl]);
            wm_done = true;
        }
        // 앞 스트림이 눌러 둔 q 를 여기서 되돌린다. 원본이 배율을 바꿔 놓은
        // 채 끝나면 워터마크까지 같이 줄어든다.
        const head = "Q q 0.85 g BT /";
        @memcpy(body[bl..][0..head.len], head);
        bl += head.len;
        if (use_doc) {
            const nm = core.fonts.all()[doc_font].name[0..core.fonts.all()[doc_font].name_len];
            @memcpy(body[bl..][0..nm.len], nm);
            bl += nm.len;
        } else {
            @memcpy(body[bl..][0..3], "WMF");
            bl += 3;
        }
        body[bl] = ' ';
        bl += 1;
        bl += core.putNum(body[bl..], @intFromFloat(fsize));
        const mid = " Tf 0.866 0.5 -0.5 0.866 ";
        @memcpy(body[bl..][0..mid.len], mid);
        bl += mid.len;
        bl += core.putNum(body[bl..], @intFromFloat(@max(tx, 0)));
        body[bl] = ' ';
        bl += 1;
        bl += core.putNum(body[bl..], @intFromFloat(@max(ty, 0)));
        const mid2 = " Tm ";
        @memcpy(body[bl..][0..mid2.len], mid2);
        bl += mid2.len;
        if (use_doc) {
            // 글꼴 안의 코드로 적는다
            body[bl] = '<';
            bl += 1;
            const two = core.fonts.all()[doc_font].two_byte;
            var ci: usize = 0;
            while (ci < core.wm_n and bl + 8 < body.len) : (ci += 1) {
                const code = core.wmCode(&core.fonts.all()[doc_font], core.wm_cp[ci]) orelse 0;
                const digits: u32 = if (two) 4 else 2;
                var d: u32 = 0;
                while (d < digits) : (d += 1) {
                    const nib: u8 = @truncate((code >> @intCast(4 * (digits - 1 - d))) & 0xF);
                    body[bl] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                    bl += 1;
                }
            }
            body[bl] = '>';
            bl += 1;
        } else {
            body[bl] = '(';
            bl += 1;
            @memcpy(body[bl..][0..core.wm_len], core.wm[0..core.wm_len]);
            bl += core.wm_len;
            body[bl] = ')';
            bl += 1;
        }
        const tail = " Tj ET Q\n";
        @memcpy(body[bl..][0..tail.len], tail);
        bl += tail.len;
        if (!wm_done) writeStream(&pos, new_offsets, new_nums, &new_n, wm_content, body[0..bl]);
    }

    // 새로 다는 주석 — 주석 객체와 겉모습을 함께 적는다
    if (has_notes) {
        var ni: u32 = 0;
        while (ni < core.note.n and new_n + 3 < new_nums.len and core.outRoom(pos, 8192)) : (ni += 1) {
            const t = &core.notes.all()[ni];
            const w = t.rect[2] - t.rect[0];
            const h = t.rect[3] - t.rect[1];
            if (w < 1 or h < 1) continue;
            const ap = mask_next;
            const an = mask_next + 1;
            mask_next += 2;
            t.obj = an;

            // 겉모습 내용
            var bd: [4096]u8 = undefined;
            var bl: usize = 0;
            const pu = struct {
                fn f(d: []u8, at: *usize, x: []const u8) void {
                    if (at.* + x.len > d.len) return;
                    @memcpy(d[at.*..][0..x.len], x);
                    at.* += x.len;
                }
            }.f;
            const num3 = struct {
                fn f(d: []u8, at: *usize, v: f32) void {
                    at.* += core.putNum(d[at.*..], @intFromFloat(@max(0, @min(100000, v))));
                }
            }.f;
            const col3 = struct {
                fn f(d: []u8, at: *usize, c: [3]f32) void {
                    at.* += core.putFrac(d[at.*..], c[0]);
                    d[at.*] = ' ';
                    at.* += 1;
                    at.* += core.putFrac(d[at.*..], c[1]);
                    d[at.*] = ' ';
                    at.* += 1;
                    at.* += core.putFrac(d[at.*..], c[2]);
                }
            }.f;
            pu(&bd, &bl, "q ");
            switch (t.kind) {
                0 => { // 하이라이트 — 곱하기로 겹쳐 글자가 비치게
                    pu(&bd, &bl, "/GSa gs ");
                    col3(&bd, &bl, t.col);
                    pu(&bd, &bl, " rg 0 0 ");
                    num3(&bd, &bl, w);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h);
                    pu(&bd, &bl, " re f");
                },
                1, 2 => { // 밑줄·취소선
                    col3(&bd, &bl, t.col);
                    pu(&bd, &bl, " rg 0 ");
                    num3(&bd, &bl, if (t.kind == 1) h * 0.08 else h * 0.45);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, w);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, @max(1, h * 0.07));
                    pu(&bd, &bl, " re f");
                },
                3 => { // 네모
                    col3(&bd, &bl, t.col);
                    pu(&bd, &bl, " RG 1.5 w 1 1 ");
                    num3(&bd, &bl, w - 2);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h - 2);
                    pu(&bd, &bl, " re S");
                },
                4 => { // 동그라미 — 베지에 넷으로 그린다
                    const k = 0.5523;
                    const cx2 = w / 2;
                    const cy2 = h / 2;
                    const rx = w / 2 - 1;
                    const ry = h / 2 - 1;
                    col3(&bd, &bl, t.col);
                    pu(&bd, &bl, " RG 1.5 w ");
                    const pt = struct {
                        fn f(d: []u8, at: *usize, x: f32, y: f32, tail: []const u8) void {
                            at.* += core.putNum(d[at.*..], @intFromFloat(@max(0, x)));
                            d[at.*] = ' ';
                            at.* += 1;
                            at.* += core.putNum(d[at.*..], @intFromFloat(@max(0, y)));
                            if (at.* + tail.len < d.len) {
                                @memcpy(d[at.*..][0..tail.len], tail);
                                at.* += tail.len;
                            }
                        }
                    }.f;
                    pt(&bd, &bl, cx2 - rx, cy2, " m ");
                    pt(&bd, &bl, cx2 - rx, cy2 + ry * k, " ");
                    pt(&bd, &bl, cx2 - rx * k, cy2 + ry, " ");
                    pt(&bd, &bl, cx2, cy2 + ry, " c ");
                    pt(&bd, &bl, cx2 + rx * k, cy2 + ry, " ");
                    pt(&bd, &bl, cx2 + rx, cy2 + ry * k, " ");
                    pt(&bd, &bl, cx2 + rx, cy2, " c ");
                    pt(&bd, &bl, cx2 + rx, cy2 - ry * k, " ");
                    pt(&bd, &bl, cx2 + rx * k, cy2 - ry, " ");
                    pt(&bd, &bl, cx2, cy2 - ry, " c ");
                    pt(&bd, &bl, cx2 - rx * k, cy2 - ry, " ");
                    pt(&bd, &bl, cx2 - rx, cy2 - ry * k, " ");
                    pt(&bd, &bl, cx2 - rx, cy2, " c S");
                },
                5 => { // 메모 — 작은 말풍선
                    col3(&bd, &bl, t.col);
                    pu(&bd, &bl, " rg 0 0 ");
                    num3(&bd, &bl, w);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h);
                    pu(&bd, &bl, " re f 1 1 1 RG 1 w ");
                    num3(&bd, &bl, w * 0.2);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h * 0.65);
                    pu(&bd, &bl, " m ");
                    num3(&bd, &bl, w * 0.8);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h * 0.65);
                    pu(&bd, &bl, " l S ");
                    num3(&bd, &bl, w * 0.2);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h * 0.4);
                    pu(&bd, &bl, " m ");
                    num3(&bd, &bl, w * 0.6);
                    pu(&bd, &bl, " ");
                    num3(&bd, &bl, h * 0.4);
                    pu(&bd, &bl, " l S");
                },
                else => { // 자유선
                    col3(&bd, &bl, t.col);
                    pu(&bd, &bl, " RG 2 w 1 J 1 j ");
                    var k2: u32 = 0;
                    while (k2 < t.pts and bl + 40 < bd.len) : (k2 += 1) {
                        const px = core.note.pts[t.off + k2 * 2] - t.rect[0];
                        const py = core.note.pts[t.off + k2 * 2 + 1] - t.rect[1];
                        num3(&bd, &bl, px);
                        pu(&bd, &bl, " ");
                        num3(&bd, &bl, py);
                        pu(&bd, &bl, if (k2 == 0) " m " else " l ");
                    }
                    pu(&bd, &bl, "S");
                },
            }
            pu(&bd, &bl, " Q\n");

            new_offsets[new_n] = pos;
            new_nums[new_n] = ap;
            new_n += 1;
            core.appendNum(&pos, ap);
            core.appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 ");
            core.appendNum(&pos, @intFromFloat(@max(1, w)));
            core.appendStr(&pos, " ");
            core.appendNum(&pos, @intFromFloat(@max(1, h)));
            core.appendStr(&pos, " ] /Resources << /ExtGState << /GSa << /ca 0.45 /BM /Multiply >> >> >> /Length ");
            core.appendNum(&pos, @intCast(bl));
            core.appendStr(&pos, " >>\nstream\n");
            if (core.outRoom(pos, bl)) {
                if (!core.outRoom(pos, bl)) return 0;
                @memcpy(core.outBuf()[pos..][0..bl], bd[0..bl]);
                pos += bl;
            }
            core.appendStr(&pos, "\nendstream\nendobj\n");

            // 주석 객체
            const names = [_][]const u8{
                "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Text", "Ink",
            };
            new_offsets[new_n] = pos;
            new_nums[new_n] = an;
            new_n += 1;
            core.appendNum(&pos, an);
            core.appendStr(&pos, " 0 obj\n<< /Type /Annot /Subtype /");
            core.appendStr(&pos, names[@min(t.kind, 6)]);
            core.appendStr(&pos, " /F 4 /Rect [");
            var q3: u32 = 0;
            while (q3 < 4) : (q3 += 1) {
                core.appendStr(&pos, " ");
                core.appendNum(&pos, @intFromFloat(@max(0, t.rect[q3])));
            }
            core.appendStr(&pos, " ] /C [ ");
            var bd2: [64]u8 = undefined;
            var bl2: usize = 0;
            col3(&bd2, &bl2, t.col);
            core.appendStr(&pos, bd2[0..bl2]);
            core.appendStr(&pos, " ]");
            if (t.kind <= 2) {
                // 글자 위에 얹는 표시는 네 모서리를 적어야 한다
                core.appendStr(&pos, " /QuadPoints [");
                const qx = [_]f32{ t.rect[0], t.rect[2], t.rect[0], t.rect[2] };
                const qy = [_]f32{ t.rect[3], t.rect[3], t.rect[1], t.rect[1] };
                q3 = 0;
                while (q3 < 4) : (q3 += 1) {
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, @intFromFloat(@max(0, qx[q3])));
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, @intFromFloat(@max(0, qy[q3])));
                }
                core.appendStr(&pos, " ]");
            }
            if (t.kind == 0) core.appendStr(&pos, " /CA 0.45");
            if (t.kind == 5) core.appendStr(&pos, " /Name /Comment /Open false");
            if (t.kind == 6 and t.pts > 0) {
                core.appendStr(&pos, " /InkList [[");
                var k3: u32 = 0;
                while (k3 < t.pts and core.outRoom(pos, 32)) : (k3 += 1) {
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, @intFromFloat(@max(0, core.note.pts[t.off + k3 * 2])));
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, @intFromFloat(@max(0, core.note.pts[t.off + k3 * 2 + 1])));
                }
                core.appendStr(&pos, " ]]");
            }
            if (t.kind != 6 and t.len > 0) {
                // 메모 글 — 라틴 밖 글자가 있으면 UTF-16 으로
                const val = core.note.buf[t.off..][0..t.len];
                var wide = false;
                var cz: usize = 0;
                while (cz < val.len) {
                    const cu = core.utf8At(val, cz);
                    cz += cu[1];
                    if (cu[0] > 255) { wide = true; break; }
                }
                if (wide) {
                    core.appendStr(&pos, " /Contents <FEFF");
                    var cx3: usize = 0;
                    while (cx3 < val.len and core.outRoom(pos, 16)) {
                        const cu = core.utf8At(val, cx3);
                        cx3 += cu[1];
                        var units: [2]u32 = .{ cu[0], 0 };
                        var nu: u32 = 1;
                        if (cu[0] > 0xFFFF) {
                            const v = cu[0] - 0x10000;
                            units = .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) };
                            nu = 2;
                        }
                        var ui: u32 = 0;
                        while (ui < nu) : (ui += 1) {
                            var d3: u32 = 0;
                            while (d3 < 4) : (d3 += 1) {
                                const nib: u8 = @truncate((units[ui] >> @intCast(4 * (3 - d3))) & 0xF);
                                core.outBuf()[pos] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                                pos += 1;
                            }
                        }
                    }
                    core.appendStr(&pos, ">");
                } else {
                    core.appendStr(&pos, " /Contents (");
                    var cx3: usize = 0;
                    while (cx3 < val.len and core.outRoom(pos, 8)) : (cx3 += 1) {
                        const ch = val[cx3];
                        if (ch == '(' or ch == ')' or ch == '\\') {
                            core.outBuf()[pos] = '\\';
                            pos += 1;
                        }
                        core.outBuf()[pos] = ch;
                        pos += 1;
                    }
                    core.appendStr(&pos, ")");
                }
            }
            core.appendStr(&pos, " /AP << /N ");
            core.appendNum(&pos, ap);
            core.appendStr(&pos, " 0 R >> >>\nendobj\n");
        }
    }

    // 새로 만드는 입력 칸 — 위젯 객체를 적고 번호를 기억해 둔다.
    // 쪽의 /Annots 에 걸어야 하므로 쪽을 다시 쓰기 전에 끝내야 한다.
    var newf_font: u32 = 0;
    if (core.newf_n > 0) {
        newf_font = mask_next;
        mask_next += 1;
        new_offsets[new_n] = pos;
        new_nums[new_n] = newf_font;
        new_n += 1;
        core.appendNum(&pos, newf_font);
        core.appendStr(&pos, " 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");
        var fi: u32 = 0;
        while (fi < core.newf_n and new_n + 2 < new_nums.len and core.outRoom(pos, 2048)) : (fi += 1) {
            const f = &core.newf.all()[fi];
            if (f.page >= core.page_count) continue;
            f.obj = mask_next;
            mask_next += 1;
            new_offsets[new_n] = pos;
            new_nums[new_n] = f.obj;
            new_n += 1;
            core.appendNum(&pos, f.obj);
            core.appendStr(&pos, " 0 obj\n<< /Type /Annot /Subtype /Widget /FT ");
            core.appendStr(&pos, if (f.kind == 1) "/Btn" else "/Tx");
            core.appendStr(&pos, " /T ");
            core.appendTextStr(&pos, core.newf_buf[f.off..][0..f.len]);
            core.appendStr(&pos, " /Rect [");
            var k: u32 = 0;
            while (k < 4) : (k += 1) {
                core.appendStr(&pos, " ");
                core.appendNum(&pos, @intFromFloat(@max(0, @min(100000, f.rect[k]))));
            }
            // /F 4 는 "찍을 때도 보인다" 는 뜻이다. 없으면 인쇄에서 사라진다.
            core.appendStr(&pos, " ] /F 4 /P ");
            core.appendNum(&pos, core.page_objs()[f.page]);
            core.appendStr(&pos, " 0 R /MK << /BC [0 0 0] /BG [1 1 1] >> /DA ");
            if (f.kind == 1) {
                core.appendStr(&pos, "(/ZaDb 0 Tf 0 g) /V /Off /AS /Off >>\nendobj\n");
            } else {
                core.appendStr(&pos, "(/Helv 0 Tf 0 g) /V () >>\nendobj\n");
            }
        }
    }

    var pending_res: [4096]u32 = undefined;
    var pending_src: [4096]u32 = undefined;
    var pending_n: usize = 0;

    // 3) 회전이나 워터마크가 있으면 각 페이지 객체를 다시 쓴다
    if (core.rotate != 0 or overlay or core.anyPageRotate() or has_notes or core.anyFieldStruct()) {
        i = 0;
        while (i < core.pick_n) : (i += 1) {
            const obj = core.page_objs()[core.pick.all()[i]];
            const body = core.findObj(b, obj) orelse continue;
            const end = core.find(b, "endobj", body) orelse b.len;
            // 이 쪽에 라벨이 있으면 그릴 스트림을 먼저 적어 둔다.
            // 쪽마다 자리가 다르니 스트림도 쪽마다 하나씩 나간다.
            var my_lab: u32 = 0;
            if (lab_n > 0 and pageHasLabels(core.pick.all()[i]) and new_n + 2 < new_nums.len) {
                _ = core.renderPage(core.pick.all()[i]);
                const bl2 = buildLabelStream(core.pick.all()[i]);
                if (bl2 > 2) {
                    my_lab = lab_base + lab_used;
                    lab_used += 1;
                    writeStream(&pos, new_offsets, new_nums, &new_n, my_lab, lab_body[0..bl2]);
                }
            }
            new_offsets[new_n] = pos;
            new_nums[new_n] = obj;
            new_n += 1;
            core.appendNum(&pos, obj);
            core.appendStr(&pos, " 0 obj");
            // 원본 딕셔너리를 그대로 옮기되 마지막 >> 앞에 /Rotate 를 끼운다
            const dict_end = core.rfind(b[0..end], ">>", end - 1) orelse end;
            // 워터마크를 얹을 때는 /Contents·/Resources 를 우리가 다시 쓰므로
            // 원본에서는 건너뛴다. 그대로 두면 키가 두 번 나온다.
            var cq2 = body;
            while (cq2 < dict_end) {
                if (overlay and b[cq2] == '/' and cq2 + 9 <= dict_end and
                    core.std_mem_eq(b[cq2 .. cq2 + 9], "/Contents"))
                {
                    cq2 += 9;
                    while (cq2 < dict_end and core.isSpace(b[cq2])) cq2 += 1;
                    if (cq2 < dict_end and b[cq2] == '[') {
                        while (cq2 < dict_end and b[cq2] != ']') cq2 += 1;
                        cq2 += 1;
                    } else {
                        _ = core.readUint(b, &cq2);
                        while (cq2 < dict_end and core.isSpace(b[cq2])) cq2 += 1;
                        _ = core.readUint(b, &cq2);
                        while (cq2 < dict_end and core.isSpace(b[cq2])) cq2 += 1;
                        if (cq2 < dict_end and b[cq2] == 'R') cq2 += 1;
                    }
                    continue;
                }
                if (b[cq2] == '/' and keyIs(b, cq2, dict_end, "/Rotate")) {
                    cq2 = skipVal(b, cq2 + 7, dict_end);
                    continue;
                }
                if ((has_notes or core.anyFieldStruct()) and b[cq2] == '/' and
                    keyIs(b, cq2, dict_end, "/Annots"))
                {
                    cq2 = skipVal(b, cq2 + 7, dict_end);
                    continue;
                }
                if (overlay and b[cq2] == '/' and cq2 + 10 <= dict_end and
                    core.std_mem_eq(b[cq2 .. cq2 + 10], "/Resources"))
                {
                    cq2 += 10;
                    while (cq2 < dict_end and core.isSpace(b[cq2])) cq2 += 1;
                    if (cq2 < dict_end and b[cq2] == '<') {
                        var depth: u32 = 0;
                        while (cq2 < dict_end) {
                            if (b[cq2] == '<') depth += 1;
                            if (b[cq2] == '>') { depth -= 1; if (depth == 0) { cq2 += 1; break; } }
                            cq2 += 1;
                        }
                    } else {
                        _ = core.readUint(b, &cq2);
                        while (cq2 < dict_end and core.isSpace(b[cq2])) cq2 += 1;
                        _ = core.readUint(b, &cq2);
                        while (cq2 < dict_end and core.isSpace(b[cq2])) cq2 += 1;
                        if (cq2 < dict_end and b[cq2] == 'R') cq2 += 1;
                    }
                    continue;
                }
                if (!core.outRoom(pos, 8)) break;
                core.outBuf()[pos] = b[cq2];
                pos += 1;
                cq2 += 1;
            }
            if ((has_notes and core.notesOnPage(core.pick.all()[i])) or core.anyFieldStruct()) {
                // 원래 있던 주석에 새로 단 것을 이어 붙인다
                core.appendStr(&pos, " /Annots [");
                if (core.findObj(b, obj)) |pb2| {
                    const pe2 = core.objDictEnd(b, pb2);
                    if (core.find(b[pb2..pe2], "/Annots", 0)) |aa4| {
                        var ap4 = pb2 + aa4 + 7;
                        while (ap4 < pe2 and core.isSpace(b[ap4])) ap4 += 1;
                        var s4 = ap4;
                        var e4 = pe2;
                        if (ap4 < pe2 and b[ap4] == '[') {
                            s4 = ap4 + 1;
                            e4 = pdfenc.arrayEnd(b, ap4, pe2) - 1;
                        } else if (ap4 < pe2 and core.isDigit(b[ap4])) {
                            const an4 = core.readUint(b, &ap4);
                            if (core.findObj(b, an4)) |ob4| {
                                var q4b = ob4;
                                const oe4 = core.find(b, "endobj", ob4) orelse b.len;
                                while (q4b < oe4 and b[q4b] != '[') q4b += 1;
                                s4 = q4b + 1;
                                e4 = pdfenc.arrayEnd(b, q4b, oe4) - 1;
                            }
                        }
                        // 지우기로 고른 칸은 여기서 빠진다
                        core.copyRefsKeeping(b, s4, e4, &pos);
                    }
                }
                var nk: u32 = 0;
                while (nk < core.note.n) : (nk += 1) {
                    if (core.notes.all()[nk].page != core.pick.all()[i] or core.notes.all()[nk].obj == 0) continue;
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, core.notes.all()[nk].obj);
                    core.appendStr(&pos, " 0 R");
                }
                var nf: u32 = 0;
                while (nf < core.newf_n) : (nf += 1) {
                    if (core.newf.all()[nf].page != core.pick.all()[i] or core.newf.all()[nf].obj == 0) continue;
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, core.newf.all()[nf].obj);
                    core.appendStr(&pos, " 0 R");
                }
                core.appendStr(&pos, " ]");
            }
            // 원본의 /Rotate 는 위에서 건너뛰었으므로 여기서 다시 쓴다.
            // 쓰는 이가 준 회전은 원본에 **더한다** — 예전에는 원본을 버리고
            // 사용자 값만 적어, /Rotate 90 인 가로 스캔이 아무 설정도 안 했는데
            // 똑바로(0도) 나왔다.
            const src_rot: i32 = blk: {
                const inh = core.inheritedKey(b, body, end, "/Rotate") orelse break :blk 0;
                var rp = inh.at + 7;
                while (rp < inh.e and core.isSpace(b[rp])) rp += 1;
                var neg = false;
                if (rp < inh.e and b[rp] == '-') { neg = true; rp += 1; }
                if (rp >= inh.e or !core.isDigit(b[rp])) break :blk 0;
                const v: i32 = @intCast(core.readUint(b, &rp) % 360);
                break :blk if (neg) -v else v;
            };
            const rot_here = src_rot + core.rotOf(core.pick.all()[i]);
            if (@mod(rot_here, 360) != 0) {
                core.appendStr(&pos, " /Rotate ");
                const r = @mod(rot_here, 360);
                core.appendNum(&pos, @intCast(if (r < 0) r + 360 else r));
            }
            if (overlay) {
                // q → 원본 → Q+얹을 것 순으로 잇는다
                core.appendStr(&pos, " /Contents [ ");
                core.appendNum(&pos, wm_pre);
                core.appendStr(&pos, " 0 R");
                var cq = body;
                const cend = dict_end;
                if (core.find(b[cq..cend], "/Contents", 0)) |ca| {
                    var cp = cq + ca + 9;
                    while (cp < cend and core.isSpace(b[cp])) cp += 1;
                    if (cp < cend and b[cp] == '[') {
                        cp += 1;
                        while (cp < cend and b[cp] != ']') {
                            if (!core.outRoom(pos, 8)) break;
                            core.outBuf()[pos] = b[cp];
                            pos += 1;
                            cp += 1;
                        }
                    } else {
                        const cn = core.readUint(b, &cp);
                        core.appendStr(&pos, " ");
                        core.appendNum(&pos, cn);
                        core.appendStr(&pos, " 0 R");
                    }
                }
                if (core.wm_n > 0) {
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, wm_content);
                    core.appendStr(&pos, " 0 R");
                }
                if (my_lab != 0) {
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, my_lab);
                    core.appendStr(&pos, " 0 R");
                }
                core.appendStr(&pos, " ]");
                // 리소스는 통째로 갈아치우면 안 된다. 원본 폰트가 사라져
                // 본문 글자가 하나도 그려지지 않는다. 원본을 복사해 우리
                // 글꼴만 끼운 새 객체를 만들고 그걸 가리킨다.
                const new_res = wm_res_base + wm_res_n;
                wm_res_n += 1;
                core.appendStr(&pos, " /Resources ");
                core.appendNum(&pos, new_res);
                core.appendStr(&pos, " 0 R");
                pending_res[pending_n] = new_res;
                pending_src[pending_n] = obj;
                pending_n += 1;
                cq = body;
            }
            core.appendStr(&pos, " >>\nendobj\n");
        }
    }

    // 3) 채운 입력 칸을 다시 쓴다
    if (core.edit.n > 0 or core.newf_n > 0) {
        const fld_font = mask_next;
        var ap_next = mask_next + 1;
        var wrote_font = false;
        var ei: u32 = 0;
        while (ei < core.edit.n and new_n + 3 < new_nums.len and core.outRoom(pos, 4096)) : (ei += 1) {
            const e = core.edits.all()[ei];
            // 지울 칸은 다시 적지 않는다. 쪽의 /Annots 와 양식의 /Fields 에서
            // 이름이 빠지므로 아무도 가리키지 않는 객체가 된다.
            if (e.kind == 4) continue;
            const ob = core.findObj(b, e.obj) orelse continue;
            const oe = core.objDictEnd(b, ob);
            var ds2 = ob;
            while (ds2 < oe and b[ds2] != '<') ds2 += 1;
            if (ds2 >= oe) continue;
            const de2 = pdfenc.dictEnd(b, ds2, oe);
            if (de2 <= ds2 + 2) continue;
            const val = core.edit.buf[e.off..][0..e.len];

            // 글상자면 겉모습을 새로 그린다
            var ap_obj: u32 = 0;
            if (e.kind == 0 and e.mlen > 0) {
                // 표준 글꼴에 없는 글자가 섞였다 — 화면 글꼴로 그린 그림을
                // 그대로 심는다. 1비트 마스크라 지금 색으로 칠해진다.
                var rect: [4]f32 = .{ 0, 0, 0, 0 };
                if (core.find(b[ob..oe], "/Rect", 0)) |ra| {
                    var rp = ob + ra + 5;
                    while (rp < oe and b[rp] != '[') rp += 1;
                    rp += 1;
                    var ii: u32 = 0;
                    while (ii < 4 and rp < oe) : (ii += 1) rect[ii] = core.readFloat(b, &rp);
                }
                if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
                if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }
                const bw = rect[2] - rect[0];
                const bh = rect[3] - rect[1];
                if (bw > 1 and bh > 1 and new_n + 3 < new_nums.len and core.outRoom(pos, e.mlen + 1024)) {
                    const img_obj = ap_next;
                    ap_obj = ap_next + 1;
                    ap_next += 2;
                    // 마스크 그림
                    new_offsets[new_n] = pos;
                    new_nums[new_n] = img_obj;
                    new_n += 1;
                    core.appendNum(&pos, img_obj);
                    core.appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Image /Width ");
                    core.appendNum(&pos, e.mw);
                    core.appendStr(&pos, " /Height ");
                    core.appendNum(&pos, e.mh);
                    core.appendStr(&pos, " /ImageMask true /BitsPerComponent 1 /Decode [0 1] /Length ");
                    core.appendNum(&pos, e.mlen);
                    core.appendStr(&pos, " >>\nstream\n");
                    if (!core.outRoom(pos, e.mlen)) return 0;
                    @memcpy(core.outBuf()[pos..][0..e.mlen], core.maskBuf()[e.moff..][0..e.mlen]);
                    pos += e.mlen;
                    core.appendStr(&pos, "\nendstream\nendobj\n");
                    // 겉모습 — 그림을 상자에 꽉 채워 그린다
                    var body3: [256]u8 = undefined;
                    var b3: usize = 0;
                    const put3 = struct {
                        fn f(d: []u8, at: *usize, t: []const u8) void {
                            if (at.* + t.len > d.len) return;
                            @memcpy(d[at.*..][0..t.len], t);
                            at.* += t.len;
                        }
                    }.f;
                    put3(&body3, &b3, "/Tx BMC q 0 g ");
                    b3 += core.putNum(body3[b3..], @intFromFloat(@max(1, bw)));
                    put3(&body3, &b3, " 0 0 ");
                    b3 += core.putNum(body3[b3..], @intFromFloat(@max(1, bh)));
                    put3(&body3, &b3, " 0 0 cm /Im0 Do Q EMC\n");
                    new_offsets[new_n] = pos;
                    new_nums[new_n] = ap_obj;
                    new_n += 1;
                    core.appendNum(&pos, ap_obj);
                    core.appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 ");
                    core.appendNum(&pos, @intFromFloat(@max(1, bw)));
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, @intFromFloat(@max(1, bh)));
                    core.appendStr(&pos, " ] /Resources << /XObject << /Im0 ");
                    core.appendNum(&pos, img_obj);
                    core.appendStr(&pos, " 0 R >> >> /Length ");
                    core.appendNum(&pos, @intCast(b3));
                    core.appendStr(&pos, " >>\nstream\n");
                    if (core.outRoom(pos, b3)) {
                        if (!core.outRoom(pos, b3)) return 0;
                        @memcpy(core.outBuf()[pos..][0..b3], body3[0..b3]);
                        pos += b3;
                    }
                    core.appendStr(&pos, "\nendstream\nendobj\n");
                }
            } else if (e.kind == 0) {
                var rect: [4]f32 = .{ 0, 0, 0, 0 };
                if (core.find(b[ob..oe], "/Rect", 0)) |ra| {
                    var rp = ob + ra + 5;
                    while (rp < oe and b[rp] != '[') rp += 1;
                    rp += 1;
                    var ax: u32 = 0;
                    while (ax < 4 and rp < oe) : (ax += 1) rect[ax] = core.readFloat(b, &rp);
                }
                if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
                if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }
                const bw = rect[2] - rect[0];
                const bh = rect[3] - rect[1];
                if (bw > 1 and bh > 1) {
                    if (!wrote_font) {
                        new_offsets[new_n] = pos;
                        new_nums[new_n] = fld_font;
                        new_n += 1;
                        core.appendNum(&pos, fld_font);
                        core.appendStr(&pos, " 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");
                        wrote_font = true;
                    }
                    ap_obj = ap_next;
                    ap_next += 1;
                    // 여러 줄인지
                    var multi = false;
                    if (pdfform.fieldLookup(b, e.obj, "/Ff", 0)) |r| {
                        var vp = r[0];
                        while (vp < r[1] and core.isSpace(b[vp])) vp += 1;
                        if (vp < r[1] and core.isDigit(b[vp])) {
                            const ff = core.readUint(b, &vp);
                            multi = (ff & (1 << 12)) != 0;
                        }
                    }
                    var size: f32 = 0;
                    if (pdfform.fieldLookup(b, e.obj, "/DA", 0)) |r| {
                        const da = pdfform.fldPutStr(b, r[0], r[1]);
                        const txt = pdfform.fld_buf.all()[da[0]..][0..da[1]];
                        if (core.findIn(txt, " Tf", 0)) |ti| {
                            var dx: usize = ti;
                            while (dx > 0 and core.isSpace(txt[dx - 1])) dx -= 1;
                            var ex: usize = dx;
                            while (ex > 0 and (core.isDigit(txt[ex - 1]) or txt[ex - 1] == '.')) ex -= 1;
                            var pz: usize = 0;
                            if (ex < dx) size = core.readFloat(txt[ex..dx], &pz);
                        }
                        pdfform.fld_used = da[0];
                    }
                    if (size <= 0) size = if (multi) 10 else @min(12, @max(6, bh * 0.62));
                    const lead = size * 1.16;

                    var body2: [8192]u8 = undefined;
                    var bl: usize = 0;
                    const put = struct {
                        fn f(d: []u8, at: *usize, t: []const u8) void {
                            if (at.* + t.len > d.len) return;
                            @memcpy(d[at.*..][0..t.len], t);
                            at.* += t.len;
                        }
                    }.f;
                    put(&body2, &bl, "/Tx BMC q BT /Helv ");
                    bl += core.putNum(body2[bl..], @intFromFloat(@max(1, size)));
                    put(&body2, &bl, " Tf 0 g 2 ");
                    const first_y: f32 = if (multi) bh - lead else (bh - size * 0.72) / 2;
                    bl += core.putNum(body2[bl..], @intFromFloat(@max(1, first_y)));
                    put(&body2, &bl, " Td\n");
                    // 줄마다 적는다. 아스키만 넣는다 — 한글은 표준 글꼴에 없다.
                    var bx: usize = 0;
                    var line_open = false;
                    while (bx < val.len and bl + 32 < body2.len) {
                        const cu = core.utf8At(val, bx);
                        bx += cu[1];
                        if (cu[0] == '\n' or cu[0] == '\r') {
                            if (line_open) { put(&body2, &bl, ") Tj\n"); line_open = false; }
                            if (cu[0] == '\r' and bx < val.len and val[bx] == '\n') bx += 1;
                            put(&body2, &bl, "0 -");
                            bl += core.putNum(body2[bl..], @intFromFloat(@max(1, lead)));
                            put(&body2, &bl, " Td\n");
                            continue;
                        }
                        if (!line_open) { put(&body2, &bl, "("); line_open = true; }
                        if (cu[0] < 32 or cu[0] > 126) continue;
                        if (cu[0] == '(' or cu[0] == ')' or cu[0] == '\\') {
                            body2[bl] = '\\';
                            bl += 1;
                        }
                        body2[bl] = @intCast(cu[0]);
                        bl += 1;
                    }
                    if (line_open) put(&body2, &bl, ") Tj\n");
                    put(&body2, &bl, "ET Q EMC\n");

                    // 겉모습 폼 객체
                    new_offsets[new_n] = pos;
                    new_nums[new_n] = ap_obj;
                    new_n += 1;
                    core.appendNum(&pos, ap_obj);
                    core.appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 ");
                    core.appendNum(&pos, @intFromFloat(@max(1, bw)));
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, @intFromFloat(@max(1, bh)));
                    core.appendStr(&pos, " ] /Resources << /Font << /Helv ");
                    core.appendNum(&pos, fld_font);
                    core.appendStr(&pos, " 0 R >> >> /Length ");
                    core.appendNum(&pos, @intCast(bl));
                    core.appendStr(&pos, " >>\nstream\n");
                    if (core.outRoom(pos, bl)) {
                        if (!core.outRoom(pos, bl)) return 0;
                        @memcpy(core.outBuf()[pos..][0..bl], body2[0..bl]);
                        pos += bl;
                    }
                    core.appendStr(&pos, "\nendstream\nendobj\n");
                }
            }

            // 위젯을 다시 쓴다 — 원본 딕셔너리에서 /V·/AS·/AP 만 갈아 끼운다
            new_offsets[new_n] = pos;
            new_nums[new_n] = e.obj;
            new_n += 1;
            core.appendNum(&pos, e.obj);
            core.appendStr(&pos, " 0 obj\n<<");
            var fx = ds2 + 2;
            const inner_end = de2 - 2;
            while (fx < inner_end and core.outRoom(pos, 8)) {
                // 이름만 바꿀 때는 값을 건드리지 않는다 — /T 만 걷어 낸다
                const drop = if (e.kind == 3)
                    keyIs(b, fx, inner_end, "/T")
                else
                    (keyIs(b, fx, inner_end, "/V") or keyIs(b, fx, inner_end, "/AS") or
                        (e.kind == 0 and keyIs(b, fx, inner_end, "/AP")));
                if (b[fx] == '/' and drop) {
                    var kq = fx + 1;
                    while (kq < inner_end and !core.isSpace(b[kq]) and b[kq] != '/' and b[kq] != '(' and
                        b[kq] != '<' and b[kq] != '[' and !core.isDigit(b[kq])) kq += 1;
                    fx = skipVal(b, kq, inner_end);
                    continue;
                }
                core.outBuf()[pos] = b[fx];
                pos += 1;
                fx += 1;
            }
            if (e.kind == 3) {
                core.appendStr(&pos, " /T ");
                core.appendTextStr(&pos, val);
            } else if (e.kind == 0) {
                // 라틴 밖 글자가 있으면 UTF-16 으로 담는다 — 괄호 문자열에는
                // 한 바이트 글자만 들어가므로 한글이 통째로 사라진다.
                var wide = false;
                {
                    var cz: usize = 0;
                    while (cz < val.len) {
                        const cu = core.utf8At(val, cz);
                        cz += cu[1];
                        if (cu[0] > 255) { wide = true; break; }
                    }
                }
                if (wide) {
                    core.appendStr(&pos, " /V <FEFF");
                    var cx: usize = 0;
                    while (cx < val.len and core.outRoom(pos, 16)) {
                        const cu = core.utf8At(val, cx);
                        cx += cu[1];
                        if (cu[0] == '\r') continue;
                        var units: [2]u32 = .{ cu[0], 0 };
                        var nu: u32 = 1;
                        if (cu[0] > 0xFFFF) {
                            const v = cu[0] - 0x10000;
                            units = .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) };
                            nu = 2;
                        }
                        var ui: u32 = 0;
                        while (ui < nu) : (ui += 1) {
                            var d: u32 = 0;
                            while (d < 4) : (d += 1) {
                                const nib: u8 = @truncate((units[ui] >> @intCast(4 * (3 - d))) & 0xF);
                                core.outBuf()[pos] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                                pos += 1;
                            }
                        }
                    }
                    core.appendStr(&pos, ">");
                } else {
                    core.appendStr(&pos, " /V (");
                    var cx: usize = 0;
                    while (cx < val.len and core.outRoom(pos, 8)) {
                        const cu = core.utf8At(val, cx);
                        cx += cu[1];
                        if (cu[0] == '\r') continue;
                        if (cu[0] == '(' or cu[0] == ')' or cu[0] == '\\') {
                            core.outBuf()[pos] = '\\';
                            pos += 1;
                        }
                        core.outBuf()[pos] = @intCast(cu[0]);
                        pos += 1;
                    }
                    core.appendStr(&pos, ")");
                }
                if (ap_obj != 0) {
                    core.appendStr(&pos, " /AP << /N ");
                    core.appendNum(&pos, ap_obj);
                    core.appendStr(&pos, " 0 R >>");
                }
            } else {
                const on = if (e.kind == 1 and val.len > 0) val else "Off";
                if (core.outRoom(pos, on.len * 2 + 32)) {
                    core.appendStr(&pos, " /V /");
                    if (!core.outRoom(pos, on.len)) return 0;
                    @memcpy(core.outBuf()[pos..][0..on.len], on);
                    pos += on.len;
                    core.appendStr(&pos, " /AS /");
                    if (!core.outRoom(pos, on.len)) return 0;
                    @memcpy(core.outBuf()[pos..][0..on.len], on);
                    pos += on.len;
                }
            }
            core.appendStr(&pos, " >>\nendobj\n");
        }
        // 겉모습을 다시 그릴 줄 아는 뷰어는 제 글꼴로 다시 그리게 한다 —
        // 우리가 넣은 겉모습은 표준 글꼴이라 한글이 빠진다.
        if (core.doc_root != 0) {
            if (core.findObj(b, core.doc_root)) |rb3| {
                const re3 = core.objDictEnd(b, rb3);
                const has_acro = core.find(b[rb3..re3], "/AcroForm", 0) != null;
                // 양식이 아예 없는 문서에 칸을 만들면 카탈로그에 양식을 새로 단다
                if (!has_acro and core.newf_n > 0 and new_n + 1 < new_nums.len) {
                    var ix0 = rb3;
                    while (ix0 < re3 and b[ix0] != '<') ix0 += 1;
                    const hx0 = pdfenc.dictEnd(b, ix0, re3);
                    if (hx0 > ix0 + 2) {
                        new_offsets[new_n] = pos;
                        new_nums[new_n] = core.doc_root;
                        new_n += 1;
                        core.appendNum(&pos, core.doc_root);
                        core.appendStr(&pos, " 0 obj\n<<");
                        var gx0 = ix0 + 2;
                        while (gx0 < hx0 - 2 and core.outRoom(pos, 64)) : (gx0 += 1) {
                            core.outBuf()[pos] = b[gx0];
                            pos += 1;
                        }
                        core.appendStr(&pos, " /AcroForm << /Fields [");
                        var nf0: u32 = 0;
                        while (nf0 < core.newf_n) : (nf0 += 1) {
                            if (core.newf.all()[nf0].obj == 0) continue;
                            core.appendStr(&pos, " ");
                            core.appendNum(&pos, core.newf.all()[nf0].obj);
                            core.appendStr(&pos, " 0 R");
                        }
                        core.appendStr(&pos, " ] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv ");
                        core.appendNum(&pos, newf_font);
                        core.appendStr(&pos, " 0 R >> >> /NeedAppearances true >> >>\nendobj\n");
                    }
                }
                if (core.find(b[rb3..re3], "/AcroForm", 0)) |aa3| {
                    var ap3 = rb3 + aa3 + 9;
                    while (ap3 < re3 and core.isSpace(b[ap3])) ap3 += 1;
                    if (ap3 < re3 and core.isDigit(b[ap3])) {
                        const an3 = core.readUint(b, &ap3);
                        if (core.findObj(b, an3)) |ab3| {
                            const abe3 = core.objDictEnd(b, ab3);
                            var ix = ab3;
                            while (ix < abe3 and b[ix] != '<') ix += 1;
                            const hx = pdfenc.dictEnd(b, ix, abe3);
                            if (hx > ix + 2 and new_n + 1 < new_nums.len) {
                                new_offsets[new_n] = pos;
                                new_nums[new_n] = an3;
                                new_n += 1;
                                core.appendNum(&pos, an3);
                                core.appendStr(&pos, " 0 obj\n<<");
                                var gx = ix + 2;
                                const jx = hx - 2;
                                const redo = core.anyFieldStruct();
                                while (gx < jx and core.outRoom(pos, 64)) {
                                    if (b[gx] == '/' and keyIs(b, gx, jx, "/NeedAppearances")) {
                                        gx = skipVal(b, gx + 16, jx);
                                        continue;
                                    }
                                    // 칸을 만들거나 지웠으면 목록을 우리가 다시 적는다
                                    if (redo and b[gx] == '/' and keyIs(b, gx, jx, "/Fields")) {
                                        gx = skipVal(b, gx + 7, jx);
                                        continue;
                                    }
                                    core.outBuf()[pos] = b[gx];
                                    pos += 1;
                                    gx += 1;
                                }
                                if (redo) {
                                    core.appendStr(&pos, " /Fields [");
                                    // 원래 목록에서 지운 것만 뺀다
                                    if (core.find(b[ab3..abe3], "/Fields", 0)) |fa| {
                                        var fp = ab3 + fa + 7;
                                        while (fp < abe3 and core.isSpace(b[fp])) fp += 1;
                                        var fs2 = fp;
                                        var fe2 = abe3;
                                        if (fp < abe3 and b[fp] == '[') {
                                            fs2 = fp + 1;
                                            fe2 = pdfenc.arrayEnd(b, fp, abe3) - 1;
                                        } else if (fp < abe3 and core.isDigit(b[fp])) {
                                            const fn2 = core.readUint(b, &fp);
                                            if (core.findObj(b, fn2)) |fb2| {
                                                const fee = core.find(b, "endobj", fb2) orelse b.len;
                                                var fq = fb2;
                                                while (fq < fee and b[fq] != '[') fq += 1;
                                                fs2 = fq + 1;
                                                fe2 = pdfenc.arrayEnd(b, fq, fee) - 1;
                                            }
                                        }
                                        core.copyRefsKeeping(b, fs2, fe2, &pos);
                                    }
                                    var nf2: u32 = 0;
                                    while (nf2 < core.newf_n) : (nf2 += 1) {
                                        if (core.newf.all()[nf2].obj == 0) continue;
                                        core.appendStr(&pos, " ");
                                        core.appendNum(&pos, core.newf.all()[nf2].obj);
                                        core.appendStr(&pos, " 0 R");
                                    }
                                    core.appendStr(&pos, " ]");
                                }
                                core.appendStr(&pos, " /NeedAppearances true >>\nendobj\n");
                            }
                        }
                    }
                }
            }
        }
    }

    // 3) 새 xref — 갱신한 객체만 담는다
    // 워터마크용 리소스 객체 — 원본 리소스에 우리 글꼴만 더한다.
    // 통째로 갈아치우면 원본 폰트가 사라져 본문 글자가 하나도 안 그려진다.
    {
        var t: usize = 0;
        while (t < pending_n and new_n < new_nums.len - 2) : (t += 1) {
            const page_obj = pending_src[t];
            new_offsets[new_n] = pos;
            new_nums[new_n] = pending_res[t];
            new_n += 1;
            core.appendNum(&pos, pending_res[t]);
            core.appendStr(&pos, " 0 obj\n");

            var rs: usize = 0;
            var re_: usize = 0;
            if (core.findObj(b, page_obj)) |pb| {
                const pe = core.find(b, "endobj", pb) orelse b.len;
                if (core.find(b[pb..pe], "/Resources", 0)) |ra| {
                    var rp = pb + ra + 10;
                    while (rp < pe and core.isSpace(b[rp])) rp += 1;
                    if (rp < pe and b[rp] == '<') {
                        rs = rp;
                        var depth: u32 = 0;
                        var q2 = rp;
                        while (q2 < pe) {
                            if (b[q2] == '<') depth += 1;
                            if (b[q2] == '>') {
                                depth -= 1;
                                if (depth == 0) { re_ = q2 + 1; break; }
                            }
                            q2 += 1;
                        }
                    } else if (rp < pe and b[rp] >= '0' and b[rp] <= '9') {
                        const rn = core.readUint(b, &rp);
                        if (core.findObj(b, rn)) |rb| {
                            const rend = core.find(b, "endobj", rb) orelse b.len;
                            var q3 = rb;
                            while (q3 < rend and b[q3] != '<') q3 += 1;
                            rs = q3;
                            var depth: u32 = 0;
                            while (q3 < rend) {
                                if (b[q3] == '<') depth += 1;
                                if (b[q3] == '>') {
                                    depth -= 1;
                                    if (depth == 0) { re_ = q3 + 1; break; }
                                }
                                q3 += 1;
                            }
                        }
                    }
                }
            }

            if (re_ > rs and rs != 0) {
                var q4 = rs;
                var put_font = false;
                while (q4 < re_) {
                    if (!put_font and b[q4] == '/' and q4 + 5 <= re_ and
                        core.std_mem_eq(b[q4 .. q4 + 5], "/Font"))
                    {
                        if (!core.outRoom(pos, 64)) break;
                        if (!core.outRoom(pos, 5)) return 0;
                    @memcpy(core.outBuf()[pos..][0..5], "/Font");
                        pos += 5;
                        q4 += 5;
                        while (q4 < re_ and core.isSpace(b[q4])) q4 += 1;
                        if (q4 + 1 < re_ and b[q4] == '<' and b[q4 + 1] == '<') {
                            core.appendStr(&pos, " << /WMF ");
                            core.appendNum(&pos, wm_font);
                            core.appendStr(&pos, " 0 R ");
                            q4 += 2;
                            put_font = true;
                        }
                        continue;
                    }
                    if (!core.outRoom(pos, 8)) break;
                    core.outBuf()[pos] = b[q4];
                    pos += 1;
                    q4 += 1;
                }
                if (!put_font) {
                    pos -= 2;
                    core.appendStr(&pos, " /Font << /WMF ");
                    core.appendNum(&pos, wm_font);
                    core.appendStr(&pos, " 0 R >> >>");
                }
            } else {
                core.appendStr(&pos, "<< /Font << /WMF ");
                core.appendNum(&pos, wm_font);
                core.appendStr(&pos, " 0 R >> >>");
            }
            // 화면 글꼴로 그린 그림도 이름을 달아 둔다
            if (any_mask) {
                pos -= 2;
                core.appendStr(&pos, " /XObject <<");
                var mj: u32 = 0;
                while (mj < lab_n) : (mj += 1) {
                    if (labs.all()[mj].mobj == 0) continue;
                    core.appendStr(&pos, " /PdLb");
                    core.appendNum(&pos, mj);
                    core.appendStr(&pos, " ");
                    core.appendNum(&pos, labs.all()[mj].mobj);
                    core.appendStr(&pos, " 0 R");
                }
                if (wm_mobj != 0) {
                    core.appendStr(&pos, " /PdWm ");
                    core.appendNum(&pos, wm_mobj);
                    core.appendStr(&pos, " 0 R");
                }
                core.appendStr(&pos, " >> >>");
            }
            core.appendStr(&pos, "\nendobj\n");
        }
    }
    // 상호참조표는 객체 번호 오름차순이어야 한다. 순서가 어긋나면 엄격한
    // 리더가 표를 통째로 버려, 덧붙인 객체가 없는 것처럼 읽힌다.
    {
        var si: usize = 1;
        while (si < new_n) : (si += 1) {
            const kn = new_nums[si];
            const ko = new_offsets[si];
            var sj = si;
            while (sj > 0 and new_nums[sj - 1] > kn) : (sj -= 1) {
                new_nums[sj] = new_nums[sj - 1];
                new_offsets[sj] = new_offsets[sj - 1];
            }
            new_nums[sj] = kn;
            new_offsets[sj] = ko;
        }
    }
    const xref_pos = pos;
    core.appendStr(&pos, "xref\n");
    i = 0;
    while (i < new_n) : (i += 1) {
        core.appendNum(&pos, new_nums[i]);
        core.appendStr(&pos, " 1\n");
        // 10자리 오프셋 + 5자리 세대
        var off = new_offsets[i];
        var digits: [10]u8 = undefined;
        var d: usize = 10;
        while (d > 0) : (d -= 1) { digits[d - 1] = @intCast('0' + (off % 10)); off /= 10; }
        if (!core.outRoom(pos, 10)) return 0;
        @memcpy(core.outBuf()[pos..][0..10], &digits);
        pos += 10;
        core.appendStr(&pos, " 00000 n \n");
    }

    // 4) trailer — 이전 xref 를 가리킨다
    var prev: u32 = 0;
    if (core.rfindTail(b[0..core.in_len], "startxref")) |at| {
        var p = at + 9;
        prev = core.readUint(b, &p);
    }
    var root: u32 = 0;
    if (core.trailerKeyOrScan(b, "/Root")) |at| {
        var p = at + 5;
        root = core.readUint(b, &p);
    }
    core.appendStr(&pos, "trailer\n<< /Size ");
    core.appendNum(&pos, core.max_obj + 8);
    core.appendStr(&pos, " /Root ");
    core.appendNum(&pos, root);
    core.appendStr(&pos, " 0 R /Prev ");
    core.appendNum(&pos, prev);
    core.appendStr(&pos, " >>\nstartxref\n");
    core.appendNum(&pos, @intCast(xref_pos));
    core.appendStr(&pos, "\n%%EOF\n");

    stripEncryptOut(pos);
    core.out_len = pos;
    return pos;
}


