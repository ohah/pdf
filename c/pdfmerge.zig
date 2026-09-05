//! 다른 PDF 를 뒤에 이어 붙인다
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 1개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 34개다.
//!
//! JS 에 내보내는 함수(5개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");

// ===== 병합 =====
//
// 증분 업데이트로 붙인다. 원본 A 는 그대로 두고, 뒤에 B 의 객체들을 번호를
// 밀어서 다시 적은 뒤 새 페이지 트리와 상호참조표를 덧붙인다. 재작성이
// 아니므로 A 의 폰트·이미지는 손대지 않는다.
//
// 어려운 곳은 B 의 참조다. "12 0 R" 같은 참조가 딕셔너리 곳곳에 있어 전부
// 밀어야 하는데, 스트림 안의 이진 데이터는 건드리면 안 된다. 그래서 객체를
// 딕셔너리 구간과 스트림 구간으로 나눠 딕셔너리에서만 숫자를 고친다.

var b2_at: usize = 0;
var b2_cap_n: u32 = 0;
fn b2_pages() []u32 { return core.u32sAt(b2_at, b2_cap_n); }
var b2_page_n: u32 = 0;
var b2_max_obj: u32 = 0;

fn b2Slice() []u8 {
    return @as([*]u8, @ptrFromInt(core.bin2.off))[0..core.bin2.len];
}

/// 두 번째 문서를 읽어 페이지 목록과 최대 객체 번호를 센다.
pub fn parseSecond(len: usize) u32 {
    core.bin2.len = len;
    b2_page_n = 0;
    b2_max_obj = 0;
    const b = b2Slice();
    if (len < 8 or !core.std_mem_eq(b[0..5], "%PDF-")) return 0;

    // 최대 객체 번호
    var i: usize = 0;
    while (i + 4 < b.len) {
        const at = core.find(b, " obj", i) orelse break;
        var j = at;
        while (j > 0 and core.isSpace(b[j - 1])) j -= 1;
        while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
        var k = j;
        while (k > 0 and core.isSpace(b[k - 1])) k -= 1;
        var st = k;
        while (st > 0 and b[st - 1] >= '0' and b[st - 1] <= '9') st -= 1;
        if (st < k) {
            var p: usize = st;
            const n = core.readUint(b, &p);
            if (n > b2_max_obj) b2_max_obj = n;
        }
        i = at + 4;
    }

    // 페이지 트리
    var root: u32 = 0;
    if (core.trailerKeyOrScan(b, "/Root")) |at| {
        var p = at + 5;
        root = core.readUint(b, &p);
    }
    var pgs: u32 = 0;
    if (root != 0) {
        if (core.findObj(b, root)) |body| {
            const end = core.find(b, "endobj", body) orelse b.len;
            if (core.dictInt(b, body, end, "/Pages")) |x| pgs = x;
        }
    }
    if (pgs == 0) return 0;
    // 둘째 문서의 쪽은 제 자리에 바로 담는다. 예전에는 page_objs 를 잠시
    // 빌려 쓰고 앞 64 개만 되돌렸다 — 첫 문서가 64 쪽을 넘으면 그 뒤가
    // 둘째 문서의 번호로 덮인 채 남았다.
    // 둘째 문서를 걷는 동안 첫 문서의 "잘렸다" 표시를 건드리지 않는다
    const cut_keep = core.pages_cut;
    const keep_at = core.walk.at;
    const keep_cap = core.walk.cap;
    const keep_ceil = core.walk.ceil;
    if (!core.walkStart(b.len)) return 0;
    b2_page_n = 0;
    core.collectPages(b, pgs, 0, &b2_page_n);
    b2_at = core.walk.at;
    b2_cap_n = b2_page_n;
    core.zoneShrink(b2_at + @as(usize, b2_page_n) * 4);
    core.pages_cut = cut_keep;
    core.walk.at = keep_at;
    core.walk.cap = keep_cap;
    core.walk.ceil = keep_ceil;
    return if (b2_page_n > 0) 1 else 0;
}

pub fn secondPageCount() u32 { return b2_page_n; }
/// 지금 잡아 둔 출력 자리와 원본 길이 — 이어 붙이기 전에 모자란지 보라고 준다
pub fn outCapacity() usize { return core.outbuf.cap; }
pub fn inputLen() usize { return core.in_len; }

/// 숫자를 output 에 적는다.
fn writeNum(pos: *usize, v: u32) void { core.appendNum(pos, v); }

/// 두 문서를 이어 붙인다. 결과 길이를 돌려주고 0이면 실패.
pub fn merge() usize {
    core.outbuf.len = 0;
    if (core.bin2.len == 0 or b2_page_n == 0 or core.pages_obj == 0) return 0;
    const a = core.searchSlice();
    const b = b2Slice();
    const shift = 1000000; // A 의 번호와 겹치지 않게 넉넉히 민다

    // 이어 붙이면 두 문서를 합친 만큼이 필요하다. 자리가 모자라면 여기서
    // 접는다 — 예전에는 그냥 넘겨 썼고, 그 뒤에는 쪽 표가 있다.
    if (!core.outRoom(core.in_len + b.len, 64 * 1024)) return 0;
    @memcpy(core.outBuf()[0..core.in_len], a[0..core.in_len]);
    var pos: usize = core.in_len;
    if (pos > 0 and core.outBuf()[pos - 1] != '\n') { core.outBuf()[pos] = '\n'; pos += 1; }

    const xr_keep = core.zoneTop();
    defer core.zoneShrink(xr_keep);
    // 둘째 문서의 객체 수는 미리 모르니 파일 크기로 어림잡는다(객체 하나에
    // 최소 열여섯 바이트). 예전에는 8192 로 묶여, 그보다 많은 객체를 가진
    // 문서를 붙이면 뒤가 조용히 빠진 채 /Kids 만 남았다.
    const xr = core.xrefTables(b.len / 16 + core.cpage.count + 128) orelse return 0;
    const new_offsets = xr.offs;
    const new_nums = xr.nums;
    var new_n: usize = 0;

    // B 의 객체를 번호를 밀어 다시 적는다
    var i: usize = 0;
    while (i + 4 < b.len and new_n < new_nums.len - 8) {
        const at = core.find(b, " obj", i) orelse break;
        i = at + 4;
        var j = at;
        while (j > 0 and core.isSpace(b[j - 1])) j -= 1;
        while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
        var k = j;
        while (k > 0 and core.isSpace(b[k - 1])) k -= 1;
        var st = k;
        while (st > 0 and b[st - 1] >= '0' and b[st - 1] <= '9') st -= 1;
        if (st >= k) continue;
        var np: usize = st;
        const num = core.readUint(b, &np);
        const body = at + 4;
        const end = core.find(b, "endobj", body) orelse b.len;

        new_offsets[new_n] = pos;
        new_nums[new_n] = num + shift;
        new_n += 1;

        writeNum(&pos, num + shift);
        core.appendStr(&pos, " 0 obj");

        // 딕셔너리 구간과 스트림 구간을 나눈다
        const sm = core.find(b[body..end], "stream", 0);
        const dict_end = if (sm) |x| body + x else end;

        // 딕셔너리: "N G R" 의 N 을 민다
        var q = body;
        while (q < dict_end) {
            if (b[q] >= '0' and b[q] <= '9') {
                var r = q;
                const n1 = core.readUint(b, &r);
                var r2 = r;
                while (r2 < dict_end and core.isSpace(b[r2])) r2 += 1;
                const gen_start = r2;
                var has_gen = false;
                while (r2 < dict_end and b[r2] >= '0' and b[r2] <= '9') { r2 += 1; has_gen = true; }
                var r3 = r2;
                while (r3 < dict_end and core.isSpace(b[r3])) r3 += 1;
                if (has_gen and r3 < dict_end and b[r3] == 'R' and
                    (r3 + 1 >= dict_end or !(b[r3 + 1] >= 'a' and b[r3 + 1] <= 'z')))
                {
                    writeNum(&pos, n1 + shift);
                    core.appendStr(&pos, " ");
                    if (!core.outCopy(&pos, b[gen_start .. r3 + 1])) return 0;
                    q = r3 + 1;
                    continue;
                }
                // 참조가 아니면 그대로
                if (!core.outCopy(&pos, b[q..r])) return 0;
                q = r;
                continue;
            }
            if (!core.outRoom(pos, 1)) return 0;
            core.outBuf()[pos] = b[q];
            pos += 1;
            q += 1;
        }
        // 스트림 구간은 손대지 않는다
        if (dict_end < end) {
            if (!core.outCopy(&pos, b[dict_end..end])) return 0;
        }
        core.appendStr(&pos, "endobj\n");
    }

    // 새 페이지 트리 — A 의 쪽 뒤에 B 의 쪽을 잇는다
    new_offsets[new_n] = pos;
    new_nums[new_n] = core.pages_obj;
    new_n += 1;
    writeNum(&pos, core.pages_obj);
    core.appendStr(&pos, " 0 obj\n<< /Type /Pages /Count ");
    writeNum(&pos, core.cpage.count + b2_page_n);
    core.appendStr(&pos, " /Kids [");
    var t: u32 = 0;
    while (t < core.cpage.count) : (t += 1) {
        core.appendStr(&pos, " ");
        writeNum(&pos, core.page_objs()[t]);
        core.appendStr(&pos, " 0 R");
    }
    t = 0;
    while (t < b2_page_n) : (t += 1) {
        core.appendStr(&pos, " ");
        writeNum(&pos, b2_pages()[t] + shift);
        core.appendStr(&pos, " 0 R");
    }
    core.appendStr(&pos, " ] >>\nendobj\n");

    // B 쪽 페이지의 부모를 A 의 트리로 바꾼다
    t = 0;
    while (t < b2_page_n and new_n < new_nums.len - 2) : (t += 1) {
        const obj = b2_pages()[t];
        const body = core.findObj(b, obj) orelse continue;
        const end = core.find(b, "endobj", body) orelse b.len;
        new_offsets[new_n] = pos;
        new_nums[new_n] = obj + shift;
        new_n += 1;
        writeNum(&pos, obj + shift);
        core.appendStr(&pos, " 0 obj\n<< /Type /Page /Parent ");
        writeNum(&pos, core.pages_obj);
        core.appendStr(&pos, " 0 R");
        // 원본 딕셔너리에서 /Parent 를 뺀 나머지를 옮긴다
        var q = body;
        while (q < end and b[q] != '<') q += 1;
        if (q + 1 < end and b[q + 1] == '<') q += 2;
        // 딕셔너리 깊이. 쪽 딕셔너리 안에는 /Resources << … >> 처럼 딕셔너리가
        // 또 들어 있다. 처음 만난 ">>" 에서 멈추면 그 안쪽 것에서 끊겨
        // /MediaBox·/Contents 가 통째로 날아간다 — 실제로 그랬다.
        var depth: u32 = 0;
        while (q < end) {
            // 글 안의 괄호·부등호는 구조가 아니다
            if (b[q] == '(') {
                const st2 = q;
                q += 1;
                var par: u32 = 1;
                while (q < end and par > 0) : (q += 1) {
                    if (b[q] == '\\') { q += 1; continue; }
                    if (b[q] == '(') par += 1;
                    if (b[q] == ')') par -= 1;
                }
                if (!core.outCopy(&pos, b[st2..q])) return 0;
                continue;
            }
            if (b[q] == '<' and q + 1 < end and b[q + 1] == '<') {
                depth += 1;
                core.appendStr(&pos, "<<");
                q += 2;
                continue;
            }
            if (b[q] == '<') {
                // 16진 글자열 <AB12> — 닫는 '>' 까지 그대로 옮긴다
                const st2 = q;
                q += 1;
                while (q < end and b[q] != '>') q += 1;
                if (q < end) q += 1;
                if (!core.outCopy(&pos, b[st2..q])) return 0;
                continue;
            }
            if (b[q] == '>' and q + 1 < end and b[q + 1] == '>') {
                if (depth == 0) break; // 바깥 딕셔너리의 끝
                depth -= 1;
                core.appendStr(&pos, ">>");
                q += 2;
                continue;
            }
            if (b[q] == '/' and q + 7 <= end and core.std_mem_eq(b[q .. q + 7], "/Parent")) {
                q += 7;
                while (q < end and core.isSpace(b[q])) q += 1;
                _ = core.readUint(b, &q);
                while (q < end and core.isSpace(b[q])) q += 1;
                _ = core.readUint(b, &q);
                while (q < end and core.isSpace(b[q])) q += 1;
                if (q < end and b[q] == 'R') q += 1;
                continue;
            }
            if (b[q] >= '0' and b[q] <= '9') {
                var r = q;
                const n1 = core.readUint(b, &r);
                var r2 = r;
                while (r2 < end and core.isSpace(b[r2])) r2 += 1;
                var has_gen = false;
                while (r2 < end and b[r2] >= '0' and b[r2] <= '9') { r2 += 1; has_gen = true; }
                var r3 = r2;
                while (r3 < end and core.isSpace(b[r3])) r3 += 1;
                if (has_gen and r3 < end and b[r3] == 'R') {
                    writeNum(&pos, n1 + shift);
                    core.appendStr(&pos, " 0 R");
                    q = r3 + 1;
                    continue;
                }
                if (!core.outCopy(&pos, b[q..r])) return 0;
                q = r;
                continue;
            }
            if (!core.outRoom(pos, 1)) return 0;
            core.outBuf()[pos] = b[q];
            pos += 1;
            q += 1;
        }
        core.appendStr(&pos, " >>\nendobj\n");
    }

    // 상호참조표와 트레일러
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
    var w: usize = 0;
    while (w < new_n) : (w += 1) {
        writeNum(&pos, new_nums[w]);
        core.appendStr(&pos, " 1\n");
        var off = new_offsets[w];
        var digits: [10]u8 = undefined;
        var d: usize = 10;
        while (d > 0) : (d -= 1) { digits[d - 1] = @intCast('0' + (off % 10)); off /= 10; }
        if (!core.outRoom(pos, 10)) return 0;
        @memcpy(core.outBuf()[pos..][0..10], &digits);
        pos += 10;
        core.appendStr(&pos, " 00000 n \n");
    }
    var prev: u32 = 0;
    if (core.rfindTail(a[0..core.in_len], "startxref")) |at| {
        var p = at + 9;
        prev = core.readUint(a, &p);
    }
    var root: u32 = 0;
    if (core.rfind(a, "/Root", a.len - 1)) |at| {
        var p = at + 5;
        root = core.readUint(a, &p);
    }
    core.appendStr(&pos, "trailer\n<< /Size 2000000 /Root ");
    writeNum(&pos, root);
    core.appendStr(&pos, " 0 R /Prev ");
    writeNum(&pos, prev);
    core.appendStr(&pos, " >>\nstartxref\n");
    writeNum(&pos, @intCast(xref_pos));
    core.appendStr(&pos, "\n%%EOF\n");

    core.stripEncryptOut(pos);
    core.outbuf.len = pos;
    return pos;
}


