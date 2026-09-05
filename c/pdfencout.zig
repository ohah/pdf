//! 문서에 암호를 건다
//!
//! pdf.zig 를 덩이별로 떼어 내는 중이다. 여기서 바깥이 쓰는 것은 1개,
//! 이쪽이 pdf.zig 의 도구를 쓰는 것은 32개다.
//!
//! JS 에 내보내는 함수(4개)는 pdf.zig 에 껍데기만 남기고 알맹이를
//! 여기 뒀다. 다른 파일에 export fn 을 두면 아무도 안 부를 때 Zig 가 분석조차
//! 하지 않아 링커가 못 찾는다.

const std = @import("std");
const core = @import("pdf.zig");

// ===== 암호 걸기 =====
//
// 푸는 것만 되고 거는 것은 안 됐다. 거는 쪽은 모든 스트림과 문자열을 다시
// 암호화해야 해서, 원본을 그대로 두고 뒤에 덧붙이는 길로는 안 된다.
// 객체를 처음부터 다시 쓰는 "파일 줄이기" 길에 얹는다.
//
// 방식은 AES-256(V5·R6) 하나만 쓴다. 요즘 표준이고, 객체마다 열쇠를 따로
// 만들지 않아 쓰기도 단순하다.
var enc_want: bool = false;
var enc_pw: [128]u8 = undefined;
var enc_pw_len: u32 = 0;
var enc_rand: [64]u8 = undefined;
var enc_fkey: [32]u8 = undefined;
var enc_ctr: u32 = 0;

pub fn setEncrypt(on: u32) void {
    enc_want = on != 0;
    enc_pw_len = 0;
}
/// 사용자 암호 한 글자 (utf-8 로 담는다)
pub fn addEncryptChar(c: u32) void {
    if (c < 0x80) {
        if (enc_pw_len + 1 > enc_pw.len) return;
        enc_pw[enc_pw_len] = @intCast(c);
        enc_pw_len += 1;
    } else if (c < 0x800) {
        if (enc_pw_len + 2 > enc_pw.len) return;
        enc_pw[enc_pw_len] = @intCast(0xC0 | (c >> 6));
        enc_pw[enc_pw_len + 1] = @intCast(0x80 | (c & 63));
        enc_pw_len += 2;
    } else {
        if (enc_pw_len + 3 > enc_pw.len) return;
        enc_pw[enc_pw_len] = @intCast(0xE0 | (c >> 12));
        enc_pw[enc_pw_len + 1] = @intCast(0x80 | ((c >> 6) & 63));
        enc_pw[enc_pw_len + 2] = @intCast(0x80 | (c & 63));
        enc_pw_len += 3;
    }
}
/// 무작위 64 바이트를 화면 쪽이 채운다 — wasm 에는 난수원이 없다
pub fn encRandomPtr() usize { return @intFromPtr(&enc_rand); }

/// 스트림·문자열마다 다른 IV. 열쇠와 차례로 만든다.
fn encIv(out: *[16]u8) void {
    enc_ctr +%= 1;
    var c4: [4]u8 = .{
        @truncate(enc_ctr), @truncate(enc_ctr >> 8),
        @truncate(enc_ctr >> 16), @truncate(enc_ctr >> 24),
    };
    var h: [32]u8 = undefined;
    core.crypt.sha256(&[_][]const u8{ &enc_fkey, &c4, enc_rand[48..64] }, &h);
    @memcpy(out, h[0..16]);
}

/// AES-256-CBC 로 암호화해 dst 에 담는다. 앞 16 바이트가 IV 다.
/// 규격대로 항상 덧대기를 붙인다(딱 맞아떨어져도 한 덩이 더).
fn aesSeal(src: []const u8, dst: []u8) u32 {
    const pad: usize = 16 - (src.len % 16);
    const total = 16 + src.len + pad;
    if (total > dst.len) return 0;
    var iv: [16]u8 = undefined;
    encIv(&iv);
    @memcpy(dst[0..16], &iv);
    @memcpy(dst[16..][0..src.len], src);
    var i: usize = 0;
    while (i < pad) : (i += 1) dst[16 + src.len + i] = @intCast(pad);
    core.crypt.aesCbcEncrypt(&enc_fkey, &iv, dst[16..total]);
    return @intCast(total);
}

/// 글자열 하나를 암호화할 때만 쓰는 작은 자리.
///
/// 스트림은 여기 안 담는다. 예전에는 16MB 짜리 정적 배열 하나에 둘 다
/// 담았는데, 그보다 큰 스트림(300dpi 스캔 한 장이면 25MB 다)을 만나면
/// 조용히 건너뛰고 딕셔너리에는 원래 /Length 를 적었다 — 스트림은 없는데
/// 있다고 적힌 파일이 나갔다. 이제 스트림은 그때그때 메모리 끝을 빌린다.
var seal_str: [64 * 1024]u8 = undefined;

/// 문자열 하나를 암호화해 <16진> 으로 적는다.
fn writeSealedString(pos: *usize, raw: []const u8) void {
    if (raw.len + 64 > seal_str.len) return;
    const n = aesSeal(raw, &seal_str);
    if (n == 0 or !core.outRoom(pos.*, n * 2 + 8)) {
        core.appendStr(pos, "<>");
        return;
    }
    core.appendStr(pos, "<");
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const hi: u8 = seal_str[i] >> 4;
        const lo: u8 = seal_str[i] & 15;
        core.outBuf()[pos.*] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
        core.outBuf()[pos.* + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
        pos.* += 2;
    }
    core.appendStr(pos, ">");
}

/// 딕셔너리 한 조각을 옮겨 적으며 문자열은 암호화하고 /Length 는 건너뛴다.
fn copyDictSealed(b: []const u8, from: usize, to: usize, pos: *usize, skip_len: bool) void {
    var p = from;
    var tmp: [65536]u8 = undefined;
    while (p < to and core.outRoom(pos.*, 64)) {
        if (skip_len and b[p] == '/' and core.keyIs(b, p, to, "/Length")) {
            p = core.skipVal(b, p + 7, to);
            continue;
        }
        if (b[p] == '(') {
            // 괄호 문자열 — 이스케이프를 풀어 날바이트로 만든 뒤 암호화
            var n: usize = 0;
            var q = p + 1;
            var nest: u32 = 1;
            while (q < to and n < tmp.len) : (q += 1) {
                if (b[q] == '\\' and q + 1 < to) {
                    q += 1;
                    if (b[q] >= '0' and b[q] <= '7') {
                        var v: u32 = 0;
                        var d: u32 = 0;
                        while (d < 3 and q < to and b[q] >= '0' and b[q] <= '7') : (d += 1) {
                            v = v * 8 + (b[q] - '0');
                            q += 1;
                        }
                        q -= 1;
                        tmp[n] = @truncate(v);
                        n += 1;
                        continue;
                    }
                    tmp[n] = switch (b[q]) { 'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[q] };
                    n += 1;
                    continue;
                }
                if (b[q] == '(') nest += 1;
                if (b[q] == ')') { nest -= 1; if (nest == 0) break; }
                tmp[n] = b[q];
                n += 1;
            }
            writeSealedString(pos, tmp[0..n]);
            p = q + 1;
            continue;
        }
        // 딕셔너리 괄호는 두 글자를 한꺼번에 넘긴다. 한 글자씩 보면 << 의
        // 둘째 < 가 16진 문자열의 시작으로 읽혀 /Resources 가 통째로 암호화된다.
        if (b[p] == '<' and p + 1 < to and b[p + 1] == '<') {
            core.outBuf()[pos.*] = '<';
            core.outBuf()[pos.* + 1] = '<';
            pos.* += 2;
            p += 2;
            continue;
        }
        if (b[p] == '>' and p + 1 < to and b[p + 1] == '>') {
            core.outBuf()[pos.*] = '>';
            core.outBuf()[pos.* + 1] = '>';
            pos.* += 2;
            p += 2;
            continue;
        }
        if (b[p] == '<' and p + 1 < to and b[p + 1] != '<') {
            var n: usize = 0;
            var q = p + 1;
            var hi: ?u8 = null;
            while (q < to and b[q] != '>' and n < tmp.len) : (q += 1) {
                const hv = core.hexVal(b[q]) orelse continue;
                if (hi) |h| { tmp[n] = (h << 4) | hv; n += 1; hi = null; } else hi = hv;
            }
            if (hi) |h| { if (n < tmp.len) { tmp[n] = h << 4; n += 1; } }
            writeSealedString(pos, tmp[0..n]);
            p = q + 1;
            continue;
        }
        core.outBuf()[pos.*] = b[p];
        pos.* += 1;
        p += 1;
    }
}

pub fn compact() usize {
    core.out_len = 0;
    if (core.pick_n == 0 or core.pages_obj == 0) return 0;
    const b = core.searchSlice();

    // 살아 있는 객체 표를 문서에서 본 가장 큰 번호에 맞춰 잡는다
    const reach_keep = core.zoneTop();
    defer core.zoneShrink(reach_keep);
    core.reach_n = @as(usize, core.max_obj) + 64;
    core.reach_at = core.zoneAlloc(core.reach_n) orelse { core.reach_n = 0; return 0; };
    const reach = core.reachTable();
    @memset(reach, false);

    // 옛 페이지 트리를 먼저 방문한 것으로 막는다. 이렇게 하지 않으면
    // Catalog → Pages → 모든 쪽으로 내려가 버려서, 버리려던 쪽까지 전부
    // 살아남는다(= 파일이 하나도 줄지 않는다).
    if (core.pages_obj < reach.len) reach[core.pages_obj] = true;

    var root: u32 = 0;
    if (core.trailerKeyOrScan(b, "/Root")) |at| {
        var p = at + 5;
        root = core.readUint(b, &p);
    }
    if (root != 0) core.markReach(b, root, 0);

    // 고른 쪽과 그 아래 딸린 것들만 표시한다
    var i: usize = 0;
    while (i < core.pick_n) : (i += 1) core.markReach(b, core.page_objs()[core.pick.all()[i]], 0);

    var pos: usize = 0;
    core.appendStr(&pos, "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n");
    if (enc_want) {
        @memcpy(&enc_fkey, enc_rand[0..32]);
        enc_ctr = 0;
    }

    const xr_keep = core.zoneTop();
    defer core.zoneShrink(xr_keep);
    const xr = core.xrefTables(@as(usize, core.max_obj) + 64) orelse return 0;
    const new_offsets = xr.offs;
    const new_nums = xr.nums;
    var new_n: usize = 0;

    // 살아남은 객체를 번호를 그대로 두고 옮긴다. 번호를 다시 매기면 모든
    // 참조를 고쳐야 하는데, 얻는 건 상호참조표 몇 바이트뿐이다.
    var num: u32 = 1;
    while (num < reach.len and new_n < new_nums.len - 4) : (num += 1) {
        if (!reach[num]) continue;
        if (num == core.pages_obj) continue;
        const r = core.objRange(b, num) orelse continue;
        new_offsets[new_n] = pos;
        new_nums[new_n] = num;
        new_n += 1;
        core.appendNum(&pos, num);
        core.appendStr(&pos, " 0 obj");
        if (!enc_want) {
            if (!core.outRoom(pos, r.end - r.start)) break;
            if (!core.outRoom(pos, r.end - r.start)) return 0;
            @memcpy(core.outBuf()[pos..][0 .. r.end - r.start], b[r.start..r.end]);
            pos += r.end - r.start;
        } else {
            // 스트림과 문자열을 암호화해 다시 적는다
            const sp2 = core.find(b[r.start..r.end], "stream", 0);
            var dict_to = r.end;
            var sealed: u32 = 0;
            var sealed_at: []u8 = &[_]u8{};
            if (sp2) |sa| {
                dict_to = r.start + sa;
                const length = core.lengthOf(b, r.start, dict_to) orelse 0;
                var d2 = r.start + sa + 6;
                if (d2 < b.len and b[d2] == '\r') d2 += 1;
                if (d2 < b.len and b[d2] == '\n') d2 += 1;
                if (length > 0 and d2 + length <= b.len) {
                    // 스트림 크기에 맞춰 메모리 끝을 빌린다. 못 빌리면 여기서
                    // 접는다 — 스트림 없이 /Length 만 적힌 파일을 내느니
                    // 만들기를 실패로 돌리는 편이 낫다.
                    sealed_at = core.bigScratch(length + 64) orelse return 0;
                    sealed = aesSeal(b[d2..][0..length], sealed_at);
                }
            }
            // 딕셔너리
            var ds5 = r.start;
            while (ds5 < dict_to and b[ds5] != '<') ds5 += 1;
            const de5 = if (ds5 < dict_to) core.dictEnd(b, ds5, dict_to) else dict_to;
            if (de5 > ds5 + 2) {
                core.appendStr(&pos, "\n<<");
                copyDictSealed(b, ds5 + 2, de5 - 2, &pos, sealed > 0);
                if (sealed > 0) {
                    core.appendStr(&pos, " /Length ");
                    core.appendNum(&pos, sealed);
                }
                core.appendStr(&pos, " >>");
            } else {
                copyDictSealed(b, r.start, dict_to, &pos, false);
            }
            if (sealed > 0 and core.outRoom(pos, sealed + 64)) {
                core.appendStr(&pos, "\nstream\n");
                if (!core.outRoom(pos, sealed)) return 0;
                @memcpy(core.outBuf()[pos..][0..sealed], sealed_at[0..sealed]);
                pos += sealed;
                core.appendStr(&pos, "\nendstream\n");
            } else core.appendStr(&pos, "\n");
        }
        core.appendStr(&pos, "endobj\n");
    }

    // 새 페이지 트리
    new_offsets[new_n] = pos;
    new_nums[new_n] = core.pages_obj;
    new_n += 1;
    core.appendNum(&pos, core.pages_obj);
    core.appendStr(&pos, " 0 obj\n<< /Type /Pages /Count ");
    core.appendNum(&pos, @intCast(core.pick_n));
    core.appendStr(&pos, " /Kids [");
    i = 0;
    while (i < core.pick_n) : (i += 1) {
        core.appendStr(&pos, " ");
        core.appendNum(&pos, core.page_objs()[core.pick.all()[i]]);
        core.appendStr(&pos, " 0 R");
    }
    core.appendStr(&pos, " ] >>\nendobj\n");

    // 암호 딕셔너리 — 열쇠를 확인할 값들을 담는다 (V5·R6)
    var enc_obj_num: u32 = 0;
    if (enc_want) {
        enc_obj_num = new_nums[new_n - 1] + 1;
        var m: u32 = 0;
        while (m < new_n) : (m += 1) if (new_nums[m] >= enc_obj_num) { enc_obj_num = new_nums[m] + 1; };
        const pw = enc_pw[0..enc_pw_len];
        var uval: [48]u8 = undefined;
        core.hash2B(pw, enc_rand[32..40], &[_]u8{}, uval[0..32]);
        @memcpy(uval[32..40], enc_rand[32..40]);
        @memcpy(uval[40..48], enc_rand[40..48]);
        var ikey: [32]u8 = undefined;
        core.hash2B(pw, enc_rand[40..48], &[_]u8{}, &ikey);
        var ue: [32]u8 = enc_fkey;
        core.crypt.aesCbcEncrypt(&ikey, &[_]u8{0} ** 16, &ue);
        var oval: [48]u8 = undefined;
        core.hash2B(pw, enc_rand[48..56], uval[0..48], oval[0..32]);
        @memcpy(oval[32..40], enc_rand[48..56]);
        @memcpy(oval[40..48], enc_rand[56..64]);
        var okey: [32]u8 = undefined;
        core.hash2B(pw, enc_rand[56..64], uval[0..48], &okey);
        var oe: [32]u8 = enc_fkey;
        core.crypt.aesCbcEncrypt(&okey, &[_]u8{0} ** 16, &oe);
        // 권한 — 인쇄·복사까지 다 허용한다 (-1 에서 예약 비트만 맞춘다)
        const perm: i32 = -4;
        var pblk: [16]u8 = .{
            @truncate(@as(u32, @bitCast(perm))), @truncate(@as(u32, @bitCast(perm)) >> 8),
            @truncate(@as(u32, @bitCast(perm)) >> 16), @truncate(@as(u32, @bitCast(perm)) >> 24),
            0xFF, 0xFF, 0xFF, 0xFF, 'T', 'a', 'd', 'b',
            enc_rand[0], enc_rand[1], enc_rand[2], enc_rand[3],
        };
        core.crypt.aesCbcEncrypt(&enc_fkey, &[_]u8{0} ** 16, &pblk);

        new_offsets[new_n] = pos;
        new_nums[new_n] = enc_obj_num;
        new_n += 1;
        core.appendNum(&pos, enc_obj_num);
        core.appendStr(&pos, " 0 obj\n<< /Filter /Standard /V 5 /R 6 /Length 256");
        core.appendStr(&pos, " /CF << /StdCF << /CFM /AESV3 /Length 32 /AuthEvent /DocOpen >> >>");
        core.appendStr(&pos, " /StmF /StdCF /StrF /StdCF /EncryptMetadata true /P ");
        core.appendStr(&pos, "-4");
        const hexOut = struct {
            fn f(pp: *usize, key: []const u8, d: []const u8) void {
                core.appendStr(pp, key);
                core.appendStr(pp, " <");
                var za: usize = 0;
                while (za < d.len and core.outRoom(pp.*, 8)) : (za += 1) {
                    const hi: u8 = d[za] >> 4;
                    const lo: u8 = d[za] & 15;
                    core.outBuf()[pp.*] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
                    core.outBuf()[pp.* + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
                    pp.* += 2;
                }
                core.appendStr(pp, ">");
            }
        }.f;
        hexOut(&pos, " /U", uval[0..48]);
        hexOut(&pos, " /UE", &ue);
        hexOut(&pos, " /O", oval[0..48]);
        hexOut(&pos, " /OE", &oe);
        hexOut(&pos, " /Perms", &pblk);
        core.appendStr(&pos, " >>\nendobj\n");
    }

    // 상호참조표 — 처음부터 쓰므로 0번 항목이 필요하다
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
    core.appendStr(&pos, "xref\n0 1\n0000000000 65535 f \n");
    i = 0;
    while (i < new_n) : (i += 1) {
        core.appendNum(&pos, new_nums[i]);
        core.appendStr(&pos, " 1\n");
        var off = new_offsets[i];
        var digits: [10]u8 = undefined;
        var d: usize = 10;
        while (d > 0) : (d -= 1) { digits[d - 1] = @intCast('0' + (off % 10)); off /= 10; }
        if (!core.outRoom(pos, 10)) return 0;
        @memcpy(core.outBuf()[pos..][0..10], &digits);
        pos += 10;
        core.appendStr(&pos, " 00000 n \n");
    }
    core.appendStr(&pos, "trailer\n<< /Size ");
    core.appendNum(&pos, new_nums[new_n - 1] + 1);
    core.appendStr(&pos, " /Root ");
    core.appendNum(&pos, root);
    core.appendStr(&pos, " 0 R");
    if (enc_want and enc_obj_num != 0) {
        core.appendStr(&pos, " /Encrypt ");
        core.appendNum(&pos, enc_obj_num);
        core.appendStr(&pos, " 0 R /ID [<");
        var zb: usize = 0;
        while (zb < 16) : (zb += 1) {
            const hi: u8 = enc_rand[zb] >> 4;
            const lo: u8 = enc_rand[zb] & 15;
            core.outBuf()[pos] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
            core.outBuf()[pos + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
            pos += 2;
        }
        core.appendStr(&pos, "> <");
        zb = 0;
        while (zb < 16) : (zb += 1) {
            const hi: u8 = enc_rand[zb] >> 4;
            const lo: u8 = enc_rand[zb] & 15;
            core.outBuf()[pos] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
            core.outBuf()[pos + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
            pos += 2;
        }
        core.appendStr(&pos, ">]");
    }
    core.appendStr(&pos, " >>\nstartxref\n");
    core.appendNum(&pos, @intCast(xref_pos));
    core.appendStr(&pos, "\n%%EOF\n");

    core.stripEncryptOut(pos);
    core.out_len = pos;
    return pos;
}

