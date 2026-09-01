// PDF 페이지 도구 — 페이지 고르기·순서 바꾸기·회전.
//
// PDF 를 통째로 다시 쓰지 않고 증분 업데이트로 처리한다. 규격이 허용하는
// 방식으로, 원본 바이트는 한 글자도 건드리지 않고 파일 끝에 바뀐 객체와
// 새 xref 만 덧붙인다. 원본을 재작성하면 폰트·이미지·주석까지 전부 옮겨야
// 하지만, 이 방식은 페이지 트리 하나만 다시 쓰면 된다.
//
// 페이지 트리를 찾는 데 필요한 만큼만 파싱한다. 완전한 PDF 파서가 아니다.

// 버퍼를 정적 배열로 잡으면 wasm 이 그 크기만큼 메모리를 들고 시작한다.
// 288MB 짜리 모듈이 되면 브라우저 개발자 도구가 힙을 훑다가 멎는다.
// 그래서 링커가 알려주는 힙 시작점 뒤를 쓰고, 파일 크기에 맞춰 늘린다.
// var 여야 한다. const 로 두면 최적화가 이 주소로의 쓰기를 "상수에 쓰기"로
// 보고 통째로 지운다 — 실제로 ReleaseSmall 에서 암호 해제 결과가 사라졌다.
extern var __heap_base: u8;
extern fn pw_inflate(src: [*]const u8, src_len: c_uint, dst: [*]u8, dst_cap: c_uint) c_int;

const PAGE: usize = 64 * 1024;
var in_len: usize = 0;
var out_len: usize = 0;
var out_off: usize = 0;
/// 객체 스트림(ObjStm)을 풀어 평문 객체로 펼쳐 두는 자리.
/// 원본 뒤에 이어 두고, 객체를 찾을 때 원본과 이 영역을 모두 훑는다.
var exp_off: usize = 0;
var exp_len: usize = 0;
var exp_cap: usize = 0;
/// 병합할 두 번째 문서
var b2_off: usize = 0;
var b2_len: usize = 0;
var b2_cap: usize = 0;
/// 이어 붙일 문서를 담으려면 이만큼은 있어야 한다 — 다음 reserve 에서 본다
var b2_want: usize = 0;
/// 페이지에서 꺼낸 그림 한 장을 두는 자리
var img_off: usize = 0;
/// JBIG2 낱장 곳간 — 문서마다 한 번 잡는다
var jb_pool_at: usize = 0;
var img_cap: usize = 0;
var font_off: usize = 0;
var font_cap: usize = 0;
var inl_off: usize = 0;
var inl_cap: usize = 0;
var inl_used: u32 = 0;
var sub_off: usize = 0;
var sub_cap: usize = 0;
var t1_off: usize = 0;
var t1_cap: usize = 0;
var t1_used: u32 = 0;
var img_len: usize = 0;
var img_w: u32 = 0;
var img_h: u32 = 0;
/// 0=없음 1=RGB 2=흑백 3=JPEG(브라우저가 푼다)
var img_kind: u32 = 0;

fn heapBase() usize { return @intFromPtr(&__heap_base); }

/// 입력·출력에 쓸 자리를 확보한다. 모자라면 메모리를 늘린다.
export fn reserve(want_in: usize, want_out: usize) u32 {
    // 원본 · 펼친 객체 · 출력 순으로 잡는다. 펼친 객체는 원본만큼 여유를 준다.
    exp_cap = want_in + 1024 * 1024;
    // 여벌 자리.
    //
    // 이어 붙일 둘째 문서를 담기도 하고, 스트림 하나를 풀거나 푸는 동안
    // 중간 결과를 두는 데도 쓴다. 파일만큼 잡아 두었더니 300MB 문서를
    // 보기만 해도 300MB 를 더 들고 있었다 — 붙이지도 않는데. 스트림 하나에
    // 맞춰 잡고, 이어 붙일 때만 setSecondRoom 으로 늘린다.
    b2_cap = @max(@min(want_in + 1024 * 1024, 128 * 1024 * 1024), b2_want);
    // 아래 다섯은 여기서 안 잡는다. 글자만 있는 계약서를 열어도 그림 자리
    // 48MB 를, 글꼴이 안 박힌 문서도 글꼴 자리 8MB 를 들고 있었다 —
    // 문서가 실제로 그것을 쓸 때 잡는다(areaOf).
    img_cap = 48 * 1024 * 1024;
    font_cap = 8 * 1024 * 1024;
    inl_cap = 8 * 1024 * 1024;
    sub_cap = 6 * 1024 * 1024; // 폼·글리프 그림용, 깊이마다 2MB
    t1_cap = 4 * 1024 * 1024; // Type1 글리프 프로그램
    img_off = 0;
    jb_pool_at = 0;
    font_off = 0;
    inl_off = 0;
    sub_off = 0;
    t1_off = 0;
    const need = heapBase() + want_in + exp_cap + b2_cap + want_out;
    const have = @wasmMemorySize(0) * PAGE;
    if (need > have) {
        const more = (need - have + PAGE - 1) / PAGE;
        if (@wasmMemoryGrow(0, more) < 0) return 0;
    }
    exp_off = heapBase() + want_in;
    b2_off = exp_off + exp_cap;
    out_off = b2_off + b2_cap;
    out_cap = want_out;
    return 1;
}

var out_cap: usize = 0;

/// 그림·글꼴·인라인·폼·Type1 자리를 쓸 때 잡는다.
///
/// 예전에는 문서를 보기도 전에 74MB 를 통째로 잡았다. 그림 없는 문서도,
/// 글꼴이 안 박힌 문서도 그만큼 들고 있었다 — 탭마다 워커가 하나씩 뜨는
/// 브라우저에서는 그게 곱해진다. 처음 쓸 때 잡고, 문서를 새로 열면 놓는다.
fn areaOf(off: *usize, cap: usize) usize {
    if (off.* != 0) return off.*;
    off.* = zoneAlloc(cap) orelse 0;
    return off.*;
}
fn imgArea() usize { return areaOf(&img_off, img_cap); }
fn fontArea() usize { return areaOf(&font_off, font_cap); }
fn inlArea() usize { return areaOf(&inl_off, inl_cap); }
fn subArea() usize { return areaOf(&sub_off, sub_cap); }
fn t1Area() usize { return areaOf(&t1_off, t1_cap); }

/// 큰 그림 하나를 푸는 동안만 쓰는 여벌 자리.
///
/// JPEG2000 은 웨이블릿 계수를 실수로 들고 있어야 해서 화소당 스무 바이트가
/// 넘게 든다. 늘 잡아 두면 어떤 PDF 를 열든 수백 MB 를 들고 시작하므로,
/// 필요할 때만 메모리 끝을 늘려 쓴다.
/// 문서 크기에 맞춰 표를 떼어 주는 자리 (출력 버퍼 뒤).
///
/// 쪽 수만큼 필요한 표가 넷이다 — 쪽 객체 번호·고른 쪽·쪽마다 회전·쪽 라벨.
/// 고정 배열로 두면 상한이 생긴다. 실제로 4096 쪽에 묶여 있었고 그보다 긴
/// 문서는 뒤가 조용히 잘렸다. 문서를 읽고 나서 쓸 만큼만 떼어 준다.
/// 메모리 끝에 있어 늘려도 앞의 것을 옮길 일이 없다.
var zone_top: usize = 0;
fn zoneBase() usize { return out_off + out_cap; }
fn zoneTop() usize { return if (zone_top < zoneBase()) zoneBase() else zone_top; }
fn zoneReset() void { zone_top = zoneBase(); }
/// 자리를 떼어 준다. 못 늘리면 null.
fn zoneAlloc(bytes: usize) ?usize {
    if (out_off == 0) return null;
    const at = (zoneTop() + 7) & ~@as(usize, 7);
    const need = at + bytes;
    const have = @wasmMemorySize(0) * PAGE;
    if (need > have) {
        const more = (need - have + PAGE - 1) / PAGE;
        if (@wasmMemoryGrow(0, more) < 0) return null;
    }
    zone_top = need;
    return at;
}
/// 넉넉히 잡아 둔 것을 실제로 쓴 만큼으로 줄인다.
fn zoneShrink(to: usize) void { if (to >= zoneBase()) zone_top = to; }

/// 글꼴 표 하나의 짝 배열을 읽는다. 아직 안 잡았으면 빈 것을 준다.
fn u16buf(at: usize, cap: u32) []u16 {
    if (at == 0 or cap == 0) return &[_]u16{};
    return @as([*]u16, @ptrFromInt(at))[0..cap];
}

/// 큰 임시 자리 하나. 돌려 쓴다.
///
/// 예전에는 "구역 끝 너머를 빌린다" 였다. 자리를 잡아 두지 않으므로,
/// 빌린 것을 쓰는 동안 누가 zoneAlloc 을 하면 그 위에 겹쳐 앉았다.
/// 실제로 봉인한 스트림 한가운데가 남의 표로 덮여 나왔다. 이제는 구역에
/// 제 몫으로 잡아 두고, 더 큰 것이 필요할 때만 늘린다.
var big_at: usize = 0;
var big_cap: u32 = 0;
fn bigScratch(want: usize) ?[]u8 {
    if (out_off == 0 or want == 0 or want > 0xF000_0000) return null;
    if (!growTableTo(&big_at, &big_cap, @intCast(want), 1, 1 << 16, 1 << 30)) return null;
    return @as([*]u8, @ptrFromInt(big_at))[0..want];
}

export fn secondPtr() usize { return b2_off; }
/// 이어 붙이기 전에 "이만큼 담을 자리가 필요하다" 고 알린다
export fn setSecondRoom(n: usize) void { b2_want = n; }
export fn maxSecond() usize { return b2_cap; }

fn expBuf() [*]u8 { return @ptrFromInt(exp_off); }

/// 원본과 펼친 객체를 한 덩어리로 본다. findObj 가 둘 다 훑도록.
fn searchSlice() []u8 {
    return @as([*]u8, @ptrFromInt(heapBase()))[0 .. in_len + exp_len];
}


/// 페이지 객체 번호들 (문서 순서). 자리는 parse 가 쪽 수에 맞춰 잡는다.
var pg_at: usize = 0;
var pg_cap: u32 = 0;
var page_count: u32 = 0;
/// 담을 자리가 모자라 뒤를 잘랐는가 — 화면에 알려 주기 위한 것이다.
var pages_cut: bool = false;

fn u32sAt(at: usize, n: u32) []u32 {
    if (at == 0 or n == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(at))[0..n];
}
fn page_objs() []u32 { return u32sAt(pg_at, pg_cap); }
/// Pages 트리 루트 객체 번호
var pages_obj: u32 = 0;
/// Catalog 객체 번호 — 만들 때 /AcroForm 을 손대는 데 쓴다
var doc_root: u32 = 0;
/// 사용자가 고른 순서
var pick_at: usize = 0;
var pick_cap: u32 = 0;
fn pick() []u32 { return u32sAt(pick_at, pick_cap); }
var pick_n: usize = 0;
var rotate: i32 = 0;
/// 워터마크 문구 (라틴 문자만 — 표준 글꼴을 쓰므로 한글은 넣을 수 없다)
var wm: [128]u8 = undefined;
var wm_len: usize = 0;
/// 워터마크 글자를 코드 그대로 담는다. 1바이트로 자르면 한글이 엉뚱한
/// 라틴 글자가 된다 — ㅁ(U+3141) 이 'A'(0x41) 로 보였다.
var wm_cp: [64]u32 = undefined;
var wm_n: usize = 0;

export fn clearWatermark() void { wm_len = 0; wm_n = 0; wm_mlen = 0; wm_mobj = 0; }
export fn addWatermarkChar(c: u32) void {
    if (c < 32 or c == 127) return;
    if (wm_n < wm_cp.len) { wm_cp[wm_n] = c; wm_n += 1; }
    // 표준 글꼴로 찍을 때 쓸 아스키 판
    if (wm_len < wm.len and c >= 32 and c < 127 and c != '(' and c != ')' and c != '\\') {
        wm[wm_len] = @truncate(c);
        wm_len += 1;
    }
}
/// 워터마크가 아스키만인가
fn wmIsAscii() bool {
    var i: usize = 0;
    while (i < wm_n) : (i += 1) if (wm_cp[i] > 126) return false;
    return true;
}

export fn inputPtr() usize { return heapBase(); }
export fn outputPtr() usize { return out_off; }
/// wasm32 가 쓸 수 있는 주소는 4GB 다. 그 안에서 우리가 쓰는 만큼을 빼고
/// 남는 것이 받을 수 있는 파일 크기다. 안전 여유를 두어 3.5GB 로 잡는다 —
/// 브라우저가 실제로 내주는 양은 기기마다 다르고, 못 늘리면 reserve 가
/// 0 을 돌려주므로 그때는 "메모리를 못 잡았다"로 끝난다.
const BUDGET: usize = 3584 * 1024 * 1024;
/// 파일 크기와 무관하게 늘 잡는 것 — 그림 48 · 글꼴 8 · 인라인 8 · 폼 6 ·
/// Type1 4 · 마스크 곳간 12(쓸 때만) · 모듈이 들고 시작하는 35
const FIXED: usize = (48 + 8 + 8 + 6 + 4 + 12 + 35) * 1024 * 1024;

/// 받을 수 있는 파일 크기.
///
/// 예전에는 입출력이 정적 배열이라 그 배열 크기가 곧 한계였다. 배열을
/// 걷어내고 필요할 때 memory.grow 하도록 바꾸면서 배열은 사라졌는데,
/// 그때 적어 둔 512MB 라는 숫자만 남아 아무것도 지키지 않은 채 문턱 노릇을
/// 했다. 지금은 여는 데 실제로 드는 양에서 거꾸로 구한다 —
/// 원본 + 펼친 객체(원본만큼) + 여벌(원본만큼) + 고정분 + 출력 여유.
export fn maxInput() usize {
    // 여는 데 드는 것: 원본(1) + 펼친 객체(1) + 여벌(최대 128MB) + 고정분 + 여유.
    // 낼 때는 출력 자리를 더 잡지만 그건 그때 늘리고, 못 늘리면 그때 알린다.
    const scratch: usize = 128 * 1024 * 1024;
    const slack: usize = 4 * 1024 * 1024;
    return (BUDGET - FIXED - scratch - slack) / 2;
}
export fn outputLen() usize { return out_len; }
export fn pageCount() u32 { return page_count; }
/// 쪽이 너무 많아 뒤를 잘랐는가
export fn pagesTruncated() u32 { return if (pages_cut) 1 else 0; }

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0 or c == 12;
}

/// haystack 에서 needle 을 뒤에서부터 찾는다.
/// 뒤에서부터 찾는다. find 와 같은 수를 쓰되 방향만 반대다 —
/// 여덟 바이트를 한 번에 읽어 첫 글자가 없으면 여덟 칸을 건너뛴다.
/// /Root · /Encrypt 처럼 파일 끝에 적히는 것을 찾는 데 쓰므로 뜨겁다.
fn rfind(h: []const u8, n: []const u8, from: usize) ?usize {
    if (n.len == 0 or n.len > h.len) return null;
    const last = h.len - n.len;
    var i: usize = @min(from, last);
    const c0 = n[0];
    const ones: u64 = 0x0101010101010101;
    const highs: u64 = 0x8080808080808080;
    const spread: u64 = ones *% @as(u64, c0);
    while (true) {
        var gone = false;
        while (i >= 7) {
            const w: u64 = @bitCast(h[i - 7 ..][0..8].*);
            const x = w ^ spread;
            const hit = (x -% ones) & ~x & highs;
            if (hit != 0) {
                // 켜진 것 중 가장 높은 자리 = 가장 뒤쪽 바이트
                const b: usize = (63 - @clz(hit)) >> 3;
                i = i - 7 + b;
                break;
            }
            if (i < 8) { gone = true; break; }
            i -= 8;
        }
        if (gone) return null;
        if (i <= last and h[i] == c0 and std_mem_eq(h[i .. i + n.len], n)) return i;
        if (i == 0) return null;
        i -= 1;
    }
}
/// 뒤에서 찾되 꼬리부터 본다.
///
/// /Root · /Info · /Encrypt · /ID 는 파일 끝의 trailer 에 적힌다. 그런데
/// rfind 는 못 찾으면 파일 앞까지 내려가므로, 그런 것이 없는 문서에서는
/// 34MB 를 통째로 훑고 나서 "없다"고 답했다. 꼬리를 먼저 보고 거기 있으면
/// 그것이 마지막 것이다 — 없을 때만 예전처럼 통째로 훑으므로 답은 같다.
fn rfindTail(h: []const u8, n: []const u8) ?usize {
    if (h.len == 0 or n.len == 0) return null;
    const win: usize = 64 * 1024;
    if (h.len > win) {
        const stop = h.len - win;
        if (rfind(h[stop..], n, win - 1)) |at| return stop + at;
    }
    return rfind(h, n, h.len - 1);
}

/// trailer 딕셔너리 안에서 키를 찾는다. 없으면 파일 전체를 뒤진다.
///
/// /Root · /Info · /Encrypt · /ID 는 파일 끝의 trailer 에 적힌다. 예전에는
/// 파일 전체에서 마지막 것을 찾았는데, 그 키가 없는 문서에서는 없다는 것을
/// 확인하려고 34MB 를 통째로 훑었다 — 34MB 문서를 여는 값의 절반이 이것이었다.
///
/// 이제 trailer 를 먼저 잡고 거기서 본다. 갱신이 여러 번 얹힌 문서는
/// /Prev 를 따라 이전 trailer 도 본다. trailer 를 못 잡으면 예전처럼
/// 통째로 훑는다 — 망가진 파일에서 답이 달라지지 않게 하려는 것이다.
fn trailerKey(b: []const u8, key: []const u8) ?usize {
    var seen: u32 = 0;
    var at = trailerStart(b);
    while (at) |ts| {
        const te = dictEndFrom(b, ts);
        if (find(b[ts..te], key, 0)) |k| return ts + k;
        seen += 1;
        if (seen > 256) break; // 갱신이 끝없이 얽힌 파일에서 멈추기 위한 것
        at = prevTrailer(b, ts, te);
    }
    if (seen == 0) {
        // trailer 를 못 잡았다 — 옛 방식으로 통째로 훑는다
        return rfind(b, key, b.len - 1);
    }
    return null;
}

/// trailer 에 없으면 파일 전체에서 한 번 더 찾는다.
///
/// 틀렸을 때 값이 큰 키에 쓴다.
///
///   /Root    — 없으면 문서를 아예 못 연다.
///   /Encrypt — 놓치면 암호글을 그냥 글로 읽어 깨진 글자를 내놓고, 게다가
///              "안 잠긴 문서, 인쇄·복사 다 됨" 이라고 답한다. 조용히
///              틀리는 데다 권한까지 잘못 말한다. 갱신이 얹힌 문서 중에는
///              새 trailer 에 /Encrypt 를 안 적는 것이 실제로 있다.
///
///   /ID      — 암호 열쇠를 만드는 재료다. 놓치면 열쇠가 달라져 맞는 암호를
///              줘도 안 열린다. 게다가 문서 지문이기도 하다.
///
/// /Info 는 여기 쓰지 않는다 — 규격이 trailer 에 적으라고 하고, 놓쳐도
/// 문서 정보가 비는 정도라 훑는 값을 치를 만하지 않다.
fn trailerKeyOrScan(b: []const u8, key: []const u8) ?usize {
    if (trailerKey(b, key)) |at| return at;
    if (b.len == 0) return null;
    return rfind(b, key, b.len - 1);
}

/// 파일 끝의 trailer 딕셔너리가 시작하는 자리.
///
/// "trailer" 라고 적힌 옛 꼴과, xref 자체가 스트림인 새 꼴 둘 다 본다.
/// 새 꼴은 startxref 가 가리키는 객체의 딕셔너리가 trailer 다.
fn trailerStart(b: []const u8) ?usize {
    if (b.len == 0) return null;
    const win: usize = 64 * 1024;
    const from = if (b.len > win) b.len - win else 0;
    // startxref 를 먼저 본다.
    //
    // 옛 꼴(trailer 키워드)로 만든 문서에 xref 스트림으로 갱신을 얹으면,
    // 꼬리 창에 죽은 옛 trailer 가 그대로 남아 있다. 키워드를 먼저 찾으면
    // 그 죽은 판의 /Root 를 집어 옛 쪽 트리를 읽는다 — 세 쪽짜리가 한 쪽으로
    // 보였다. startxref 는 언제나 지금 판을 가리킨다.
    if (rfind(b[from..], "startxref", b.len - from - 1)) |sx| {
        var p = from + sx + 9;
        const off = readUint(b, &p);
        if (off > 0 and off < b.len) {
            // 그 자리에 "N 0 obj" 가 있으면 그 딕셔너리다
            if (find(b[off..@min(b.len, off + 64)], "obj", 0)) |o| {
                var q = off + o + 3;
                while (q < b.len and isSpace(b[q])) q += 1;
                if (q + 1 < b.len and b[q] == '<' and b[q + 1] == '<') return q;
            }
            // 옛 꼴이면 그 자리에 xref 표가 있고 그 뒤에 trailer 가 온다
            if (find(b[off..], "trailer", 0)) |t| {
                var q = off + t + 7;
                while (q < b.len and isSpace(b[q])) q += 1;
                if (q + 1 < b.len and b[q] == '<' and b[q + 1] == '<') return q;
            }
        }
    }
    // startxref 를 못 읽으면 꼬리에 적힌 trailer 를 찾는다
    if (rfind(b[from..], "trailer", b.len - from - 1)) |t| {
        var p = from + t + 7;
        while (p < b.len and isSpace(b[p])) p += 1;
        if (p + 1 < b.len and b[p] == '<' and b[p + 1] == '<') return p;
    }
    return null;
}

/// "<<" 에서 시작해 짝이 맞는 ">>" 까지
fn dictEndFrom(b: []const u8, ds: usize) usize {
    var depth: u32 = 0;
    var r = ds;
    while (r + 1 < b.len) : (r += 1) {
        // 글자열 안의 부등호는 구조가 아니다 — /Title (a >> b) 같은 것
        if (b[r] == '(') {
            var par: u32 = 1;
            r += 1;
            while (r < b.len and par > 0) : (r += 1) {
                if (b[r] == '\\') { r += 1; continue; }
                if (b[r] == '(') par += 1;
                if (b[r] == ')') par -= 1;
            }
            if (r == 0) return b.len;
            r -= 1; // for 의 증가분을 되돌린다
            continue;
        }
        if (b[r] == '<' and b[r + 1] == '<') { depth += 1; r += 1; continue; }
        if (b[r] == '<') {
            // 16진 글자열 <AB12>
            r += 1;
            while (r < b.len and b[r] != '>') r += 1;
            continue;
        }
        if (b[r] == '>' and b[r + 1] == '>') {
            if (depth > 0) depth -= 1;
            r += 1;
            if (depth == 0) return @min(b.len, r + 1);
            continue;
        }
    }
    return b.len;
}

/// 이 trailer 가 가리키는 이전 xref 의 trailer 시작 자리
fn prevTrailer(b: []const u8, ts: usize, te: usize) ?usize {
    const pa = find(b[ts..te], "/Prev", 0) orelse return null;
    var p = ts + pa + 5;
    const off = readUint(b, &p);
    if (off == 0 or off >= b.len) return null;
    // 옛 꼴이면 그 자리부터 "trailer" 가 곧 나온다
    if (find(b[off..], "trailer", 0)) |t| {
        var q = off + t + 7;
        while (q < b.len and isSpace(b[q])) q += 1;
        if (q + 1 < b.len and b[q] == '<' and b[q + 1] == '<') return q;
    }
    // xref 스트림이면 그 객체의 딕셔너리
    if (find(b[off..@min(b.len, off + 64)], "obj", 0)) |o| {
        var q = off + o + 3;
        while (q < b.len and isSpace(b[q])) q += 1;
        if (q + 1 < b.len and b[q] == '<' and b[q + 1] == '<') return q;
    }
    return null;
}

/// 엔진에서 가장 뜨거운 고리다. 문서 하나를 여는 동안 파일 크기의 몇 배를
/// 이 함수로 훑는다.
///
/// 한 바이트씩 밀며 비교하면 바이트마다 서너 클럭이 든다. 첫 글자만 찾을
/// 때는 여덟 바이트를 u64 로 한 번에 읽어 본다 — 그 안에 첫 글자가 없으면
/// 여덟 칸을 통째로 건너뛴다. 찾는 것과 답은 같고 훑는 값만 준다.
fn find(h: []const u8, n: []const u8, from: usize) ?usize {
    if (n.len == 0 or n.len > h.len) return null;
    const last = h.len - n.len;
    const c0 = n[0];
    const ones: u64 = 0x0101010101010101;
    const highs: u64 = 0x8080808080808080;
    const spread: u64 = ones *% @as(u64, c0);
    var i: usize = from;
    while (i <= last) {
        // 여덟 바이트 중에 첫 글자가 있는지 — 없으면 여덟 칸 건너뛴다
        while (i + 8 <= last) {
            const w: u64 = @bitCast(h[i..][0..8].*);
            const x = w ^ spread;
            const hit = (x -% ones) & ~x & highs;
            if (hit != 0) {
                i += @ctz(hit) >> 3;
                break;
            }
            i += 8;
        }
        if (i > last) return null;
        if (h[i] == c0 and std_mem_eq(h[i .. i + n.len], n)) return i;
        i += 1;
    }
    return null;
}
fn std_mem_eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

fn readUint(b: []const u8, p: *usize) u32 {
    while (p.* < b.len and isSpace(b[p.*])) p.* += 1;
    var v: u32 = 0;
    while (p.* < b.len and b[p.*] >= '0' and b[p.*] <= '9') : (p.* += 1)
        v = v * 10 + (b[p.*] - '0');
    return v;
}

/// "N 0 obj" 를 찾아 그 객체의 본문 시작 위치를 준다.
// 객체 찾기.
//
// 같은 번호가 여러 번 나올 수 있다. 증분 업데이트로 고친 PDF 는 원본을 그대로
// 두고 새 판을 파일 끝에 덧붙이므로, 뒤에 있는 것이 최신이다. 우리가 만든
// 회전·워터마크 파일이 그렇게 생겼는데 앞의 것을 집어 쓰는 바람에 정작
// 우리 미리보기에서는 워터마크가 보이지 않았다.
//
// 순위가 하나 더 있다. 객체 스트림을 풀어 둔 자리는 원본 뒤에 붙지만 새 판이
// 아니라 원본의 사본이다. 그래서 원본 구간에 평문으로 있는 것을 먼저 본다.
var max_obj: u32 = 0;

/// 색인은 문서에 맞춰 늘어난다.
///
/// 예전에는 [65536] 고정이었다. 번호가 그보다 큰 객체는 색인에 못 들어가고,
/// 그것을 찾을 때마다 파일을 통째로 훑었다 — 3만 쪽 문서 46ms 가 4만 쪽에서
/// 89초가 되는 벼랑이 상수 하나에 걸려 있었다. 처음 6만 5천 개로 시작해
/// 더 큰 번호를 만나면 배로 늘린다.
const OBJ_IDX_START: u32 = 65536;
/// 여기서 멈춘다 — 번호가 끝없이 큰 망가진 파일에 끌려가지 않기 위한 것
const OBJ_IDX_LIMIT: u32 = 1 << 22;
var obj_at: usize = 0;
var rank_at: usize = 0;
var obj_cap: u32 = 0;
var obj_idx_len: usize = 0; // 색인을 만든 버퍼 길이 (0 이면 없음)

fn objOff() []u32 {
    if (obj_at == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(obj_at))[0..obj_cap];
}
fn objRankTable() []u8 {
    if (rank_at == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(rank_at))[0..obj_cap];
}

/// num 번까지 담을 자리를 마련한다. 못 늘리면 false — 그 번호는 색인에
/// 안 들어가고 찾을 때 훑는다(예전과 같은 길).

/// 표 하나를 문서에 맞춰 늘린다.
///
/// 고정 배열로 두면 그 숫자가 곧 상한이 되고, 넘는 문서는 뒤가 조용히
/// 잘린다. 자리잡개에서 떼어 쓰고 모자라면 배로 늘린다 — 늘릴 때 앞자리는
/// 버리므로 최대 두 배까지 더 쓰지만, 세는 상한이 사라진다.
/// (pdf.js 는 JS 배열이라 이런 상한이 아예 없다.)
fn growTable(at: *usize, cap: *u32, want: u32, elem: usize, start: u32) bool {
    return growTableTo(at, cap, want, elem, start, 1 << 22);
}

/// 위와 같되 몇 개까지 늘릴지 따로 정한다. 큰 임시 자리는 개수가 아니라
/// 바이트라 4M 에서 막히면 안 된다.
fn growTableTo(at: *usize, cap: *u32, want: u32, elem: usize, start: u32, limit: u32) bool {
    // 구역이 되감겼으면(merge·compact 가 그런다) 들고 있던 자리는 남의 것이다
    if (at.* != 0 and at.* + @as(usize, cap.*) * elem > zoneTop()) {
        at.* = 0;
        cap.* = 0;
    }
    if (want < cap.*) return true;
    if (want >= limit) return false;
    var n: u32 = if (cap.* == 0) start else cap.*;
    while (n <= want) : (n *|= 2) {
        if (n >= limit) return false;
    }
    const fresh = zoneAlloc(@as(usize, n) * elem) orelse return false;
    if (cap.* > 0 and at.* != 0) {
        const old = @as([*]const u8, @ptrFromInt(at.*))[0 .. @as(usize, cap.*) * elem];
        @memcpy(@as([*]u8, @ptrFromInt(fresh))[0..old.len], old);
    }
    at.* = fresh;
    cap.* = n;
    return true;
}

fn growIndex(num: u32) bool {
    if (num < obj_cap) return true;
    if (num >= OBJ_IDX_LIMIT) return false;
    var want: u32 = if (obj_cap == 0) OBJ_IDX_START else obj_cap;
    while (want <= num) : (want *|= 2) {
        if (want >= OBJ_IDX_LIMIT) return false;
    }
    const off_at = zoneAlloc(@as(usize, want) * 4) orelse return false;
    const rk_at = zoneAlloc(want) orelse return false;
    const new_off = @as([*]u32, @ptrFromInt(off_at))[0..want];
    const new_rank = @as([*]u8, @ptrFromInt(rk_at))[0..want];
    @memset(new_rank, 0);
    if (obj_cap > 0) {
        @memcpy(new_off[0..obj_cap], objOff());
        @memcpy(new_rank[0..obj_cap], objRankTable());
    }
    obj_at = off_at;
    rank_at = rk_at;
    obj_cap = want;
    return true;
}

/// "N G obj" 를 뒤에서부터 읽는다. 숫자 시작 위치와 번호를 준다.
fn objHeadAt(b: []const u8, at: usize) ?struct { start: usize, num: u32 } {
    var j = at;
    while (j > 0 and isSpace(b[j - 1])) j -= 1;
    while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
    var k = j;
    while (k > 0 and isSpace(b[k - 1])) k -= 1;
    var s = k;
    while (s > 0 and b[s - 1] >= '0' and b[s - 1] <= '9') s -= 1;
    if (s >= k) return null;
    var p: usize = s;
    return .{ .start = s, .num = readUint(b, &p) };
}

// 얼마나 믿을 만한 자리인가.
//
// 압축된 스트림 안의 이진 바이트가 "8 0 obj" 처럼 보이는 일이 실제로 있다.
// 진짜 객체는 언제나 줄머리에서 시작하므로 그것을 먼저 본다.
fn objRank(b: []const u8, start: usize) u8 {
    const line_start = start == 0 or b[start - 1] == '\n' or b[start - 1] == '\r';
    const original = start < in_len;
    if (line_start) return if (original) 4 else 3;
    return if (original) 2 else 1;
}

fn buildObjIndex(b: []const u8) void {
    // 자리를 처음부터 다시 잡는다. 앞 문서 것이 남아 있으면 안 된다.
    obj_at = 0;
    rank_at = 0;
    obj_cap = 0;
    _ = growIndex(OBJ_IDX_START - 1);
    max_obj = 0;
    addObjIndex(b, 0);
}

/// 색인을 from 부터 이어 훑는다. 이미 만든 것을 지우지 않는다.
///
/// 가장 큰 객체 번호도 여기서 같이 센다. 예전에는 그것만 보려고 파일을
/// 한 번 더 훑었는데, 어차피 여기서 객체 머리를 다 읽으므로 덤이다.
fn addObjIndex(b: []const u8, from: usize) void {
    var i: usize = from;
    while (i + 4 < b.len) {
        const at = find(b, " obj", i) orelse break;
        if (objHeadAt(b, at)) |h| {
            if (h.num < obj_cap or growIndex(h.num)) {
                const rank = objRank(b, h.start);
                const rk = objRankTable();
                if (rk[h.num] <= rank) {
                    rk[h.num] = rank;
                    objOff()[h.num] = @intCast(at + 4);
                }
            }
            // 새로 만드는 객체는 이 뒤에 붙여야 트레일러의 /Size 안에 든다
            if (h.num > max_obj and h.num < 500000) max_obj = h.num;
        }
        i = at + 4;
    }
    obj_idx_len = b.len;
}

fn findObj(b: []const u8, num: u32) ?usize {
    // 본 버퍼는 색인으로 바로 찾는다. 병합용 두 번째 버퍼는 색인이 없다.
    if (obj_idx_len != 0 and b.len == obj_idx_len and
        b.ptr == @as([*]const u8, @ptrFromInt(heapBase())) and num < obj_cap)
    {
        if (objRankTable()[num] == 0) return null;
        return objOff()[num];
    }
    var best: ?usize = null;
    var best_rank: u8 = 0;
    var i: usize = 0;
    while (i + 4 < b.len) {
        const at = find(b, " obj", i) orelse break;
        if (objHeadAt(b, at)) |h| {
            if (h.num == num) {
                const rank = objRank(b, h.start);
                if (rank >= best_rank) { best_rank = rank; best = at + 4; }
            }
        }
        i = at + 4;
    }
    return best;
}

/// 객체 딕셔너리의 끝. stream 이 먼저 오면 거기까지다.
///
/// "stream" 을 그냥 앞에서부터 찾으면 그 객체에 스트림이 없을 때 다음 객체의
/// 것을 집어, 남의 /ShadingType·/PatternType 을 제 것으로 읽는다.
fn objDictEnd(b: []const u8, ob: usize) usize {
    const e1 = find(b, "endobj", ob) orelse b.len;
    const e2 = find(b, "stream", ob) orelse b.len;
    return @min(e1, e2);
}

/// 딕셔너리 안에서 /Key 뒤의 정수를 읽는다.
fn dictInt(b: []const u8, start: usize, end: usize, key: []const u8) ?u32 {
    const at = find(b[start..end], key, 0) orelse return null;
    var p = start + at + key.len;
    while (p < end and isSpace(b[p])) p += 1;
    if (p >= end or b[p] < '0' or b[p] > '9') return null;
    return readUint(b, &p);
}

/// 쪽을 담는 자리. 모자라면 늘린다.
///
/// 쪽 수는 걷어 봐야 안다. 객체 수로 미리 어림잡았더니, 같은 쪽을 여러 번
/// 가리키는 문서(/Kids 에 같은 객체가 500번)가 열여섯 쪽으로 잘렸다 — 쪽
/// 하나가 객체 하나라는 가정이 그런 문서에서는 깨진다. 지금 자리를 잡아 둔
/// 것이 이 표뿐이므로 뒤로 이어 붙이면 옮길 일 없이 늘어난다.
var walk_at: usize = 0;
var walk_cap: u32 = 0;
var walk_ceil: u32 = 0;

/// 걷어 담을 자리를 처음 잡는다. 천장은 파일 크기로 묶는다 — 고리처럼
/// 얽힌 쪽 트리를 만나도 훑는 양이 파일 크기를 넘지 않게 한다.
fn walkStart(total: usize) bool {
    walk_ceil = @intCast(@max(@as(usize, 64), @min(total / 4 + 64, 1 << 22)));
    walk_cap = 0;
    walk_at = zoneAlloc(256 * 4) orelse return false;
    walk_cap = 256;
    return true;
}

fn walkPush(n: *u32, obj: u32) bool {
    if (n.* >= walk_cap) {
        if (walk_cap >= walk_ceil) { pages_cut = true; return false; }
        // 두 배씩. 짝수로 잡아 다음 자리가 여덟 바이트에 맞게 둔다.
        var want: u32 = @min(walk_ceil, walk_cap * 2);
        want += want & 1;
        if (want <= walk_cap) { pages_cut = true; return false; }
        if (zoneAlloc(@as(usize, want - walk_cap) * 4) == null) { pages_cut = true; return false; }
        walk_cap = want;
    }
    u32sAt(walk_at, walk_cap)[n.*] = obj;
    n.* += 1;
    return true;
}

/// Kids 배열에서 "N 0 R" 들을 걷어 페이지 객체를 모은다. 중첩 트리도 따라간다.
fn collectPages(b: []const u8, obj: u32, depth: u32, n: *u32) void {
    if (depth > 16 or pages_cut) return;
    const body = findObj(b, obj) orelse return;
    // 객체 끝 = 다음 endobj
    const end = find(b, "endobj", body) orelse b.len;
    const is_page = find(b[body..end], "/Type", 0) != null and
        find(b[body..end], "/Page", 0) != null and
        find(b[body..end], "/Pages", 0) == null;
    if (is_page) {
        _ = walkPush(n, obj);
        return;
    }
    const kids_at = find(b[body..end], "/Kids", 0) orelse return;
    var p = body + kids_at + 5;
    while (p < end and b[p] != '[') p += 1;
    p += 1;
    while (p < end) {
        while (p < end and isSpace(b[p])) p += 1;
        if (p >= end or b[p] == ']') break;
        if (b[p] < '0' or b[p] > '9') { p += 1; continue; }
        const kid = readUint(b, &p);
        // "0 R" 을 건너뛴다
        _ = readUint(b, &p);
        while (p < end and isSpace(b[p])) p += 1;
        if (p < end and b[p] == 'R') p += 1;
        collectPages(b, kid, depth + 1, n);
    }
}

/// 문서를 읽고 페이지 목록을 세운다. 실패하면 0.
fn inputSlice2(len: usize) []u8 {
    return @as([*]u8, @ptrFromInt(heapBase()))[0..len];
}

/// 딕셔너리 구간에서 /Key 뒤 정수를 읽는다.
/// 스트림 길이를 읽는다.
///
/// `/Length 35 0 R` 처럼 딴 객체를 가리키는 꼴이 흔하다. 앞의 숫자만 읽으면
/// 35 바이트만 떼어 와 압축이 통째로 안 풀린다 — 쪽이 빈 채로 나온다.
fn lengthOf(b: []const u8, from: usize, to: usize) ?u32 {
    var at_from: usize = 0;
    while (find(b[from..to], "/Length", at_from)) |at| {
        var p = from + at + 7;
        const c = if (p < to) b[p] else ' ';
        // /Length1 같은 더 긴 이름에 걸리지 않게
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            at_from = at + 1;
            continue;
        }
        while (p < to and isSpace(b[p])) p += 1;
        if (p >= to or !isDigit(b[p])) return null;
        const first = readUint(b, &p);
        // 숫자 뒤에 세대와 R 이 오면 딴 객체를 가리키는 것이다
        var q = p;
        while (q < to and isSpace(b[q])) q += 1;
        if (q < to and isDigit(b[q])) {
            _ = readUint(b, &q);
            while (q < to and isSpace(b[q])) q += 1;
            if (q < to and b[q] == 'R') {
                const ob = findObj(b, first) orelse return null;
                var r = ob;
                while (r < b.len and isSpace(b[r])) r += 1;
                if (r < b.len and isDigit(b[r])) return readUint(b, &r);
                return null;
            }
        }
        return first;
    }
    return null;
}

/// 스트림이 실제로 끝나는 자리를 찾아 길이를 고친다.
///
/// /Length 가 틀린 문서가 흔하다(만든 프로그램이 헤아리다 틀리거나, 뒤에서
/// 손댄 뒤 안 고쳐 놓거나). 길이대로 잘랐는데 그 자리에 endstream 이 없으면
/// 믿지 않고 직접 찾는다.
fn fixStreamLen(b: []const u8, data: usize, length: u32) u32 {
    // wasm32 에서 usize 는 32비트다. /Length 가 4294967295 인 문서를 만나면
    // data + length 가 넘쳐 도로 작은 값이 되고, 그 뒤 검사가 통째로 뚫린다.
    // 넘치면 붙잡아 두는 덧셈을 쓴다.
    const at = data +| @as(usize, length);
    if (at <= b.len) {
        var q = at;
        var slack: u32 = 0;
        while (q < b.len and slack < 8 and isSpace(b[q])) : (slack += 1) q += 1;
        if (q + 9 <= b.len and std_mem_eq(b[q .. q + 9], "endstream")) return length;
    }
    const e = find(b, "endstream", data) orelse return length;
    var q2 = e;
    // 앞의 줄바꿈은 자료가 아니다
    if (q2 > data and b[q2 - 1] == '\n') q2 -= 1;
    if (q2 > data and b[q2 - 1] == '\r') q2 -= 1;
    if (q2 <= data) return length;
    return @intCast(q2 - data);
}

fn intAfter(b: []const u8, from: usize, to: usize, key: []const u8) ?u32 {
    // 이름은 그 자리에서 끝나야 한다. "/Length1 26340 /Length 4017" 처럼
    // 더 긴 이름이 앞에 오면 "/Length" 가 먼저 걸려 1 을 길이로 읽어 버린다.
    // 글꼴 스트림이 다 그 꼴이라 안 풀리던 원인이었다.
    var at_from: usize = 0;
    while (find(b[from..to], key, at_from)) |at| {
        var p = from + at + key.len;
        const c = if (p < to) b[p] else ' ';
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            at_from = at + 1;
            continue;
        }
        while (p < to and isSpace(b[p])) p += 1;
        if (p >= to or b[p] < '0' or b[p] > '9') return null;
        return readUint(b, &p);
    }
    return null;
}

/// 객체 스트림을 풀어 평문 객체로 펼친다.
///
/// PDF 1.5 부터는 Catalog·Pages 같은 작은 객체들을 ObjStm 안에 압축해 넣는다.
/// 그러면 파일을 아무리 뒤져도 "/Type /Pages" 가 보이지 않는다. 미리 풀어 원본
/// 뒤에 이어 두면 이후 로직은 평문 PDF 를 다루듯 그대로 동작한다.
fn expandObjectStreams() void {
    exp_len = 0;
    const b = @as([*]u8, @ptrFromInt(heapBase()))[0..in_len];
    var scan: usize = 0;
    while (scan < in_len) {
        const at = find(b, "/ObjStm", scan) orelse break;
        scan = at + 7;
        var ds = at;
        while (ds > 0 and !(b[ds] == 'o' and ds + 3 <= in_len and std_mem_eq(b[ds .. ds + 3], "obj"))) ds -= 1;
        const sp = find(b, "stream", at) orelse continue;
        const n_obj = intAfter(b, ds, sp, "/N") orelse continue;
        const first = intAfter(b, ds, sp, "/First") orelse continue;
        const raw_len = lengthOf(b, ds, sp) orelse 0;
        var data = sp + 6;
        if (data < in_len and b[data] == '\r') data += 1;
        if (data < in_len and b[data] == '\n') data += 1;
        const length = fixStreamLen(b, data, raw_len);
        if (data + length > in_len) continue;

        // 임시로 뒤쪽에 풀고, 앞쪽에 객체 형태로 다시 적는다.
        if (exp_len + 1024 >= exp_cap) return;
        const tmp_off = exp_len + (exp_cap - exp_len) / 2;
        const room = exp_cap - tmp_off;
        const got = pw_inflate(b[data..].ptr, @intCast(length), expBuf() + tmp_off, @intCast(room));
        if (got <= 0) continue;
        const dec = expBuf()[tmp_off .. tmp_off + @as(usize, @intCast(got))];

        var write = exp_len;
        var hp: usize = 0;
        var k: u32 = 0;
        while (k < n_obj) : (k += 1) {
            const num = readUint(dec, &hp);
            const off = readUint(dec, &hp);
            var hp2 = hp;
            var end_off: usize = dec.len - first;
            if (k + 1 < n_obj) {
                _ = readUint(dec, &hp2);
                end_off = readUint(dec, &hp2);
            }
            const s0 = first + off;
            const s1 = @min(first + end_off, dec.len);
            if (s1 <= s0 or s0 >= dec.len) continue;
            if (write + (s1 - s0) + 32 >= tmp_off) return;
            var w = write;
            var tmp: [12]u8 = undefined;
            var tn: usize = 0;
            var x = num;
            if (x == 0) { tmp[0] = '0'; tn = 1; }
            while (x > 0) : (x /= 10) { tmp[tn] = @intCast('0' + (x % 10)); tn += 1; }
            var t: usize = 0;
            while (t < tn) : (t += 1) { expBuf()[w] = tmp[tn - 1 - t]; w += 1; }
            @memcpy(expBuf()[w..][0..7], " 0 obj ");
            w += 7;
            @memcpy(expBuf()[w..][0 .. s1 - s0], dec[s0..s1]);
            w += s1 - s0;
            @memcpy(expBuf()[w..][0..8], "\nendobj\n");
            w += 8;
            write = w;
        }
        exp_len = write;
    }
}

export fn parse(len: usize) u32 {
    in_len = len;
    obj_idx_len = 0;
    page_count = 0;
    pages_obj = 0;
    if (len < 8) return 0;
    // 색인도 쪽 표도 이 자리를 쓴다. 문서를 새로 열 때 한 번만 비운다.
    zoneReset();
    // 자리잡개를 비웠으니 거기서 떼어 쓰던 것들도 다시 잡아야 한다.
    // 안 그러면 앞 문서가 쓰던 자리를 가리킨 채 새 문서의 색인이 그 위에 얹힌다.
    img_off = 0;
    font_off = 0;
    inl_off = 0;
    sub_off = 0;
    t1_off = 0;
    mask_at = 0;
    mask_used = 0;
    att_at = 0;
    {
        const head = inputSlice2(len);
        if (!std_mem_eq(head[0..5], "%PDF-")) return 0;
    }
    {
        // 먼저 원본만으로 색인을 만들어 /Encrypt 를 찾는다
        const raw = inputSlice2(len);
        buildObjIndex(raw);
        setupEncryption(raw);
        // 서명은 원본 바이트 자리를 가리킨다. 스트림을 풀기 전에 걷어 둔다.
        collectSigs(raw);
        if (enc_on) decryptAllStreams(raw);
    }
    expandObjectStreams();
    layoutScratch();
    const b = searchSlice();
    // 원본 쪽 색인은 방금 만든 것 그대로다. 암호가 걸려 스트림을 그 자리에서
    // 푼 경우에만 바이트가 달라졌으므로 그때만 처음부터 다시 만든다.
    if (enc_on) buildObjIndex(b) else addObjIndex(b, in_len);
    const total = b.len;

    // trailer 나 Catalog 에서 /Root 를 찾는다
    var root: u32 = 0;
    if (trailerKeyOrScan(b[0..total], "/Root")) |at| {
        var p = at + 5;
        root = readUint(b, &p);
    }
    doc_root = root;
    if (root != 0) {
        if (findObj(b, root)) |body| {
            const end = find(b, "endobj", body) orelse total;
            if (dictInt(b, body, end, "/Pages")) |pg| pages_obj = pg;
        }
    }
    // /Root 로 못 찾으면 /Type /Pages 를 직접 뒤진다
    if (pages_obj == 0) {
        if (find(b, "/Type /Pages", 0) orelse find(b, "/Type/Pages", 0)) |at| {
            var j = at;
            while (j > 0 and !(b[j] == 'o' and j + 3 < total and std_mem_eq(b[j .. j + 3], "obj"))) j -= 1;
            var s = j;
            while (s > 0 and isSpace(b[s - 1])) s -= 1;
            while (s > 0 and b[s - 1] >= '0' and b[s - 1] <= '9') s -= 1;
            var k = s;
            while (k > 0 and isSpace(b[k - 1])) k -= 1;
            var t = k;
            while (t > 0 and b[t - 1] >= '0' and b[t - 1] <= '9') t -= 1;
            var p: usize = t;
            pages_obj = readUint(b, &p);
        }
    }
    // 꺼 놓은 레이어 (/OCProperties /D /OFF)
    ocg_off_n = 0;
    oc_n = 0;
    oc_used = 0;
    if (root != 0) {
        if (findObj(b, root)) |rb2| {
            const re2 = objDictEnd(b, rb2);
            if (find(b[rb2..re2], "/OCProperties", 0)) |oa| {
                var op2 = rb2 + oa + 13;
                var os2 = op2;
                var oe2 = re2;
                while (op2 < re2 and isSpace(b[op2])) op2 += 1;
                if (op2 < re2 and b[op2] == '<') { os2 = op2; oe2 = dictEnd(b, op2, re2); }
                else if (op2 < re2 and isDigit(b[op2])) {
                    const on7 = readUint(b, &op2);
                    if (findObj(b, on7)) |ob7| { os2 = ob7; oe2 = objDictEnd(b, ob7); }
                }
                // 레이어 목록 — 화면이 켜고 끌 수 있게 이름과 번호를 걷는다
                if (find(b[os2..oe2], "/OCGs", 0)) |ga| {
                    var q = os2 + ga + 5;
                    while (q < oe2 and b[q] != '[') q += 1;
                    q += 1;
                    while (q < oe2 and b[q] != ']' and ocRoom(oc_n + 1)) {
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q >= oe2 or b[q] == ']') break;
                        if (!isDigit(b[q])) { q += 1; continue; }
                        const num8 = readUint(b, &q);
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q < oe2 and isDigit(b[q])) _ = readUint(b, &q);
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q < oe2 and b[q] == 'R') q += 1;
                        // 이름은 그 객체의 /Name 에 있다
                        var noff: u32 = oc_used;
                        var nlen: u32 = 0;
                        if (findObj(b, num8)) |gb| {
                            const ge = objDictEnd(b, gb);
                            if (find(b[gb..ge], "/Name", 0)) |na| {
                                _ = oc_bufRoom(oc_used + 4096);
                                const r2 = sigPutStrTo(b, gb + na + 5, ge, oc_buf(), &oc_used);
                                noff = r2[0];
                                nlen = r2[1];
                            }
                        }
                        oc_objBuf()[oc_n] = num8;
                        oc_name_offBuf()[oc_n] = noff;
                        oc_name_lenBuf()[oc_n] = nlen;
                        oc_onBuf()[oc_n] = true;
                        oc_n += 1;
                    }
                }
                if (find(b[os2..oe2], "/OFF", 0)) |fa2| {
                    var q = os2 + fa2 + 4;
                    while (q < oe2 and b[q] != '[') q += 1;
                    q += 1;
                    while (q < oe2 and b[q] != ']' and ocg_off_listRoom(ocg_off_n + 1)) {
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q >= oe2 or b[q] == ']') break;
                        if (!isDigit(b[q])) { q += 1; continue; }
                        const off8 = readUint(b, &q);
                        ocg_off_listBuf()[ocg_off_n] = off8;
                        ocg_off_n += 1;
                        var k8: u32 = 0;
                        while (k8 < oc_n) : (k8 += 1) if (oc_objBuf()[k8] == off8) { oc_onBuf()[k8] = false; };
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q < oe2 and isDigit(b[q])) _ = readUint(b, &q);
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q < oe2 and b[q] == 'R') q += 1;
                    }
                }
            }
        }
    }
    // 문서가 어떤 미리 정의된 CMap 을 쓰는지 알아 둔다. 표는 PDF 안에
    // 없으니, 화면 쪽이 이 목록을 보고 받아서 넣어 준 뒤 페이지를 그린다.
    collectNeeds(b);
    collectAttach(b);
    checkXfa(b);
    if (pages_obj == 0) return 0;

    // 쪽 표 자리를 잡는다.
    //
    // 쪽 수는 걷어 봐야 알지만 쪽 하나는 반드시 객체 하나이므로, 문서에서
    // 본 가장 큰 객체 번호가 상한이 된다. 파일 크기로도 한 번 더 묶는다 —
    // 고리처럼 얽힌 쪽 트리를 만나도 훑는 양이 파일 크기를 넘지 않게 한다.
    // 넉넉히 잡아 채운 뒤 실제로 쓴 만큼으로 줄인다.
    pages_cut = false;
    if (!walkStart(total)) return 0;
    page_count = 0;
    collectPages(b, pages_obj, 0, &page_count);
    // 쓴 만큼만 남기고 나머지 표를 그 뒤에 잇는다
    pg_at = walk_at;
    pg_cap = page_count;
    zoneShrink(pg_at + @as(usize, page_count) * 4);
    {
        // 고른 쪽은 같은 쪽을 두 번 넣을 수도 있어 넉넉히 잡는다
        pick_cap = page_count * 2 + 64;
        pick_at = zoneAlloc(@as(usize, pick_cap) * 4) orelse return 0;
        pick_n = 0;
        rot_at = zoneAlloc(@as(usize, page_count) * 2 + 2) orelse return 0;
        rot_cap = page_count;
        clearPageRotate();
        lbl_off_at = zoneAlloc(@as(usize, page_count) * 4 + 4) orelse return 0;
        lbl_len_at = zoneAlloc(@as(usize, page_count) + 4) orelse return 0;
        // 0 으로 채운다. 예전에는 .bss 라 저절로 0 이었지만 지금은 앞 문서가
        // 쓰던 자리를 물려받는다 — 라벨이 안 붙은 쪽에서 남의 자리·길이를
        // 읽어 엉뚱한 글자를 내놓거나 아예 열다 죽었다.
        @memset(u32sAt(lbl_off_at, page_count + 1), 0);
        @memset(@as([*]u8, @ptrFromInt(lbl_len_at))[0 .. page_count + 4], 0);
        lbl_buf_cap = @max(@as(usize, 1024), @as(usize, page_count) * 16);
        lbl_buf_at = zoneAlloc(lbl_buf_cap) orelse return 0;
        label_n = 0;
    }
    if (root != 0) collectOutline(b, root);
    collectInfo(b);
    collectMeta(b);
    collectDests(b);
    collectOpenAction(b); // 이름 붙은 자리를 찾으려면 dests 뒤여야 한다
    collectViewPrefs(b);
    collectXmp(b);
    collectStruct(b);
    collectLabels(b);
    return if (page_count > 0) 1 else 0;
}

export fn clearPick() void { pick_n = 0; }
export fn addPick(i: u32) void {
    if (pick_n < pick_cap and i < page_count) { pick()[pick_n] = i; pick_n += 1; }
}
export fn setRotate(deg: i32) void { rotate = deg; }

/// 쪽마다 따로 돌리기. -1 은 "정하지 않음" 이라 전체 회전을 따른다.
var rot_at: usize = 0;
var rot_cap: u32 = 0;
fn rot_each() []i16 {
    if (rot_at == 0 or rot_cap == 0) return &[_]i16{};
    return @as([*]i16, @ptrFromInt(rot_at))[0..rot_cap];
}
export fn clearPageRotate() void {
    for (rot_each()) |*r| r.* = -1;
}
export fn setPageRotate(page: u32, deg: i32) void {
    if (page >= rot_cap) return;
    const d = @mod(deg, 360);
    rot_each()[page] = @intCast(if (d < 0) d + 360 else d);
}
fn rotOf(page: u32) i32 {
    if (page < rot_cap and rot_each()[page] >= 0) return rot_each()[page];
    return rotate;
}
fn anyPageRotate() bool {
    for (rot_each()) |r| if (r >= 0) return true;
    return false;
}

fn outBuf() [*]u8 { return @ptrFromInt(out_off); }

/// 출력 자리가 남았나. 넘겨 쓰면 wasm 이 통째로 죽는다 — 입력 칸을 천 개
/// 채우면 실제로 그랬다.
/// 출력에 그대로 옮겨 적는다. 자리가 모자라면 안 적고 false.
fn outCopy(pos: *usize, src: []const u8) bool {
    if (!outRoom(pos.*, src.len)) return false;
    @memcpy(outBuf()[pos.*..][0..src.len], src);
    pos.* += src.len;
    return true;
}

fn outRoom(pos: usize, need: usize) bool {
    return pos + need + 64 <= out_cap;
}

fn appendStr(pos: *usize, s: []const u8) void {
    if (!outRoom(pos.*, s.len)) return;
    @memcpy(outBuf()[pos.*..][0..s.len], s);
    pos.* += s.len;
}
fn appendNum(pos: *usize, v: u32) void {
    if (!outRoom(pos.*, 12)) return;
    var tmp: [12]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) { tmp[0] = '0'; n = 1; }
    while (x > 0) : (x /= 10) { tmp[n] = @intCast('0' + (x % 10)); n += 1; }
    var i: usize = 0;
    while (i < n) : (i += 1) outBuf()[pos.* + i] = tmp[n - 1 - i];
    pos.* += n;
}

/// 유니코드 하나를 이 글꼴 안의 코드로 되찾는다.
fn wmCode(f: *const FontMap, uni: u32) ?u32 {
    var i: u16 = 0;
    while (i < f.n) : (i += 1) if (u16buf(f.unis_at, f.unis_cap)[i] == uni) return u16buf(f.codes_at, f.codes_cap)[i];
    return null;
}

/// 숫자를 적고 쓴 자릿수를 준다.
fn putNum(dst: []u8, v: u32) usize {
    var tmp: [12]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) { tmp[0] = '0'; n = 1; }
    while (x > 0) : (x /= 10) { tmp[n] = @intCast('0' + (x % 10)); n += 1; }
    var i: usize = 0;
    while (i < n and i < dst.len) : (i += 1) dst[i] = tmp[n - 1 - i];
    return n;
}

/// 0~1 을 0.00 꼴로 적는다. 색은 정수로 못 적는다.
fn putFrac(dst: []u8, v: f32) usize {
    const c: u32 = @intFromFloat(@max(0, @min(1, v)) * 100 + 0.5);
    const n = putNum(dst, c / 100);
    if (n + 3 > dst.len) return n;
    dst[n] = '.';
    dst[n + 1] = '0' + @as(u8, @intCast((c / 10) % 10));
    dst[n + 2] = '0' + @as(u8, @intCast(c % 10));
    return n + 3;
}

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
var labs_at: usize = 0;
var labs_cap: u32 = 0;
fn labs() []LabelT {
    if (labs_at == 0 or labs_cap == 0) return &[_]LabelT{};
    return @as([*]LabelT, @ptrFromInt(labs_at))[0..labs_cap];
}
var lab_n: u32 = 0;
var lab_cp: [4096]u32 = undefined;
var lab_cn: u32 = 0;
var lab_body: [16384]u8 = undefined;

export fn clearLabels() void { lab_n = 0; lab_cn = 0; }
export fn addLabel(page: u32, x: f32, y: f32, size: f32, r: f32, g: f32, bb: f32) u32 {
    if (!growTable(&labs_at, &labs_cap, lab_n, @sizeOf(LabelT), 32)) return 0;
    labs()[lab_n] = .{
        .page = page, .x = x, .y = y, .size = size,
        .col = .{ r, g, bb }, .off = @intCast(lab_cn), .n = 0,
    };
    lab_n += 1;
    return 1;
}
/// 방금 만든 라벨에 화면 글꼴로 그린 그림을 붙인다.
export fn setLabelMask(w: u32, h: u32, len: u32, pw: f32, ph: f32) u32 {
    if (lab_n == 0) return 0;
    const at = maskAlloc(len, w, h) orelse return 0;
    const L = &labs()[lab_n - 1];
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
var wm_mlen: u32 = 0;
var wm_mobj: u32 = 0;
var wm_pw: f32 = 0;
var wm_ph: f32 = 0;
export fn setWatermarkMask(w: u32, h: u32, len: u32, pw: f32, ph: f32) u32 {
    const at = maskAlloc(len, w, h) orelse return 0;
    wm_mw = w;
    wm_mh = h;
    wm_moff = at;
    wm_mlen = len;
    wm_pw = @max(1, pw);
    wm_ph = @max(1, ph);
    return 1;
}

/// 방금 만든 라벨에 글자 하나를 잇는다.
export fn addLabelChar(c: u32) void {
    if (lab_n == 0 or lab_cn >= lab_cp.len) return;
    lab_cp[lab_cn] = c;
    lab_cn += 1;
    labs()[lab_n - 1].n += 1;
}

fn pageHasLabels(page: u32) bool {
    var i: u32 = 0;
    while (i < lab_n) : (i += 1) if (labs()[i].page == page and labs()[i].n > 0) return true;
    return false;
}

/// 한 쪽의 라벨을 그리는 콘텐츠 스트림을 짓는다.
///
/// 이 쪽의 글꼴이 fontsBuf()[] 에 채워져 있어야 하므로 renderPage 를 먼저 부른다.
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
        const L = labs()[li];
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
            bl += putFrac(dst[bl..], L.col[0]);
            put0(dst, &bl, " ");
            bl += putFrac(dst[bl..], L.col[1]);
            put0(dst, &bl, " ");
            bl += putFrac(dst[bl..], L.col[2]);
            put0(dst, &bl, " rg ");
            bl += putNum(dst[bl..], @intFromFloat(@max(1, L.pw)));
            put0(dst, &bl, " 0 0 ");
            bl += putNum(dst[bl..], @intFromFloat(@max(1, L.ph)));
            put0(dst, &bl, " ");
            bl += putNum(dst[bl..], @intFromFloat(@max(0, L.x)));
            put0(dst, &bl, " ");
            bl += putNum(dst[bl..], @intFromFloat(@max(0, L.y)));
            put0(dst, &bl, " cm /PdLb");
            bl += putNum(dst[bl..], li);
            put0(dst, &bl, " Do Q\n");
            continue;
        }
        // 이 글자들을 다 가진 문서 글꼴을 찾는다
        var use_doc = false;
        var doc_font: u8 = 0;
        var fi: u8 = 0;
        outer: while (fi < font_n) : (fi += 1) {
            if (fontsBuf()[fi].n == 0 or fontsBuf()[fi].name_len == 0) continue;
            var ci: u32 = 0;
            while (ci < L.n) : (ci += 1) {
                if (wmCode(&fontsBuf()[fi], lab_cp[L.off + ci]) == null) continue :outer;
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
        bl += putFrac(dst[bl..], L.col[0]);
        put(dst, &bl, " ");
        bl += putFrac(dst[bl..], L.col[1]);
        put(dst, &bl, " ");
        bl += putFrac(dst[bl..], L.col[2]);
        put(dst, &bl, " rg BT /");
        if (use_doc) {
            const nm = fontsBuf()[doc_font].name[0..fontsBuf()[doc_font].name_len];
            put(dst, &bl, nm);
        } else {
            put(dst, &bl, "WMF");
        }
        put(dst, &bl, " ");
        bl += putNum(dst[bl..], @intFromFloat(@max(1, @min(999, L.size))));
        put(dst, &bl, " Tf 1 0 0 1 ");
        bl += putNum(dst[bl..], @intFromFloat(@max(0, L.x)));
        put(dst, &bl, " ");
        bl += putNum(dst[bl..], @intFromFloat(@max(0, L.y)));
        put(dst, &bl, " Tm ");

        if (use_doc) {
            const two = fontsBuf()[doc_font].two_byte;
            put(dst, &bl, "<");
            var ci: u32 = 0;
            while (ci < L.n and bl + 8 < dst.len) : (ci += 1) {
                const code = wmCode(&fontsBuf()[doc_font], lab_cp[L.off + ci]) orelse 0;
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
fn keyIs(b: []const u8, p: usize, end: usize, key: []const u8) bool {
    if (p + key.len > end) return false;
    if (!std_mem_eq(b[p..][0..key.len], key)) return false;
    const c = b[p + key.len];
    // 숫자를 구분자로 보면 /Length1 이 /Length 로 잡힌다 — 글꼴 스트림이
    // 통째로 망가진다. 이름과 숫자 사이에는 규격상 공백이 있어야 한다.
    return isSpace(c) or c == '/' or c == '(' or c == '<' or c == '[' or c == '>';
}

/// 값 하나를 건너뛴다 — 이름·수·문자열·배열·딕셔너리·참조를 다 받는다.
fn skipVal(b: []const u8, from: usize, end: usize) usize {
    var p = from;
    while (p < end and isSpace(b[p])) p += 1;
    if (p >= end) return end;
    if (b[p] == '/') {
        p += 1;
        while (p < end and !isSpace(b[p]) and b[p] != '/' and b[p] != '>' and
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
    if (p + 1 < end and b[p] == '<' and b[p + 1] == '<') return dictEnd(b, p, end);
    if (b[p] == '<') {
        while (p < end and b[p] != '>') p += 1;
        return @min(p + 1, end);
    }
    if (b[p] == '[') return arrayEnd(b, p, end);
    if (isDigit(b[p]) or b[p] == '-' or b[p] == '.') {
        _ = readFloat(b, &p);
        // 참조인가 — "n g R"
        var q = p;
        while (q < end and isSpace(b[q])) q += 1;
        if (q < end and isDigit(b[q])) {
            const save = q;
            _ = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and b[q] == 'R') return q + 1;
            q = save;
        }
        return p;
    }
    // true·false·null
    while (p < end and !isSpace(b[p]) and b[p] != '/' and b[p] != '>') p += 1;
    return p;
}

/// 콘텐츠 스트림 하나를 출력에 적고 xref 목록에 올린다.
/// 새로 적은 객체의 자리·번호를 담을 표를 잡는다.
///
/// 예전에는 [4098]·[8192] 같은 고정 배열이었다. 4098 은 쪽이 [4096] 이던
/// 시절의 숫자인데, 쪽 상한을 없애면서 이 둘만 남았다 — 4100 쪽짜리를
/// 돌려 내면 표 밖으로 넘겨 써서 상호참조표에 엉뚱한 번호가 박혔다
/// (6000 쪽이면 3806 개). 이제 담을 만큼 잡는다.
fn xrefTables(want: usize) ?struct { offs: []usize, nums: []u32 } {
    const cap = @max(@as(usize, 64), @min(want, 1 << 20));
    const off_at = zoneAlloc(cap * @sizeOf(usize)) orelse return null;
    const num_at = zoneAlloc(cap * 4) orelse return null;
    return .{
        .offs = @as([*]usize, @ptrFromInt(off_at))[0..cap],
        .nums = @as([*]u32, @ptrFromInt(num_at))[0..cap],
    };
}

fn writeStream(pos: *usize, offs: []usize, nums: []u32, n: *usize,
    obj: u32, body: []const u8) void
{
    if (n.* >= nums.len or !outRoom(pos.*, body.len + 128)) return;
    offs[n.*] = pos.*;
    nums[n.*] = obj;
    n.* += 1;
    appendNum(pos, obj);
    appendStr(pos, " 0 obj\n<< /Length ");
    appendNum(pos, @intCast(body.len));
    appendStr(pos, " >>\nstream\n");
    @memcpy(outBuf()[pos.*..][0..body.len], body);
    pos.* += body.len;
    appendStr(pos, "\nendstream\nendobj\n");
}

/// 결과 파일에서 /Encrypt 참조를 지운다.
///
/// 우리는 스트림을 이미 풀어 두고 원본 바이트를 그대로 옮기므로, 트레일러에
/// /Encrypt 가 남아 있으면 읽는 쪽이 한 번 더 풀려다 내용을 망친다.
fn stripEncryptOut(len: usize) void {
    if (!enc_on) return;
    const o = outBuf();
    var i: usize = 0;
    while (i + 8 < len) : (i += 1) {
        if (o[i] != '/') continue;
        if (!std_mem_eq(o[i .. i + 8], "/Encrypt")) continue;
        var j = i + 8;
        // "N G R" 까지 지운다
        while (j < len and (isSpace(o[j]) or isDigit(o[j]) or o[j] == 'R')) j += 1;
        var k = i;
        while (k < j) : (k += 1) o[k] = ' ';
        i = j;
    }
}

/// 고른 페이지만 남긴 PDF 를 만든다. 증분 업데이트로 덧붙인다.


export fn apply() usize {
    out_len = 0;
    if (pick_n == 0 or pages_obj == 0) return 0;
    // 페이지 객체가 ObjStm 안에 있을 수 있으므로 펼친 영역까지 훑는다.
    // 출력에 옮기는 원본은 in_len 까지다.
    const b = searchSlice();

    // 원본을 그대로 옮긴다 (펼친 영역은 우리가 만든 것이라 옮기지 않는다)
    if (!outRoom(0, in_len)) return 0;
    @memcpy(outBuf()[0..in_len], b[0..in_len]);
    var pos: usize = in_len;
    if (pos > 0 and outBuf()[pos - 1] != '\n') { outBuf()[pos] = '\n'; pos += 1; }

    // 새로 쓸 객체: Pages 하나 + (회전이면) 고른 페이지들
    // 쪽마다 하나씩, 라벨·주석·칸까지 더해 잡는다. 다 쓰면 되돌린다.
    const xr_keep = zoneTop();
    defer zoneShrink(xr_keep);
    // 하나가 객체 여럿을 낳는다 — 주석은 겉모습 스트림까지 둘, 새 칸도
    // 마찬가지다. 넉넉히 잡지 않으면 뒤가 조용히 빠진다(주석 2000개 중
    // 1038개만 나갔다).
    const xr = xrefTables(pick_n * 4 + @as(usize, edit_n) * 2 + note_n * 3 + newf_n * 3 + 128) orelse return 0;
    const new_offsets = xr.offs;
    const new_nums = xr.nums;
    var new_n: usize = 0;

    // 1) Pages 객체 — Kids 를 고른 순서로
    new_offsets[new_n] = pos;
    new_nums[new_n] = pages_obj;
    new_n += 1;
    appendNum(&pos, pages_obj);
    appendStr(&pos, " 0 obj\n<< /Type /Pages /Count ");
    appendNum(&pos, @intCast(pick_n));
    appendStr(&pos, " /Kids [");
    var i: usize = 0;
    while (i < pick_n) : (i += 1) {
        appendStr(&pos, " ");
        appendNum(&pos, page_objs()[pick()[i]]);
        appendStr(&pos, " 0 R");
    }
    appendStr(&pos, " ] >>\nendobj\n");

    // 2) 쪽 위에 얹을 것 — 워터마크와 라벨. 둘 다 같은 길을 탄다.
    const overlay = wm_n > 0 or lab_n > 0;
    const has_notes = note_n > 0;
    var wm_pre: u32 = 0;
    var wm_content: u32 = 0;
    var wm_font: u32 = 0;
    var wm_res_base: u32 = 0;
    var wm_res_n: u32 = 0;
    var lab_base: u32 = 0;
    var lab_used: u32 = 0;
    if (overlay) {
        wm_pre = max_obj + 1;
        wm_content = max_obj + 2;
        wm_font = max_obj + 3;
        wm_res_base = max_obj + 4;
        // 리소스 객체가 쪽마다 하나씩 나가므로 그 뒤부터 라벨 스트림을 준다
        lab_base = max_obj + 4 + @as(u32, @intCast(pick_n));

        // 글꼴 — 표준 14 종이라 파일에 심지 않아도 된다
        new_offsets[new_n] = pos;
        new_nums[new_n] = wm_font;
        new_n += 1;
        appendNum(&pos, wm_font);
        appendStr(&pos, " 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

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
    var mask_next = max_obj + 4 + 2 * @as(u32, @intCast(pick_n)) + 1;
    var any_mask = false;
    if (overlay) {
        const writeMask = struct {
            fn f(num: u32, w: u32, h: u32, off: u32, len: u32,
                offs: []usize, nums: []u32, n: *usize, pp: *usize) void
            {
                if (n.* >= nums.len or !outRoom(pp.*, len + 512)) return;
                offs[n.*] = pp.*;
                nums[n.*] = num;
                n.* += 1;
                appendNum(pp, num);
                appendStr(pp, " 0 obj\n<< /Type /XObject /Subtype /Image /Width ");
                appendNum(pp, w);
                appendStr(pp, " /Height ");
                appendNum(pp, h);
                appendStr(pp, " /ImageMask true /BitsPerComponent 1 /Decode [0 1] /Length ");
                appendNum(pp, len);
                appendStr(pp, " >>\nstream\n");
                if (!outRoom(pp.*, len)) return;
                @memcpy(outBuf()[pp.*..][0..len], maskBuf()[off..][0..len]);
                pp.* += len;
                appendStr(pp, "\nendstream\nendobj\n");
            }
        }.f;
        var mi: u32 = 0;
        while (mi < lab_n) : (mi += 1) {
            if (labs()[mi].mlen == 0) continue;
            labs()[mi].mobj = mask_next;
            mask_next += 1;
            any_mask = true;
            writeMask(labs()[mi].mobj, labs()[mi].mw, labs()[mi].mh, labs()[mi].moff, labs()[mi].mlen,
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
    if (wm_n > 0) {
        // 문서에 박힌 글꼴 중 이 글자들을 다 가진 것을 찾는다.
        // 한글 워터마크는 그래야 나온다 — 표준 14종에는 한글이 없다.
        var use_doc = false;
        var doc_font: u8 = 0;
        if (!wmIsAscii()) {
            _ = renderPage(pick()[0]);
            var fi: u8 = 0;
            outer: while (fi < font_n) : (fi += 1) {
                if (fontsBuf()[fi].n == 0 or fontsBuf()[fi].name_len == 0) continue;
                var ci: usize = 0;
                while (ci < wm_n) : (ci += 1) {
                    if (wmCode(&fontsBuf()[fi], wm_cp[ci]) == null) continue :outer;
                }
                use_doc = true;
                doc_font = fi;
                break;
            }
        } else {
            _ = renderPage(pick()[0]);
        }

        // 쪽 한가운데에 비스듬히, 쪽 크기에 맞춰 얹는다
        const pw2 = if (page_w > 1) page_w else 612;
        const ph2 = if (page_h > 1) page_h else 792;
        const nch: f32 = @floatFromInt(@max(wm_n, 1));
        const kw: f32 = if (use_doc and fontsBuf()[doc_font].two_byte) 1.0 else 0.55;
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
            bl += putNum(body[bl..], @intFromFloat(@max(0, ix2)));
            putw(&body, &bl, " ");
            bl += putNum(body[bl..], @intFromFloat(@max(0, iy2)));
            putw(&body, &bl, " cm ");
            bl += putNum(body[bl..], @intFromFloat(@max(1, iw2)));
            putw(&body, &bl, " 0 0 ");
            bl += putNum(body[bl..], @intFromFloat(@max(1, ih2)));
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
            const nm = fontsBuf()[doc_font].name[0..fontsBuf()[doc_font].name_len];
            @memcpy(body[bl..][0..nm.len], nm);
            bl += nm.len;
        } else {
            @memcpy(body[bl..][0..3], "WMF");
            bl += 3;
        }
        body[bl] = ' ';
        bl += 1;
        bl += putNum(body[bl..], @intFromFloat(fsize));
        const mid = " Tf 0.866 0.5 -0.5 0.866 ";
        @memcpy(body[bl..][0..mid.len], mid);
        bl += mid.len;
        bl += putNum(body[bl..], @intFromFloat(@max(tx, 0)));
        body[bl] = ' ';
        bl += 1;
        bl += putNum(body[bl..], @intFromFloat(@max(ty, 0)));
        const mid2 = " Tm ";
        @memcpy(body[bl..][0..mid2.len], mid2);
        bl += mid2.len;
        if (use_doc) {
            // 글꼴 안의 코드로 적는다
            body[bl] = '<';
            bl += 1;
            const two = fontsBuf()[doc_font].two_byte;
            var ci: usize = 0;
            while (ci < wm_n and bl + 8 < body.len) : (ci += 1) {
                const code = wmCode(&fontsBuf()[doc_font], wm_cp[ci]) orelse 0;
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
            @memcpy(body[bl..][0..wm_len], wm[0..wm_len]);
            bl += wm_len;
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
        while (ni < note_n and new_n + 3 < new_nums.len and outRoom(pos, 8192)) : (ni += 1) {
            const t = &notes()[ni];
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
                    at.* += putNum(d[at.*..], @intFromFloat(@max(0, @min(100000, v))));
                }
            }.f;
            const col3 = struct {
                fn f(d: []u8, at: *usize, c: [3]f32) void {
                    at.* += putFrac(d[at.*..], c[0]);
                    d[at.*] = ' ';
                    at.* += 1;
                    at.* += putFrac(d[at.*..], c[1]);
                    d[at.*] = ' ';
                    at.* += 1;
                    at.* += putFrac(d[at.*..], c[2]);
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
                            at.* += putNum(d[at.*..], @intFromFloat(@max(0, x)));
                            d[at.*] = ' ';
                            at.* += 1;
                            at.* += putNum(d[at.*..], @intFromFloat(@max(0, y)));
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
                        const px = note_pts[t.off + k2 * 2] - t.rect[0];
                        const py = note_pts[t.off + k2 * 2 + 1] - t.rect[1];
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
            appendNum(&pos, ap);
            appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 ");
            appendNum(&pos, @intFromFloat(@max(1, w)));
            appendStr(&pos, " ");
            appendNum(&pos, @intFromFloat(@max(1, h)));
            appendStr(&pos, " ] /Resources << /ExtGState << /GSa << /ca 0.45 /BM /Multiply >> >> >> /Length ");
            appendNum(&pos, @intCast(bl));
            appendStr(&pos, " >>\nstream\n");
            if (outRoom(pos, bl)) {
                if (!outRoom(pos, bl)) return 0;
                @memcpy(outBuf()[pos..][0..bl], bd[0..bl]);
                pos += bl;
            }
            appendStr(&pos, "\nendstream\nendobj\n");

            // 주석 객체
            const names = [_][]const u8{
                "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Text", "Ink",
            };
            new_offsets[new_n] = pos;
            new_nums[new_n] = an;
            new_n += 1;
            appendNum(&pos, an);
            appendStr(&pos, " 0 obj\n<< /Type /Annot /Subtype /");
            appendStr(&pos, names[@min(t.kind, 6)]);
            appendStr(&pos, " /F 4 /Rect [");
            var q3: u32 = 0;
            while (q3 < 4) : (q3 += 1) {
                appendStr(&pos, " ");
                appendNum(&pos, @intFromFloat(@max(0, t.rect[q3])));
            }
            appendStr(&pos, " ] /C [ ");
            var bd2: [64]u8 = undefined;
            var bl2: usize = 0;
            col3(&bd2, &bl2, t.col);
            appendStr(&pos, bd2[0..bl2]);
            appendStr(&pos, " ]");
            if (t.kind <= 2) {
                // 글자 위에 얹는 표시는 네 모서리를 적어야 한다
                appendStr(&pos, " /QuadPoints [");
                const qx = [_]f32{ t.rect[0], t.rect[2], t.rect[0], t.rect[2] };
                const qy = [_]f32{ t.rect[3], t.rect[3], t.rect[1], t.rect[1] };
                q3 = 0;
                while (q3 < 4) : (q3 += 1) {
                    appendStr(&pos, " ");
                    appendNum(&pos, @intFromFloat(@max(0, qx[q3])));
                    appendStr(&pos, " ");
                    appendNum(&pos, @intFromFloat(@max(0, qy[q3])));
                }
                appendStr(&pos, " ]");
            }
            if (t.kind == 0) appendStr(&pos, " /CA 0.45");
            if (t.kind == 5) appendStr(&pos, " /Name /Comment /Open false");
            if (t.kind == 6 and t.pts > 0) {
                appendStr(&pos, " /InkList [[");
                var k3: u32 = 0;
                while (k3 < t.pts and outRoom(pos, 32)) : (k3 += 1) {
                    appendStr(&pos, " ");
                    appendNum(&pos, @intFromFloat(@max(0, note_pts[t.off + k3 * 2])));
                    appendStr(&pos, " ");
                    appendNum(&pos, @intFromFloat(@max(0, note_pts[t.off + k3 * 2 + 1])));
                }
                appendStr(&pos, " ]]");
            }
            if (t.kind != 6 and t.len > 0) {
                // 메모 글 — 라틴 밖 글자가 있으면 UTF-16 으로
                const val = note_buf[t.off..][0..t.len];
                var wide = false;
                var cz: usize = 0;
                while (cz < val.len) {
                    const cu = utf8At(val, cz);
                    cz += cu[1];
                    if (cu[0] > 255) { wide = true; break; }
                }
                if (wide) {
                    appendStr(&pos, " /Contents <FEFF");
                    var cx3: usize = 0;
                    while (cx3 < val.len and outRoom(pos, 16)) {
                        const cu = utf8At(val, cx3);
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
                                outBuf()[pos] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                                pos += 1;
                            }
                        }
                    }
                    appendStr(&pos, ">");
                } else {
                    appendStr(&pos, " /Contents (");
                    var cx3: usize = 0;
                    while (cx3 < val.len and outRoom(pos, 8)) : (cx3 += 1) {
                        const ch = val[cx3];
                        if (ch == '(' or ch == ')' or ch == '\\') {
                            outBuf()[pos] = '\\';
                            pos += 1;
                        }
                        outBuf()[pos] = ch;
                        pos += 1;
                    }
                    appendStr(&pos, ")");
                }
            }
            appendStr(&pos, " /AP << /N ");
            appendNum(&pos, ap);
            appendStr(&pos, " 0 R >> >>\nendobj\n");
        }
    }

    // 새로 만드는 입력 칸 — 위젯 객체를 적고 번호를 기억해 둔다.
    // 쪽의 /Annots 에 걸어야 하므로 쪽을 다시 쓰기 전에 끝내야 한다.
    var newf_font: u32 = 0;
    if (newf_n > 0) {
        newf_font = mask_next;
        mask_next += 1;
        new_offsets[new_n] = pos;
        new_nums[new_n] = newf_font;
        new_n += 1;
        appendNum(&pos, newf_font);
        appendStr(&pos, " 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");
        var fi: u32 = 0;
        while (fi < newf_n and new_n + 2 < new_nums.len and outRoom(pos, 2048)) : (fi += 1) {
            const f = &newf()[fi];
            if (f.page >= page_count) continue;
            f.obj = mask_next;
            mask_next += 1;
            new_offsets[new_n] = pos;
            new_nums[new_n] = f.obj;
            new_n += 1;
            appendNum(&pos, f.obj);
            appendStr(&pos, " 0 obj\n<< /Type /Annot /Subtype /Widget /FT ");
            appendStr(&pos, if (f.kind == 1) "/Btn" else "/Tx");
            appendStr(&pos, " /T ");
            appendTextStr(&pos, newf_buf[f.off..][0..f.len]);
            appendStr(&pos, " /Rect [");
            var k: u32 = 0;
            while (k < 4) : (k += 1) {
                appendStr(&pos, " ");
                appendNum(&pos, @intFromFloat(@max(0, @min(100000, f.rect[k]))));
            }
            // /F 4 는 "찍을 때도 보인다" 는 뜻이다. 없으면 인쇄에서 사라진다.
            appendStr(&pos, " ] /F 4 /P ");
            appendNum(&pos, page_objs()[f.page]);
            appendStr(&pos, " 0 R /MK << /BC [0 0 0] /BG [1 1 1] >> /DA ");
            if (f.kind == 1) {
                appendStr(&pos, "(/ZaDb 0 Tf 0 g) /V /Off /AS /Off >>\nendobj\n");
            } else {
                appendStr(&pos, "(/Helv 0 Tf 0 g) /V () >>\nendobj\n");
            }
        }
    }

    var pending_res: [4096]u32 = undefined;
    var pending_src: [4096]u32 = undefined;
    var pending_n: usize = 0;

    // 3) 회전이나 워터마크가 있으면 각 페이지 객체를 다시 쓴다
    if (rotate != 0 or overlay or anyPageRotate() or has_notes or anyFieldStruct()) {
        i = 0;
        while (i < pick_n) : (i += 1) {
            const obj = page_objs()[pick()[i]];
            const body = findObj(b, obj) orelse continue;
            const end = find(b, "endobj", body) orelse b.len;
            // 이 쪽에 라벨이 있으면 그릴 스트림을 먼저 적어 둔다.
            // 쪽마다 자리가 다르니 스트림도 쪽마다 하나씩 나간다.
            var my_lab: u32 = 0;
            if (lab_n > 0 and pageHasLabels(pick()[i]) and new_n + 2 < new_nums.len) {
                _ = renderPage(pick()[i]);
                const bl2 = buildLabelStream(pick()[i]);
                if (bl2 > 2) {
                    my_lab = lab_base + lab_used;
                    lab_used += 1;
                    writeStream(&pos, new_offsets, new_nums, &new_n, my_lab, lab_body[0..bl2]);
                }
            }
            new_offsets[new_n] = pos;
            new_nums[new_n] = obj;
            new_n += 1;
            appendNum(&pos, obj);
            appendStr(&pos, " 0 obj");
            // 원본 딕셔너리를 그대로 옮기되 마지막 >> 앞에 /Rotate 를 끼운다
            const dict_end = rfind(b[0..end], ">>", end - 1) orelse end;
            // 워터마크를 얹을 때는 /Contents·/Resources 를 우리가 다시 쓰므로
            // 원본에서는 건너뛴다. 그대로 두면 키가 두 번 나온다.
            var cq2 = body;
            while (cq2 < dict_end) {
                if (overlay and b[cq2] == '/' and cq2 + 9 <= dict_end and
                    std_mem_eq(b[cq2 .. cq2 + 9], "/Contents"))
                {
                    cq2 += 9;
                    while (cq2 < dict_end and isSpace(b[cq2])) cq2 += 1;
                    if (cq2 < dict_end and b[cq2] == '[') {
                        while (cq2 < dict_end and b[cq2] != ']') cq2 += 1;
                        cq2 += 1;
                    } else {
                        _ = readUint(b, &cq2);
                        while (cq2 < dict_end and isSpace(b[cq2])) cq2 += 1;
                        _ = readUint(b, &cq2);
                        while (cq2 < dict_end and isSpace(b[cq2])) cq2 += 1;
                        if (cq2 < dict_end and b[cq2] == 'R') cq2 += 1;
                    }
                    continue;
                }
                if (b[cq2] == '/' and keyIs(b, cq2, dict_end, "/Rotate")) {
                    cq2 = skipVal(b, cq2 + 7, dict_end);
                    continue;
                }
                if ((has_notes or anyFieldStruct()) and b[cq2] == '/' and
                    keyIs(b, cq2, dict_end, "/Annots"))
                {
                    cq2 = skipVal(b, cq2 + 7, dict_end);
                    continue;
                }
                if (overlay and b[cq2] == '/' and cq2 + 10 <= dict_end and
                    std_mem_eq(b[cq2 .. cq2 + 10], "/Resources"))
                {
                    cq2 += 10;
                    while (cq2 < dict_end and isSpace(b[cq2])) cq2 += 1;
                    if (cq2 < dict_end and b[cq2] == '<') {
                        var depth: u32 = 0;
                        while (cq2 < dict_end) {
                            if (b[cq2] == '<') depth += 1;
                            if (b[cq2] == '>') { depth -= 1; if (depth == 0) { cq2 += 1; break; } }
                            cq2 += 1;
                        }
                    } else {
                        _ = readUint(b, &cq2);
                        while (cq2 < dict_end and isSpace(b[cq2])) cq2 += 1;
                        _ = readUint(b, &cq2);
                        while (cq2 < dict_end and isSpace(b[cq2])) cq2 += 1;
                        if (cq2 < dict_end and b[cq2] == 'R') cq2 += 1;
                    }
                    continue;
                }
                if (!outRoom(pos, 8)) break;
                outBuf()[pos] = b[cq2];
                pos += 1;
                cq2 += 1;
            }
            if ((has_notes and notesOnPage(pick()[i])) or anyFieldStruct()) {
                // 원래 있던 주석에 새로 단 것을 이어 붙인다
                appendStr(&pos, " /Annots [");
                if (findObj(b, obj)) |pb2| {
                    const pe2 = objDictEnd(b, pb2);
                    if (find(b[pb2..pe2], "/Annots", 0)) |aa4| {
                        var ap4 = pb2 + aa4 + 7;
                        while (ap4 < pe2 and isSpace(b[ap4])) ap4 += 1;
                        var s4 = ap4;
                        var e4 = pe2;
                        if (ap4 < pe2 and b[ap4] == '[') {
                            s4 = ap4 + 1;
                            e4 = arrayEnd(b, ap4, pe2) - 1;
                        } else if (ap4 < pe2 and isDigit(b[ap4])) {
                            const an4 = readUint(b, &ap4);
                            if (findObj(b, an4)) |ob4| {
                                var q4b = ob4;
                                const oe4 = find(b, "endobj", ob4) orelse b.len;
                                while (q4b < oe4 and b[q4b] != '[') q4b += 1;
                                s4 = q4b + 1;
                                e4 = arrayEnd(b, q4b, oe4) - 1;
                            }
                        }
                        // 지우기로 고른 칸은 여기서 빠진다
                        copyRefsKeeping(b, s4, e4, &pos);
                    }
                }
                var nk: u32 = 0;
                while (nk < note_n) : (nk += 1) {
                    if (notes()[nk].page != pick()[i] or notes()[nk].obj == 0) continue;
                    appendStr(&pos, " ");
                    appendNum(&pos, notes()[nk].obj);
                    appendStr(&pos, " 0 R");
                }
                var nf: u32 = 0;
                while (nf < newf_n) : (nf += 1) {
                    if (newf()[nf].page != pick()[i] or newf()[nf].obj == 0) continue;
                    appendStr(&pos, " ");
                    appendNum(&pos, newf()[nf].obj);
                    appendStr(&pos, " 0 R");
                }
                appendStr(&pos, " ]");
            }
            // 원본의 /Rotate 는 위에서 건너뛰었으므로 여기서 다시 쓴다.
            // 쓰는 이가 준 회전은 원본에 **더한다** — 예전에는 원본을 버리고
            // 사용자 값만 적어, /Rotate 90 인 가로 스캔이 아무 설정도 안 했는데
            // 똑바로(0도) 나왔다.
            const src_rot: i32 = blk: {
                const inh = inheritedKey(b, body, end, "/Rotate") orelse break :blk 0;
                var rp = inh.at + 7;
                while (rp < inh.e and isSpace(b[rp])) rp += 1;
                var neg = false;
                if (rp < inh.e and b[rp] == '-') { neg = true; rp += 1; }
                if (rp >= inh.e or !isDigit(b[rp])) break :blk 0;
                const v: i32 = @intCast(readUint(b, &rp) % 360);
                break :blk if (neg) -v else v;
            };
            const rot_here = src_rot + rotOf(pick()[i]);
            if (@mod(rot_here, 360) != 0) {
                appendStr(&pos, " /Rotate ");
                const r = @mod(rot_here, 360);
                appendNum(&pos, @intCast(if (r < 0) r + 360 else r));
            }
            if (overlay) {
                // q → 원본 → Q+얹을 것 순으로 잇는다
                appendStr(&pos, " /Contents [ ");
                appendNum(&pos, wm_pre);
                appendStr(&pos, " 0 R");
                var cq = body;
                const cend = dict_end;
                if (find(b[cq..cend], "/Contents", 0)) |ca| {
                    var cp = cq + ca + 9;
                    while (cp < cend and isSpace(b[cp])) cp += 1;
                    if (cp < cend and b[cp] == '[') {
                        cp += 1;
                        while (cp < cend and b[cp] != ']') {
                            if (!outRoom(pos, 8)) break;
                            outBuf()[pos] = b[cp];
                            pos += 1;
                            cp += 1;
                        }
                    } else {
                        const cn = readUint(b, &cp);
                        appendStr(&pos, " ");
                        appendNum(&pos, cn);
                        appendStr(&pos, " 0 R");
                    }
                }
                if (wm_n > 0) {
                    appendStr(&pos, " ");
                    appendNum(&pos, wm_content);
                    appendStr(&pos, " 0 R");
                }
                if (my_lab != 0) {
                    appendStr(&pos, " ");
                    appendNum(&pos, my_lab);
                    appendStr(&pos, " 0 R");
                }
                appendStr(&pos, " ]");
                // 리소스는 통째로 갈아치우면 안 된다. 원본 폰트가 사라져
                // 본문 글자가 하나도 그려지지 않는다. 원본을 복사해 우리
                // 글꼴만 끼운 새 객체를 만들고 그걸 가리킨다.
                const new_res = wm_res_base + wm_res_n;
                wm_res_n += 1;
                appendStr(&pos, " /Resources ");
                appendNum(&pos, new_res);
                appendStr(&pos, " 0 R");
                pending_res[pending_n] = new_res;
                pending_src[pending_n] = obj;
                pending_n += 1;
                cq = body;
            }
            appendStr(&pos, " >>\nendobj\n");
        }
    }

    // 3) 채운 입력 칸을 다시 쓴다
    if (edit_n > 0 or newf_n > 0) {
        const fld_font = mask_next;
        var ap_next = mask_next + 1;
        var wrote_font = false;
        var ei: u32 = 0;
        while (ei < edit_n and new_n + 3 < new_nums.len and outRoom(pos, 4096)) : (ei += 1) {
            const e = editsBuf()[ei];
            // 지울 칸은 다시 적지 않는다. 쪽의 /Annots 와 양식의 /Fields 에서
            // 이름이 빠지므로 아무도 가리키지 않는 객체가 된다.
            if (e.kind == 4) continue;
            const ob = findObj(b, e.obj) orelse continue;
            const oe = objDictEnd(b, ob);
            var ds2 = ob;
            while (ds2 < oe and b[ds2] != '<') ds2 += 1;
            if (ds2 >= oe) continue;
            const de2 = dictEnd(b, ds2, oe);
            if (de2 <= ds2 + 2) continue;
            const val = edit_buf[e.off..][0..e.len];

            // 글상자면 겉모습을 새로 그린다
            var ap_obj: u32 = 0;
            if (e.kind == 0 and e.mlen > 0) {
                // 표준 글꼴에 없는 글자가 섞였다 — 화면 글꼴로 그린 그림을
                // 그대로 심는다. 1비트 마스크라 지금 색으로 칠해진다.
                var rect: [4]f32 = .{ 0, 0, 0, 0 };
                if (find(b[ob..oe], "/Rect", 0)) |ra| {
                    var rp = ob + ra + 5;
                    while (rp < oe and b[rp] != '[') rp += 1;
                    rp += 1;
                    var ii: u32 = 0;
                    while (ii < 4 and rp < oe) : (ii += 1) rect[ii] = readFloat(b, &rp);
                }
                if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
                if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }
                const bw = rect[2] - rect[0];
                const bh = rect[3] - rect[1];
                if (bw > 1 and bh > 1 and new_n + 3 < new_nums.len and outRoom(pos, e.mlen + 1024)) {
                    const img_obj = ap_next;
                    ap_obj = ap_next + 1;
                    ap_next += 2;
                    // 마스크 그림
                    new_offsets[new_n] = pos;
                    new_nums[new_n] = img_obj;
                    new_n += 1;
                    appendNum(&pos, img_obj);
                    appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Image /Width ");
                    appendNum(&pos, e.mw);
                    appendStr(&pos, " /Height ");
                    appendNum(&pos, e.mh);
                    appendStr(&pos, " /ImageMask true /BitsPerComponent 1 /Decode [0 1] /Length ");
                    appendNum(&pos, e.mlen);
                    appendStr(&pos, " >>\nstream\n");
                    if (!outRoom(pos, e.mlen)) return 0;
                    @memcpy(outBuf()[pos..][0..e.mlen], maskBuf()[e.moff..][0..e.mlen]);
                    pos += e.mlen;
                    appendStr(&pos, "\nendstream\nendobj\n");
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
                    b3 += putNum(body3[b3..], @intFromFloat(@max(1, bw)));
                    put3(&body3, &b3, " 0 0 ");
                    b3 += putNum(body3[b3..], @intFromFloat(@max(1, bh)));
                    put3(&body3, &b3, " 0 0 cm /Im0 Do Q EMC\n");
                    new_offsets[new_n] = pos;
                    new_nums[new_n] = ap_obj;
                    new_n += 1;
                    appendNum(&pos, ap_obj);
                    appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 ");
                    appendNum(&pos, @intFromFloat(@max(1, bw)));
                    appendStr(&pos, " ");
                    appendNum(&pos, @intFromFloat(@max(1, bh)));
                    appendStr(&pos, " ] /Resources << /XObject << /Im0 ");
                    appendNum(&pos, img_obj);
                    appendStr(&pos, " 0 R >> >> /Length ");
                    appendNum(&pos, @intCast(b3));
                    appendStr(&pos, " >>\nstream\n");
                    if (outRoom(pos, b3)) {
                        if (!outRoom(pos, b3)) return 0;
                        @memcpy(outBuf()[pos..][0..b3], body3[0..b3]);
                        pos += b3;
                    }
                    appendStr(&pos, "\nendstream\nendobj\n");
                }
            } else if (e.kind == 0) {
                var rect: [4]f32 = .{ 0, 0, 0, 0 };
                if (find(b[ob..oe], "/Rect", 0)) |ra| {
                    var rp = ob + ra + 5;
                    while (rp < oe and b[rp] != '[') rp += 1;
                    rp += 1;
                    var ax: u32 = 0;
                    while (ax < 4 and rp < oe) : (ax += 1) rect[ax] = readFloat(b, &rp);
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
                        appendNum(&pos, fld_font);
                        appendStr(&pos, " 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");
                        wrote_font = true;
                    }
                    ap_obj = ap_next;
                    ap_next += 1;
                    // 여러 줄인지
                    var multi = false;
                    if (fieldLookup(b, e.obj, "/Ff", 0)) |r| {
                        var vp = r[0];
                        while (vp < r[1] and isSpace(b[vp])) vp += 1;
                        if (vp < r[1] and isDigit(b[vp])) {
                            const ff = readUint(b, &vp);
                            multi = (ff & (1 << 12)) != 0;
                        }
                    }
                    var size: f32 = 0;
                    if (fieldLookup(b, e.obj, "/DA", 0)) |r| {
                        const da = fldPutStr(b, r[0], r[1]);
                        const txt = fld_buf()[da[0]..][0..da[1]];
                        if (findIn(txt, " Tf", 0)) |ti| {
                            var dx: usize = ti;
                            while (dx > 0 and isSpace(txt[dx - 1])) dx -= 1;
                            var ex: usize = dx;
                            while (ex > 0 and (isDigit(txt[ex - 1]) or txt[ex - 1] == '.')) ex -= 1;
                            var pz: usize = 0;
                            if (ex < dx) size = readFloat(txt[ex..dx], &pz);
                        }
                        fld_used = da[0];
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
                    bl += putNum(body2[bl..], @intFromFloat(@max(1, size)));
                    put(&body2, &bl, " Tf 0 g 2 ");
                    const first_y: f32 = if (multi) bh - lead else (bh - size * 0.72) / 2;
                    bl += putNum(body2[bl..], @intFromFloat(@max(1, first_y)));
                    put(&body2, &bl, " Td\n");
                    // 줄마다 적는다. 아스키만 넣는다 — 한글은 표준 글꼴에 없다.
                    var bx: usize = 0;
                    var line_open = false;
                    while (bx < val.len and bl + 32 < body2.len) {
                        const cu = utf8At(val, bx);
                        bx += cu[1];
                        if (cu[0] == '\n' or cu[0] == '\r') {
                            if (line_open) { put(&body2, &bl, ") Tj\n"); line_open = false; }
                            if (cu[0] == '\r' and bx < val.len and val[bx] == '\n') bx += 1;
                            put(&body2, &bl, "0 -");
                            bl += putNum(body2[bl..], @intFromFloat(@max(1, lead)));
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
                    appendNum(&pos, ap_obj);
                    appendStr(&pos, " 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 ");
                    appendNum(&pos, @intFromFloat(@max(1, bw)));
                    appendStr(&pos, " ");
                    appendNum(&pos, @intFromFloat(@max(1, bh)));
                    appendStr(&pos, " ] /Resources << /Font << /Helv ");
                    appendNum(&pos, fld_font);
                    appendStr(&pos, " 0 R >> >> /Length ");
                    appendNum(&pos, @intCast(bl));
                    appendStr(&pos, " >>\nstream\n");
                    if (outRoom(pos, bl)) {
                        if (!outRoom(pos, bl)) return 0;
                        @memcpy(outBuf()[pos..][0..bl], body2[0..bl]);
                        pos += bl;
                    }
                    appendStr(&pos, "\nendstream\nendobj\n");
                }
            }

            // 위젯을 다시 쓴다 — 원본 딕셔너리에서 /V·/AS·/AP 만 갈아 끼운다
            new_offsets[new_n] = pos;
            new_nums[new_n] = e.obj;
            new_n += 1;
            appendNum(&pos, e.obj);
            appendStr(&pos, " 0 obj\n<<");
            var fx = ds2 + 2;
            const inner_end = de2 - 2;
            while (fx < inner_end and outRoom(pos, 8)) {
                // 이름만 바꿀 때는 값을 건드리지 않는다 — /T 만 걷어 낸다
                const drop = if (e.kind == 3)
                    keyIs(b, fx, inner_end, "/T")
                else
                    (keyIs(b, fx, inner_end, "/V") or keyIs(b, fx, inner_end, "/AS") or
                        (e.kind == 0 and keyIs(b, fx, inner_end, "/AP")));
                if (b[fx] == '/' and drop) {
                    var kq = fx + 1;
                    while (kq < inner_end and !isSpace(b[kq]) and b[kq] != '/' and b[kq] != '(' and
                        b[kq] != '<' and b[kq] != '[' and !isDigit(b[kq])) kq += 1;
                    fx = skipVal(b, kq, inner_end);
                    continue;
                }
                outBuf()[pos] = b[fx];
                pos += 1;
                fx += 1;
            }
            if (e.kind == 3) {
                appendStr(&pos, " /T ");
                appendTextStr(&pos, val);
            } else if (e.kind == 0) {
                // 라틴 밖 글자가 있으면 UTF-16 으로 담는다 — 괄호 문자열에는
                // 한 바이트 글자만 들어가므로 한글이 통째로 사라진다.
                var wide = false;
                {
                    var cz: usize = 0;
                    while (cz < val.len) {
                        const cu = utf8At(val, cz);
                        cz += cu[1];
                        if (cu[0] > 255) { wide = true; break; }
                    }
                }
                if (wide) {
                    appendStr(&pos, " /V <FEFF");
                    var cx: usize = 0;
                    while (cx < val.len and outRoom(pos, 16)) {
                        const cu = utf8At(val, cx);
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
                                outBuf()[pos] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                                pos += 1;
                            }
                        }
                    }
                    appendStr(&pos, ">");
                } else {
                    appendStr(&pos, " /V (");
                    var cx: usize = 0;
                    while (cx < val.len and outRoom(pos, 8)) {
                        const cu = utf8At(val, cx);
                        cx += cu[1];
                        if (cu[0] == '\r') continue;
                        if (cu[0] == '(' or cu[0] == ')' or cu[0] == '\\') {
                            outBuf()[pos] = '\\';
                            pos += 1;
                        }
                        outBuf()[pos] = @intCast(cu[0]);
                        pos += 1;
                    }
                    appendStr(&pos, ")");
                }
                if (ap_obj != 0) {
                    appendStr(&pos, " /AP << /N ");
                    appendNum(&pos, ap_obj);
                    appendStr(&pos, " 0 R >>");
                }
            } else {
                const on = if (e.kind == 1 and val.len > 0) val else "Off";
                if (outRoom(pos, on.len * 2 + 32)) {
                    appendStr(&pos, " /V /");
                    if (!outRoom(pos, on.len)) return 0;
                    @memcpy(outBuf()[pos..][0..on.len], on);
                    pos += on.len;
                    appendStr(&pos, " /AS /");
                    if (!outRoom(pos, on.len)) return 0;
                    @memcpy(outBuf()[pos..][0..on.len], on);
                    pos += on.len;
                }
            }
            appendStr(&pos, " >>\nendobj\n");
        }
        // 겉모습을 다시 그릴 줄 아는 뷰어는 제 글꼴로 다시 그리게 한다 —
        // 우리가 넣은 겉모습은 표준 글꼴이라 한글이 빠진다.
        if (doc_root != 0) {
            if (findObj(b, doc_root)) |rb3| {
                const re3 = objDictEnd(b, rb3);
                const has_acro = find(b[rb3..re3], "/AcroForm", 0) != null;
                // 양식이 아예 없는 문서에 칸을 만들면 카탈로그에 양식을 새로 단다
                if (!has_acro and newf_n > 0 and new_n + 1 < new_nums.len) {
                    var ix0 = rb3;
                    while (ix0 < re3 and b[ix0] != '<') ix0 += 1;
                    const hx0 = dictEnd(b, ix0, re3);
                    if (hx0 > ix0 + 2) {
                        new_offsets[new_n] = pos;
                        new_nums[new_n] = doc_root;
                        new_n += 1;
                        appendNum(&pos, doc_root);
                        appendStr(&pos, " 0 obj\n<<");
                        var gx0 = ix0 + 2;
                        while (gx0 < hx0 - 2 and outRoom(pos, 64)) : (gx0 += 1) {
                            outBuf()[pos] = b[gx0];
                            pos += 1;
                        }
                        appendStr(&pos, " /AcroForm << /Fields [");
                        var nf0: u32 = 0;
                        while (nf0 < newf_n) : (nf0 += 1) {
                            if (newf()[nf0].obj == 0) continue;
                            appendStr(&pos, " ");
                            appendNum(&pos, newf()[nf0].obj);
                            appendStr(&pos, " 0 R");
                        }
                        appendStr(&pos, " ] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv ");
                        appendNum(&pos, newf_font);
                        appendStr(&pos, " 0 R >> >> /NeedAppearances true >> >>\nendobj\n");
                    }
                }
                if (find(b[rb3..re3], "/AcroForm", 0)) |aa3| {
                    var ap3 = rb3 + aa3 + 9;
                    while (ap3 < re3 and isSpace(b[ap3])) ap3 += 1;
                    if (ap3 < re3 and isDigit(b[ap3])) {
                        const an3 = readUint(b, &ap3);
                        if (findObj(b, an3)) |ab3| {
                            const abe3 = objDictEnd(b, ab3);
                            var ix = ab3;
                            while (ix < abe3 and b[ix] != '<') ix += 1;
                            const hx = dictEnd(b, ix, abe3);
                            if (hx > ix + 2 and new_n + 1 < new_nums.len) {
                                new_offsets[new_n] = pos;
                                new_nums[new_n] = an3;
                                new_n += 1;
                                appendNum(&pos, an3);
                                appendStr(&pos, " 0 obj\n<<");
                                var gx = ix + 2;
                                const jx = hx - 2;
                                const redo = anyFieldStruct();
                                while (gx < jx and outRoom(pos, 64)) {
                                    if (b[gx] == '/' and keyIs(b, gx, jx, "/NeedAppearances")) {
                                        gx = skipVal(b, gx + 16, jx);
                                        continue;
                                    }
                                    // 칸을 만들거나 지웠으면 목록을 우리가 다시 적는다
                                    if (redo and b[gx] == '/' and keyIs(b, gx, jx, "/Fields")) {
                                        gx = skipVal(b, gx + 7, jx);
                                        continue;
                                    }
                                    outBuf()[pos] = b[gx];
                                    pos += 1;
                                    gx += 1;
                                }
                                if (redo) {
                                    appendStr(&pos, " /Fields [");
                                    // 원래 목록에서 지운 것만 뺀다
                                    if (find(b[ab3..abe3], "/Fields", 0)) |fa| {
                                        var fp = ab3 + fa + 7;
                                        while (fp < abe3 and isSpace(b[fp])) fp += 1;
                                        var fs2 = fp;
                                        var fe2 = abe3;
                                        if (fp < abe3 and b[fp] == '[') {
                                            fs2 = fp + 1;
                                            fe2 = arrayEnd(b, fp, abe3) - 1;
                                        } else if (fp < abe3 and isDigit(b[fp])) {
                                            const fn2 = readUint(b, &fp);
                                            if (findObj(b, fn2)) |fb2| {
                                                const fee = find(b, "endobj", fb2) orelse b.len;
                                                var fq = fb2;
                                                while (fq < fee and b[fq] != '[') fq += 1;
                                                fs2 = fq + 1;
                                                fe2 = arrayEnd(b, fq, fee) - 1;
                                            }
                                        }
                                        copyRefsKeeping(b, fs2, fe2, &pos);
                                    }
                                    var nf2: u32 = 0;
                                    while (nf2 < newf_n) : (nf2 += 1) {
                                        if (newf()[nf2].obj == 0) continue;
                                        appendStr(&pos, " ");
                                        appendNum(&pos, newf()[nf2].obj);
                                        appendStr(&pos, " 0 R");
                                    }
                                    appendStr(&pos, " ]");
                                }
                                appendStr(&pos, " /NeedAppearances true >>\nendobj\n");
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
            appendNum(&pos, pending_res[t]);
            appendStr(&pos, " 0 obj\n");

            var rs: usize = 0;
            var re_: usize = 0;
            if (findObj(b, page_obj)) |pb| {
                const pe = find(b, "endobj", pb) orelse b.len;
                if (find(b[pb..pe], "/Resources", 0)) |ra| {
                    var rp = pb + ra + 10;
                    while (rp < pe and isSpace(b[rp])) rp += 1;
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
                        const rn = readUint(b, &rp);
                        if (findObj(b, rn)) |rb| {
                            const rend = find(b, "endobj", rb) orelse b.len;
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
                        std_mem_eq(b[q4 .. q4 + 5], "/Font"))
                    {
                        if (!outRoom(pos, 64)) break;
                        if (!outRoom(pos, 5)) return 0;
                    @memcpy(outBuf()[pos..][0..5], "/Font");
                        pos += 5;
                        q4 += 5;
                        while (q4 < re_ and isSpace(b[q4])) q4 += 1;
                        if (q4 + 1 < re_ and b[q4] == '<' and b[q4 + 1] == '<') {
                            appendStr(&pos, " << /WMF ");
                            appendNum(&pos, wm_font);
                            appendStr(&pos, " 0 R ");
                            q4 += 2;
                            put_font = true;
                        }
                        continue;
                    }
                    if (!outRoom(pos, 8)) break;
                    outBuf()[pos] = b[q4];
                    pos += 1;
                    q4 += 1;
                }
                if (!put_font) {
                    pos -= 2;
                    appendStr(&pos, " /Font << /WMF ");
                    appendNum(&pos, wm_font);
                    appendStr(&pos, " 0 R >> >>");
                }
            } else {
                appendStr(&pos, "<< /Font << /WMF ");
                appendNum(&pos, wm_font);
                appendStr(&pos, " 0 R >> >>");
            }
            // 화면 글꼴로 그린 그림도 이름을 달아 둔다
            if (any_mask) {
                pos -= 2;
                appendStr(&pos, " /XObject <<");
                var mj: u32 = 0;
                while (mj < lab_n) : (mj += 1) {
                    if (labs()[mj].mobj == 0) continue;
                    appendStr(&pos, " /PdLb");
                    appendNum(&pos, mj);
                    appendStr(&pos, " ");
                    appendNum(&pos, labs()[mj].mobj);
                    appendStr(&pos, " 0 R");
                }
                if (wm_mobj != 0) {
                    appendStr(&pos, " /PdWm ");
                    appendNum(&pos, wm_mobj);
                    appendStr(&pos, " 0 R");
                }
                appendStr(&pos, " >> >>");
            }
            appendStr(&pos, "\nendobj\n");
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
    appendStr(&pos, "xref\n");
    i = 0;
    while (i < new_n) : (i += 1) {
        appendNum(&pos, new_nums[i]);
        appendStr(&pos, " 1\n");
        // 10자리 오프셋 + 5자리 세대
        var off = new_offsets[i];
        var digits: [10]u8 = undefined;
        var d: usize = 10;
        while (d > 0) : (d -= 1) { digits[d - 1] = @intCast('0' + (off % 10)); off /= 10; }
        if (!outRoom(pos, 10)) return 0;
        @memcpy(outBuf()[pos..][0..10], &digits);
        pos += 10;
        appendStr(&pos, " 00000 n \n");
    }

    // 4) trailer — 이전 xref 를 가리킨다
    var prev: u32 = 0;
    if (rfindTail(b[0..in_len], "startxref")) |at| {
        var p = at + 9;
        prev = readUint(b, &p);
    }
    var root: u32 = 0;
    if (trailerKeyOrScan(b, "/Root")) |at| {
        var p = at + 5;
        root = readUint(b, &p);
    }
    appendStr(&pos, "trailer\n<< /Size ");
    appendNum(&pos, max_obj + 8);
    appendStr(&pos, " /Root ");
    appendNum(&pos, root);
    appendStr(&pos, " 0 R /Prev ");
    appendNum(&pos, prev);
    appendStr(&pos, " >>\nstartxref\n");
    appendNum(&pos, @intCast(xref_pos));
    appendStr(&pos, "\n%%EOF\n");

    stripEncryptOut(pos);
    out_len = pos;
    return pos;
}


// ===== 텍스트 렌더링 =====
//
// 브라우저 내장 뷰어를 쓰지 않고 캔버스에 직접 그리기 위한 최소 렌더러.
// 콘텐츠 스트림의 텍스트 연산자만 해석한다. 한글은 폰트의 ToUnicode CMap 을
// 읽어야 실제 글자가 나온다.

/// 쪽 하나에서 뽑을 글자 덩이 수.
///
/// 4096 이던 것을 올렸다. 표가 촘촘한 쪽은 그 수를 넘겨, textItems() 가
/// 뒤를 조용히 잃었다(text() 는 따로 담아 두어 멀쩡했다). 덩이 하나가
/// 24 바이트라 16384 개도 384KB 다.

/// 한 번에 그릴 글자 조각
// 글꼴 번호(fonts 의 자리)와 세로쓰기 여부까지 함께 남긴다. pdf.js 의
// TextItem 이 fontName·dir 을 주는 자리다 — 글자층이 글꼴을 맞춰 눕히거나
// 세로쓰기를 알아보는 데 쓴다.
const Item = struct { x: f32, y: f32, size: f32, off: u32, len: u32, font: i32 = -1, vert: bool = false };
/// 글자 조각. 필요한 만큼 늘어난다(세는 상한 없음).
var items_at: usize = 0;
var items_cap: u32 = 0;
fn itemsBuf() []Item {
    if (items_at == 0 or items_cap == 0) return &[_]Item{};
    return @as([*]Item, @ptrFromInt(items_at))[0..items_cap];
}
fn itemsRoom(want: u32) bool { return growTable(&items_at, &items_cap, want, @sizeOf(Item), 4096); }
var item_n: u32 = 0;

// --- 그리기 명령 목록 ---
// PDF.js 의 OperatorList 와 같은 생각이다. 파싱 결과를 명령으로 쌓아 넘기고
// 그리기는 캔버스가 맡는다. 좌표 변환을 우리가 곱하지 않고 그대로 넘겨야
// 선 굵기·클리핑·글자 크기가 함께 변환된다.
/// 명령 자리는 필요한 만큼 늘어난다(세는 상한 없음). 예전에는 524288 개로
/// 못박아 두어, 자리 다 다른 네모 20만 개를 그리면 절반에서 잘렸다.
/// LIMIT 은 growTable 이 정하는 4M 개(=16MB)다 — 그 위는 문서가 망가진 것으로 본다.
var ops_at: usize = 0;
var ops_cap: u32 = 0;
var ops_n: u32 = 0;
fn opsBuf() []f32 {
    if (ops_at == 0 or ops_cap == 0) return &[_]f32{};
    return @as([*]f32, @ptrFromInt(ops_at))[0..ops_cap];
}
fn opsRoom(want: u32) bool { return growTable(&ops_at, &ops_cap, want, 4, 65536); }
/// 그물 셰이딩이 명령 자리를 다 먹으면 그 뒤 그림이 통째로 사라진다.
/// 망가진 파일은 삼각형을 수만 개 뱉으므로 더 못 늘릴 때만 그만둔다.
fn opsRoomLow() bool { return !opsRoom(ops_n + 4096); }
/// 숨긴 레이어를 지나는 동안 명령을 내지 않는다
var emit_mute: bool = false;
// ===== 글자 묶음 =====
//
// 글자를 하나씩 명령으로 내면, 문서 글꼴을 못 실어 다른 글꼴로 대신 그릴 때
// 좁은 글자마다 틈이 벌어진다("Pri ncess Dai sy"). 이어지는 글자를 한 묶음
// 으로 내고 묶음 전체 폭에 맞춰 늘이거나 줄이면 눈에 띄지 않는다.
// PDF.js 도 문자열 단위로 그린다.
var run_on: bool = false;
var run_x: f32 = 0;
var run_y: f32 = 0;
var run_m: [4]f32 = .{ 1, 0, 0, 1 };
var run_size: f32 = 0;
var run_off: u32 = 0;
var run_roff: u32 = 0;
/// 지금 걸린 채우기 투명도와 섞기 방식. 투명 그룹을 겹칠 때 쓴다.
var cur_alpha: f32 = 1;
var cur_bm: i32 = 0;
var run_adv: f32 = 0;
var run_font: i32 = -1;
var run_mode: i32 = 0;

fn runFlush() void {
    if (!run_on) return;
    run_on = false;
    if (dtext_n <= run_off) return;
    emitOp(17, &[_]f32{
        run_x, run_y, run_size,
        @floatFromInt(run_off), @floatFromInt(dtext_n - run_off),
        @floatFromInt(run_font + 1),
        run_m[0], run_m[1], run_m[2], run_m[3], run_adv,
        @floatFromInt(run_mode),
        // 글자층에 얹을 글자 자리 — 그리는 글자와 다르다
        @floatFromInt(run_roff), @floatFromInt(rtext_n - run_roff),
    });
}
/// 지금 그리는 경로가 차지하는 범위. 타일 무늬를 깔 자리를 정하는 데 쓴다.
var path_x0: f32 = 1e30;
var path_y0: f32 = 1e30;
var path_x1: f32 = -1e30;
var path_y1: f32 = -1e30;
fn pathTouch(x: f32, y: f32) void {
    if (x < path_x0) path_x0 = x;
    if (x > path_x1) path_x1 = x;
    if (y < path_y0) path_y0 = y;
    if (y > path_y1) path_y1 = y;
}
fn pathReset() void {
    path_x0 = 1e30;
    path_y0 = 1e30;
    path_x1 = -1e30;
    path_y1 = -1e30;
}

fn emitOp(code: f32, args: []const f32) void {
    if (emit_mute) return;
    const need: u32 = ops_n + 2 + @as(u32, @intCast(args.len));
    if (!opsRoom(need)) return;
    const buf = opsBuf();
    buf[ops_n] = code;
    buf[ops_n + 1] = @floatFromInt(args.len);
    ops_n += 2;
    for (args) |a| {
        buf[ops_n] = a;
        ops_n += 1;
    }
}

export fn opsPtr() [*]f32 {
    return if (ops_at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(ops_at);
}
export fn opsLen() u32 { return ops_n; }
/// 뽑아 내는 글자. 필요한 만큼 늘어난다(세는 상한 없음) — 예전에는 256KB 에서
/// 잘려, 빽빽한 쪽의 뒷글자가 소리 없이 사라졌다.
var text_at: usize = 0;
var text_cap: u32 = 0;
fn textBuf() []u8 {
    if (text_at == 0 or text_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(text_at))[0..text_cap];
}
fn textRoom(want: u32) bool { return growTable(&text_at, &text_cap, want, 1, 65536); }
var text_n: u32 = 0;
/// 화면에 찍을 글자. text 와 다를 수 있다.
///
/// 부분집합 글꼴은 ToUnicode 가 여러 코드를 같은 글자로 보내는 일이 흔하다.
/// 바코드 글꼴이 특히 그렇다 — 막대 무늬 수십 개가 같은 한 글자를 가리킨다.
/// 그 글자를 그리면 무늬 대신 글자가 겹쳐 찍힌다. 그래서 글꼴 파일을 실을 수
/// 있으면 cmap 을 "사용자 영역 → 글리프 번호"로 새로 적고, 여기에는 그 사용자
/// 영역 문자를 담아 글리프를 번호로 곧장 집는다.
/// 화면에 찍을 글자. 필요한 만큼 늘어난다(세는 상한 없음) — 예전에는 256KB 에서
/// 잘려, 빽빽한 쪽의 뒷글자가 소리 없이 사라졌다.
var dtext_at: usize = 0;
var dtext_cap: u32 = 0;
fn dtextBuf() []u8 {
    if (dtext_at == 0 or dtext_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(dtext_at))[0..dtext_cap];
}
fn dtextRoom(want: u32) bool { return growTable(&dtext_at, &dtext_cap, want, 1, 65536); }
/// dtext 와 나란히 가는, 사람이 읽는 글자.
///
/// 그리는 글자와 읽는 글자는 다르다. 번호로 집는 글꼴은 사용자 영역
/// (U+E000+글리프번호)으로 찍어야 그려지는데, 그걸 그대로 글자층에 얹으면
/// 긁어 붙였을 때 깨진 글자가 나온다. PDF.js 도 둘을 따로 둔다 — 캔버스는
/// 글리프로 찍고, 글자층은 ToUnicode 로 되찾은 글자로 짓는다.
/// 사람이 읽는 글자. 필요한 만큼 늘어난다(세는 상한 없음) — 예전에는 256KB 에서
/// 잘려, 빽빽한 쪽의 뒷글자가 소리 없이 사라졌다.
var rtext_at: usize = 0;
var rtext_cap: u32 = 0;
fn rtextBuf() []u8 {
    if (rtext_at == 0 or rtext_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(rtext_at))[0..rtext_cap];
}
fn rtextRoom(want: u32) bool { return growTable(&rtext_at, &rtext_cap, want, 1, 65536); }
var rtext_n: u32 = 0;
var dtext_n: u32 = 0;

/// 폰트 하나의 코드→유니코드 표 (희소)
const FontMap = struct {
    name: [24]u8,
    name_len: u8,
    two_byte: bool,
    /// 코드→유니코드 표. 글꼴마다 따로 구역에서 잡고 필요한 만큼 늘린다.
    /// 예전에는 글꼴 하나에 2048 쌍으로 못박혀, 한자·전각 글꼴의 뒷부분이
    /// 조용히 빠졌다.
    codes_at: usize,
    codes_cap: u32,
    unis_at: usize,
    unis_cap: u32,
    n: u32,
    /// 문서에 박힌 글꼴 파일. 글꼴 영역 안 위치와 길이.
    file_off: u32,
    file_len: u32,
    /// 표준 14종의 폭 표. /Widths 가 없을 때 여기서 본다.
    std_w: ?*const [256]u16,
    /// 글자 폭 (1000 단위). 없는 코드는 dw 를 쓴다.
    dw: f32,
    wn: u32,
    /// 글자 폭 표도 같은 식으로 잡는다(1024 개로 못박혀 있었다).
    wcodes_at: usize,
    wcodes_cap: u32,
    wvals_at: usize,
    wvals_cap: u32,
    /// Identity-H — 문자 코드가 곧 글리프 번호다
    identity: bool,
    /// 세로쓰기
    vertical: bool,
    /// 미리 정의된 CMap 갈래.
    /// 0 한 바이트  1 Identity(두 바이트)  2 UCS2·UTF16(두 바이트)
    /// 3 EUC·UHC·Big5(앞바이트가 0x81 이상이면 두 바이트)
    /// 4 Shift-JIS(0x81~0x9F, 0xE0~0xFC 가 두 바이트)
    cmap_kind: u8,
    /// 받아 둔 미리 정의된 CMap 자리 (-1 이면 없음). 코드→CID 를 준다.
    cm: i16,
    /// CID → 글리프 번호 표 (/CIDToGIDMap 스트림). 길이 0 이면 CID=글리프다.
    c2g_off: u32,
    c2g_len: u32,
    /// 이 글꼴 계열의 CID→유니코드 표 자리 (-1 이면 없음).
    /// ToUnicode 가 없는 옛 문서에서 글자를 복사할 때 쓴다.
    uc: i16,
    /// 글꼴 파일의 cmap 을 "사용자 영역 → 글리프 번호"로 새로 적었다.
    /// 그러면 코드로 글리프를 바로 집을 수 있다.
    pua: bool,
    /// Type3 — 글리프가 작은 콘텐츠 스트림으로 들어 있다
    type3: bool,
    /// 글리프 공간 → 텍스트 공간 변환
    fm: [6]f32,
    /// 코드 → 글리프 그림 객체 번호 (0 이면 없음)
    t3: [256]u32,
    /// Type1 — 글리프가 암호화된 외곽선 프로그램으로 들어 있다
    t1: bool,
    /// 글리프 프로그램 자리 (t1_pool 의 첫 칸). 코드 256 개가 이어진다.
    t1_cs: u16,
    /// 서브루틴 자리와 개수
    t1_sub: u16,
    t1_sub_n: u16,
    /// 표준 인코딩 코드 → 글리프 자리 (seac 로 악센트를 합칠 때 쓴다)
    t1_std: [128]u16,
    /// 어떤 글꼴인지 — 화면의 "문서 정보"가 이걸 보여 준다.
    /// 1 Identity-H  2 번호로 집음  4 파일 실음  8 ToUnicode 있음
    /// 16 FontFile3(맨 CFF 라 못 실음)  32 Type3  64 FontFile(Type1)
    /// 128 파일이 아예 없음(표준 글꼴)  256 Type3 껍데기  512 CFF 를 감싸 실음
    kind: u16,
};
/// 쪽의 글꼴. 필요한 만큼 늘어난다(세는 상한 없음) — 32개로 못박아 두었을 때는
/// 글꼴을 많이 쓰는 쪽에서 33번째부터 글자가 다른 글꼴로 찍혔다.
var fonts_at: usize = 0;
var fonts_cap: u32 = 0;
fn fontsBuf() []FontMap {
    if (fonts_at == 0 or fonts_cap == 0) return &[_]FontMap{};
    return @as([*]FontMap, @ptrFromInt(fonts_at))[0..fonts_cap];
}
fn fontsRoom(want: u32) bool { return growTable(&fonts_at, &fonts_cap, want, @sizeOf(FontMap), 8); }
var font_n: u8 = 0;
var cur_font: i32 = -1;
/// 글꼴 영역에서 이번 쪽이 쓴 만큼
var font_used: u32 = 0;

var page_x0: f32 = 0;
var page_y0: f32 = 0;
var page_rotate: i32 = 0;
var page_w: f32 = 612;
var page_h: f32 = 792;
/// 이 페이지가 그린 외부 객체(대개 이미지)의 수.
/// 글자가 없는데 이것이 있으면 스캔 문서다.
var draw_count: u32 = 0;
/// 이 쪽이 가진 폼 XObject 의 수. 아직 그리지 않는다.
var form_n: u32 = 0;

/// 쪽이 쓰는 그림들.
///
/// 한 장만 꺼내 모든 Do 자리에 그리면, 도장 하나가 바코드 자리에도 찍힌다.
/// 이름으로 찾아 제 자리에 그리도록 이름과 함께 담는다.
const Img = struct {
    name: [24]u8,
    name_len: u8,
    kind: u32, // 1 RGB  2 회색  3 JPEG  4 1비트 스텐실
    w: u32,
    h: u32,
    off: u32, // img_off 로부터
    len: u32,
    flip: u8, // /Decode [1 0] — 켜고 끄는 값이 뒤집혀 있다
    smask: u8, // 부드러운 마스크가 든 칸 번호 + 1
};
/// 쪽에 놓인 그림 칸. 필요한 만큼 늘어난다(세는 상한 없음).
var imgs_at: usize = 0;
var imgs_cap: u32 = 0;
fn imgsBuf() []Img {
    if (imgs_at == 0 or imgs_cap == 0) return &[_]Img{};
    return @as([*]Img, @ptrFromInt(imgs_at))[0..imgs_cap];
}
fn imgsRoom(want: u32) bool { return growTable(&imgs_at, &imgs_cap, want, @sizeOf(Img), 16); }

/// 쪽이 쓰는 폼 XObject. 콘텐츠 스트림을 제 변환·자르기로 그린다.
const Form = struct {
    name: [24]u8,
    name_len: u8,
    obj: u32,
    mat: [6]f32,
    bbox: [4]f32,
    has_bbox: bool,
    /// /Group << /S /Transparency >> — 통째로 한 판에 그려 겹쳐야 한다
    group: bool = false,
};
/// 쪽 안에 끼운 폼 XObject. 필요한 만큼 늘어난다(세는 상한 없음).
var forms_at: usize = 0;
var forms_cap: u32 = 0;
fn formsBuf() []Form {
    if (forms_at == 0 or forms_cap == 0) return &[_]Form{};
    return @as([*]Form, @ptrFromInt(forms_at))[0..forms_cap];
}
fn formsRoom(want: u32) bool { return growTable(&forms_at, &forms_cap, want, @sizeOf(Form), 16); }
var form_n2: u32 = 0;

/// 그래픽 상태 묶음 (/ExtGState). 투명도와 선 굵기만 본다.
const GState = struct {
    name: [24]u8,
    name_len: u8,
    ca: f32,
    CA: f32,
    lw: f32,
    bm: i32, // 섞는 방식 (-1 이면 없음)
    /// 부드러운 가리개(/SMask). 그림 하나를 그려 그 밝기로 뒤엣것을 가린다.
    /// 0 이면 없음. /SMask /None 이면 sm_off 가 선다.
    sm_obj: u32,
    sm_lum: bool,
    sm_off: bool,
    sm_bc: [3]f32,
};
/// 이름 붙은 그래픽 상태. 필요한 만큼 늘어난다(세는 상한 없음).
var gstates_at: usize = 0;
var gstates_cap: u32 = 0;
fn gstatesBuf() []GState {
    if (gstates_at == 0 or gstates_cap == 0) return &[_]GState{};
    return @as([*]GState, @ptrFromInt(gstates_at))[0..gstates_cap];
}
fn gstatesRoom(want: u32) bool { return growTable(&gstates_at, &gstates_cap, want, @sizeOf(GState), 16); }
var gs_n: u32 = 0;

/// 이름 붙은 색 공간 (/ColorSpace).
///
/// 요즘 PDF 는 색을 rg·g·k 로 바로 적지 않고 색 공간을 먼저 고른 뒤
/// sc·scn 으로 값을 준다. 이걸 모르면 색이 검정으로 남아, 연한 분홍 상자가
/// 새까맣게 칠해진다.
const CS_GRAY = 0;
const CS_RGB = 1;
const CS_CMYK = 2;
const CS_TINT = 3; // Separation·DeviceN — 값이 잉크 양이라 뒤집어야 한다
const CS_PATTERN = 4;
const CS_LAB = 5; // L*a*b* — 값이 0~100 과 ±100 이라 그대로 쓰면 시뻘겋게 나온다

/// L*a*b* 를 화면 색(sRGB)으로 옮긴다.
///
/// 흰 점은 D50 으로 본다 — PDF 가 적어 두는 값이 거의 그것이고, 조금 달라도
/// 눈에 띄지 않는다. 안 옮기고 그냥 쓰면 L=100 이 빨강 100 이 되어 딴 그림이 된다.
fn labToRgb(l: f32, a: f32, bb: f32) [3]f32 {
    const fy = (l + 16) / 116;
    const fx = fy + a / 500;
    const fz = fy - bb / 200;
    const g = struct {
        fn f(t: f32) f32 {
            return if (t > 6.0 / 29.0) t * t * t else 3 * (6.0 / 29.0) * (6.0 / 29.0) * (t - 4.0 / 29.0);
        }
    }.f;
    const x = 0.9642 * g(fx);
    const y = 1.0 * g(fy);
    const z = 0.8249 * g(fz);
    var v = [3]f32{
        3.1339 * x - 1.6169 * y - 0.4906 * z,
        -0.9785 * x + 1.9160 * y + 0.0333 * z,
        0.0720 * x - 0.2290 * y + 1.4057 * z,
    };
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var c = @max(@as(f32, 0), @min(@as(f32, 1), v[i]));
        c = if (c <= 0.0031308) 12.92 * c else 1.055 * @exp2(@log2(c) / 2.4) - 0.055;
        v[i] = @max(0, @min(1, c));
    }
    return v;
}
const CSpace = struct { name: [24]u8, name_len: u8, kind: u8, comps: u8 };
/// 이름 붙은 색 공간. 필요한 만큼 늘어난다(세는 상한 없음).
var cspaces_at: usize = 0;
var cspaces_cap: u32 = 0;
fn cspacesBuf() []CSpace {
    if (cspaces_at == 0 or cspaces_cap == 0) return &[_]CSpace{};
    return @as([*]CSpace, @ptrFromInt(cspaces_at))[0..cspaces_cap];
}
fn cspacesRoom(want: u32) bool { return growTable(&cspaces_at, &cspaces_cap, want, @sizeOf(CSpace), 16); }
var cs_n: u32 = 0;

fn findCs(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < cs_n) : (i += 1)
        if (txEq(cspacesBuf()[i].name[0..cspacesBuf()[i].name_len], name)) return @intCast(i);
    return -1;
}

fn findGs(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < gs_n) : (i += 1)
        if (txEq(gstatesBuf()[i].name[0..gstatesBuf()[i].name_len], name)) return @intCast(i);
    return -1;
}

/// 부드러운 가리개를 그린다.
///
/// 가리개는 그림 하나다 — 그걸 그려 밝기(또는 불투명도)를 뽑아 뒤에 오는
/// 그림을 그 값만큼 비쳐 보이게 한다. 캔버스에는 그런 상태가 없으므로,
/// 가리개를 딴 판에 그려 두고 뒤엣것도 딴 판에 그렸다가 오려서 얹는다.
/// 글자 오려 내기와 같은 길이다.
fn emitSMask(b: []const u8, g2: *const GState, dep: u32) void {
    const body = findObj(b, g2.sm_obj) orelse return;
    const end = objDictEnd(b, body);
    emitOp(30, &[_]f32{
        if (g2.sm_lum) 1 else 0,
        g2.sm_bc[0], g2.sm_bc[1], g2.sm_bc[2],
    });
    emitOp(14, &[_]f32{});
    var mat: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
    if (readArr(b, body, end, "/Matrix", &mat) == 6)
        emitOp(16, &[_]f32{ mat[0], mat[1], mat[2], mat[3], mat[4], mat[5] });
    var bbox: [4]f32 = .{ 0, 0, 0, 0 };
    if (readArr(b, body, end, "/BBox", &bbox) == 4) {
        emitOp(5, &[_]f32{ bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1] });
        emitOp(10, &[_]f32{0});
        emitOp(9, &[_]f32{});
    }
    if (subStream(g2.sm_obj, dep)) |gs2| runOps(gs2, dep + 1);
    emitOp(15, &[_]f32{});
    emitOp(31, &[_]f32{});
}

fn findForm(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < form_n2) : (i += 1)
        if (txEq(formsBuf()[i].name[0..formsBuf()[i].name_len], name)) return @intCast(i);
    return -1;
}
var img_n: u32 = 0;
var img_used: u32 = 0;

export fn imageSlots() u32 { return img_n; }
export fn jbDbgN() u32 { return jbig2.dbg_n; }
export fn jbDbg(i: u32, k: u32) i32 { return if (i < jbig2.dbg_n and k < 5) jbig2.dbg[i][k] else 0; }
export fn jbSymN() u32 { return jbig2.sym_n; }
export fn jbSymW(i: u32) u32 { return if (i < jbig2.sym_n) jbig2.syms[i].w else 0; }
export fn slotKind(i: u32) u32 { return if (i < img_n) imgsBuf()[i].kind else 0; }
export fn slotWidth(i: u32) u32 { return if (i < img_n) imgsBuf()[i].w else 0; }
export fn slotHeight(i: u32) u32 { return if (i < img_n) imgsBuf()[i].h else 0; }
export fn slotOff(i: u32) u32 { return if (i < img_n) imgsBuf()[i].off else 0; }
export fn slotLen(i: u32) u32 { return if (i < img_n) imgsBuf()[i].len else 0; }
export fn slotFlip(i: u32) u32 { return if (i < img_n) imgsBuf()[i].flip else 0; }
export fn slotSMask(i: u32) u32 { return if (i < img_n) imgsBuf()[i].smask else 0; }

/// 그림 객체 하나를 풀어 그림 표에 담는다. 담은 칸 번호를 준다.
fn takeImage(b: []const u8, ob: usize, name: []const u8) ?u32 {
    if (!imgsRoom(img_n + 2)) return null;
    const oe = objDictEnd(b, ob);
    if (find(b[ob..oe], "/Image", 0) == null) return null;
    const w = intAfter(b, ob, oe, "/Width") orelse 0;
    const h = intAfter(b, ob, oe, "/Height") orelse 0;
    var bpc = intAfter(b, ob, oe, "/BitsPerComponent") orelse 8;
    const length = lengthOf(b, ob, oe) orelse 0;
    if (w == 0 or h == 0 or length == 0 or w > 20000 or h > 20000) return null;

    // Indexed 팔레트 — 값이 색이 아니라 표의 번호다
    var pal: [768]u8 = undefined;
    var pal_n: u32 = 0;
    if (find(b[ob..oe], "/Indexed", 0)) |ia| {
        var q = ob + ia + 8;
        // [/Indexed 바탕 최대값 팔레트]
        while (q < oe and isSpace(b[q])) q += 1;
        // 바탕 색공간을 건너뛴다
        if (q < oe and b[q] == '/') { while (q < oe and !isSpace(b[q])) q += 1; }
        else if (q < oe and b[q] == '[') { while (q < oe and b[q] != ']') q += 1; q += 1; }
        else if (q < oe and isDigit(b[q])) { _ = readUint(b, &q); while (q < oe and isSpace(b[q])) q += 1;
            if (q < oe and isDigit(b[q])) _ = readUint(b, &q);
            while (q < oe and isSpace(b[q])) q += 1;
            if (q < oe and b[q] == 'R') q += 1; }
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and isDigit(b[q])) _ = readUint(b, &q); // hival
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and b[q] == '<') {
            q += 1;
            var hi: ?u8 = null;
            while (q < oe and b[q] != '>' and pal_n < pal.len) : (q += 1) {
                const hv = hexVal(b[q]) orelse continue;
                if (hi) |hh| { pal[pal_n] = (hh << 4) | hv; pal_n += 1; hi = null; } else hi = hv;
            }
        } else if (q < oe and b[q] == '(') {
            q += 1;
            while (q < oe and b[q] != ')' and pal_n < pal.len) : (q += 1) {
                if (b[q] == '\\' and q + 1 < oe) q += 1;
                pal[pal_n] = b[q];
                pal_n += 1;
            }
        } else if (q < oe and isDigit(b[q])) {
            const pn2 = readUint(b, &q);
            if (streamOf(b, pn2)) |ps3| {
                const n3 = @min(ps3.len, pal.len);
                @memcpy(pal[0..n3], ps3[0..n3]);
                pal_n = @intCast(n3);
            }
        }
    }

    var is_mask = false;
    if (find(b[ob..oe], "/ImageMask", 0)) |ma| {
        var q = ob + ma + 10;
        while (q < oe and isSpace(b[q])) q += 1;
        if (q + 4 <= oe and std_mem_eq(b[q .. q + 4], "true")) { is_mask = true; bpc = 1; }
    }
    var flip = false;
    if (find(b[ob..oe], "/Decode", 0)) |da| {
        var q = ob + da + 7;
        while (q < oe and b[q] != '[') q += 1;
        q += 1;
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and b[q] == '1') flip = true;
    }
    const is_jpeg = find(b[ob..oe], "/DCTDecode", 0) != null;
    const is_flate = find(b[ob..oe], "/FlateDecode", 0) != null;
    const is_fax = find(b[ob..oe], "/CCITTFaxDecode", 0) != null;
    const is_jbig2 = find(b[ob..oe], "/JBIG2Decode", 0) != null;
    const unsupported = find(b[ob..oe], "/JPXDecode", 0) != null;
    var data = oe + 6;
    if (data < b.len and b[data] == '\r') data += 1;
    if (data < b.len and b[data] == '\n') data += 1;
    if (data > b.len or length > b.len - data) return null; // 넘침 없이 견준다

    const room = img_cap - img_used;
    if (room < 4096) return null;
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img_used));
    var kind: u32 = 0;
    var got: u32 = 0;
    if (is_jbig2) {
        // JBIG2 — 글자를 사전에 담고 쪽에는 자리만 적는 형식.
        // 사전이 /JBIG2Globals 에 따로 있기도 하다.
        const rb = (w + 7) / 8;
        var glob: []const u8 = &[_]u8{};
        if (find(b[ob..oe], "/JBIG2Globals", 0)) |ga| {
            var q = ob + ga + 13;
            while (q < oe and isSpace(b[q])) q += 1;
            if (q < oe and isDigit(b[q])) {
                const gn = readUint(b, &q);
                if (streamOf(b, gn)) |gd| glob = gd;
            }
        }
        if (rb * h <= room and
            blk: {
                // 스캔 문서를 만났을 때만 곳간을 잡는다. 문서마다 한 번만 —
                // 그릴 때마다 새로 잡았더니 한 쪽을 다섯 번 그리면 메모리가
                // 90MB 에서 154MB 로 늘었다(자리잡개는 되돌리지 않는다).
                if (jb_pool_at == 0) jb_pool_at = zoneAlloc(jbig2.POOL) orelse 0;
                if (jb_pool_at == 0) break :blk false;
                jbig2.setPool(jb_pool_at);
                break :blk jbig2.decode(b[data..][0..length], glob, w, h, dst[0 .. rb * h]);
            })
        {
            got = rb * h;
            kind = 4;
            // 우리 스텐실은 0 을 칠한다. JBIG2 는 1 이 검정이라 뒤집는다.
            var q2: u32 = 0;
            while (q2 < got) : (q2 += 1) dst[q2] = ~dst[q2];
        } else {
            // 못 풀면 자리만 알린다
            kind = 5;
            got = 0;
        }
    } else if (unsupported) {
        // JPEG2000. 웨이블릿으로 여러 해상도로 쪼갠 그림이라 JPEG 과는
        // 뼈대부터 다르다. 푼 결과를 RGB 로 펴서 넘긴다.
        const need = w * h * 3;
        // 화소당 스무 바이트 남짓 든다. 넉넉히 잡아 메모리를 늘린다.
        const want: usize = @as(usize, w) * h * 28 + 12 * 1024 * 1024;
        if (need + 4096 <= room) blk: {
            var jw: u32 = 0;
            var jh: u32 = 0;
            var jc: u32 = 0;
            const tmp = bigScratch(want) orelse break :blk;
            // 성분을 섞어 담을 자리는 작업 자리 앞부분을 쓴다
            const px = w * h * 4;
            if (px + 1024 < tmp.len and
                jpx.decode(b[data..][0..length], tmp[px..], tmp[0..px], &jw, &jh, &jc) and
                jw == w and jh == h)
            {
                var q3: u32 = 0;
                while (q3 < w * h) : (q3 += 1) {
                    const s3 = q3 * jc;
                    if (jc >= 4) {
                        // CMYK — 검정을 섞어 RGB 로 편다
                        const kk = @as(u32, tmp[s3 + 3]);
                        dst[q3 * 3] = @intCast(255 - @min(@as(u32, 255), 255 - @as(u32, tmp[s3]) + 255 - kk));
                        dst[q3 * 3 + 1] = @intCast(255 - @min(@as(u32, 255), 255 - @as(u32, tmp[s3 + 1]) + 255 - kk));
                        dst[q3 * 3 + 2] = @intCast(255 - @min(@as(u32, 255), 255 - @as(u32, tmp[s3 + 2]) + 255 - kk));
                    } else if (jc == 3) {
                        dst[q3 * 3] = tmp[s3];
                        dst[q3 * 3 + 1] = tmp[s3 + 1];
                        dst[q3 * 3 + 2] = tmp[s3 + 2];
                    } else {
                        dst[q3 * 3] = tmp[s3];
                        dst[q3 * 3 + 1] = tmp[s3];
                        dst[q3 * 3 + 2] = tmp[s3];
                    }
                }
                got = need;
                kind = 1;
            }
        }
        if (got == 0) {
            // 못 풀면 자리만 알린다
            kind = 5;
        }
    } else if (is_jpeg) {
        if (length <= room) {
            @memcpy(dst[0..length], b[data..][0..length]);
            got = @intCast(length);
            kind = 3;
            // 브라우저는 CMYK JPEG 을 못 푼다 — 성분이 넷이면 우리가 푼다.
            // 안 그러면 createImageBitmap 이 조용히 실패해 그림이 사라진다.
            const nfo = jpeg.probe(dst[0..got]);
            // 크기가 딕셔너리와 다르면 손대지 않는다 — 바깥이 /Width·/Height 로 읽는다
            if (nfo.comps == 4 and nfo.w == w and nfo.h == h and !nfo.progressive) {
                const px = @as(usize, nfo.w) * nfo.h;
                // 원본 뒤에 RGB 자리와 성분별 중간 자리를 잡는다
                if (got + px * 3 + px * 5 <= room) {
                    const rgb = dst[got..][0 .. px * 3];
                    const scratch = dst[got + px * 3 ..][0 .. px * 5];
                    const n2 = jpeg.decodeCmyk(dst[0..got], rgb, scratch, flip);
                    if (n2 > 0) {
                        // 앞으로 당겨 놓는다 — 바깥은 dst 앞부터 읽는다
                        var mv: usize = 0;
                        while (mv < px * 3) : (mv += 1) dst[mv] = rgb[mv];
                        got = @intCast(px * 3);
                        kind = 1;
                    }
                }
            }
        }
    } else if (is_fax) {
        // 팩스로 스캔한 그림. 1비트 스텐실과 같은 꼴로 편다.
        var kk: i32 = 0;
        if (find(b[ob..oe], "/K", 0)) |ka| {
            var q = ob + ka + 2;
            while (q < oe and isSpace(b[q])) q += 1;
            var neg = false;
            if (q < oe and b[q] == '-') { neg = true; q += 1; }
            if (q < oe and isDigit(b[q])) {
                const kv: i32 = @intCast(readUint(b, &q));
                kk = if (neg) -kv else kv;
            }
        }
        const balign = find(b[ob..oe], "/EncodedByteAlign true", 0) != null;
        // BlackIs1 이 아니면 1 이 흰색이다 — 우리 스텐실은 0 이 칠하는 쪽이라
        // 기본값에서 그대로 맞는다.
        const black1 = find(b[ob..oe], "/BlackIs1", 0) != null and
            find(b[ob..oe], "true", 0) != null;
        const rb = (w + 7) / 8;
        if (rb * h <= room and ccitt.decode(b[data..][0..length], w, h, kk, balign, dst[0 .. rb * h])) {
            got = rb * h;
            kind = 4;
            // 우리 스텐실은 0 을 칠한다. 팩스는 1 이 검정이므로 뒤집어 준다.
            if (!black1) {
                var q2: u32 = 0;
                while (q2 < got) : (q2 += 1) dst[q2] = ~dst[q2];
            }
        }
    } else if (find(b[ob..oe], "/Filter", 0) == null) {
        // 필터가 없으면 바이트가 그대로다. 우리가 입력 칸 겉모습에 심는
        // 1비트 마스크가 이 꼴이라, 우리 화면에서도 보이려면 필요하다.
        if (length <= room) {
            @memcpy(dst[0..length], b[data..][0..length]);
            got = @intCast(length);
            const rowb = (w * bpc + 7) / 8;
            if (is_mask or bpc == 1) kind = 4
            else if (bpc == 8) {
                const npx = @as(usize, w) * @as(usize, h);
                const comps = if (npx == 0) 0 else length / npx;
                kind = if (comps >= 3) 1 else if (comps >= 1) 2 else 0;
            } else kind = 0;
            if (kind != 0 and rowb * h > length) kind = 0;
        }
    } else if (is_flate or find(b[ob..oe], "/LZWDecode", 0) != null or
        find(b[ob..oe], "/RunLengthDecode", 0) != null or
        find(b[ob..oe], "/ASCII85Decode", 0) != null or
        find(b[ob..oe], "/ASCIIHexDecode", 0) != null)
    {
        const r = decodeChain(b, ob, oe, data, length, dst[0..room]);
        if (r > 0) {
            got = r;
            if (is_mask or bpc == 1) {
                kind = 4;
            } else if (bpc == 8 and pal_n >= 3) {
                // 팔레트를 펴서 RGB 로 만든다
                const n_px = @as(usize, w) * @as(usize, h);
                if (img_used + got + n_px * 3 <= img_cap and got >= n_px) {
                    const out3 = dst + got;
                    var k3: usize = 0;
                    while (k3 < n_px) : (k3 += 1) {
                        const idx = @as(usize, dst[k3]) * 3;
                        out3[k3 * 3] = if (idx + 2 < pal_n) pal[idx] else 0;
                        out3[k3 * 3 + 1] = if (idx + 2 < pal_n) pal[idx + 1] else 0;
                        out3[k3 * 3 + 2] = if (idx + 2 < pal_n) pal[idx + 2] else 0;
                    }
                    @memcpy(dst[0 .. n_px * 3], out3[0 .. n_px * 3]);
                    got = @intCast(n_px * 3);
                    kind = 1;
                }
            } else if (bpc == 8) {
                const n_px = @as(usize, w) * @as(usize, h);
                const comps = @as(usize, @intCast(r)) / (if (n_px == 0) 1 else n_px);
                if (comps >= 3) kind = 1 else if (comps >= 1) kind = 2;
            } else if (bpc == 16) {
                // 16비트는 높은 바이트만 남긴다. 화면은 8비트면 충분하고,
                // 안 펴 두면 성분 수를 잘못 세어 딴 그림이 된다.
                const half = got / 2;
                var hb: u32 = 0;
                while (hb < half) : (hb += 1) dst[hb] = dst[hb * 2];
                got = half;
                const n_px = @as(usize, w) * @as(usize, h);
                const comps = @as(usize, half) / (if (n_px == 0) 1 else n_px);
                if (comps >= 3) kind = 1 else if (comps >= 1) kind = 2;
            } else if (bpc == 2 or bpc == 4) {
                // 2·4비트 회색은 8비트로 펴 둔다
                const row_in = (w * bpc + 7) / 8;
                const need2 = w * h;
                if (img_used + got + need2 <= img_cap) {
                    const out2 = dst + got;
                    var yy: u32 = 0;
                    while (yy < h) : (yy += 1) {
                        var xx: u32 = 0;
                        while (xx < w) : (xx += 1) {
                            const bit = xx * bpc;
                            const byte = dst[yy * row_in + bit / 8];
                            const shift: u3 = @intCast(8 - bpc - (bit % 8));
                            const maxv: u32 = (@as(u32, 1) << @intCast(bpc)) - 1;
                            const v3 = (byte >> shift) & @as(u8, @intCast(maxv));
                            out2[yy * w + xx] = @intCast(@as(u32, v3) * 255 / maxv);
                        }
                    }
                    @memcpy(dst[0..need2], out2[0..need2]);
                    got = need2;
                    kind = 2;
                }
            }
        }
    }
    if (kind == 0) return null;

    const im = &imgsBuf()[img_n];
    const nl = @min(name.len, 24);
    var k: usize = 0;
    while (k < nl) : (k += 1) im.name[k] = name[k];
    im.name_len = @intCast(nl);
    im.kind = kind;
    im.w = w;
    im.h = h;
    im.off = img_used;
    im.len = got;
    im.flip = if (flip) 1 else 0;
    im.smask = 0;
    const slot = img_n;
    if (slot == 0) { img_kind = kind; img_w = w; img_h = h; img_off_first = img_used; img_len = got; }
    img_n += 1;
    img_used += (got + 3) & ~@as(u32, 3);

    // 부드러운 마스크 — 투명도가 여기 들어 있다
    if (find(b[ob..oe], "/SMask", 0)) |sa| {
        var q = ob + sa + 6;
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and isDigit(b[q])) {
            const sn = readUint(b, &q);
            if (findObj(b, sn)) |sb2| {
                if (takeImage(b, sb2, "")) |ms| imgsBuf()[slot].smask = @intCast(ms + 1);
            }
        }
    }
    // 딱딱한 가리개(/Mask). 두 꼴이 있다.
    //
    //   · 스텐실 그림을 가리키면 그 그림의 1 인 자리가 뚫린다(투명).
    //   · [최소 최대 …] 배열이면 그 범위에 든 색이 뚫린다(색 키).
    //
    // 안 보면 투명해야 할 로고가 흰 네모로 나온다.
    if (imgsBuf()[slot].smask == 0) {
        if (find(b[ob..oe], "/Mask", 0)) |ma| {
            var q = ob + ma + 5;
            while (q < oe and isSpace(b[q])) q += 1;
            if (q < oe and isDigit(b[q])) {
                const mn = readUint(b, &q);
                if (findObj(b, mn)) |mb| {
                    if (takeImage(b, mb, "")) |ms| {
                        // 스텐실은 1비트로 담겨 있고 1 이 "가린다" 는 뜻이다.
                        // 알파로 쓰려면 8비트로 펴면서 뒤집어야 한다.
                        if (stencilAlpha(ms)) |al| imgsBuf()[slot].smask = @intCast(al + 1);
                    }
                }
            } else if (q < oe and b[q] == '[' and kind != 3) {
                // 색 키 — 범위 안에 든 화소를 투명으로 만들 알파 판을 짓는다
                var lo: [8]u32 = .{0} ** 8;
                var hi: [8]u32 = .{0} ** 8;
                var nk: u32 = 0;
                q += 1;
                while (q < oe and b[q] != ']' and nk < 8) {
                    while (q < oe and isSpace(b[q])) q += 1;
                    if (q >= oe or !isDigit(b[q])) break;
                    lo[nk] = readUint(b, &q);
                    while (q < oe and isSpace(b[q])) q += 1;
                    if (q >= oe or !isDigit(b[q])) break;
                    hi[nk] = readUint(b, &q);
                    nk += 1;
                }
                if (nk > 0) colorKeyMask(slot, lo[0..nk], hi[0..nk]);
            }
        }
    }
    return slot;
}

/// 1비트 스텐실 가리개를 8비트 알파 판으로 편다.
///
/// 스텐실은 1 이 "가린다" 는 뜻이라 알파로는 0 이 된다. /Decode [1 0] 이
/// 붙어 있으면 그 뜻이 뒤집힌다.
fn stencilAlpha(mi: u32) ?u32 {
    if (mi >= img_n or !imgsRoom(img_n + 1)) return null;
    const im = imgsBuf()[mi];
    if (im.kind != 4 or im.w == 0 or im.h == 0) return null;
    const px = @as(usize, im.w) * im.h;
    if (px == 0 or px + 4 > img_cap - img_used) return null;
    const stride = (@as(usize, im.w) + 7) / 8;
    if (im.len < stride * im.h) return null;
    const src = @as([*]const u8, @ptrFromInt(imgArea() + im.off));
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img_used));
    var y: u32 = 0;
    while (y < im.h) : (y += 1) {
        var x: u32 = 0;
        while (x < im.w) : (x += 1) {
            const bit = (src[y * stride + x / 8] >> @intCast(7 - (x % 8))) & 1;
            const masked = if (im.flip == 1) bit == 0 else bit == 1;
            dst[@as(usize, y) * im.w + x] = if (masked) 0 else 255;
        }
    }
    const slot2 = img_n;
    imgsBuf()[slot2] = .{
        .name_len = 0, .name = undefined, .kind = 2, .w = im.w, .h = im.h,
        .off = img_used, .len = @intCast(px), .flip = 0, .smask = 0,
    };
    img_n += 1;
    img_used += @intCast((px + 3) & ~@as(usize, 3));
    return slot2;
}

/// 색 키 가리개 — 범위에 든 화소를 투명으로 만드는 알파 판을 새 칸에 짓는다.
fn colorKeyMask(slot: u32, lo: []const u32, hi: []const u32) void {
    if (slot >= img_n or !imgsRoom(img_n + 1)) return;
    const im = imgsBuf()[slot];
    const px = @as(usize, im.w) * im.h;
    if (px == 0 or px > img_cap - img_used) return;
    const comps: u32 = if (im.kind == 1) 3 else 1;
    if (lo.len < comps) return;
    const src = @as([*]const u8, @ptrFromInt(imgArea() + im.off));
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img_used));
    if (im.len < px * comps) return;
    var i: usize = 0;
    while (i < px) : (i += 1) {
        var inside = true;
        var c: u32 = 0;
        while (c < comps) : (c += 1) {
            const v: u32 = src[i * comps + c];
            if (v < lo[c] or v > hi[c]) { inside = false; break; }
        }
        dst[i] = if (inside) 0 else 255;
    }
    imgsBuf()[img_n] = .{
        .name_len = 0, .name = undefined, .kind = 2, .w = im.w, .h = im.h,
        .off = img_used, .len = @intCast(px), .flip = 0, .smask = 0,
    };
    imgsBuf()[slot].smask = @intCast(img_n + 1);
    img_n += 1;
    img_used += @intCast((px + 3) & ~@as(usize, 3));
}

fn findImg(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < img_n) : (i += 1)
        if (txEq(imgsBuf()[i].name[0..imgsBuf()[i].name_len], name)) return @intCast(i);
    return -1;
}

export fn itemCount() u32 { return item_n; }
export fn imageCount() u32 { return draw_count; }
export fn formCount() u32 { return form_n; }
export fn imageWidth() u32 { return img_w; }
export fn imageHeight() u32 { return img_h; }
export fn imageKind() u32 { return img_kind; }
export fn imagePtr() usize { return (if (img_off == 0) heapBase() else img_off) + img_off_first; }
export fn imageAreaPtr() usize { return if (img_off == 0) heapBase() else img_off; }
var img_off_first: u32 = 0;
export fn imageLen() usize { return img_len; }
export fn itemX(i: u32) f32 { return itemsBuf()[i].x; }
export fn itemY(i: u32) f32 { return itemsBuf()[i].y; }
export fn itemSize(i: u32) f32 { return itemsBuf()[i].size; }
export fn itemOff(i: u32) u32 { return itemsBuf()[i].off; }
/// 이 항목을 그린 글꼴 번호(1부터, 없으면 0). 이름은 fontNamePtr 로 읽는다.
export fn itemFont(i: u32) u32 {
    if (i >= item_n or itemsBuf()[i].font < 0) return 0;
    return @as(u32, @intCast(itemsBuf()[i].font)) + 1;
}
/// 세로쓰기 글꼴로 그렸나 — pdf.js 의 dir === "ttb" 자리다.
export fn itemVertical(i: u32) u32 { return if (i < item_n and itemsBuf()[i].vert) 1 else 0; }
export fn itemLen(i: u32) u32 { return itemsBuf()[i].len; }
export fn textPtr() [*]u8 { return if (text_at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(text_at); }
export fn textLen() u32 { return text_n; }
export fn drawPtr() [*]u8 { return if (dtext_at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(dtext_at); }
export fn drawLen() u32 { return dtext_n; }
export fn readPtr() [*]u8 { return if (rtext_at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(rtext_at); }
export fn readLen() u32 { return rtext_n; }
export fn fontIsPua(i: u32) u32 { return if (i < font_n and fontsBuf()[i].pua) 1 else 0; }
export fn fontKind(i: u32) u32 {
    if (i >= font_n) return 0;
    const f = &fontsBuf()[i];
    var k: u32 = f.kind;
    if (f.identity) k |= 1;
    if (f.pua) k |= 2;
    if (f.file_len > 0) k |= 4;
    if (f.n > 0) k |= 8;
    return k;
}
export fn fontNamePtr(i: u32) [*]const u8 {
    return if (i < font_n) &fontsBuf()[i].name else &fontsBuf()[0].name;
}
export fn fontNameLen(i: u32) u32 { return if (i < font_n) fontsBuf()[i].name_len else 0; }
export fn fontGlyphs(i: u32) u32 { return if (i < font_n) fontsBuf()[i].wn else 0; }
export fn fontCount() u32 { return font_n; }
export fn fontFileOff(i: u32) u32 { return if (i < font_n) fontsBuf()[i].file_off else 0; }
export fn fontFileLen(i: u32) u32 { return if (i < font_n) fontsBuf()[i].file_len else 0; }
export fn fontAreaPtr() usize { return if (font_off == 0) heapBase() else font_off; }
export fn inlinePtr() usize { return if (inl_off == 0) heapBase() else inl_off; }
export fn pageOriginX() f32 { return page_x0; }
export fn pageOriginY() f32 { return page_y0; }
export fn pageRotate() i32 { return page_rotate; }
export fn pageWidth() f32 { return page_w; }
export fn pageHeight() f32 { return page_h; }

fn isDigit(c: u8) bool { return c >= '0' and c <= '9'; }
fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn txEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| if (c != b[i]) return false;
    return true;
}
fn findIn(h: []const u8, n: []const u8, from: usize) ?usize {
    if (n.len == 0 or n.len > h.len) return null;
    var i = from;
    while (i + n.len <= h.len) : (i += 1) if (txEq(h[i .. i + n.len], n)) return i;
    return null;
}

fn readFloat(b: []const u8, p: *usize) f32 {
    while (p.* < b.len and isSpace(b[p.*])) p.* += 1;
    var neg = false;
    if (p.* < b.len and (b[p.*] == '-' or b[p.*] == '+')) {
        neg = b[p.*] == '-';
        p.* += 1;
    }
    var v: f32 = 0;
    while (p.* < b.len and isDigit(b[p.*])) : (p.* += 1)
        v = v * 10 + @as(f32, @floatFromInt(b[p.*] - '0'));
    if (p.* < b.len and b[p.*] == '.') {
        p.* += 1;
        var scale: f32 = 0.1;
        while (p.* < b.len and isDigit(b[p.*])) : (p.* += 1) {
            v += @as(f32, @floatFromInt(b[p.*] - '0')) * scale;
            scale *= 0.1;
        }
    }
    return if (neg) -v else v;
}

/// 글자층에 얹을 글자를 한 자 쓴다 (그리는 글자와 나란히 간다)
fn putRead(cp: u32) void {
    if (!rtextRoom(rtext_n + 8)) return;
    if (cp < 0x80) {
        rtextBuf()[rtext_n] = @intCast(cp);
        rtext_n += 1;
    } else if (cp < 0x800) {
        rtextBuf()[rtext_n] = @intCast(0xC0 | (cp >> 6));
        rtextBuf()[rtext_n + 1] = @intCast(0x80 | (cp & 0x3F));
        rtext_n += 2;
    } else {
        rtextBuf()[rtext_n] = @intCast(0xE0 | (cp >> 12));
        rtextBuf()[rtext_n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        rtextBuf()[rtext_n + 2] = @intCast(0x80 | (cp & 0x3F));
        rtext_n += 3;
    }
}

/// UTF-8 로 한 글자 쓴다
fn putDraw(cp: u32) void {
    if (!dtextRoom(dtext_n + 8)) return;
    if (cp < 0x80) {
        dtextBuf()[dtext_n] = @intCast(cp);
        dtext_n += 1;
    } else if (cp < 0x800) {
        dtextBuf()[dtext_n] = @intCast(0xC0 | (cp >> 6));
        dtextBuf()[dtext_n + 1] = @intCast(0x80 | (cp & 0x3F));
        dtext_n += 2;
    } else {
        dtextBuf()[dtext_n] = @intCast(0xE0 | (cp >> 12));
        dtextBuf()[dtext_n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dtextBuf()[dtext_n + 2] = @intCast(0x80 | (cp & 0x3F));
        dtext_n += 3;
    }
}

fn putUtf8(cp: u32) void {
    if (!textRoom(text_n + 8)) return;
    if (cp < 0x80) {
        textBuf()[text_n] = @intCast(cp);
        text_n += 1;
    } else if (cp < 0x800) {
        textBuf()[text_n] = @intCast(0xC0 | (cp >> 6));
        textBuf()[text_n + 1] = @intCast(0x80 | (cp & 0x3F));
        text_n += 2;
    } else {
        textBuf()[text_n] = @intCast(0xE0 | (cp >> 12));
        textBuf()[text_n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        textBuf()[text_n + 2] = @intCast(0x80 | (cp & 0x3F));
        text_n += 3;
    }
}

/// ToUnicode CMap 을 읽어 코드→유니코드 표를 채운다.
fn parseCMap(f: *FontMap, cm: []const u8) void {
    f.n = 0;
    f.two_byte = false;
    // codespacerange 의 첫 항목 길이로 코드 폭을 정한다
    if (findIn(cm, "begincodespacerange", 0)) |cs| {
        var p = cs + 19;
        while (p < cm.len and cm[p] != '<') p += 1;
        p += 1;
        var digits: u32 = 0;
        while (p < cm.len and cm[p] != '>') : (p += 1) digits += 1;
        if (digits >= 4) f.two_byte = true;
    }

    // beginbfchar: <src> <dst>
    var at: usize = 0;
    while (findIn(cm, "beginbfchar", at)) |bc| {
        var p = bc + 11;
        const end = findIn(cm, "endbfchar", p) orelse cm.len;
        while (p < end) {
            while (p < end and cm[p] != '<') p += 1;
            if (p >= end) break;
            p += 1;
            var src: u32 = 0;
            while (p < end and cm[p] != '>') : (p += 1)
                if (hexVal(cm[p])) |h| { src = (src << 4) | h; };
            p += 1;
            while (p < end and cm[p] != '<') p += 1;
            if (p >= end) break;
            p += 1;
            var dst: u32 = 0;
            var nd: u32 = 0;
            while (p < end and cm[p] != '>') : (p += 1) {
                if (hexVal(cm[p])) |h| { dst = (dst << 4) | h; nd += 1; }
                if (nd == 4) break; // 서로게이트는 앞 4자리만
            }
            while (p < end and cm[p] != '>') p += 1;
            p += 1;
            if (!mapRoom(f, f.n + 1)) break;
            u16buf(f.codes_at, f.codes_cap)[f.n] = @truncate(src);
            u16buf(f.unis_at, f.unis_cap)[f.n] = @truncate(dst);
            f.n += 1;
        }
        at = end + 1;
    }

    // beginbfrange: <lo> <hi> <dst>
    at = 0;
    while (findIn(cm, "beginbfrange", at)) |br| {
        var p = br + 12;
        const end = findIn(cm, "endbfrange", p) orelse cm.len;
        while (p < end) {
            while (p < end and cm[p] != '<') p += 1;
            if (p >= end) break;
            p += 1;
            var lo: u32 = 0;
            while (p < end and cm[p] != '>') : (p += 1)
                if (hexVal(cm[p])) |h| { lo = (lo << 4) | h; };
            p += 1;
            while (p < end and cm[p] != '<') p += 1;
            if (p >= end) break;
            p += 1;
            var hi: u32 = 0;
            while (p < end and cm[p] != '>') : (p += 1)
                if (hexVal(cm[p])) |h| { hi = (hi << 4) | h; };
            p += 1;
            while (p < end and isSpace(cm[p])) p += 1;
            if (p < end and cm[p] == '[') { // 배열형은 건너뛴다
                while (p < end and cm[p] != ']') p += 1;
                p += 1;
                continue;
            }
            while (p < end and cm[p] != '<') p += 1;
            if (p >= end) break;
            p += 1;
            var dst: u32 = 0;
            var nd: u32 = 0;
            while (p < end and cm[p] != '>') : (p += 1) {
                if (hexVal(cm[p])) |h| { dst = (dst << 4) | h; nd += 1; }
                if (nd == 4) break;
            }
            while (p < end and cm[p] != '>') p += 1;
            p += 1;
            var c = lo;
            while (c <= hi) : (c += 1) {
                if (!mapRoom(f, f.n + 1)) break;
                u16buf(f.codes_at, f.codes_cap)[f.n] = @truncate(c);
                u16buf(f.unis_at, f.unis_cap)[f.n] = @truncate(dst + (c - lo));
                f.n += 1;
            }
        }
        at = end + 1;
    }
}

fn mapCode(byte: u8) u32 {
    if (cur_font >= 0 and fontsBuf()[@intCast(cur_font)].n > 0)
        return lookup(&fontsBuf()[@intCast(cur_font)], byte);
    return byte;
}
fn mapCode2(code: u32) u32 {
    if (cur_font >= 0) return lookup(&fontsBuf()[@intCast(cur_font)], code);
    return code;
}

fn lookup(f: *const FontMap, code: u32) u32 {
    var i: u16 = 0;
    while (i < f.n) : (i += 1) if (u16buf(f.codes_at, f.codes_cap)[i] == code) return u16buf(f.unis_at, f.unis_cap)[i];
    // 표에 없으면 코드를 그대로 본다 (라틴 폰트는 대개 맞는다)
    return code;
}

export fn resetPage(w: f32, h: f32) void {
    item_n = 0;
    text_n = 0;
    dtext_n = 0;
    rtext_n = 0;
    cur_alpha = 1;
    cur_bm = 0;
    draw_count = 0;
    form_n = 0;
    form_n2 = 0;
    gs_n = 0;
    cs_n = 0;
    shade_n = 0;
    tile_n = 0;
    prop_n = 0;
    img_n = 0;
    emit_mute = false;
    run_on = false;
    field_n = 0;
    fld_used = 0;
    img_used = 0;
    inl_used = 0;
    ops_n = 0;
    font_n = 0;
    font_used = 0;
    c2g_used = 0;
    fnReset();
    cur_font = -1;
    page_w = w;
    page_h = h;
}

/// 코드→유니코드 짝을 want 개까지 담을 자리를 마련한다.
fn mapRoom(f: *FontMap, want: u32) bool {
    return growTable(&f.codes_at, &f.codes_cap, want, 2, 256) and
        growTable(&f.unis_at, &f.unis_cap, want, 2, 256);
}
/// 글자 폭 표도 같은 식으로.
fn widthRoom(f: *FontMap, want: u32) bool {
    return growTable(&f.wcodes_at, &f.wcodes_cap, want, 2, 256) and
        growTable(&f.wvals_at, &f.wvals_cap, want, 2, 256);
}

/// 폰트 하나를 등록한다. cmap 이 비어 있으면 코드=유니코드로 본다.
export fn addFont(name: [*]const u8, name_len: u32, cmap: [*]const u8, cmap_len: u32) void {
    if (!fontsRoom(font_n + 1)) return;
    const f = &fontsBuf()[font_n];
    // 이 자리는 구역에서 떼어 온 것이라, 앞서 누가 쓰던 값이 그대로 남아
    // 있다. 정적 배열이던 때는 0 으로 시작해 눈에 안 띄었다.
    @memset(@as([*]u8, @ptrCast(f))[0..@sizeOf(FontMap)], 0);
    const nl = @min(name_len, 24);
    var i: u32 = 0;
    while (i < nl) : (i += 1) f.name[i] = name[i];
    f.name_len = @intCast(nl);
    f.n = 0;
    f.two_byte = false;
    f.file_off = 0;
    f.file_len = 0;
    f.dw = 0;
    f.wn = 0;
    f.std_w = null;
    f.identity = false;
    f.vertical = false;
    f.cmap_kind = 0;
    f.cm = -1;
    f.uc = -1;
    f.c2g_off = 0;
    f.c2g_len = 0;
    f.pua = false;
    f.kind = 0;
    f.type3 = false;
    f.t1 = false;
    f.t1_cs = 0;
    f.t1_sub = 0;
    f.t1_sub_n = 0;
    @memset(&f.t1_std, 0);
    f.fm = .{ 0.001, 0, 0, 0.001, 0, 0 };
    @memset(&f.t3, 0);
    if (cmap_len > 0) parseCMap(f, cmap[0..cmap_len]);
    font_n += 1;
}

fn selectFont(name: []const u8) void {
    var i: u8 = 0;
    while (i < font_n) : (i += 1) {
        if (txEq(fontsBuf()[i].name[0..fontsBuf()[i].name_len], name)) {
            cur_font = i;
            return;
        }
    }
    cur_font = -1;
}

/// 문자열 하나를 항목으로 남긴다.
fn emit(x: f32, y: f32, size: f32, start: u32) void {
    if (!itemsRoom(item_n + 1) or text_n <= start) return;
    // CTM 을 적용한 좌표는 PDF 기준(아래가 원점)이므로 캔버스 기준으로 뒤집는다.
    // 다만 문서가 이미 위 기준으로 그리는 경우(세로 배율 음수)는 그대로 둔다.
    const cy = if (y > page_h or y < 0) y else page_h - y;
    itemsBuf()[item_n] = .{
        .x = x, .y = cy, .size = size, .off = start, .len = text_n - start,
        .font = cur_font,
        .vert = cur_font >= 0 and fontsBuf()[@intCast(cur_font)].vertical,
    };
    item_n += 1;
}

/// 콘텐츠 스트림을 훑어 글자와 위치를 모은다.
/// 2×3 아핀 행렬. PDF 의 [a b c d e f] 순서를 그대로 쓴다.
const Mat = struct {
    a: f32 = 1, b: f32 = 0, c: f32 = 0, d: f32 = 1, e: f32 = 0, f: f32 = 0,
};

/// m 을 n 에 이어 붙인다 (m 먼저, 그 다음 n).
fn matMul(m: Mat, n: Mat) Mat {
    return .{
        .a = m.a * n.a + m.b * n.c,
        .b = m.a * n.b + m.b * n.d,
        .c = m.c * n.a + m.d * n.c,
        .d = m.c * n.b + m.d * n.d,
        .e = m.e * n.a + m.f * n.c + n.e,
        .f = m.e * n.b + m.f * n.d + n.f,
    };
}

/// 콘텐츠 스트림을 그리기 명령으로 옮긴다.
///
/// PDF 는 후위 표기다 — 인자가 앞, 연산자가 뒤. 그래서 숫자는 스택에 쌓고
/// 연산자를 만났을 때 꺼내 쓴다. 예전처럼 연산자에서 뒤로 되짚어 숫자를 읽는
/// 방식은 인자 개수가 다른 연산자를 만나면 어긋난다.
/// 콘텐츠 안에 바로 박힌 그림(BI … ID … EI)을 읽는다.
///
/// Type3 글리프가 이 꼴로 들어 있는 일이 흔하다 — 크롬이 맥에서 만든 PDF 의
/// 한글이 그렇다. 건너뛰기만 해도 쓰레기는 안 나오지만, 그러면 글자가 통째로
/// 사라진다. 풀어서 그리기 명령으로 넘긴다.
/// p 는 "BI" 바로 뒤를 가리키고, 끝나면 "EI" 뒤로 옮겨 둔다.
fn inlineImage(b: []const u8, p: *usize) void {
    var w: u32 = 0;
    var h: u32 = 0;
    var bpc: u32 = 8;
    var mask = false;
    var flate = false;
    var flip = false;
    var comps: u32 = 1;

    // 딕셔너리 — 이름이 줄어 있다 (/W /H /BPC /IM /F /D /CS)
    while (p.* + 1 < b.len) {
        while (p.* < b.len and isSpace(b[p.*])) p.* += 1;
        if (p.* + 1 < b.len and b[p.*] == 'I' and b[p.* + 1] == 'D') { p.* += 2; break; }
        if (p.* >= b.len) return;
        if (b[p.*] != '/') { p.* += 1; continue; }
        const ks = p.* + 1;
        var kq = ks;
        while (kq < b.len and !isSpace(b[kq]) and b[kq] != '/' and b[kq] != '[') kq += 1;
        const key = b[ks..kq];
        p.* = kq;
        while (p.* < b.len and isSpace(b[p.*])) p.* += 1;
        if (p.* >= b.len) return;
        if (txEq(key, "W") or txEq(key, "Width")) {
            w = readUint(b, p);
        } else if (txEq(key, "H") or txEq(key, "Height")) {
            h = readUint(b, p);
        } else if (txEq(key, "BPC") or txEq(key, "BitsPerComponent")) {
            bpc = readUint(b, p);
        } else if (txEq(key, "IM") or txEq(key, "ImageMask")) {
            mask = b[p.*] == 't';
        } else if (txEq(key, "F") or txEq(key, "Filter")) {
            const fs2 = p.*;
            var fq = p.*;
            while (fq < b.len and b[fq] != '/' and !isSpace(b[fq])) fq += 1;
            _ = fs2;
            var scan = p.*;
            while (scan < b.len and b[scan] != '/') scan += 1;
            if (scan + 3 <= b.len and (std_mem_eq(b[scan .. scan + 3], "/Fl") or
                std_mem_eq(b[scan .. scan + 3], "/FD"))) flate = true;
        } else if (txEq(key, "D") or txEq(key, "Decode")) {
            // [1 0] 이면 켜고 끄는 값이 뒤집혀 있다
            var q = p.*;
            while (q < b.len and b[q] != '[') q += 1;
            q += 1;
            while (q < b.len and isSpace(b[q])) q += 1;
            if (q < b.len and b[q] == '1') flip = true;
        } else if (txEq(key, "CS") or txEq(key, "ColorSpace")) {
            var q = p.*;
            while (q < b.len and b[q] != '/') q += 1;
            if (q + 4 <= b.len and (std_mem_eq(b[q .. q + 4], "/RGB") or
                std_mem_eq(b[q .. q + 4], "/Dev"))) comps = 3;
        }
        // 값 토큰을 건너뛴다
        while (p.* < b.len and b[p.*] != '/' and !(b[p.*] == 'I' and p.* + 1 < b.len and b[p.* + 1] == 'D')) {
            if (b[p.*] == '[') { while (p.* < b.len and b[p.*] != ']') p.* += 1; }
            p.* += 1;
        }
    }
    if (p.* < b.len and isSpace(b[p.*])) p.* += 1;
    const ds = p.*;

    // 자료의 끝: 공백 뒤에 오는 EI
    var e = ds;
    while (e + 2 < b.len) : (e += 1) {
        if (!isSpace(b[e])) continue;
        if (b[e + 1] != 'E' or b[e + 2] != 'I') continue;
        if (e + 3 < b.len and !isSpace(b[e + 3]) and b[e + 3] != '/' and
            b[e + 3] != 'Q' and b[e + 3] != '[') continue;
        break;
    }
    if (e + 2 >= b.len) { p.* = b.len; return; }
    const raw = b[ds..e];
    p.* = e + 3;

    if (mask) { bpc = 1; comps = 1; }
    if (w == 0 or h == 0 or w > 8192 or h > 8192) return;
    const row = (w * bpc * comps + 7) / 8;
    const need = row * h;
    if (need == 0 or inl_used + need > inl_cap) return;

    const dst = @as([*]u8, @ptrFromInt(inlArea() + inl_used))[0..(inl_cap - inl_used)];
    var got: u32 = 0;
    if (flate) {
        const r = pw_inflate(raw.ptr, @intCast(raw.len), dst.ptr, @intCast(dst.len));
        if (r <= 0) return;
        got = @intCast(r);
    } else {
        if (raw.len > dst.len) return;
        @memcpy(dst[0..raw.len], raw);
        got = @intCast(raw.len);
    }
    if (got < need) return;

    emitOp(22, &[_]f32{
        @floatFromInt(w), @floatFromInt(h), @floatFromInt(bpc),
        if (mask) 1 else 0,
        @floatFromInt(inl_used), @floatFromInt(need),
        if (flip) 1 else 0, @floatFromInt(comps),
    });
    inl_used += need;
}

/// 문서 전체 (폼·글리프 그림을 꺼내려면 필요하다)
var doc: []const u8 = &[_]u8{};

/// 겹쳐 부르는 스트림을 담을 자리. 깊이마다 따로 둔다 — 같은 자리를 쓰면
/// 바깥에서 훑던 내용이 안쪽에서 덮인다.
fn subStream(num: u32, depth: u32) ?[]const u8 {
    if (depth >= 3 or subArea() == 0) return null;
    const slot = sub_cap / 3;
    const cs = streamOf(doc, num) orelse return null;
    const n = @min(cs.len, slot);
    const dst = @as([*]u8, @ptrFromInt(subArea() + depth * slot));
    @memcpy(dst[0..n], cs[0..n]);
    return dst[0..n];
}

export fn runContent(buf: [*]const u8, len: u32) u32 {
    runOps(buf[0..len], 0);
    return item_n;
}

fn runOps(b: []const u8, depth: u32) void {
    var p: usize = 0;

    var st: [32]f32 = undefined;
    var sp: usize = 0;
    const push = struct {
        fn f(stk: *[32]f32, n: *usize, v: f32) void {
            if (n.* < stk.len) { stk[n.*] = v; n.* += 1; }
        }
    }.f;

    // 텍스트 상태
    var tf_size: f32 = 12;
    var tm = Mat{};
    var tlm = Mat{}; // 줄 시작 행렬
    var lead: f32 = 0;
    var tc: f32 = 0; // 자간
    var tw: f32 = 0; // 낱말 사이
    var th: f32 = 1; // 가로 비율
    var in_arr = false; // TJ 배열 안인가
    var mc_depth: u32 = 0; // 표시 구간 깊이
    var hide_at: u32 = 0; // 숨기기 시작한 깊이 (0 이면 안 숨김)
    var cur_cs_f: i32 = -1;
    var cur_cs_s: i32 = -1;
    var t_render: i32 = 0; // Tr — 3·7 은 안 보이는 글자다
    // 이 글자 묶음이 오려 내기를 쓰는가 (Tr 4~7)
    var t_clip = false;
    var t_rise: f32 = 0; // Ts
    var pending_tile: i32 = -1; // 채울 때 깔 타일 무늬
    var name_buf: [32]u8 = undefined;
    var name_len: usize = 0;
    var pending_clip: f32 = -1; // 0=nonzero 1=evenodd

    while (p < b.len) {
        const c = b[p];

        // 공백
        if (isSpace(c)) { p += 1; continue; }

        // 주석
        if (c == '%') {
            while (p < b.len and b[p] != '\n') p += 1;
            continue;
        }

        // 숫자
        if ((c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.') {
            var q = p;
            const v = readFloat(b, &q);
            if (q == p) { p += 1; continue; }
            push(&st, &sp, v);
            p = q;
            continue;
        }

        // 이름 — 다음 연산자가 쓴다
        if (c == '/') {
            var q = p + 1;
            name_len = 0;
            while (q < b.len and !isSpace(b[q]) and b[q] != '/' and b[q] != '[' and
                b[q] != '(' and b[q] != '<' and b[q] != ']' and b[q] != '>' and
                name_len < name_buf.len) : (q += 1)
            {
                name_buf[name_len] = b[q];
                name_len += 1;
            }
            p = q;
            continue;
        }

        // 문자열 — 곧바로 글자로 옮긴다
        if (c == '(' or (c == '<' and p + 1 < b.len and b[p + 1] != '<')) {
            // TJ 배열에서 문자열 앞에 오는 숫자는 자리를 당기는 조정값이다.
            if (in_arr and sp > 0) {
                var adj: f32 = 0;
                var ai: usize = 0;
                while (ai < sp) : (ai += 1) adj += st[ai];
                sp = 0;
                tm = matMul(.{ .e = -adj / 1000 * tf_size * th, .f = 0 }, tm);
            }
            // ' 와 " 는 줄을 먼저 넘기고 글자를 찍는다. 우리는 글자를 만나는
            // 자리에서 바로 그리므로, 뒤에 오는 연산자를 미리 본다.
            {
                var q2 = p;
                // 문자열 끝을 찾아 그 뒤의 연산자를 엿본다
                var depth2: u32 = 0;
                if (c == '(') {
                    depth2 = 1;
                    q2 = p + 1;
                    while (q2 < b.len and depth2 > 0) : (q2 += 1) {
                        if (b[q2] == '\\') { q2 += 1; continue; }
                        if (b[q2] == '(') depth2 += 1;
                        if (b[q2] == ')') depth2 -= 1;
                    }
                } else {
                    q2 = p + 1;
                    while (q2 < b.len and b[q2] != '>') q2 += 1;
                    q2 += 1;
                }
                while (q2 < b.len and isSpace(b[q2])) q2 += 1;
                if (q2 < b.len and (b[q2] == '\'' or b[q2] == '"')) {
                    if (b[q2] == '"' and sp >= 2) { tw = st[0]; tc = st[1]; }
                    tlm = matMul(.{ .e = 0, .f = -lead }, tlm);
                    tm = tlm;
                }
            }
            const fp: ?*const FontMap = if (cur_font >= 0) &fontsBuf()[@intCast(cur_font)] else null;
            const start_text = text_n;
            const x0 = tm.e;
            const y0 = tm.f;

            // 글자 하나마다 명령을 낸다.
            //
            // 문자열을 통째로 한 번에 찍으면 글꼴이 바뀌었을 때 자리가 어긋난다.
            // 폭이 좁은 글꼴을 시스템 글꼴로 대신 그리면 글자들이 겹쳐 뭉개진다.
            // PDF 가 정한 자리에 하나씩 찍고, 칸보다 넓으면 캔버스 쪽에서
            // 가로로 눌러 넣는다.
            const emitGlyph = struct {
                fn f(
                    ff: ?*const FontMap, code: u32, uni: u32,
                    size: f32, m: *Mat, cf: i32,
                    tc2: f32, tw2: f32, th2: f32, dep: u32,
                    mode: i32, rise: f32,
                ) void {
                    putUtf8(uni);
                    const adv = step(ff, code, size, tc2, tw2, th2);
                    // Tr 3 은 안 보이는 글자, 7 은 오려 내기용이다. 둘 다
                    // 화면에는 안 그리지만 명령은 낸다 — 3 은 스캔 문서 위에
                    // 얹힌 OCR 결과라 긁어 복사할 수 있어야 하고, 7 은 글자
                    // 모양으로 오려 내려면 모양이 있어야 한다. 그리지 않는
                    // 것은 캔버스 쪽이 판단한다.
                    // Ts 는 글자를 기준선 위아래로 올린다
                    const ex2 = m.e + m.c * rise;
                    const ey2 = m.f + m.d * rise;
                    // Type1 은 글리프가 외곽선 프로그램이다. 그 자리에 그린다.
                    if (ff) |g| {
                        if (g.t1 and code < 256 and t1_pool[g.t1_cs + code].len > 0) {
                            runFlush();
                            emitOp(14, &[_]f32{});
                            emitOp(16, &[_]f32{ m.a, m.b, m.c, m.d, ex2, ey2 });
                            emitOp(16, &[_]f32{ size * th2, 0, 0, size, 0, 0 });
                            emitOp(16, &[_]f32{ g.fm[0], g.fm[1], g.fm[2], g.fm[3], g.fm[4], g.fm[5] });
                            const ok = drawType1(g, code);
                            emitOp(15, &[_]f32{});
                            if (ok) {
                                m.* = advance(ff, adv, m.*);
                                return;
                            }
                        }
                    }
                    // Type3 는 글리프가 그림이다. 그 자리에 펼쳐 그린다.
                    if (ff) |g| {
                        if (g.type3 and code < 256 and g.t3[code] != 0) {
                            if (subStream(g.t3[code], dep)) |gs| {
                                runFlush();
                                emitOp(14, &[_]f32{});
                                emitOp(16, &[_]f32{ m.a, m.b, m.c, m.d, ex2, ey2 });
                                emitOp(16, &[_]f32{ size * th2, 0, 0, size, 0, 0 });
                                emitOp(16, &[_]f32{ g.fm[0], g.fm[1], g.fm[2], g.fm[3], g.fm[4], g.fm[5] });
                                runOps(gs, dep + 1);
                                emitOp(15, &[_]f32{});
                                m.* = advance(ff, adv, m.*);
                                return;
                            }
                        }
                    }
                    // 이어지는 글자는 한 묶음으로 모은다. 글꼴·크기·기울기·
                    // 그리기 방식이 바뀌면 거기서 끊는다.
                    if (run_on and (run_font != cf or run_size != size or run_mode != mode or
                        run_m[0] != m.a or run_m[1] != m.b or run_m[2] != m.c or run_m[3] != m.d))
                    {
                        runFlush();
                    }
                    if (!run_on) {
                        run_on = true;
                        run_x = ex2;
                        run_y = ey2;
                        run_size = size;
                        run_m = .{ m.a, m.b, m.c, m.d };
                        run_off = dtext_n;
                        run_roff = rtext_n;
                        run_adv = 0;
                        run_font = cf;
                        run_mode = mode;
                    }
                    // 사용자 영역은 U+E000~U+F8FF 6400 자리뿐이다
                    // 번호로 집는 글꼴은 CID 가 아니라 글리프 번호로 집는다
                    const gid = if (ff) |g| cidToGid(g, code) else code;
                    const pua = if (ff) |g| g.pua and gid < 6400 else false;
                    putDraw(if (pua) 0xE000 + gid else uni);
                    // 글자층은 읽을 수 있는 쪽을 쓴다. 되찾지 못한 글자는
                    // 자리만 지키게 빈칸으로 둔다 — 안 그러면 뒤 글자가 밀린다.
                    putRead(if (uni >= 0x20 and uni != 0xFFFD) uni else ' ');
                    run_adv += adv;
                    m.* = advance(ff, adv, m.*);
                    // 세로쓰기는 글자마다 자리가 아래로 내려간다. 묶어서
                    // 내보내면 글자층이 가로로 눕는다 — 한 자씩 끊는다.
                    if (ff) |g3| if (g3.vertical) runFlush();
                }
            }.f;

            // 문자열의 날바이트를 먼저 모은다. 코드가 몇 바이트인지는
            // 글꼴의 CMap 갈래가 정한다 — EUC·UHC 는 앞바이트를 봐야 안다.
            var sbuf: [4096]u8 = undefined;
            var sn: usize = 0;
            if (c == '(') {
                p += 1;
                var nest: u32 = 1;
                while (p < b.len and sn < sbuf.len) : (p += 1) {
                    if (b[p] == '\\' and p + 1 < b.len) {
                        p += 1;
                        if (b[p] >= '0' and b[p] <= '7') {
                            var v3: u32 = 0;
                            var d3: u32 = 0;
                            while (d3 < 3 and p < b.len and b[p] >= '0' and b[p] <= '7') : (d3 += 1) {
                                v3 = v3 * 8 + (b[p] - '0');
                                p += 1;
                            }
                            p -= 1;
                            sbuf[sn] = @truncate(v3);
                            sn += 1;
                            continue;
                        }
                        sbuf[sn] = switch (b[p]) { 'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p] };
                        sn += 1;
                        continue;
                    }
                    if (b[p] == '(') nest += 1;
                    if (b[p] == ')') { nest -= 1; if (nest == 0) break; }
                    sbuf[sn] = b[p];
                    sn += 1;
                }
                p += 1;
            } else {
                p += 1;
                var hi: ?u8 = null;
                while (p < b.len and b[p] != '>' and sn < sbuf.len) : (p += 1) {
                    const hv = hexVal(b[p]) orelse continue;
                    if (hi) |h| { sbuf[sn] = (h << 4) | hv; sn += 1; hi = null; } else hi = hv;
                }
                if (hi) |h| { if (sn < sbuf.len) { sbuf[sn] = h << 4; sn += 1; } }
                p += 1;
            }
            {
                var k: usize = 0;
                while (k < sn) {
                    var w = codeLen(fp, sbuf[k]);
                    if (k + w > sn) w = @intCast(sn - k);
                    var code: u32 = 0;
                    var j: usize = 0;
                    while (j < w) : (j += 1) code = (code << 8) | sbuf[k + j];
                    // 미리 정의된 CMap 은 코드와 CID 가 다르다. 폭도 글리프도
                    // CID 로 찾아야 한다. 글자는 ToUnicode 가 코드로 준다.
                    const cid = toCid(fp, code);
                    var uni = if (w >= 2) mapCode2(code) else mapCode(@truncate(code));
                    // ToUnicode 가 없으면 CID 로 글자를 찾는다
                    if (uni == code) {
                        if (cidUni(fp, cid)) |uv| uni = uv;
                    }
                    emitGlyph(fp, cid, uni, tf_size, &tm, cur_font, tc, tw, th, depth, t_render, t_rise);
                    k += w;
                }
            }
            runFlush();
            // 뽑아 둔 글자는 문자열 단위로 묶는다 — 나중에 본문 검색에 쓴다
            if (text_n > start_text and itemsRoom(item_n + 1)) {
                itemsBuf()[item_n] = .{
                    .x = x0, .y = y0, .size = tf_size,
                    .off = start_text, .len = text_n - start_text,
                    // 어떤 글꼴로 그렸는지·세로쓰기인지도 함께 남긴다
                    .font = cur_font,
                    .vert = cur_font >= 0 and fontsBuf()[@intCast(cur_font)].vertical,
                };
                item_n += 1;
            }
            continue;
        }

        // 배열 — TJ 의 조정값은 자간이라 여기서는 건너뛴다
        if (c == '[') { in_arr = true; sp = 0; p += 1; continue; }
        if (c == ']') { in_arr = false; p += 1; continue; }
        // 딕셔너리 괄호는 두 글자를 한꺼번에 넘긴다.
        //
        // 한 글자씩 넘기면 << 의 둘째 < 가 16진 문자열의 시작으로 보인다.
        // BDC 의 <</MCID 299 >> 가 통째로 글자가 되어, 라벨마다 "Í0" 같은
        // 군더더기가 찍히고 글자 자리까지 밀렸다.
        if (c == '<' and p + 1 < b.len and b[p + 1] == '<') { p += 2; continue; }
        if (c == '>' and p + 1 < b.len and b[p + 1] == '>') { p += 2; continue; }
        if (c == '<' or c == '>') { p += 1; continue; }
        if (c == '{' or c == '}') { p += 1; continue; }

        // 연산자
        var q = p;
        var opb: [4]u8 = undefined;
        var opl: usize = 0;
        while (q < b.len and !isSpace(b[q]) and b[q] != '/' and b[q] != '[' and
            b[q] != '(' and b[q] != '<' and opl < 4) : (q += 1)
        {
            opb[opl] = b[q];
            opl += 1;
        }
        if (opl == 0) { p += 1; continue; }
        const op = opb[0..opl];
        p = q;

        const eqs = struct {
            fn f(a: []const u8, x: []const u8) bool {
                if (a.len != x.len) return false;
                for (a, 0..) |ch, i| if (ch != x[i]) return false;
                return true;
            }
        }.f;

        if (eqs(op, "q")) emitOp(14, &[_]f32{})
        else if (eqs(op, "Q")) emitOp(15, &[_]f32{})
        else if (eqs(op, "cm") and sp >= 6)
            emitOp(16, &[_]f32{ st[0], st[1], st[2], st[3], st[4], st[5] })
        else if (eqs(op, "m") and sp >= 2) { pathTouch(st[0], st[1]); emitOp(1, &[_]f32{ st[0], st[1] }); }
        else if (eqs(op, "l") and sp >= 2) { pathTouch(st[0], st[1]); emitOp(2, &[_]f32{ st[0], st[1] }); }
        else if (eqs(op, "c") and sp >= 6) { pathTouch(st[0], st[1]); pathTouch(st[4], st[5]); emitOp(3, &[_]f32{ st[0], st[1], st[2], st[3], st[4], st[5] }); }
        else if (eqs(op, "v") and sp >= 4)
            // 시작점을 첫 제어점으로 쓰는 축약형. 캔버스에는 3차로 편다.
            emitOp(3, &[_]f32{ st[0], st[1], st[0], st[1], st[2], st[3] })
        else if (eqs(op, "y") and sp >= 4)
            emitOp(3, &[_]f32{ st[0], st[1], st[2], st[3], st[2], st[3] })
        else if (eqs(op, "h")) emitOp(4, &[_]f32{})
        else if (eqs(op, "re") and sp >= 4) {
            pathTouch(st[0], st[1]);
            pathTouch(st[0] + st[2], st[1] + st[3]);
            emitOp(5, &[_]f32{ st[0], st[1], st[2], st[3] });
        }
        else if (eqs(op, "f") or eqs(op, "F")) {
            if (pending_tile >= 0) { paintTile(@intCast(pending_tile), depth); pending_tile = -1; } else emitOp(6, &[_]f32{0});
            pathReset();
            if (pending_clip >= 0) { emitOp(10, &[_]f32{pending_clip}); pending_clip = -1; }
        }
        else if (eqs(op, "f*")) { emitOp(6, &[_]f32{1}); if (pending_clip >= 0) { emitOp(10, &[_]f32{pending_clip}); pending_clip = -1; } }
        else if (eqs(op, "S")) { emitOp(7, &[_]f32{}); if (pending_clip >= 0) { emitOp(10, &[_]f32{pending_clip}); pending_clip = -1; } }
        else if (eqs(op, "s")) { emitOp(4, &[_]f32{}); emitOp(7, &[_]f32{}); }
        else if (eqs(op, "B")) emitOp(8, &[_]f32{0})
        else if (eqs(op, "B*")) emitOp(8, &[_]f32{1})
        else if (eqs(op, "b")) { emitOp(4, &[_]f32{}); emitOp(8, &[_]f32{0}); }
        else if (eqs(op, "b*")) { emitOp(4, &[_]f32{}); emitOp(8, &[_]f32{1}); }
        else if (eqs(op, "n")) {
            if (pending_clip >= 0) { emitOp(10, &[_]f32{pending_clip}); pending_clip = -1; }
            else emitOp(9, &[_]f32{});
        }
        else if (eqs(op, "W")) pending_clip = 0
        else if (eqs(op, "W*")) pending_clip = 1
        else if (eqs(op, "rg") and sp >= 3) { pending_tile = -1; emitOp(11, &[_]f32{ st[0], st[1], st[2] }); }
        else if (eqs(op, "RG") and sp >= 3) emitOp(12, &[_]f32{ st[0], st[1], st[2] })
        else if (eqs(op, "g") and sp >= 1) { pending_tile = -1; emitOp(11, &[_]f32{ st[0], st[0], st[0] }); }
        else if (eqs(op, "G") and sp >= 1) emitOp(12, &[_]f32{ st[0], st[0], st[0] })
        else if (eqs(op, "k") and sp >= 4) {
            // CMYK → RGB. 정확한 변환은 색 프로파일이 필요하지만 화면용으로는
            // 이 근사로 충분하다.
            const r = (1 - @min(st[0] + st[3], 1));
            const g2 = (1 - @min(st[1] + st[3], 1));
            const bl = (1 - @min(st[2] + st[3], 1));
            emitOp(11, &[_]f32{ r, g2, bl });
        }
        else if (eqs(op, "K") and sp >= 4) {
            const r = (1 - @min(st[0] + st[3], 1));
            const g2 = (1 - @min(st[1] + st[3], 1));
            const bl = (1 - @min(st[2] + st[3], 1));
            emitOp(12, &[_]f32{ r, g2, bl });
        }
        else if (eqs(op, "w") and sp >= 1) emitOp(13, &[_]f32{st[0]})
        else if (eqs(op, "J") and sp >= 1) emitOp(19, &[_]f32{st[0]})
        else if (eqs(op, "j") and sp >= 1) emitOp(20, &[_]f32{st[0]})
        else if (eqs(op, "BT")) { tm = Mat{}; tlm = Mat{}; t_clip = false; }
        else if (eqs(op, "Tr") and sp >= 1) {
            t_render = @intFromFloat(st[0]);
            // Tr 4~7 은 글자 모양으로 오려 낸다 — ET 에서 알려 준다
            if (t_render >= 4) t_clip = true;
        }
        else if (eqs(op, "Ts") and sp >= 1) t_rise = st[0]
        else if (eqs(op, "M") and sp >= 1) emitOp(25, &[_]f32{st[0]})
        else if (eqs(op, "Tc") and sp >= 1) tc = st[0]
        else if (eqs(op, "Tw") and sp >= 1) tw = st[0]
        else if (eqs(op, "Tz") and sp >= 1) th = st[0] / 100
        else if (eqs(op, "ET")) {
            if (t_clip) { emitOp(29, &[_]f32{}); t_clip = false; }
        }
        else if (eqs(op, "Tf") and sp >= 1) {
            selectFont(name_buf[0..name_len]);
            tf_size = st[sp - 1];
        }
        else if (eqs(op, "Tm") and sp >= 6) {
            tm = .{ .a = st[0], .b = st[1], .c = st[2], .d = st[3], .e = st[4], .f = st[5] };
            tlm = tm;
        }
        else if (eqs(op, "Td") and sp >= 2) {
            tlm = matMul(.{ .e = st[0], .f = st[1] }, tlm);
            tm = tlm;
        }
        else if (eqs(op, "TD") and sp >= 2) {
            lead = -st[1];
            tlm = matMul(.{ .e = st[0], .f = st[1] }, tlm);
            tm = tlm;
        }
        else if (eqs(op, "TL") and sp >= 1) lead = st[0]
        else if (eqs(op, "T*")) {
            tlm = matMul(.{ .e = 0, .f = -lead }, tlm);
            tm = tlm;
        }
        else if (eqs(op, "BDC") or eqs(op, "BMC")) {
            mc_depth += 1;
            // /OC /이름 BDC — 꺼 놓은 레이어면 EMC 까지 그리지 않는다
            if (hide_at == 0 and name_len > 0) {
                const ob8 = propObj(name_buf[0..name_len]);
                if (ob8 != 0 and ocgHidden(ob8)) {
                    hide_at = mc_depth;
                    emit_mute = true;
                }
            }
        }
        else if (eqs(op, "EMC")) {
            if (hide_at != 0 and mc_depth == hide_at) {
                hide_at = 0;
                emit_mute = false;
            }
            if (mc_depth > 0) mc_depth -= 1;
        }
        else if (eqs(op, "sh")) {
            const si = findShade(name_buf[0..name_len]);
            if (si >= 0) emitShade(&shadesBuf()[@intCast(si)], 27);
        }
        else if (eqs(op, "cs") or eqs(op, "CS")) {
            const ci = findCs(name_buf[0..name_len]);
            const stroke = op[0] == 'C';
            if (stroke) cur_cs_s = ci else cur_cs_f = ci;
            // 색 공간을 바꾸면 색은 검정(또는 첫 성분 0)으로 되돌아간다
            const k = if (ci >= 0) cspacesBuf()[@intCast(ci)].kind else CS_RGB;
            if (k != CS_PATTERN) emitOp(if (stroke) 12 else 11, &[_]f32{ 0, 0, 0 });
        }
        else if (eqs(op, "sc") or eqs(op, "scn") or eqs(op, "SC") or eqs(op, "SCN")) {
            const stroke = op[0] == 'S';
            const ci = if (stroke) cur_cs_s else cur_cs_f;
            const kind: u8 = if (ci >= 0) cspacesBuf()[@intCast(ci)].kind else CS_RGB;
            var r: f32 = 0;
            var g2: f32 = 0;
            var b3: f32 = 0;
            var ok = true;
            if (kind == CS_PATTERN or sp == 0) {
                const si = findShade(name_buf[0..name_len]);
                if (si >= 0 and !stroke) {
                    // 셰이딩 무늬 — 채우기 색 대신 그라데이션을 건다
                    emitShade(&shadesBuf()[@intCast(si)], 28);
                    sp = 0;
                    continue;
                }
                const ti = findTile(name_buf[0..name_len]);
                if (ti >= 0) {
                    if (!stroke and tilesBuf()[@intCast(ti)].obj != 0 and depth < 2) {
                        pending_tile = ti;
                    }
                    r = tilesBuf()[@intCast(ti)].r;
                    g2 = tilesBuf()[@intCast(ti)].g;
                    b3 = tilesBuf()[@intCast(ti)].b;
                } else {
                    r = 0.6;
                    g2 = 0.6;
                    b3 = 0.6;
                }
            } else if (sp >= 4) {
                const cy = st[sp - 4];
                const m = st[sp - 3];
                const y2 = st[sp - 2];
                const k2 = st[sp - 1];
                r = (1 - @min(@as(f32, 1), cy + k2));
                g2 = (1 - @min(@as(f32, 1), m + k2));
                b3 = (1 - @min(@as(f32, 1), y2 + k2));
            } else if (kind == CS_LAB and sp >= 3) {
                const v = labToRgb(st[sp - 3], st[sp - 2], st[sp - 1]);
                r = v[0];
                g2 = v[1];
                b3 = v[2];
            } else if (sp >= 3) {
                r = st[sp - 3];
                g2 = st[sp - 2];
                b3 = st[sp - 1];
            } else if (sp >= 1) {
                const v2 = st[sp - 1];
                const gv = if (kind == CS_TINT) 1 - v2 else v2;
                r = gv;
                g2 = gv;
                b3 = gv;
            } else ok = false;
            if (ok) emitOp(if (stroke) 12 else 11, &[_]f32{ r, g2, b3 });
        }
        else if (eqs(op, "gs")) {
            const gi = findGs(name_buf[0..name_len]);
            if (gi >= 0) {
                const g2 = &gstatesBuf()[@intCast(gi)];
                if (g2.ca >= 0) { emitOp(21, &[_]f32{g2.ca}); cur_alpha = g2.ca; }
                if (g2.CA >= 0) emitOp(23, &[_]f32{g2.CA});
                if (g2.lw >= 0) emitOp(13, &[_]f32{g2.lw});
                if (g2.bm >= 0) { emitOp(26, &[_]f32{@floatFromInt(g2.bm)}); cur_bm = g2.bm; }
                if (g2.sm_off) emitOp(32, &[_]f32{});
                if (g2.sm_obj != 0 and depth < 2) emitSMask(doc, g2, depth);
            }
        }
        else if (eqs(op, "d")) {
            // [a b ...] phase — 앞의 값들이 스택에 그대로 쌓여 있다
            var n2: usize = if (sp > 0) sp - 1 else 0;
            if (n2 > 6) n2 = 6;
            var arr: [8]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
            arr[0] = @floatFromInt(n2);
            var di: usize = 0;
            while (di < n2) : (di += 1) arr[di + 1] = st[di];
            arr[7] = if (sp > 0) st[sp - 1] else 0;
            emitOp(24, arr[0..8]);
        }
        else if (eqs(op, "BI")) { inlineImage(b, &p); sp = 0; continue; }
        else if (eqs(op, "Do")) {
            draw_count += 1;
            const nm2 = name_buf[0..name_len];
            const fi = findForm(nm2);
            if (fi >= 0 and depth < 2) {
                // 폼 XObject — 제 변환을 걸고 BBox 로 자른 뒤 안을 그린다
                const fo = &formsBuf()[@intCast(fi)];
                // 투명 그룹은 통째로 딴 판에 그려 한 번에 겹친다. 안 그러면
                // 겹친 것끼리 각자 투명해져 겹친 데가 더 진해진다.
                const grp = fo.group and (cur_alpha < 0.999 or cur_bm > 0);
                if (grp) emitOp(33, &[_]f32{ cur_alpha, @floatFromInt(cur_bm) });
                emitOp(14, &[_]f32{});
                emitOp(16, &[_]f32{ fo.mat[0], fo.mat[1], fo.mat[2], fo.mat[3], fo.mat[4], fo.mat[5] });
                if (fo.has_bbox) {
                    emitOp(5, &[_]f32{
                        fo.bbox[0], fo.bbox[1],
                        fo.bbox[2] - fo.bbox[0], fo.bbox[3] - fo.bbox[1],
                    });
                    emitOp(10, &[_]f32{0});
                    emitOp(9, &[_]f32{});
                }
                if (subStream(fo.obj, depth)) |fs2| runOps(fs2, depth + 1);
                emitOp(15, &[_]f32{});
                if (grp) emitOp(34, &[_]f32{});
            } else {
                emitOp(18, &[_]f32{@floatFromInt(@max(0, findImg(nm2) + 1))});
            }
        }
        sp = 0;
    }
}


/// 쪽에 없으면 /Parent 를 타고 올라가 찾는다.
/// MediaBox·Resources·Rotate 는 상위 Pages 에 적혀 있기도 하다.
const Inh = struct { s: usize, e: usize, at: usize };
fn inheritedKey(b: []const u8, body0: usize, end0: usize, key: []const u8) ?Inh {
    var s2 = body0;
    var e2 = end0;
    var d: u32 = 0;
    while (d < 8) : (d += 1) {
        if (find(b[s2..e2], key, 0)) |at| return .{ .s = s2, .e = e2, .at = s2 + at };
        const pa = find(b[s2..e2], "/Parent", 0) orelse return null;
        var p = s2 + pa + 7;
        while (p < e2 and isSpace(b[p])) p += 1;
        if (p >= e2 or !isDigit(b[p])) return null;
        const pn = readUint(b, &p);
        const pb = findObj(b, pn) orelse return null;
        s2 = pb;
        e2 = find(b, "endobj", pb) orelse b.len;
    }
    return null;
}

/// 리소스 딕셔너리를 훑어 글꼴·그림·폼을 등록한다.
///
/// 폼 XObject 는 제 리소스를 따로 갖는다. 그 안의 글꼴도 등록해 두어야
/// 폼을 그릴 때 글자가 나온다.
fn scanResources(b: []const u8, rs: usize, re_: usize, depth: u32) void {
    // Shading 과 Pattern
    for ([_][]const u8{ "/Shading", "/Pattern" }) |key| {
        const ka = find(b[rs..re_], key, 0) orelse continue;
        var p = rs + ka + key.len;
        while (p < re_ and isSpace(b[p])) p += 1;
        var ss = p;
        var se3 = re_;
        if (p < re_ and b[p] == '<') {
            se3 = dictEnd(b, p, re_);
        } else if (p < re_ and isDigit(b[p])) {
            const sn = readUint(b, &p);
            if (findObj(b, sn)) |sb| {
                ss = sb;
                se3 = find(b, "endobj", sb) orelse b.len;
            }
        } else continue;
        var q = ss;
        while (q < se3) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            while (nq < se3 and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>' and b[nq] != '<') nq += 1;
            const nm5 = b[q + 1 .. nq];
            var vp = nq;
            while (vp < se3 and isSpace(b[vp])) vp += 1;
            var ds: usize = 0;
            var de3: usize = 0;
            if (vp < se3 and b[vp] == '<') {
                ds = vp;
                de3 = dictEnd(b, vp, se3);
            } else if (vp < se3 and isDigit(b[vp])) {
                const on5 = readUint(b, &vp);
                if (findObj(b, on5)) |ob5| {
                    ds = ob5;
                    de3 = objDictEnd(b, ob5);
                }
            }
            if (de3 > ds and nm5.len > 0) {
                if (intAfter(b, ds, de3, "/PatternType")) |pt| {
                    if (pt == 2) {
                        // 셰이딩 무늬 — 안의 /Shading 을 무늬 이름으로 등록한다
                        if (find(b[ds..de3], "/Shading", 0)) |sa2| {
                            var sp2 = ds + sa2 + 8;
                            while (sp2 < de3 and isSpace(b[sp2])) sp2 += 1;
                            if (sp2 < de3 and b[sp2] == '<') {
                                readShade(b, sp2, dictEnd(b, sp2, de3), nm5);
                            } else if (sp2 < de3 and isDigit(b[sp2])) {
                                const s2n = readUint(b, &sp2);
                                if (findObj(b, s2n)) |s2b| {
                                    readShade(b, s2b, find(b, "endobj", s2b) orelse b.len, nm5);
                                }
                            }
                        }
                    } else if (pt == 1 and tilesRoom(tile_n + 1)) {
                        // 타일 무늬 — 안에서 처음 나오는 색을 대표로 쓴다
                        const t2 = &tilesBuf()[tile_n];
                        const nl5 = @min(nm5.len, 24);
                        var k5: usize = 0;
                        while (k5 < nl5) : (k5 += 1) t2.name[k5] = nm5[k5];
                        t2.name_len = @intCast(nl5);
                        t2.r = 0.6;
                        t2.g = 0.6;
                        t2.b = 0.6;
                        t2.obj = 0;
                        t2.mat = .{ 1, 0, 0, 1, 0, 0 };
                        t2.xstep = 0;
                        t2.ystep = 0;
                        if (find(b[ds..de3], "/Matrix", 0)) |ma2| {
                            var mp2 = ds + ma2 + 7;
                            while (mp2 < de3 and b[mp2] != '[') mp2 += 1;
                            mp2 += 1;
                            var mi2: u32 = 0;
                            while (mi2 < 6 and mp2 < de3) : (mi2 += 1) t2.mat[mi2] = readFloat(b, &mp2);
                        }
                        if (find(b[ds..de3], "/XStep", 0)) |xa| {
                            var xp2 = ds + xa + 6;
                            while (xp2 < de3 and isSpace(b[xp2])) xp2 += 1;
                            t2.xstep = readFloat(b, &xp2);
                        }
                        if (find(b[ds..de3], "/YStep", 0)) |ya| {
                            var yp2 = ds + ya + 6;
                            while (yp2 < de3 and isSpace(b[yp2])) yp2 += 1;
                            t2.ystep = readFloat(b, &yp2);
                        }
                        {
                            var w4 = nq;
                            while (w4 < se3 and isSpace(b[w4])) w4 += 1;
                            if (w4 < se3 and isDigit(b[w4])) t2.obj = readUint(b, &w4);
                        }
                        if (find(b[ds..de3], "/Length", 0) != null) {
                            // 타일 내용에서 첫 색을 찾는다
                            var num5: u32 = 0;
                            var w3 = nq;
                            while (w3 < se3 and isSpace(b[w3])) w3 += 1;
                            if (w3 < se3 and isDigit(b[w3])) num5 = readUint(b, &w3);
                            if (num5 > 0) {
                                if (streamOf(b, num5)) |ts| {
                                    if (findIn(ts, " rg", 0)) |ra2| {
                                        var tp: usize = if (ra2 > 24) ra2 - 24 else 0;
                                        var vals: [3]f32 = .{ 0.6, 0.6, 0.6 };
                                        var vi: u32 = 0;
                                        while (tp < ra2 and vi < 3) {
                                            while (tp < ra2 and isSpace(ts[tp])) tp += 1;
                                            if (tp >= ra2) break;
                                            if (!(isDigit(ts[tp]) or ts[tp] == '.' or ts[tp] == '-')) { tp += 1; vi = 0; continue; }
                                            vals[vi] = readFloat(ts, &tp);
                                            vi += 1;
                                        }
                                        if (vi == 3) { t2.r = vals[0]; t2.g = vals[1]; t2.b = vals[2]; }
                                    }
                                }
                            }
                        }
                        tile_n += 1;
                    }
                } else {
                    readShade(b, ds, de3, nm5);
                }
            }
            q = nq;
        }
    }

    // ColorSpace — 이름마다 성분 수와 갈래를 적어 둔다
    if (find(b[rs..re_], "/ColorSpace", 0)) |ca| {
        var p = rs + ca + 11;
        while (p < re_ and isSpace(b[p])) p += 1;
        var cs2 = p;
        var ce2 = re_;
        if (p < re_ and b[p] == '<') {
            ce2 = dictEnd(b, p, re_);
        } else if (p < re_ and isDigit(b[p])) {
            const cn = readUint(b, &p);
            if (findObj(b, cn)) |cb| {
                cs2 = cb;
                ce2 = find(b, "endobj", cb) orelse b.len;
            }
        }
        var q = cs2;
        while (q < ce2 and cspacesRoom(cs_n + 1)) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            while (nq < ce2 and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>' and
                b[nq] != '[' and b[nq] != '<') nq += 1;
            const nm4 = b[q + 1 .. nq];
            var vp = nq;
            while (vp < ce2 and isSpace(b[vp])) vp += 1;
            // 값의 범위를 잡는다
            var vs = vp;
            var ve = vp;
            if (vp < ce2 and b[vp] == '[') {
                vs = vp;
                var d2: u32 = 0;
                var w = vp;
                while (w < ce2) : (w += 1) {
                    if (b[w] == '[') d2 += 1;
                    if (b[w] == ']') { d2 -= 1; if (d2 == 0) { ve = w + 1; break; } }
                }
            } else if (vp < ce2 and isDigit(b[vp])) {
                var w = vp;
                const on3 = readUint(b, &w);
                if (findObj(b, on3)) |ob3| {
                    vs = ob3;
                    ve = find(b, "endobj", ob3) orelse b.len;
                }
            } else if (vp < ce2 and b[vp] == '/') {
                vs = vp;
                var w = vp + 1;
                while (w < ce2 and !isSpace(b[w]) and b[w] != '/' and b[w] != '>') w += 1;
                ve = w;
            }
            if (ve > vs and nm4.len > 0 and findCs(nm4) < 0) {
                const val = b[vs..ve];
                var kind: u8 = CS_RGB;
                var comps: u8 = 3;
                if (findIn(val, "/Pattern", 0) != null) { kind = CS_PATTERN; comps = 1; }
                else if (findIn(val, "/Lab", 0) != null) { kind = CS_LAB; comps = 3; }
                else if (findIn(val, "/Separation", 0) != null) { kind = CS_TINT; comps = 1; }
                else if (findIn(val, "/DeviceN", 0) != null) { kind = CS_TINT; comps = 1; }
                else if (findIn(val, "/Indexed", 0) != null) { kind = CS_GRAY; comps = 1; }
                else if (findIn(val, "/DeviceGray", 0) != null or findIn(val, "/CalGray", 0) != null) { kind = CS_GRAY; comps = 1; }
                else if (findIn(val, "/DeviceCMYK", 0) != null) { kind = CS_CMYK; comps = 4; }
                else if (findIn(val, "/ICCBased", 0) != null) {
                    // 성분 수는 스트림 딕셔너리의 /N 에 있다
                    var nn: u32 = 3;
                    var w = vs;
                    while (w < ve and !isDigit(b[w])) w += 1;
                    if (w < ve) {
                        var w2 = w;
                        const on4 = readUint(b, &w2);
                        if (findObj(b, on4)) |ob4| {
                            const oe4 = objDictEnd(b, ob4);
                            if (intAfter(b, ob4, oe4, "/N")) |v2| nn = v2;
                        }
                    }
                    comps = @intCast(@max(1, @min(4, nn)));
                    kind = if (comps == 1) CS_GRAY else if (comps == 4) CS_CMYK else CS_RGB;
                }
                const c2 = &cspacesBuf()[cs_n];
                const nl4 = @min(nm4.len, 24);
                var k4: usize = 0;
                while (k4 < nl4) : (k4 += 1) c2.name[k4] = nm4[k4];
                c2.name_len = @intCast(nl4);
                c2.kind = kind;
                c2.comps = comps;
                cs_n += 1;
            }
            q = nq;
        }
    }

    // Properties — BDC 가 가리키는 레이어 이름표
    if (find(b[rs..re_], "/Properties", 0)) |pa| {
        var p = rs + pa + 11;
        while (p < re_ and isSpace(b[p])) p += 1;
        var ps2 = p;
        var pe2 = re_;
        if (p < re_ and b[p] == '<') {
            pe2 = dictEnd(b, p, re_);
        } else if (p < re_ and isDigit(b[p])) {
            const pn = readUint(b, &p);
            if (findObj(b, pn)) |pb| { ps2 = pb; pe2 = objDictEnd(b, pb); }
        }
        var q = ps2;
        while (q < pe2 and propsRoom(prop_n + 1)) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            while (nq < pe2 and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>') nq += 1;
            var vp = nq;
            while (vp < pe2 and isSpace(b[vp])) vp += 1;
            if (vp < pe2 and isDigit(b[vp])) {
                const on6 = readUint(b, &vp);
                const pr = &propsBuf()[prop_n];
                const nl6 = @min(nq - q - 1, 24);
                var k6: usize = 0;
                while (k6 < nl6) : (k6 += 1) pr.name[k6] = b[q + 1 + k6];
                pr.name_len = @intCast(nl6);
                pr.obj = on6;
                prop_n += 1;
            }
            q = nq;
        }
    }

    // ExtGState — 투명도(ca/CA)와 선 굵기(LW)
    if (find(b[rs..re_], "/ExtGState", 0)) |ga| {
        var p = rs + ga + 10;
        while (p < re_ and isSpace(b[p])) p += 1;
        var gsx = p;
        var gex = re_;
        if (p < re_ and b[p] == '<') {
            gex = dictEnd(b, p, re_);
        } else if (p < re_ and isDigit(b[p])) {
            const gn = readUint(b, &p);
            if (findObj(b, gn)) |gb| {
                gsx = gb;
                gex = find(b, "endobj", gb) orelse b.len;
            }
        }
        var q = gsx;
        while (q < gex and gstatesRoom(gs_n + 1)) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            while (nq < gex and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>' and b[nq] != '<') nq += 1;
            const nm3 = b[q + 1 .. nq];
            var vp = nq;
            while (vp < gex and isSpace(b[vp])) vp += 1;
            var ds: usize = 0;
            var de2: usize = 0;
            if (vp < gex and b[vp] == '<') {
                ds = vp;
                de2 = dictEnd(b, vp, gex);
            } else if (vp < gex and isDigit(b[vp])) {
                const on2 = readUint(b, &vp);
                if (findObj(b, on2)) |ob2| {
                    ds = ob2;
                    de2 = find(b, "endobj", ob2) orelse b.len;
                }
            }
            if (de2 > ds and nm3.len > 0 and findGs(nm3) < 0) {
                const g2 = &gstatesBuf()[gs_n];
                const nl3 = @min(nm3.len, 24);
                var k3: usize = 0;
                while (k3 < nl3) : (k3 += 1) g2.name[k3] = nm3[k3];
                g2.name_len = @intCast(nl3);
                g2.ca = -1;
                g2.CA = -1;
                g2.lw = -1;
                g2.bm = -1;
                g2.sm_obj = 0;
                g2.sm_lum = true;
                g2.sm_off = false;
                g2.sm_bc = .{ 0, 0, 0 };
                if (find(b[ds..de2], "/SMask", 0)) |sa| {
                    var sp2 = ds + sa + 6;
                    while (sp2 < de2 and isSpace(b[sp2])) sp2 += 1;
                    if (sp2 + 5 <= de2 and std_mem_eq(b[sp2 .. sp2 + 5], "/None")) {
                        g2.sm_off = true;
                    } else {
                        // << /S /Luminosity /G 5 0 R /BC [...] >> 또는 그 참조
                        var ss = sp2;
                        var se = de2;
                        if (sp2 < de2 and b[sp2] == '<') {
                            se = dictEnd(b, sp2, de2);
                        } else if (sp2 < de2 and isDigit(b[sp2])) {
                            const sn = readUint(b, &sp2);
                            if (findObj(b, sn)) |sb| { ss = sb; se = objDictEnd(b, sb); }
                        }
                        if (se > ss) {
                            g2.sm_lum = find(b[ss..se], "/Alpha", 0) == null;
                            if (find(b[ss..se], "/G", 0)) |gaa| {
                                var gp = ss + gaa + 2;
                                while (gp < se and isSpace(b[gp])) gp += 1;
                                if (gp < se and isDigit(b[gp])) g2.sm_obj = readUint(b, &gp);
                            }
                            var bc: [4]f32 = .{ 0, 0, 0, 0 };
                            const nbc = readArr(b, ss, se, "/BC", &bc);
                            if (nbc == 1) g2.sm_bc = .{ bc[0], bc[0], bc[0] }
                            else if (nbc >= 3) g2.sm_bc = .{ bc[0], bc[1], bc[2] };
                        }
                    }
                }
                if (find(b[ds..de2], "/BM", 0)) |ba| {
                    var bp = ds + ba + 3;
                    while (bp < de2 and (isSpace(b[bp]) or b[bp] == '[')) bp += 1;
                    if (bp < de2 and b[bp] == '/') {
                        const names = [_][]const u8{
                            "Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten",
                            "ColorDodge", "ColorBurn", "HardLight", "SoftLight", "Difference",
                            "Exclusion", "Hue", "Saturation", "Color", "Luminosity",
                        };
                        var bi: i32 = 0;
                        for (names, 0..) |nmx, ix| {
                            if (bp + 1 + nmx.len <= de2 and std_mem_eq(b[bp + 1 .. bp + 1 + nmx.len], nmx)) {
                                bi = @intCast(ix);
                                g2.bm = bi;
                            }
                        }
                        if (g2.bm < 0) g2.bm = 0;
                    }
                }
                if (find(b[ds..de2], "/ca", 0)) |aa| {
                    var ap = ds + aa + 3;
                    while (ap < de2 and isSpace(b[ap])) ap += 1;
                    g2.ca = readFloat(b, &ap);
                }
                if (find(b[ds..de2], "/CA", 0)) |aa| {
                    var ap = ds + aa + 3;
                    while (ap < de2 and isSpace(b[ap])) ap += 1;
                    g2.CA = readFloat(b, &ap);
                }
                if (find(b[ds..de2], "/LW", 0)) |aa| {
                    var ap = ds + aa + 3;
                    while (ap < de2 and isSpace(b[ap])) ap += 1;
                    g2.lw = readFloat(b, &ap);
                }
                gs_n += 1;
            }
            q = nq;
        }
    }

    if (find(b[rs..re_], "/Font", 0)) |fa| {
        var p = rs + fa + 5;
        while (p < re_ and isSpace(b[p])) p += 1;
        var fs = p;
        var fe = re_;
        if (p < re_ and b[p] == '<') {
            // 인라인 딕셔너리 — 여기서 끊지 않으면 /Contents·/Parent 까지
            // 글꼴로 잡힌다
            fe = dictEnd(b, p, re_);
        } else if (p < re_ and b[p] >= '0' and b[p] <= '9') {
            const fn_num = readUint(b, &p);
            if (findObj(b, fn_num)) |fb| {
                fs = fb;
                fe = find(b, "endobj", fb) orelse b.len;
            }
        }
        // "/이름 N 0 R" 쌍을 걷는다
        var q = fs;
        while (q < fe) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            var nlen: u32 = 0;
            while (nq < fe and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>' and nlen < 24) {
                nq += 1;
                nlen += 1;
            }
            var vp = nq;
            while (vp < fe and isSpace(b[vp])) vp += 1;
            if (vp < fe and b[vp] >= '0' and b[vp] <= '9') {
                const fobj = readUint(b, &vp);
                var cmap_ptr: [*]const u8 = b.ptr;
                var cmap_len: u32 = 0;
                if (findObj(b, fobj)) |fbody| {
                    const fend = find(b, "endobj", fbody) orelse b.len;
                    if (find(b[fbody..fend], "/ToUnicode", 0)) |tu| {
                        var tp = fbody + tu + 10;
                        while (tp < fend and isSpace(b[tp])) tp += 1;
                        const tobj = readUint(b, &tp);
                        if (streamOf(b, tobj)) |cm| {
                            cmap_ptr = cm.ptr;
                            cmap_len = @intCast(cm.len);
                        }
                    }
                }
                addFont(b[q + 1 ..].ptr, nlen, cmap_ptr, cmap_len);
                if (findObj(b, fobj)) |fbody| {
                    attachWidths(b, fbody);
                    attachType3(b, fbody);
                    attachEmbedded(b, fbody);
                }
            }
            q = nq;
        }
    }

    // 그림 한 장을 꺼낸다. 스캔 문서는 쪽마다 큰 그림 하나가 전부라,
    // 그것만 그려도 미리보기로는 충분하다.
    img_kind = 0;
    img_len = 0;
    img_w = 0;
    img_h = 0;
    if (find(b[rs..re_], "/XObject", 0)) |xa| {
        var xp = rs + xa + 8;
        while (xp < re_ and isSpace(b[xp])) xp += 1;
        var xs = xp;
        var xe = re_;
        if (xp < re_ and b[xp] >= '0' and b[xp] <= '9') {
            const xn = readUint(b, &xp);
            if (findObj(b, xn)) |xb| {
                xs = xb;
                xe = find(b, "endobj", xb) orelse b.len;
            }
        }
        // "/이름 N 0 R" 을 모두 걷어 그림을 담는다.
        // 폼 XObject 는 아직 그리지 않으므로 개수만 세어 화면에 알린다.
        var q = xs;
        while (q < xe) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            while (nq < xe and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>') nq += 1;
            const nm = b[q + 1 .. nq];
            var vp = nq;
            while (vp < xe and isSpace(b[vp])) vp += 1;
            if (vp < xe and b[vp] >= '0' and b[vp] <= '9') {
                const onum = readUint(b, &vp);
                if (findObj(b, onum)) |ob| {
                    const oe = objDictEnd(b, ob);
                    if (find(b[ob..oe], "/Form", 0) != null) {
                        form_n += 1;
                        if (formsRoom(form_n2 + 1)) {
                            const fo = &formsBuf()[form_n2];
                            const nl2 = @min(nm.len, 24);
                            var k2: usize = 0;
                            while (k2 < nl2) : (k2 += 1) fo.name[k2] = nm[k2];
                            fo.name_len = @intCast(nl2);
                            fo.obj = onum;
                            fo.mat = .{ 1, 0, 0, 1, 0, 0 };
                            fo.has_bbox = false;
                            // 투명 그룹인가 — 통째로 한 판에 그려 겹쳐야 한다
                            fo.group = find(b[ob..oe], "/Transparency", 0) != null;
                            if (find(b[ob..oe], "/Matrix", 0)) |ma| {
                                var mp = ob + ma + 7;
                                while (mp < oe and b[mp] != '[') mp += 1;
                                mp += 1;
                                var mi: u32 = 0;
                                while (mi < 6 and mp < oe) : (mi += 1) fo.mat[mi] = readFloat(b, &mp);
                            }
                            if (find(b[ob..oe], "/BBox", 0)) |ba| {
                                var bp = ob + ba + 5;
                                while (bp < oe and b[bp] != '[') bp += 1;
                                bp += 1;
                                var bi: u32 = 0;
                                while (bi < 4 and bp < oe) : (bi += 1) fo.bbox[bi] = readFloat(b, &bp);
                                fo.has_bbox = true;
                            }
                            form_n2 += 1;
                            // 폼 안의 글꼴·그림도 등록해 둔다
                            if (depth < 2) {
                                if (find(b[ob..oe], "/Resources", 0)) |ra2| {
                                    var rp = ob + ra2 + 10;
                                    while (rp < oe and isSpace(b[rp])) rp += 1;
                                    if (rp < oe and b[rp] == '<') {
                                        scanResources(b, rp, dictEnd(b, rp, oe), depth + 1);
                                    } else if (rp < oe and isDigit(b[rp])) {
                                        const rn2 = readUint(b, &rp);
                                        if (findObj(b, rn2)) |rb2| {
                                            scanResources(b, rb2, find(b, "endobj", rb2) orelse b.len, depth + 1);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    _ = takeImage(b, ob, nm);
                }
            }
            q = nq;
        }
    }
}

/// 페이지의 폰트와 콘텐츠를 찾아 글자를 뽑는다. 항목 수를 돌려준다.
export fn renderPage(idx: u32) u32 {
    if (idx >= page_count) return 0;
    const b = searchSlice();
    const obj = page_objs()[idx];
    const body = findObj(b, obj) orelse return 0;
    const end = find(b, "endobj", body) orelse b.len;

    // MediaBox 로 페이지 크기 (없으면 Letter). 상위 Pages 에서 물려받기도 한다.
    var pw: f32 = 612;
    var ph: f32 = 792;
    page_x0 = 0;
    page_y0 = 0;
    if (inheritedKey(b, body, end, "/MediaBox")) |n| {
        var p = n.at + 9;
        while (p < n.e and b[p] != '[') p += 1;
        p += 1;
        var v: [4]f32 = .{ 0, 0, 612, 792 };
        var i: u32 = 0;
        while (i < 4 and p < n.e) : (i += 1) v[i] = readFloat(b, &p);
        pw = v[2] - v[0];
        ph = v[3] - v[1];
        page_x0 = v[0];
        page_y0 = v[1];
    }
    // CropBox 는 "이만큼만 보여 준다" 는 뜻이다.
    //
    // 인쇄용 문서는 재단선과 여백을 MediaBox 에 두고 CropBox 로 잘라 보여
    // 준다. 이걸 안 보면 쪽이 크게 잡혀 여백이 딸려 나오고 가운데가 어긋난다.
    // 겹치는 데만 쓴다 — MediaBox 밖을 가리키는 CropBox 는 규격상 무시한다.
    if (inheritedKey(b, body, end, "/CropBox")) |n| crop: {
        var p = n.at + 8;
        while (p < n.e and b[p] != '[') p += 1;
        p += 1;
        var v: [4]f32 = .{ 0, 0, 0, 0 };
        var i: u32 = 0;
        while (i < 4 and p < n.e) : (i += 1) {
            while (p < n.e and isSpace(b[p])) p += 1;
            if (p >= n.e or !(isDigit(b[p]) or b[p] == '-' or b[p] == '.')) break;
            v[i] = readFloat(b, &p);
        }
        // 넷이 다 있어야 상자다. 모자라면 없는 셈 친다.
        if (i < 4) break :crop;
        const cx0 = @min(v[0], v[2]);
        const cy0 = @min(v[1], v[3]);
        const cx1 = @max(v[0], v[2]);
        const cy1 = @max(v[1], v[3]);
        const mx0 = @max(cx0, page_x0);
        const my0 = @max(cy0, page_y0);
        const mx1 = @min(cx1, page_x0 + pw);
        const my1 = @min(cy1, page_y0 + ph);
        if (mx1 - mx0 > 1 and my1 - my0 > 1) {
            pw = mx1 - mx0;
            ph = my1 - my0;
            page_x0 = mx0;
            page_y0 = my0;
        }
    }
    if (pw <= 1 or ph <= 1 or pw > 20000 or ph > 20000) { pw = 612; ph = 792; }
    page_rotate = 0;
    if (inheritedKey(b, body, end, "/Rotate")) |n| {
        var p = n.at + 7;
        while (p < n.e and isSpace(b[p])) p += 1;
        var neg = false;
        if (p < n.e and b[p] == '-') { neg = true; p += 1; }
        if (p < n.e and isDigit(b[p])) {
            var r: i32 = @intCast(readUint(b, &p));
            if (neg) r = -r;
            r = @mod(r, 360);
            if (r < 0) r += 360;
            page_rotate = @intCast(r - @mod(r, 90));
        }
    }
    resetPage(pw, ph);

    // Resources → Font → 각 폰트의 ToUnicode
    var res_start = body;
    var res_end = end;
    if (inheritedKey(b, body, end, "/Resources")) |n| {
        var p = n.at + 10;
        while (p < n.e and isSpace(b[p])) p += 1;
        if (p < n.e and b[p] >= '0' and b[p] <= '9') {
            const rn = readUint(b, &p);
            if (findObj(b, rn)) |rb| {
                res_start = rb;
                res_end = find(b, "endobj", rb) orelse b.len;
            }
        } else {
            res_start = n.s;
            res_end = n.e;
        }
    }
    scanResources(b, res_start, res_end, 0);

    // Contents 스트림을 풀어 훑는다
    doc = b;
    if (collectContents(b, body, end)) |cs| runOps(cs, 0);
    collectFields(b, body, end);
    drawAnnots(b, body, end);
    collectLinks(b, body, end);
    collectAnnots(b, body, end);
    return item_n;
}

/// 주석의 겉모습(/AP /N)을 그린다.
///
/// 양식에 채운 값, 도장, 서명 그림이 여기 들어 있다. 페이지 콘텐츠에는
/// 없으므로 따로 그려 줘야 한다. 겉모습은 폼 XObject 라서 BBox 를 Matrix 로
/// 옮긴 뒤 /Rect 에 맞춰 늘린다 — 규격이 정한 그대로다.
// ===== 새로 다는 주석 =====
//
// 하이라이트·밑줄·네모·동그라미·메모를 쪽에 얹는다. 라벨처럼 콘텐츠에
// 구워 넣지 않고 진짜 주석(/Annots)으로 단다 — 그래야 다른 뷰어에서
// 골라 지우거나 고칠 수 있고, 메모는 눌러서 읽을 수 있다.
const NoteT = struct {
    /// 0 하이라이트 · 1 밑줄 · 2 취소선 · 3 네모 · 4 동그라미 · 5 메모 · 6 자유선
    kind: u8,
    page: u32,
    rect: [4]f32,
    col: [3]f32,
    /// 메모 글, 또는 자유선의 점들이 담긴 자리
    off: u32,
    len: u32,
    /// 자유선의 점 개수 (x,y 짝)
    pts: u32,
    /// 만들 때 준 객체 번호
    obj: u32 = 0,
};
/// 사용자가 더한 것 — 세는 상한은 없다(자리잡개에서 늘어난다)
var notes_at: usize = 0;
var notes_cap: u32 = 0;
fn notes() []NoteT {
    if (notes_at == 0 or notes_cap == 0) return &[_]NoteT{};
    return @as([*]NoteT, @ptrFromInt(notes_at))[0..notes_cap];
}
var note_n: u32 = 0;
var note_buf: [64 * 1024]u8 = undefined;
var note_used: u32 = 0;
var note_pts: [8192]f32 = undefined;
var note_pt_n: u32 = 0;

export fn clearNotes() void { note_n = 0; note_used = 0; note_pt_n = 0; }
export fn addNote(kind: u32, page: u32, x0: f32, y0: f32, x1: f32, y1: f32,
    r: f32, g: f32, b: f32) u32
{
    if (!growTable(&notes_at, &notes_cap, note_n, @sizeOf(NoteT), 64)) return 0;
    notes()[note_n] = .{
        .kind = @intCast(@min(kind, 6)), .page = page,
        .rect = .{ @min(x0, x1), @min(y0, y1), @max(x0, x1), @max(y0, y1) },
        .col = .{ @max(0, @min(1, r)), @max(0, @min(1, g)), @max(0, @min(1, b)) },
        .off = note_used, .len = 0, .pts = 0, .obj = 0,
    };
    if (notes()[note_n].kind == 6) notes()[note_n].off = note_pt_n;
    note_n += 1;
    return 1;
}
/// 메모 글 한 글자 (utf-8 로 담는다)
export fn addNoteChar(c: u32) void {
    if (note_n == 0) return;
    const t = &notes()[note_n - 1];
    if (c < 0x80) {
        if (note_used + 1 > note_buf.len) return;
        note_buf[note_used] = @intCast(c);
        note_used += 1;
        t.len += 1;
    } else if (c < 0x800) {
        if (note_used + 2 > note_buf.len) return;
        note_buf[note_used] = @intCast(0xC0 | (c >> 6));
        note_buf[note_used + 1] = @intCast(0x80 | (c & 63));
        note_used += 2;
        t.len += 2;
    } else {
        if (note_used + 3 > note_buf.len) return;
        note_buf[note_used] = @intCast(0xE0 | (c >> 12));
        note_buf[note_used + 1] = @intCast(0x80 | ((c >> 6) & 63));
        note_buf[note_used + 2] = @intCast(0x80 | (c & 63));
        note_used += 3;
        t.len += 3;
    }
}
/// 자유선의 점 하나
export fn addNotePoint(x: f32, y: f32) void {
    if (note_n == 0 or note_pt_n + 2 > note_pts.len) return;
    note_pts[note_pt_n] = x;
    note_pts[note_pt_n + 1] = y;
    note_pt_n += 2;
    notes()[note_n - 1].pts += 1;
}

fn notesOnPage(page: u32) bool {
    var i: u32 = 0;
    while (i < note_n) : (i += 1) if (notes()[i].page == page) return true;
    return false;
}

// ===== 채운 값 =====
//
// 화면에서 채운 값을 여기 모았다가, 만들 때 원본 뒤에 덧붙여 써 넣는다.
// 값(/V)과 함께 겉모습(/AP /N)도 새로 그린다 — 값만 쓰면 겉모습을 다시
// 그릴 줄 모르는 뷰어에서 빈 칸으로 보인다.
const EditT = struct {
    obj: u32,
    kind: u8,
    off: u32,
    len: u32,
    /// 표준 글꼴에 없는 글자(한글 등)는 화면 글꼴로 그린 그림을 붙인다.
    /// 1비트 마스크 — 0 이 칠하는 쪽이다.
    mw: u32 = 0,
    mh: u32 = 0,
    moff: u32 = 0,
    mlen: u32 = 0,
};
const MASK_POOL = 12 * 1024 * 1024;
/// 마스크 곳간. 정적 배열로 두면 한글 워터마크 한 번 안 쓰는 문서에서도
/// 모듈이 12MB 를 들고 시작한다 — 쓸 때 잡는다.
var mask_at: usize = 0;
var mask_used: u32 = 0;
fn maskBuf() []u8 {
    if (mask_at == 0) {
        mask_at = zoneAlloc(MASK_POOL) orelse return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(mask_at))[0..MASK_POOL];
}

/// 마스크 비트를 적을 자리. 화면 쪽이 여기에 적고 붙이기를 부른다.
/// 입력 칸·라벨·워터마크가 같은 곳간을 나눠 쓴다.
///
/// 처음 부를 때 곳간을 잡느라 메모리가 늘 수 있다. 부르는 쪽은 이 값을
/// 먼저 받아 두고 나서 memory.buffer 를 잡아야 한다 — 반대로 하면 늘어난
/// 순간 앞서 잡은 버퍼가 떨어져 나가(detached) 쓰지 못한다.
export fn fieldMaskPtr() usize {
    const buf = maskBuf();
    if (buf.len == 0) return 0;
    return @intFromPtr(buf.ptr) + mask_used;
}
export fn fieldMaskRoom() u32 { return if (mask_at == 0) MASK_POOL else MASK_POOL - mask_used; }

fn maskAlloc(len: u32, w: u32, h: u32) ?u32 {
    if (maskBuf().len == 0) return null;
    if (len == 0 or len > MASK_POOL - mask_used) return null;
    if (w == 0 or h == 0 or w > 1 << 15 or h > 1 << 15) return null;
    const at = mask_used;
    mask_used += len;
    return at;
}

export fn setFieldEditMask(w: u32, h: u32, len: u32) u32 {
    if (edit_n == 0) return 0;
    const at = maskAlloc(len, w, h) orelse return 0;
    const e = &editsBuf()[edit_n - 1];
    e.mw = w;
    e.mh = h;
    e.moff = at;
    e.mlen = len;
    return 1;
}
/// 사용자가 고친 입력 칸. 필요한 만큼 늘어난다(세는 상한 없음).
var edits_at: usize = 0;
var edits_cap: u32 = 0;
fn editsBuf() []EditT {
    if (edits_at == 0 or edits_cap == 0) return &[_]EditT{};
    return @as([*]EditT, @ptrFromInt(edits_at))[0..edits_cap];
}
fn editsRoom(want: u32) bool { return growTable(&edits_at, &edits_cap, want, @sizeOf(EditT), 64); }
var edit_n: u32 = 0;
var edit_buf: [96 * 1024]u8 = undefined;
var edit_used: u32 = 0;

export fn clearFieldEdits() void { edit_n = 0; edit_used = 0; mask_used = 0; }
/// kind 0 글상자 · 1 확인란 켜기 · 2 확인란 끄기 · 3 이름 바꾸기 · 4 지우기
export fn addFieldEdit(obj: u32, kind: u32) u32 {
    if (!editsRoom(edit_n + 1)) return 0;
    editsBuf()[edit_n] = .{ .obj = obj, .kind = @intCast(@min(kind, 4)), .off = edit_used, .len = 0,
        .mw = 0, .mh = 0, .moff = 0, .mlen = 0 };
    edit_n += 1;
    return 1;
}
/// 방금 만든 항목의 값에 글자 하나를 잇는다 (utf-8 로 담는다).
export fn addFieldEditChar(c: u32) void {
    if (edit_n == 0) return;
    const e = &editsBuf()[edit_n - 1];
    if (c < 0x80) {
        if (edit_used + 1 > edit_buf.len) return;
        edit_buf[edit_used] = @intCast(c);
        edit_used += 1;
        e.len += 1;
    } else if (c < 0x800) {
        if (edit_used + 2 > edit_buf.len) return;
        edit_buf[edit_used] = @intCast(0xC0 | (c >> 6));
        edit_buf[edit_used + 1] = @intCast(0x80 | (c & 63));
        edit_used += 2;
        e.len += 2;
    } else {
        if (edit_used + 3 > edit_buf.len) return;
        edit_buf[edit_used] = @intCast(0xE0 | (c >> 12));
        edit_buf[edit_used + 1] = @intCast(0x80 | ((c >> 6) & 63));
        edit_buf[edit_used + 2] = @intCast(0x80 | (c & 63));
        edit_used += 3;
        e.len += 3;
    }
}

/// utf-8 한 글자를 읽고 코드포인트와 길이를 준다.
fn utf8At(d: []const u8, i: usize) [2]u32 {
    const c = d[i];
    if (c < 0x80) return .{ c, 1 };
    if ((c & 0xE0) == 0xC0 and i + 1 < d.len)
        return .{ (@as(u32, c & 31) << 6) | (d[i + 1] & 63), 2 };
    if ((c & 0xF0) == 0xE0 and i + 2 < d.len)
        return .{ (@as(u32, c & 15) << 12) | (@as(u32, d[i + 1] & 63) << 6) | (d[i + 2] & 63), 3 };
    if ((c & 0xF8) == 0xF0 and i + 3 < d.len)
        return .{ (@as(u32, c & 7) << 18) | (@as(u32, d[i + 1] & 63) << 12) |
            (@as(u32, d[i + 2] & 63) << 6) | (d[i + 3] & 63), 4 };
    return .{ c, 1 };
}

// ===== 새로 만드는 입력 칸 =====
//
// 있는 칸을 채우는 것과 달리, 없던 칸을 만들려면 위젯 객체를 새로 적고
// 쪽의 /Annots 와 양식의 /Fields 양쪽에 이름을 걸어야 한다. 겉모습은
// 따로 그리지 않는다 — /NeedAppearances 를 켜 두면 뷰어가 제 글꼴로
// 그려 준다. 우리가 그리면 표준 글꼴이라 한글이 빠진다.
const NewFieldT = struct {
    page: u32,
    /// 0 글상자 · 1 확인란
    kind: u8,
    rect: [4]f32,
    off: u32,
    len: u32,
    /// 적으면서 붙인 객체 번호
    obj: u32,
};
/// 사용자가 더한 것 — 세는 상한은 없다(자리잡개에서 늘어난다)
var newf_at: usize = 0;
var newf_cap: u32 = 0;
fn newf() []NewFieldT {
    if (newf_at == 0 or newf_cap == 0) return &[_]NewFieldT{};
    return @as([*]NewFieldT, @ptrFromInt(newf_at))[0..newf_cap];
}
var newf_n: u32 = 0;
var newf_buf: [16 * 1024]u8 = undefined;
var newf_used: u32 = 0;

export fn clearNewFields() void {
    newf_n = 0;
    newf_used = 0;
}

export fn addNewField(page: u32, kind: u32, x0: f32, y0: f32, x1: f32, y1: f32) u32 {
    if (!growTable(&newf_at, &newf_cap, newf_n, @sizeOf(NewFieldT), 32)) return 0;
    // 없는 쪽에 달라고 하면 그냥 안 단다. 예전에는 쪽 표가 [4096] 고정이라
    // 빈 자리(0)를 읽었지만, 지금은 그 뒤가 다른 표라 엉뚱한 번호를 집는다.
    if (page >= page_count) return 0;
    const lo_x = @min(x0, x1);
    const hi_x = @max(x0, x1);
    const lo_y = @min(y0, y1);
    const hi_y = @max(y0, y1);
    if (!(hi_x - lo_x > 1) or !(hi_y - lo_y > 1)) return 0;
    newf()[newf_n] = .{
        .page = page, .kind = @intCast(@min(kind, 1)),
        .rect = .{ lo_x, lo_y, hi_x, hi_y },
        .off = newf_used, .len = 0, .obj = 0,
    };
    newf_n += 1;
    return 1;
}

/// 방금 만든 칸의 이름에 글자 하나를 잇는다 (utf-8 로 담는다).
export fn addNewFieldChar(c: u32) void {
    if (newf_n == 0) return;
    const f = &newf()[newf_n - 1];
    var tmp: [4]u8 = undefined;
    var n: u32 = 0;
    if (c < 0x80) {
        tmp[0] = @intCast(c);
        n = 1;
    } else if (c < 0x800) {
        tmp[0] = @intCast(0xC0 | (c >> 6));
        tmp[1] = @intCast(0x80 | (c & 63));
        n = 2;
    } else {
        tmp[0] = @intCast(0xE0 | (c >> 12));
        tmp[1] = @intCast(0x80 | ((c >> 6) & 63));
        tmp[2] = @intCast(0x80 | (c & 63));
        n = 3;
    }
    if (newf_used + n > newf_buf.len) return;
    @memcpy(newf_buf[newf_used..][0..n], tmp[0..n]);
    newf_used += n;
    f.len += n;
}


/// 이 객체가 지울 칸인가
fn fieldDeleted(obj: u32) bool {
    var i: u32 = 0;
    while (i < edit_n) : (i += 1) if (editsBuf()[i].kind == 4 and editsBuf()[i].obj == obj) return true;
    return false;
}

/// 칸을 만들거나 지우면 쪽과 양식의 목록을 다시 써야 한다
fn anyFieldStruct() bool {
    if (newf_n > 0) return true;
    var i: u32 = 0;
    while (i < edit_n) : (i += 1) if (editsBuf()[i].kind == 4) return true;
    return false;
}

/// PDF 글자열 하나를 적는다.
///
/// 라틴 밖 글자가 섞이면 UTF-16BE 로 담는다 — 괄호 문자열에는 한 바이트
/// 글자만 들어가 한글이 통째로 사라진다.
fn appendTextStr(pos: *usize, val: []const u8) void {
    var wide = false;
    var cz: usize = 0;
    while (cz < val.len) {
        const cu = utf8At(val, cz);
        cz += cu[1];
        if (cu[0] > 255) { wide = true; break; }
    }
    if (!outRoom(pos.*, val.len * 6 + 16)) return;
    if (wide) {
        appendStr(pos, "<FEFF");
        var cx: usize = 0;
        while (cx < val.len and outRoom(pos.*, 16)) {
            const cu = utf8At(val, cx);
            cx += cu[1];
            if (cu[0] == '\r' or cu[0] == '\n') continue;
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
                    outBuf()[pos.*] = if (nib < 10) '0' + nib else 'A' + (nib - 10);
                    pos.* += 1;
                }
            }
        }
        appendStr(pos, ">");
        return;
    }
    appendStr(pos, "(");
    var cx: usize = 0;
    while (cx < val.len and outRoom(pos.*, 8)) {
        const cu = utf8At(val, cx);
        cx += cu[1];
        if (cu[0] == '\r' or cu[0] == '\n') continue;
        if (cu[0] == '(' or cu[0] == ')' or cu[0] == '\\') {
            outBuf()[pos.*] = '\\';
            pos.* += 1;
        }
        outBuf()[pos.*] = @intCast(cu[0]);
        pos.* += 1;
    }
    appendStr(pos, ")");
}

/// 참조 배열을 옮겨 적으며 지울 칸은 뺀다.
fn copyRefsKeeping(b: []const u8, from: usize, to: usize, pos: *usize) void {
    var w = from;
    while (w < to and outRoom(pos.*, 32)) {
        while (w < to and isSpace(b[w])) w += 1;
        if (w >= to) break;
        if (!isDigit(b[w])) { w += 1; continue; }
        var q = w;
        const num = readUint(b, &q);
        while (q < to and isSpace(b[q])) q += 1;
        var gen: u32 = 0;
        if (q < to and isDigit(b[q])) gen = readUint(b, &q);
        while (q < to and isSpace(b[q])) q += 1;
        if (q < to and b[q] == 'R') q += 1;
        if (!fieldDeleted(num)) {
            appendStr(pos, " ");
            appendNum(pos, num);
            appendStr(pos, " ");
            appendNum(pos, gen);
            appendStr(pos, " R");
        }
        w = q;
    }
}

// ===== 입력 칸 (AcroForm) =====
//
// PDF 의 양식은 쪽의 /Annots 에 /Subtype /Widget 으로 얹혀 있다. 각 칸은
// 자리(/Rect)와 갈래(/FT)와 값(/V)을 들고 있고, 겉모습(/AP /N)은 그 값을
// 그려 둔 그림이다. 우리는 자리와 값을 꺼내 화면에 진짜 입력 칸을 얹고,
// 만들 때 값과 겉모습을 다시 써 넣는다.
/// 문서의 입력 칸. 세는 상한은 없다.
var field_at: usize = 0;
var field_cap: u32 = 0;
const FieldT = struct {
    obj: u32,
    rect: [4]f32,
    /// 0 글상자 · 1 확인란 · 2 라디오 · 3 목록 · 4 누름단추
    kind: u8,
    flags: u32,
    maxlen: u32,
    size: f32,
    align_: u8,
    name_off: u32,
    name_len: u32,
    val_off: u32,
    val_len: u32,
    on_off: u32,
    on_len: u32,
    opts_off: u32,
    opts_len: u32,
    checked: bool,
};
fn fields() []FieldT {
    if (field_at == 0 or field_cap == 0) return &[_]FieldT{};
    return @as([*]FieldT, @ptrFromInt(field_at))[0..field_cap];
}
var field_n: u32 = 0;
/// fld_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var fld_buf_at: usize = 0;
var fld_buf_cap: u32 = 0;
fn fld_buf() []u8 {
    if (fld_buf_at == 0 or fld_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(fld_buf_at))[0..fld_buf_cap];
}
fn fld_bufRoom(want: u32) bool {
    return growTable(&fld_buf_at, &fld_buf_cap, want, 1, 65536);
}
var fld_used: u32 = 0;

export fn fieldCount() u32 { return field_n; }
export fn fieldObj(i: u32) u32 { return if (i < field_n) fields()[i].obj else 0; }
export fn fieldRect(i: u32, k: u32) f32 { return if (i < field_n and k < 4) fields()[i].rect[k] else 0; }
export fn fieldKind(i: u32) u32 { return if (i < field_n) fields()[i].kind else 0; }
export fn fieldFlags(i: u32) u32 { return if (i < field_n) fields()[i].flags else 0; }
export fn fieldMaxLen(i: u32) u32 { return if (i < field_n) fields()[i].maxlen else 0; }
export fn fieldSize(i: u32) f32 { return if (i < field_n) fields()[i].size else 0; }
export fn fieldAlign(i: u32) u32 { return if (i < field_n) fields()[i].align_ else 0; }
export fn fieldChecked(i: u32) u32 { return if (i < field_n and fields()[i].checked) 1 else 0; }
export fn fieldTextPtr() [*]u8 { return @ptrFromInt(if (fld_buf_at == 0) heapBase() else fld_buf_at); }
export fn fieldNameOff(i: u32) u32 { return if (i < field_n) fields()[i].name_off else 0; }
export fn fieldNameLen(i: u32) u32 { return if (i < field_n) fields()[i].name_len else 0; }
export fn fieldValOff(i: u32) u32 { return if (i < field_n) fields()[i].val_off else 0; }
export fn fieldValLen(i: u32) u32 { return if (i < field_n) fields()[i].val_len else 0; }
export fn fieldOnOff(i: u32) u32 { return if (i < field_n) fields()[i].on_off else 0; }
export fn fieldOnLen(i: u32) u32 { return if (i < field_n) fields()[i].on_len else 0; }
export fn fieldOptsOff(i: u32) u32 { return if (i < field_n) fields()[i].opts_off else 0; }
export fn fieldOptsLen(i: u32) u32 { return if (i < field_n) fields()[i].opts_len else 0; }

fn fldPut(bytes: []const u8) [2]u32 {
    _ = fld_bufRoom(fld_used + @as(u32, @intCast(bytes.len)) + 64);
    const n: u32 = @intCast(@min(bytes.len, fld_buf().len - fld_used));
    if (n == 0) return .{ fld_used, 0 };
    @memcpy(fld_buf()[fld_used..][0..n], bytes[0..n]);
    const off = fld_used;
    fld_used += n;
    return .{ off, n };
}

/// PDF 문자열 하나를 utf-8 로 풀어 담는다. (…) 와 <…> 를 다 받는다.
fn fldPutStr(b: []const u8, s0: usize, e0: usize) [2]u32 {
    const off = fld_used;
    var p = s0;
    while (p < e0 and isSpace(b[p])) p += 1;
    if (p >= e0) return .{ off, 0 };
    var tmp: [2048]u8 = undefined;
    var n: usize = 0;
    if (b[p] == '(') {
        p += 1;
        var nest: u32 = 1;
        while (p < e0 and n < tmp.len) : (p += 1) {
            if (b[p] == '\\' and p + 1 < e0) {
                p += 1;
                if (b[p] >= '0' and b[p] <= '7') {
                    var v: u32 = 0;
                    var d: u32 = 0;
                    while (d < 3 and p < e0 and b[p] >= '0' and b[p] <= '7') : (d += 1) {
                        v = v * 8 + (b[p] - '0');
                        p += 1;
                    }
                    p -= 1;
                    tmp[n] = @truncate(v);
                    n += 1;
                    continue;
                }
                tmp[n] = switch (b[p]) { 'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p] };
                n += 1;
                continue;
            }
            if (b[p] == '(') nest += 1;
            if (b[p] == ')') { nest -= 1; if (nest == 0) break; }
            tmp[n] = b[p];
            n += 1;
        }
    } else if (b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < e0 and b[p] != '>' and n < tmp.len) : (p += 1) {
            const hv = hexVal(b[p]) orelse continue;
            if (hi) |h| { tmp[n] = (h << 4) | hv; n += 1; hi = null; } else hi = hv;
        }
    } else if (b[p] == '/') {
        p += 1;
        while (p < e0 and !isSpace(b[p]) and b[p] != '/' and b[p] != '>' and b[p] != ']' and n < tmp.len) : (p += 1) {
            tmp[n] = b[p];
            n += 1;
        }
        return fldPut(tmp[0..n]);
    } else return .{ off, 0 };

    // UTF-16BE 면 풀어 준다
    if (n >= 2 and tmp[0] == 0xFE and tmp[1] == 0xFF) {
        var out: [4096]u8 = undefined;
        var m: usize = 0;
        var i: usize = 2;
        while (i + 1 < n and m + 4 < out.len) : (i += 2) {
            const u: u32 = (@as(u32, tmp[i]) << 8) | tmp[i + 1];
            if (u < 0x80) { out[m] = @intCast(u); m += 1; }
            else if (u < 0x800) {
                out[m] = @intCast(0xC0 | (u >> 6));
                out[m + 1] = @intCast(0x80 | (u & 63));
                m += 2;
            } else {
                out[m] = @intCast(0xE0 | (u >> 12));
                out[m + 1] = @intCast(0x80 | ((u >> 6) & 63));
                out[m + 2] = @intCast(0x80 | (u & 63));
                m += 3;
            }
        }
        return fldPut(out[0..m]);
    }
    // 라틴-1 → utf-8
    var out2: [4096]u8 = undefined;
    var kb: usize = 0;
    var ka: usize = 0;
    while (ka < n and kb + 2 < out2.len) : (ka += 1) {
        const ch = tmp[ka];
        if (ch < 0x80) { out2[kb] = ch; kb += 1; }
        else {
            out2[kb] = 0xC0 | (ch >> 6);
            out2[kb + 1] = 0x80 | (ch & 63);
            kb += 2;
        }
    }
    return fldPut(out2[0..kb]);
}

/// 값을 위젯에서 못 찾으면 부모 필드까지 거슬러 올라간다.
fn keyAt(b: []const u8, s0: usize, e0: usize, key: []const u8) ?usize {
    // /T 는 /Type 의 앞머리다. 열쇠 뒤에 구분자가 와야 진짜다.
    var from: usize = 0;
    while (find(b[s0..e0], key, from)) |a| {
        const after = s0 + a + key.len;
        if (after >= e0) return null;
        const c = b[after];
        if (isSpace(c) or c == '/' or c == '(' or c == '<' or c == '[' or
            isDigit(c) or c == '-' or c == '.') return after;
        from = a + 1;
    }
    return null;
}

fn fieldLookup(b: []const u8, obj: u32, key: []const u8, depth: u32) ?[2]usize {
    if (depth > 8) return null;
    const ob = findObj(b, obj) orelse return null;
    const oe = objDictEnd(b, ob);
    if (keyAt(b, ob, oe, key)) |a| return .{ a, oe };
    if (find(b[ob..oe], "/Parent", 0)) |pa| {
        var q = ob + pa + 7;
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and isDigit(b[q])) return fieldLookup(b, readUint(b, &q), key, depth + 1);
    }
    return null;
}

/// 이 쪽의 입력 칸을 모은다.
fn collectFields(b: []const u8, body: usize, end: usize) void {
    const aa = find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') {
        as2 = p + 1;
        ae = arrayEnd(b, p, end);
    } else if (p < end and isDigit(b[p])) {
        const an = readUint(b, &p);
        if (findObj(b, an)) |ab| {
            const abe = find(b, "endobj", ab) orelse b.len;
            var q2 = ab;
            while (q2 < abe and b[q2] != '[') q2 += 1;
            as2 = q2 + 1;
            ae = arrayEnd(b, q2, abe);
        } else return;
    } else return;

    var q = as2;
    var count: u32 = 0;
    // /Annots 를 훑는 횟수. 1024 이던 것을 올렸다 — 링크·주석이 앞에 많이
    // 붙은 쪽에서는 뒤에 있는 입력 칸까지 차례가 안 갔다(링크 300 + 주석
    // 400 이 앞서면 칸은 324 개까지만 걷혔다).
    while (q < ae and count < 1 << 20) {
        while (q < ae and isSpace(b[q])) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!isDigit(b[q])) { q += 1; continue; }
        const num = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and isDigit(b[q])) _ = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;
        count += 1;

        const ab = findObj(b, num) orelse continue;
        const abe = objDictEnd(b, ab);
        if (find(b[ab..abe], "/Widget", 0) == null) continue;
        if (intAfter(b, ab, abe, "/F")) |fl| {
            if ((fl & 2) != 0) continue; // 숨김
        }
        if (!growTable(&field_at, &field_cap, field_n, @sizeOf(FieldT), 64)) break;
        const f = &fields()[field_n];
        f.* = .{
            .obj = num, .rect = .{ 0, 0, 0, 0 }, .kind = 0, .flags = 0, .maxlen = 0,
            .size = 0, .align_ = 0, .name_off = 0, .name_len = 0, .val_off = 0,
            .val_len = 0, .on_off = 0, .on_len = 0, .opts_off = 0, .opts_len = 0,
            .checked = false,
        };
        if (find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) f.rect[i] = readFloat(b, &rp);
        } else continue;
        if (f.rect[2] < f.rect[0]) { const t = f.rect[0]; f.rect[0] = f.rect[2]; f.rect[2] = t; }
        if (f.rect[3] < f.rect[1]) { const t = f.rect[1]; f.rect[1] = f.rect[3]; f.rect[3] = t; }
        if (f.rect[2] - f.rect[0] < 1 or f.rect[3] - f.rect[1] < 1) continue;

        // 갈래
        var ft: u8 = 255;
        if (fieldLookup(b, num, "/FT", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and isSpace(b[vp])) vp += 1;
            if (vp + 3 <= r[1] and b[vp] == '/') {
                const nm = b[vp + 1 .. @min(r[1], vp + 3)];
                if (nm[0] == 'T' and nm[1] == 'x') ft = 0
                else if (nm[0] == 'B' and nm[1] == 't') ft = 1
                else if (nm[0] == 'C' and nm[1] == 'h') ft = 3
                else if (nm[0] == 'S' and nm[1] == 'i') ft = 4; // 서명 — 못 채운다
            }
        }
        if (ft == 255) continue;
        if (fieldLookup(b, num, "/Ff", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and isSpace(b[vp])) vp += 1;
            if (vp < r[1] and (isDigit(b[vp]) or b[vp] == '-')) f.flags = @intFromFloat(@max(0, readFloat(b, &vp)));
        }
        if (ft == 1) {
            // 라디오(1<<15) · 누름단추(1<<16)
            if ((f.flags & (1 << 16)) != 0) continue; // 누름단추는 채울 것이 없다
            f.kind = if ((f.flags & (1 << 15)) != 0) 2 else 1;
        } else f.kind = ft;

        if (fieldLookup(b, num, "/MaxLen", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and isSpace(b[vp])) vp += 1;
            if (vp < r[1] and isDigit(b[vp])) f.maxlen = readUint(b, &vp);
        }
        if (fieldLookup(b, num, "/Q", 0)) |r| {
            var vp = r[0];
            while (vp < r[1] and isSpace(b[vp])) vp += 1;
            if (vp < r[1] and isDigit(b[vp])) f.align_ = @intCast(@min(2, readUint(b, &vp)));
        }
        // /DA 에서 글자 크기 — "/Helv 9 Tf 0 g"
        if (fieldLookup(b, num, "/DA", 0)) |r| {
            const da = fldPutStr(b, r[0], r[1]);
            const txt = fld_buf()[da[0]..][0..da[1]];
            if (findIn(txt, " Tf", 0)) |ti| {
                var j: usize = ti;
                while (j > 0 and (isSpace(txt[j - 1]))) j -= 1;
                var k: usize = j;
                while (k > 0 and (isDigit(txt[k - 1]) or txt[k - 1] == '.')) k -= 1;
                var pz: usize = 0;
                if (k < j) f.size = readFloat(txt[k..j], &pz);
            }
            fld_used = da[0]; // 임시로 썼던 자리를 되돌린다
        }
        // 이름
        if (fieldLookup(b, num, "/T", 0)) |r| {
            const nm = fldPutStr(b, r[0], r[1]);
            f.name_off = nm[0];
            f.name_len = nm[1];
        }
        // 값
        if (fieldLookup(b, num, "/V", 0)) |r| {
            const v = fldPutStr(b, r[0], r[1]);
            f.val_off = v[0];
            f.val_len = v[1];
        }
        if (f.kind == 1 or f.kind == 2) {
            // 켜짐 상태 이름은 /AP /N 의 열쇠 중 Off 가 아닌 것
            if (find(b[ab..abe], "/AP", 0)) |apa| {
                var ap = ab + apa + 3;
                while (ap < abe and isSpace(b[ap])) ap += 1;
                var aps = ap;
                var ape = abe;
                if (ap < abe and b[ap] == '<') ape = dictEnd(b, ap, abe)
                else if (ap < abe and isDigit(b[ap])) {
                    const apn = readUint(b, &ap);
                    if (findObj(b, apn)) |apb| { aps = apb; ape = objDictEnd(b, apb); }
                }
                if (find(b[aps..ape], "/N", 0)) |na| {
                    var np = aps + na + 2;
                    while (np < ape and isSpace(b[np])) np += 1;
                    if (np < ape and b[np] == '<') {
                        const nde = dictEnd(b, np, ape);
                        var w = np + 2;
                        while (w < nde) {
                            if (b[w] != '/') { w += 1; continue; }
                            var wq = w + 1;
                            while (wq < nde and !isSpace(b[wq]) and b[wq] != '/' and b[wq] != '>') wq += 1;
                            const key = b[w + 1 .. wq];
                            if (!(key.len == 3 and key[0] == 'O' and key[1] == 'f' and key[2] == 'f')) {
                                const on = fldPut(key);
                                f.on_off = on[0];
                                f.on_len = on[1];
                                break;
                            }
                            w = wq;
                            // 값 하나를 건너뛴다
                            while (w < nde and isSpace(b[w])) w += 1;
                            if (w < nde and isDigit(b[w])) {
                                _ = readUint(b, &w);
                                while (w < nde and isSpace(b[w])) w += 1;
                                if (w < nde and isDigit(b[w])) _ = readUint(b, &w);
                                while (w < nde and isSpace(b[w])) w += 1;
                                if (w < nde and b[w] == 'R') w += 1;
                            }
                        }
                    }
                }
            }
            // 켜져 있나 — /AS 가 Off 가 아니면 켜짐
            if (find(b[ab..abe], "/AS", 0)) |sa| {
                var sp2 = ab + sa + 3;
                while (sp2 < abe and isSpace(b[sp2])) sp2 += 1;
                if (sp2 + 1 < abe and b[sp2] == '/') {
                    const st = b[sp2 + 1 .. @min(abe, sp2 + 4)];
                    f.checked = !(st.len >= 3 and st[0] == 'O' and st[1] == 'f' and st[2] == 'f');
                }
            }
        }
        if (f.kind == 3) {
            // 목록 항목
            if (fieldLookup(b, num, "/Opt", 0)) |r| {
                var vp = r[0];
                while (vp < r[1] and isSpace(b[vp])) vp += 1;
                if (vp < r[1] and b[vp] == '[') {
                    const oe2 = arrayEnd(b, vp, r[1]);
                    f.opts_off = fld_used;
                    var w = vp + 1;
                    var cnt: u32 = 0;
                    while (w < oe2 and cnt < 200) {
                        while (w < oe2 and (isSpace(b[w]) or b[w] == '[')) w += 1;
                        if (w >= oe2 or b[w] == ']') break;
                        if (b[w] != '(' and b[w] != '<') { w += 1; continue; }
                        const one = fldPutStr(b, w, oe2);
                        _ = one;
                        _ = fldPut("\n");
                        cnt += 1;
                        // 문자열 끝으로 건너뛴다
                        const close: u8 = if (b[w] == '(') ')' else '>';
                        var d2: u32 = 0;
                        while (w < oe2) : (w += 1) {
                            if (b[w] == '\\') { w += 1; continue; }
                            if (b[w] == '(' or b[w] == '<') d2 += 1;
                            if (b[w] == close) { d2 -= 1; if (d2 == 0) { w += 1; break; } }
                        }
                    }
                    f.opts_len = fld_used - f.opts_off;
                }
            }
        }
        field_n += 1;
    }
}

/// 화면에 진짜 입력 칸을 얹을 때는 위젯의 겉모습을 그리지 않는다.
/// 그리면 예전 값이 입력 칸 뒤에 겹쳐 보인다.
var form_layer: bool = false;
export fn setFormLayer(on: u32) void { form_layer = on != 0; }

fn drawAnnots(b: []const u8, body: usize, end: usize) void {
    const aa = find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') {
        as2 = p + 1;
        ae = arrayEnd(b, p, end);
    } else if (p < end and isDigit(b[p])) {
        const an = readUint(b, &p);
        if (findObj(b, an)) |ab| {
            const abe = find(b, "endobj", ab) orelse b.len;
            var q = ab;
            while (q < abe and b[q] != '[') q += 1;
            as2 = q + 1;
            ae = arrayEnd(b, q, abe);
        } else return;
    } else return;

    var q = as2;
    var count: u32 = 0;
    while (q < ae and count < 256) {
        while (q < ae and isSpace(q_at(b, q))) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!isDigit(b[q])) { q += 1; continue; }
        const num = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and isDigit(b[q])) _ = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;
        count += 1;

        const ab = findObj(b, num) orelse continue;
        const abe = find(b, "endobj", ab) orelse b.len;
        // 링크·팝업은 그릴 것이 없다
        if (find(b[ab..abe], "/Link", 0) != null) continue;
        if (find(b[ab..abe], "/Popup", 0) != null) continue;
        if (form_layer and find(b[ab..abe], "/Widget", 0) != null) continue;
        // 숨김(2)·보기 금지(32) 깃발
        if (intAfter(b, ab, abe, "/F")) |fl| {
            if ((fl & 2) != 0 or (fl & 32) != 0) continue;
        }
        var rect: [4]f32 = .{ 0, 0, 0, 0 };
        if (find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) rect[i] = readFloat(b, &rp);
        } else continue;
        if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
        if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }

        // /AP /N — 상태별 딕셔너리면 /AS 로 고른다
        const apa = find(b[ab..abe], "/AP", 0) orelse continue;
        var ap = ab + apa + 3;
        while (ap < abe and isSpace(b[ap])) ap += 1;
        var aps = ap;
        var ape = abe;
        if (ap < abe and b[ap] == '<') {
            ape = dictEnd(b, ap, abe);
        } else if (ap < abe and isDigit(b[ap])) {
            const apn = readUint(b, &ap);
            if (findObj(b, apn)) |apb| {
                aps = apb;
                ape = find(b, "endobj", apb) orelse b.len;
            } else continue;
        } else continue;
        const na = find(b[aps..ape], "/N", 0) orelse continue;
        var np = aps + na + 2;
        while (np < ape and isSpace(b[np])) np += 1;
        var form_obj: u32 = 0;
        if (np < ape and isDigit(b[np])) {
            form_obj = readUint(b, &np);
        } else if (np < ape and b[np] == '<') {
            // 상태별 — /AS 가 가리키는 것을 쓴다
            const nde = dictEnd(b, np, ape);
            var want: []const u8 = &[_]u8{};
            if (find(b[ab..abe], "/AS", 0)) |sa| {
                var sp2 = ab + sa + 3;
                while (sp2 < abe and isSpace(b[sp2])) sp2 += 1;
                if (sp2 < abe and b[sp2] == '/') {
                    var sq = sp2 + 1;
                    while (sq < abe and !isSpace(b[sq]) and b[sq] != '/' and b[sq] != '>') sq += 1;
                    want = b[sp2 + 1 .. sq];
                }
            }
            var w = np;
            while (w < nde) {
                if (b[w] != '/') { w += 1; continue; }
                var wq = w + 1;
                while (wq < nde and !isSpace(b[wq]) and b[wq] != '/' and b[wq] != '>') wq += 1;
                var vp2 = wq;
                while (vp2 < nde and isSpace(b[vp2])) vp2 += 1;
                if (vp2 < nde and isDigit(b[vp2])) {
                    const cand = readUint(b, &vp2);
                    if (want.len == 0 or txEq(b[w + 1 .. wq], want)) { form_obj = cand; break; }
                    if (form_obj == 0) form_obj = cand;
                }
                w = wq;
            }
        }
        if (form_obj == 0) continue;
        const fb = findObj(b, form_obj) orelse continue;
        const fe2 = objDictEnd(b, fb);

        var mat: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
        if (find(b[fb..fe2], "/Matrix", 0)) |ma| {
            var mp = fb + ma + 7;
            while (mp < fe2 and b[mp] != '[') mp += 1;
            mp += 1;
            var i: u32 = 0;
            while (i < 6 and mp < fe2) : (i += 1) mat[i] = readFloat(b, &mp);
        }
        var bbox: [4]f32 = .{ 0, 0, 1, 1 };
        if (find(b[fb..fe2], "/BBox", 0)) |ba| {
            var bp = fb + ba + 5;
            while (bp < fe2 and b[bp] != '[') bp += 1;
            bp += 1;
            var i: u32 = 0;
            while (i < 4 and bp < fe2) : (i += 1) bbox[i] = readFloat(b, &bp);
        }
        // BBox 네 모서리를 Matrix 로 옮겨 감싸는 상자를 구한다
        var minx: f32 = 1e30;
        var miny: f32 = 1e30;
        var maxx: f32 = -1e30;
        var maxy: f32 = -1e30;
        const xs = [_]f32{ bbox[0], bbox[2], bbox[0], bbox[2] };
        const ys = [_]f32{ bbox[1], bbox[1], bbox[3], bbox[3] };
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const tx = mat[0] * xs[i] + mat[2] * ys[i] + mat[4];
            const ty = mat[1] * xs[i] + mat[3] * ys[i] + mat[5];
            if (tx < minx) minx = tx;
            if (tx > maxx) maxx = tx;
            if (ty < miny) miny = ty;
            if (ty > maxy) maxy = ty;
        }
        const bw = maxx - minx;
        const bh = maxy - miny;
        const sx = if (bw > 0.0001) (rect[2] - rect[0]) / bw else 1;
        const sy = if (bh > 0.0001) (rect[3] - rect[1]) / bh else 1;

        // 겉모습이 가진 리소스도 등록해 둔다
        if (find(b[fb..fe2], "/Resources", 0)) |ra2| {
            var rp = fb + ra2 + 10;
            while (rp < fe2 and isSpace(b[rp])) rp += 1;
            if (rp < fe2 and b[rp] == '<') {
                scanResources(b, rp, dictEnd(b, rp, fe2), 1);
            } else if (rp < fe2 and isDigit(b[rp])) {
                const rn2 = readUint(b, &rp);
                if (findObj(b, rn2)) |rb2| {
                    scanResources(b, rb2, find(b, "endobj", rb2) orelse b.len, 1);
                }
            }
        }

        emitOp(14, &[_]f32{});
        // 주석은 깨끗한 상태에서 그린다. 앞의 투명도·섞는 방식이 남아 있으면
        // 도장이나 양식 값이 엉뚱한 색으로 나온다.
        emitOp(21, &[_]f32{1});
        emitOp(23, &[_]f32{1});
        emitOp(26, &[_]f32{0});
        emitOp(11, &[_]f32{ 0, 0, 0 });
        emitOp(12, &[_]f32{ 0, 0, 0 });
        emitOp(13, &[_]f32{1});
        emitOp(24, &[_]f32{ 0, 0, 0, 0, 0, 0, 0, 0 });
        emitOp(16, &[_]f32{ sx, 0, 0, sy, rect[0] - minx * sx, rect[1] - miny * sy });
        emitOp(16, &[_]f32{ mat[0], mat[1], mat[2], mat[3], mat[4], mat[5] });
        emitOp(5, &[_]f32{ bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1] });
        emitOp(10, &[_]f32{0});
        emitOp(9, &[_]f32{});
        if (subStream(form_obj, 0)) |fs3| runOps(fs3, 1);
        emitOp(15, &[_]f32{});
    }
}

/// 타일 무늬를 지금 경로 안에 깐다.
///
/// 경로로 자른 뒤 타일 내용을 XStep·YStep 만큼 옮겨 가며 되풀이한다.
/// 무늬를 진짜로 깔지 않으면 단색으로 뭉개져 보인다.
fn paintTile(idx: u32, depth: u32) void {
    const t = &tilesBuf()[idx];
    const xs = if (t.xstep > 0.01) t.xstep else 1;
    const ys = if (t.ystep > 0.01) t.ystep else 1;
    emitOp(14, &[_]f32{}); // save
    emitOp(10, &[_]f32{0}); // 지금 경로로 자른다
    emitOp(9, &[_]f32{}); // 경로 비우기
    emitOp(16, &[_]f32{ t.mat[0], t.mat[1], t.mat[2], t.mat[3], t.mat[4], t.mat[5] });
    // 칠할 경로가 차지한 자리에만 깐다. 쪽 전체를 깔면 헛일이 크다.
    const bx0 = if (path_x0 < 1e29) path_x0 else 0;
    const by0 = if (path_y0 < 1e29) path_y0 else 0;
    const bx1 = if (path_x1 > -1e29) path_x1 else page_w;
    const by1 = if (path_y1 > -1e29) path_y1 else page_h;
    const tx0: i32 = @intFromFloat(@floor(bx0 / xs) - 1);
    const ty0: i32 = @intFromFloat(@floor(by0 / ys) - 1);
    const nx: u32 = @intFromFloat(@min(@as(f32, 60), @max(@as(f32, 1), (bx1 - bx0) / xs + 3)));
    const ny: u32 = @intFromFloat(@min(@as(f32, 60), @max(@as(f32, 1), (by1 - by0) / ys + 3)));
    const stream = subStream(t.obj, depth) orelse {
        emitOp(15, &[_]f32{});
        return;
    };
    var j: u32 = 0;
    while (j < ny) : (j += 1) {
        var i: u32 = 0;
        while (i < nx) : (i += 1) {
            emitOp(14, &[_]f32{});
            emitOp(16, &[_]f32{ 1, 0, 0, 1,
                @as(f32, @floatFromInt(tx0 + @as(i32, @intCast(i)))) * xs,
                @as(f32, @floatFromInt(ty0 + @as(i32, @intCast(j)))) * ys });
            runOps(stream, depth + 1);
            emitOp(15, &[_]f32{});
            if (opsRoomLow()) break;
        }
        if (opsRoomLow()) break;
    }
    emitOp(15, &[_]f32{}); // restore
}

/// 쪽의 /Contents 를 한 덩어리로 모은다.
///
/// 배열이면 여러 스트림이 한 쪽을 이룬다 — 규격상 이어 붙인 것과 같다.
/// 우리가 워터마크를 넣은 파일이 바로 그 꼴이라, 첫 스트림만 보면 원래 내용이
/// 통째로 사라진다.
fn collectContents(b: []const u8, body: usize, end: usize) ?[]const u8 {
    const ca = find(b[body..end], "/Contents", 0) orelse return null;
    var p = body + ca + 9;
    while (p < end and isSpace(b[p])) p += 1;
    if (p >= end) return null;
    var dst = growBuf(&cont_at, &cont_cap, 64 * 1024, 256 * 1024, 0) orelse return null;
    var w: usize = 0;

    // 하나뿐이라도 제자리로 옮겨 둔다.
    //
    // streamOf 는 압축을 임시 자리에 푼다. 그 자리를 그대로 훑으면, 훑는
    // 도중에 Type3 글리프 그림을 꺼내는 순간 읽던 내용이 덮인다. 실제로
    // 글자가 통째로 깨졌다.
    if (b[p] != '[') {
        if (!isDigit(b[p])) return null;
        const n = readUint(b, &p);
        const cs = streamOf(b, n) orelse return null;
        dst = growBuf(&cont_at, &cont_cap, cs.len + 1, 256 * 1024, 0) orelse return null;
        @memcpy(dst[0..cs.len], cs);
        dst[cs.len] = '\n';
        return dst[0 .. cs.len + 1];
    }
    p += 1;
    while (p < end) {
        while (p < end and isSpace(b[p])) p += 1;
        if (p >= end or b[p] == ']') break;
        if (!isDigit(b[p])) { p += 1; continue; }
        const n = readUint(b, &p);
        while (p < end and isSpace(b[p])) p += 1;
        if (p < end and isDigit(b[p])) _ = readUint(b, &p);
        while (p < end and isSpace(b[p])) p += 1;
        if (p < end and b[p] == 'R') p += 1;
        const cs = streamOf(b, n) orelse continue;
        // 앞 스트림의 마지막 토큰과 붙지 않게 줄바꿈을 끼운다.
        // 자리가 모자라면 늘린다 — 여기서 멈추면 쪽 뒷부분이 소리 없이 잘린다.
        dst = growBuf(&cont_at, &cont_cap, w + cs.len + 1, 256 * 1024, w) orelse break;
        @memcpy(dst[w..][0..cs.len], cs);
        w += cs.len;
        dst[w] = '\n';
        w += 1;
    }
    return if (w > 0) dst[0..w] else null;
}

/// 임시 자리 두 곳. content 는 /Contents 를 모으는 자리, stream_tmp 는
/// 스트림 하나를 푸는 자리다.
///
/// 예전에는 둘 다 "펼친 객체 뒤에 남은 자리" 를 8분의 1·2분의 1 지점에서
/// 잘라 썼다. 그 자리는 파일 크기에 딸린 값이라, 작은 파일에 빽빽한 쪽이
/// 들어 있으면 모자랐다 — 그리고 모자라면 null 을 돌려 쪽이 통째로 백지가
/// 됐다. 같은 쪽(내용 1.03MB)이 1MB 파일에서는 백지, 9MB 파일에서는
/// 멀쩡했다. 이제는 필요한 만큼 zone 에서 잡고 모자라면 배로 늘린다.
var cont_at: usize = 0;
var cont_cap: usize = 0;
var tmp_at: usize = 0;
var tmp_cap: usize = 0;
fn layoutScratch() void {
    // zone 은 parse 마다 되감기므로 들고 있던 자리도 함께 버린다
    cont_at = 0;
    cont_cap = 0;
    tmp_at = 0;
    tmp_cap = 0;
}

/// 자리를 need 만큼 마련한다. 이미 잡아 둔 것이 크면 그대로 쓴다.
/// keep 바이트는 새 자리로 옮겨 준다 — 스트림을 이어 붙이는 중이면
/// 앞서 담은 것이 날아가면 안 된다.
fn growBuf(at: *usize, cap: *usize, need: usize, least: usize, keep: usize) ?[]u8 {
    // 구역이 되감겼으면(merge·compact 가 그런다) 들고 있던 자리는 남의 것이다
    if (at.* != 0 and at.* + cap.* > zoneTop()) {
        at.* = 0;
        cap.* = 0;
    }
    if (at.* != 0 and cap.* >= need) return @as([*]u8, @ptrFromInt(at.*))[0..cap.*];
    var want = if (cap.* == 0) least else cap.*;
    while (want < need) {
        const dbl = want *| 2;
        if (dbl <= want) return null; // 넘침
        want = dbl;
    }
    const got = zoneAlloc(want) orelse return null;
    const dst = @as([*]u8, @ptrFromInt(got))[0..want];
    if (keep > 0 and at.* != 0) {
        const src = @as([*]const u8, @ptrFromInt(at.*))[0..@min(keep, cap.*)];
        @memcpy(dst[0..src.len], src);
    }
    at.* = got;
    cap.* = want;
    return dst;
}

/// 스트림 하나를 필터 사슬대로 풀어 dst 에 담는다. 담은 길이를 준다.
///
/// 필터는 [/ASCII85Decode /FlateDecode] 처럼 여러 개가 이어 붙기도 한다.
/// 마지막에 /Predictor 가 있으면 되돌린다.
fn decodeChain(b: []const u8, ds: usize, de: usize, data: usize, length: usize, dst: []u8) u32 {
    if (length == 0 or data > b.len or length > b.len - data) return 0;
    // 필터 이름을 차례로 모은다
    var names: [4][]const u8 = undefined;
    var nn: usize = 0;
    if (find(b[ds..de], "/Filter", 0)) |fa| {
        var p = ds + fa + 7;
        while (p < de and isSpace(b[p])) p += 1;
        // 배열이 아니면 이름 하나로 끝이다. 계속 읽으면 뒤따르는
        // /Length 까지 필터로 잡는다.
        const is_arr = p < de and b[p] == '[';
        if (is_arr) p += 1;
        while (p < de and nn < 4) {
            while (p < de and isSpace(b[p])) p += 1;
            if (p >= de or b[p] != '/') break;
            const s2 = p + 1;
            var q = s2;
            while (q < de and !isSpace(b[q]) and b[q] != '/' and b[q] != ']' and b[q] != '>') q += 1;
            names[nn] = b[s2..q];
            nn += 1;
            p = q;
            if (!is_arr) break;
            while (p < de and isSpace(b[p])) p += 1;
            if (p < de and (b[p] == ']' or b[p] == '>')) break;
        }
    }
    if (nn == 0) {
        if (length > dst.len) return 0;
        @memcpy(dst[0..length], b[data..][0..length]);
        return @intCast(length);
    }

    // 사슬을 돌린다. 중간 결과는 병합용 자리를 빌린다.
    const tmp = @as([*]u8, @ptrFromInt(b2_off))[0..b2_cap];
    var cur_src: []const u8 = b[data..][0..length];
    var out_n: u32 = 0;
    var i: usize = 0;
    while (i < nn) : (i += 1) {
        const name = names[i];
        const into: []u8 = if (i % 2 == 0) dst else tmp;
        var n2: u32 = 0;
        if (txEq(name, "FlateDecode") or txEq(name, "Fl")) {
            const r = pw_inflate(cur_src.ptr, @intCast(cur_src.len), into.ptr, @intCast(into.len));
            if (r <= 0) return 0;
            n2 = @intCast(r);
        } else if (txEq(name, "ASCIIHexDecode") or txEq(name, "AHx")) {
            n2 = filt.asciiHex(cur_src, into);
        } else if (txEq(name, "ASCII85Decode") or txEq(name, "A85")) {
            n2 = filt.ascii85(cur_src, into);
        } else if (txEq(name, "RunLengthDecode") or txEq(name, "RL")) {
            n2 = filt.runLength(cur_src, into);
        } else if (txEq(name, "LZWDecode") or txEq(name, "LZW")) {
            const early = intAfter(b, ds, de, "/EarlyChange") orelse 1;
            n2 = filt.lzw(cur_src, into, early);
        } else {
            // 우리가 못 푸는 필터(DCT·JPX·JBIG2·CCITT)는 여기서 다루지 않는다
            return 0;
        }
        if (n2 == 0) return 0;
        cur_src = into[0..n2];
        out_n = n2;
    }
    // 홀수 번이면 결과가 tmp 에 있다
    if (nn % 2 == 0) {
        if (out_n > dst.len) return 0;
        @memcpy(dst[0..out_n], tmp[0..out_n]);
    }

    // 예측기
    if (find(b[ds..de], "/Predictor", 0)) |_| {
        const pred = intAfter(b, ds, de, "/Predictor") orelse 1;
        if (pred > 1) {
            const colors = intAfter(b, ds, de, "/Colors") orelse 1;
            const bpc2 = intAfter(b, ds, de, "/BitsPerComponent") orelse 8;
            const cols = intAfter(b, ds, de, "/Columns") orelse 1;
            out_n = filt.unpredict(dst[0..out_n], pred, colors, bpc2, cols);
        }
    }
    return out_n;
}

/// 객체 num 의 스트림을 풀어 임시 자리에 두고 돌려준다.
/// 두 번 부르면 앞의 것이 덮인다 — 부른 쪽이 곧바로 써야 한다.
fn streamOf(b: []const u8, num: u32) ?[]const u8 {
    return streamFrom(b, findObj(b, num) orelse return null);
}

/// 객체 몸통 자리를 알 때 쓰는 판. 번호를 모르는 자리에서도 스트림을 편다.
fn streamFrom(b: []const u8, body: usize) ?[]const u8 {
    const sp = find(b, "stream", body) orelse return null;
    // 길이를 못 읽어도 포기하지 않는다 — endstream 이 어디 있는지는 보인다
    const raw_len = lengthOf(b, body, sp) orelse 0;
    var data = sp + 6;
    if (data < b.len and b[data] == '\r') data += 1;
    if (data < b.len and b[data] == '\n') data += 1;
    const length = fixStreamLen(b, data, raw_len);
    // data 는 b 안이므로 b.len - data 는 안전하다. data + length 로 견주면
    // 넘쳐서 통과해 버린다(위 fixStreamLen 주석).
    if (length > b.len - data) return null;

    if (find(b[body..sp], "/Filter", 0) == null) {
        return b[data .. data + length]; // 필터가 없으면 그대로
    }
    // 푼 크기는 미리 알 수 없다. 넉넉히 잡아 풀되, 자리를 꽉 채웠으면
    // 잘렸다는 뜻이므로 배로 늘려 다시 푼다. 예전에는 남은 자리에 맞춰
    // 자르고 말았고, 그래서 큰 쪽이 반만 그려지거나 통째로 사라졌다.
    var want = @max(@as(usize, 1024 * 1024), length *| 4);
    var tries: u32 = 0;
    while (tries < 8) : (tries += 1) {
        const dst = growBuf(&tmp_at, &tmp_cap, want, 1024 * 1024, 0) orelse return null;
        const got = decodeChain(b, body, sp, data, length, dst);
        if (got == 0) return null;
        if (got < dst.len) return dst[0..got];
        // 딱 맞게 찼다 — 더 있는지 모르니 늘려서 다시 본다
        want = dst.len *| 2;
        if (want <= dst.len) return dst[0..got];
    }
    return @as([*]const u8, @ptrFromInt(tmp_at))[0..tmp_cap];
}


// ===== 문서에 박힌 글꼴 =====
//
// 브라우저에 글자를 맡기려면 글꼴 파일이 필요하다. PDF 안의 글꼴은 대개
// 부분집합이라, 파일이 그대로는 쓸 수 없다. Type0(Identity-H) 글꼴은 문자
// 코드가 곧 글리프 번호라서 파일 안의 cmap 이 우리가 넘길 유니코드와 맞지
// 않는다. 그래서 cmap 을 "유니코드 → 글리프 번호"로 다시 적어 끼운다.
// PDF.js 도 같은 일을 한다 — 글리프 외곽선을 직접 그리지 않고 글꼴을 고쳐
// FontFace 로 넘긴 뒤 평범한 fillText 를 쓴다.

/// 유니코드 → 글리프 번호. 0 은 없음으로 본다.
var uni2gid: [65536]u16 = undefined;

fn be16(b: []const u8, o: usize) u16 {
    if (o + 2 > b.len) return 0;
    return (@as(u16, b[o]) << 8) | b[o + 1];
}
fn be32(b: []const u8, o: usize) u32 {
    if (o + 4 > b.len) return 0;
    return (@as(u32, b[o]) << 24) | (@as(u32, b[o + 1]) << 16) |
        (@as(u32, b[o + 2]) << 8) | b[o + 3];
}
fn wr16(d: []u8, o: usize, v: u16) void {
    if (o + 2 > d.len) return;
    d[o] = @intCast(v >> 8);
    d[o + 1] = @truncate(v);
}
fn wr32(d: []u8, o: usize, v: u32) void {
    if (o + 4 > d.len) return;
    d[o] = @truncate(v >> 24);
    d[o + 1] = @truncate(v >> 16);
    d[o + 2] = @truncate(v >> 8);
    d[o + 3] = @truncate(v);
}
fn sumTable(d: []const u8, off: usize, len: usize) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= len) : (i += 4) sum +%= be32(d, off + i);
    if (i < len) { // 남는 바이트는 0 으로 채워 읽는다
        var tail: u32 = 0;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            tail <<= 8;
            if (i + k < len) tail |= d[off + i + k];
        }
        sum +%= tail;
    }
    return sum;
}

/// U+E000 부터 글리프 번호를 차례로 붙인 cmap 을 만든다. 구간 하나면 끝난다.
fn buildPuaCmap(dst: []u8, nglyphs: u16) u32 {
    if (nglyphs == 0 or dst.len < 64) return 0;
    const last: u16 = 0xE000 + nglyphs - 1;
    if (last > 0xF8FF) return 0;
    const segs: u32 = 2; // 우리 구간 + 규격이 요구하는 0xFFFF
    const sub_len = 16 + segs * 8;
    const total = 12 + sub_len;
    if (total > dst.len) return 0;
    wr16(dst, 0, 0);
    wr16(dst, 2, 1);
    wr16(dst, 4, 3);
    wr16(dst, 6, 1);
    wr32(dst, 8, 12);
    const s0 = 12;
    wr16(dst, s0 + 0, 4);
    wr16(dst, s0 + 2, @intCast(sub_len));
    wr16(dst, s0 + 4, 0);
    wr16(dst, s0 + 6, @intCast(segs * 2));
    wr16(dst, s0 + 8, 4);
    wr16(dst, s0 + 10, 1);
    wr16(dst, s0 + 12, 0);
    wr16(dst, s0 + 14, last);
    wr16(dst, s0 + 16, 0xFFFF);
    wr16(dst, s0 + 18, 0); // reservedPad
    wr16(dst, s0 + 20, 0xE000);
    wr16(dst, s0 + 22, 0xFFFF);
    wr16(dst, s0 + 24, @as(u16, 0) -% @as(u16, 0xE000));
    wr16(dst, s0 + 26, 1);
    wr16(dst, s0 + 28, 0);
    wr16(dst, s0 + 30, 0);
    return total;
}

/// 유니코드→글리프 표로 cmap(형식 4) 하나를 만든다. 쓴 바이트 수를 준다.
fn buildCmap(dst: []u8, has: []const u16, has_n: u32) u32 {
    if (has_n == 0 or dst.len < 32) return 0;
    // 이어지는 구간을 묶는다: 델타가 같은 동안 한 구간
    var seg_start: [1024]u16 = undefined;
    var seg_end: [1024]u16 = undefined;
    var seg_delta: [1024]u16 = undefined;
    var segs: u32 = 0;
    var i: u32 = 0;
    while (i < has_n and segs < 1023) {
        const lo = has[i];
        const g0 = uni2gid[lo];
        const delta: u16 = g0 -% lo;
        var j = i + 1;
        while (j < has_n and has[j] == has[j - 1] + 1 and
            (uni2gid[has[j]] -% has[j]) == delta) : (j += 1)
        {}
        seg_start[segs] = lo;
        seg_end[segs] = has[j - 1];
        seg_delta[segs] = delta;
        segs += 1;
        i = j;
    }
    // 마지막 0xFFFF 구간은 규격이 요구한다
    seg_start[segs] = 0xFFFF;
    seg_end[segs] = 0xFFFF;
    seg_delta[segs] = 1;
    segs += 1;

    const sub_len = 16 + segs * 8;
    const total = 12 + sub_len;
    if (total > dst.len) return 0;

    wr16(dst, 0, 0); // version
    wr16(dst, 2, 1); // numTables
    wr16(dst, 4, 3); // platform: 윈도
    wr16(dst, 6, 1); // encoding: BMP
    wr32(dst, 8, 12);

    const s0 = 12;
    wr16(dst, s0 + 0, 4);
    wr16(dst, s0 + 2, @intCast(sub_len));
    wr16(dst, s0 + 4, 0);
    wr16(dst, s0 + 6, @intCast(segs * 2));
    var p2: u32 = 1;
    var es: u16 = 0;
    while (p2 * 2 <= segs) : (p2 *= 2) es += 1;
    wr16(dst, s0 + 8, @intCast(p2 * 2));
    wr16(dst, s0 + 10, es);
    wr16(dst, s0 + 12, @intCast(segs * 2 - p2 * 2));
    var k: u32 = 0;
    while (k < segs) : (k += 1) {
        wr16(dst, s0 + 14 + k * 2, seg_end[k]);
        wr16(dst, s0 + 16 + segs * 2 + k * 2, seg_start[k]);
        wr16(dst, s0 + 16 + segs * 4 + k * 2, seg_delta[k]);
        wr16(dst, s0 + 16 + segs * 6 + k * 2, 0);
    }
    wr16(dst, s0 + 14 + segs * 2, 0); // reservedPad
    return total;
}

// ===== 없는 표를 지어 채우기 =====
//
// 브라우저는 글꼴을 그냥 받지 않고 한 번 걸러 본다(크롬은 OTS). 규격이
// 있어야 한다고 정한 표가 빠져 있으면 통째로 거절한다 — FontFace 가
// "Invalid font data" 를 던지고, 우리는 글리프를 사용자 영역 번호로 집기
// 때문에 대체 글꼴에도 그 번호가 없어 글자가 **한 자도 안 그려진다**.
//
// 실제로 한글 워드프로세서가 뽑은 문서가 name·OS/2·post 없이 글꼴을 담아,
// 여섯 쪽이 거의 빈 채로 나왔다. 없으면 여기서 최소한으로 지어 넣는다.

/// name — 이름표. 창(3,1,영어) 자리에 넉 줄만 둔다.
fn buildNameTable(dst: []u8) u32 {
    const FAM = "PDFEmbedded";
    const SUB = "Regular";
    const nrec = 4;
    const storage = 6 + nrec * 12;
    if (dst.len < storage + (FAM.len + SUB.len) * 2) return 0;
    wr16(dst, 0, 0); // format 0
    wr16(dst, 2, nrec);
    wr16(dst, 4, @intCast(storage));
    // 글자열은 UTF-16BE 로 담는다
    var w: u32 = @intCast(storage);
    const fam_off: u32 = 0;
    var i: usize = 0;
    while (i < FAM.len) : (i += 1) {
        wr16(dst, w, FAM[i]);
        w += 2;
    }
    const subOff: u32 = @intCast(FAM.len * 2);
    i = 0;
    while (i < SUB.len) : (i += 1) {
        wr16(dst, w, SUB[i]);
        w += 2;
    }
    // 줄은 (플랫폼, 인코딩, 언어, 이름번호) 차례로 놓여야 한다
    const ids = [nrec]u16{ 1, 2, 4, 6 };
    var r: u32 = 6;
    var k: u32 = 0;
    while (k < nrec) : (k += 1) {
        const fam = ids[k] != 2;
        wr16(dst, r, 3); // 윈도
        wr16(dst, r + 2, 1); // 유니코드 BMP
        wr16(dst, r + 4, 0x0409); // 영어
        wr16(dst, r + 6, ids[k]);
        wr16(dst, r + 8, @intCast(if (fam) FAM.len * 2 else SUB.len * 2));
        wr16(dst, r + 10, @intCast(if (fam) fam_off else subOff));
        r += 12;
    }
    return w;
}

/// OS/2 — 판 4. 값은 흔한 본문 글꼴에 맞춰 무난하게 둔다.
fn buildOs2Table(dst: []u8) u32 {
    if (dst.len < 96) return 0;
    @memset(dst[0..96], 0);
    wr16(dst, 0, 4); // version
    wr16(dst, 2, 500); // xAvgCharWidth
    wr16(dst, 4, 400); // usWeightClass 보통
    wr16(dst, 6, 5); // usWidthClass 보통
    wr16(dst, 8, 0); // fsType — 심는 데 제한 없음
    wr16(dst, 10, 650);
    wr16(dst, 12, 600);
    wr16(dst, 16, 75);
    wr16(dst, 18, 650);
    wr16(dst, 20, 600);
    wr16(dst, 24, 350);
    wr16(dst, 26, 50);
    wr16(dst, 28, 250);
    // achVendID
    dst[58] = 'P';
    dst[59] = 'D';
    dst[60] = 'F';
    dst[61] = ' ';
    wr16(dst, 62, 0x0040); // fsSelection — 보통체
    wr16(dst, 64, 0x0020); // usFirstCharIndex
    wr16(dst, 66, 0xFFFF); // usLastCharIndex
    wr16(dst, 68, 800); // sTypoAscender
    wr16(dst, 70, @bitCast(@as(i16, -200))); // sTypoDescender
    wr16(dst, 72, 200); // sTypoLineGap
    wr16(dst, 74, 1000); // usWinAscent
    wr16(dst, 76, 200); // usWinDescent
    wr32(dst, 78, 1); // ulCodePageRange1 — 라틴1
    wr16(dst, 86, 500); // sxHeight
    wr16(dst, 88, 700); // sCapHeight
    wr16(dst, 92, 0x20); // usBreakChar
    wr16(dst, 94, 1); // usMaxContext
    return 96;
}

/// post — 판 3.0. 글리프 이름은 담지 않는다.
fn buildPostTable(dst: []u8) u32 {
    if (dst.len < 32) return 0;
    @memset(dst[0..32], 0);
    wr32(dst, 0, 0x00030000);
    wr16(dst, 8, @bitCast(@as(i16, -100))); // underlinePosition
    wr16(dst, 10, 50); // underlineThickness
    return 32;
}

/// 글꼴 파일의 cmap 을 f 의 코드표로 갈아 끼워 dst 에 새로 적는다.
/// 성공하면 새 파일 길이, 실패하면 0.
fn patchFont(src: []const u8, f: *FontMap, dst: []u8) u32 {
    if (src.len < 12) return 0;
    const tag = be32(src, 0);
    // 0x00010000(트루타입), 'true', 'OTTO' 만 받는다
    if (tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F) return 0;
    const num = be16(src, 4);
    if (num == 0 or num > 64 or 12 + @as(usize, num) * 16 > src.len) return 0;
    if (dst.len < 4096) return 0;
    const scratch = dst.len / 2;

    // 글리프 수는 maxp 에 있다
    var nglyphs: u32 = 0;
    {
        var t: u16 = 0;
        while (t < num) : (t += 1) {
            const r = 12 + @as(usize, t) * 16;
            if (be32(src, r) == 0x6D617870) { // 'maxp'
                const off = be32(src, r + 8);
                if (off + 6 <= src.len) nglyphs = be16(src, off + 4);
            }
        }
    }

    const cmap_len = buildFontCmap(f, @intCast(@min(nglyphs, 65535)), dst[scratch..]);
    if (cmap_len == 0) return 0;

    // 표 하나: from 0 이면 원본, 1 이면 임시 자리(dst[scratch..])
    const Tbl = struct { tag: u32, from: u8, off: u32, len: u32 };
    var tbl: [80]Tbl = undefined;
    var tn: u32 = 0;

    // 원본에서 남길 것 (cmap 은 우리 것으로 바꾼다)
    var has_name = false;
    var has_os2 = false;
    var has_post = false;
    var t: u16 = 0;
    while (t < num and tn + 8 < tbl.len) : (t += 1) {
        const r = 12 + @as(usize, t) * 16;
        const tt = be32(src, r);
        if (tt == 0x636D6170) continue; // 'cmap'
        const off = be32(src, r + 8);
        const ln = be32(src, r + 12);
        if (off > src.len or ln > src.len - off) return 0;
        if (tt == 0x6E616D65) has_name = true;
        if (tt == 0x4F532F32) has_os2 = true;
        if (tt == 0x706F7374) has_post = true;
        tbl[tn] = .{ .tag = tt, .from = 0, .off = off, .len = ln };
        tn += 1;
    }
    // 우리가 지은 cmap
    tbl[tn] = .{ .tag = 0x636D6170, .from = 1, .off = 0, .len = cmap_len };
    tn += 1;

    // 규격이 있어야 한다고 정한 표가 빠졌으면 지어 넣는다.
    // 없으면 브라우저가 글꼴을 통째로 거절해 글자가 한 자도 안 그려진다.
    var syn: u32 = (cmap_len + 3) & ~@as(u32, 3);
    const room = dst.len - scratch;
    if (!has_name and syn + 256 < room) {
        const n2 = buildNameTable(dst[scratch + syn ..]);
        if (n2 > 0) {
            tbl[tn] = .{ .tag = 0x6E616D65, .from = 1, .off = syn, .len = n2 };
            tn += 1;
            syn = (syn + n2 + 3) & ~@as(u32, 3);
        }
    }
    if (!has_os2 and syn + 128 < room) {
        const n2 = buildOs2Table(dst[scratch + syn ..]);
        if (n2 > 0) {
            tbl[tn] = .{ .tag = 0x4F532F32, .from = 1, .off = syn, .len = n2 };
            tn += 1;
            syn = (syn + n2 + 3) & ~@as(u32, 3);
        }
    }
    if (!has_post and syn + 64 < room) {
        const n2 = buildPostTable(dst[scratch + syn ..]);
        if (n2 > 0) {
            tbl[tn] = .{ .tag = 0x706F7374, .from = 1, .off = syn, .len = n2 };
            tn += 1;
            syn = (syn + n2 + 3) & ~@as(u32, 3);
        }
    }

    // 표 목록은 이름순이어야 한다 (규격). 개수가 적어 그냥 끼워 넣기로 센다.
    {
        var si: u32 = 1;
        while (si < tn) : (si += 1) {
            const v = tbl[si];
            var j: u32 = si;
            while (j > 0 and tbl[j - 1].tag > v.tag) : (j -= 1) tbl[j] = tbl[j - 1];
            tbl[j] = v;
        }
    }
    const out_n = tn;
    // 표들이 서로 겹쳐 있으면 옮겨 적을 때 원본보다 몇 배로 부푼다.
    // 부풀 만큼만 허락하고 그 위는 손대지 않는다.
    var claim: u32 = 0;
    var ci: u32 = 0;
    while (ci < tn) : (ci += 1) claim += tbl[ci].len + 3;
    if (claim > 4 * src.len + 65536) return 0;
    const dir = 12 + out_n * 16;
    var pos: u32 = (dir + 3) & ~@as(u32, 3);
    if (pos >= scratch) return 0;

    // 표를 차례로 옮겨 적고 표 목록을 만든다
    var head_pos: u32 = 0;
    var recs: u32 = 0;
    var w: u32 = 0;
    while (w < out_n) : (w += 1) {
        const tt = tbl[w].tag;
        const ln = tbl[w].len;
        if (pos + ln > scratch) return 0;
        if (tbl[w].from == 1) {
            @memcpy(dst[pos..][0..ln], dst[scratch + tbl[w].off ..][0..ln]);
        } else {
            @memcpy(dst[pos..][0..ln], src[tbl[w].off..][0..ln]);
        }
        if (tt == 0x68656164) head_pos = pos; // 'head'
        const r = 12 + recs * 16;
        wr32(dst, r, tt);
        wr32(dst, r + 4, sumTable(dst, pos, ln));
        wr32(dst, r + 8, pos);
        wr32(dst, r + 12, ln);
        recs += 1;
        const end = pos + ln;
        pos = (end + 3) & ~@as(u32, 3);
        // 4바이트 맞춤으로 생긴 빈틈. 이전 쪽의 찌꺼기가 남지 않게 0 으로 둔다.
        @memset(dst[end..pos], 0);
    }

    wr32(dst, 0, tag);
    wr16(dst, 4, @intCast(out_n));
    var p2: u32 = 1;
    var es: u16 = 0;
    while (p2 * 2 <= out_n) : (p2 *= 2) es += 1;
    wr16(dst, 6, @intCast(p2 * 16));
    wr16(dst, 8, es);
    wr16(dst, 10, @intCast(out_n * 16 - p2 * 16));

    // head 의 checkSumAdjustment 를 다시 센다
    if (head_pos != 0 and head_pos + 12 <= pos) {
        wr32(dst, head_pos + 8, 0);
        const whole = sumTable(dst, 0, pos);
        wr32(dst, head_pos + 8, 0xB1B0AFBA -% whole);
    }
    return pos;
}

/// 글꼴 하나에 쓸 cmap 을 만든다.
///
/// Identity-H 는 문자 코드가 곧 글리프 번호라, 유니코드를 거치지 않고
/// 사용자 영역(U+E000~)에 번호를 그대로 붙인다. 그렇지 않으면 ToUnicode 를
/// 뒤집어 "유니코드 → 글리프" 표를 만든다.
fn buildFontCmap(f: *FontMap, nglyphs: u16, dst: []u8) u32 {
    f.pua = false;
    if (f.identity and nglyphs > 0 and nglyphs <= 6400) {
        const n = buildPuaCmap(dst, nglyphs);
        if (n > 0) { f.pua = true; return n; }
    }
    @memset(&uni2gid, 0);
    // 본 유니코드를 적어 두는 자리. 2048 개로 못박혀 있어 그 뒤 글자가
    // cmap 에서 빠졌다. u16 전 영역을 담게 넓힌다.
    var has: [65536]u16 = undefined;
    var has_n: u32 = 0;
    var i: u16 = 0;
    while (i < f.n) : (i += 1) {
        const u = u16buf(f.unis_at, f.unis_cap)[i];
        const gid = u16buf(f.codes_at, f.codes_cap)[i];
        if (u == 0 or gid == 0) continue;
        if (uni2gid[u] == 0) {
            uni2gid[u] = gid;
            if (has_n < has.len) { has[has_n] = u; has_n += 1; }
        }
    }
    if (has_n == 0) return 0;
    var a: u32 = 1;
    while (a < has_n) : (a += 1) {
        const v = has[a];
        var b2: u32 = a;
        while (b2 > 0 and has[b2 - 1] > v) : (b2 -= 1) has[b2] = has[b2 - 1];
        has[b2] = v;
    }
    return buildCmap(dst, &has, has_n);
}

// ===== 암호 =====
//
// 표준 보안 처리기. 빈 사용자 암호로 잠긴 파일이 대부분이라 그것만 푼다.
// 판 2~4 는 RC4·AES-128, 판 5~6 은 AES-256 이다.

const crypt = @import("pdfcrypt.zig");
const std14 = @import("pdfstd14.zig");
const ccitt = @import("pdfccitt.zig");
const jbig2 = @import("pdfjbig2.zig");
const jpx = @import("pdfjpx.zig");
const jpeg = @import("pdfjpeg.zig");
const filt = @import("pdffilters.zig");

const PAD = [32]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56,
    0xFF, 0xFA, 0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

var enc_on = false;
var enc_aes = false;
var enc_key: [32]u8 = undefined;
var enc_key_len: u32 = 0;
var enc_obj: u32 = 0;
var enc_v: u32 = 0;

/// 딕셔너리에서 문자열(리터럴이나 16진)을 꺼낸다.
fn readPdfString(b: []const u8, s2: usize, e: usize, key: []const u8, out: []u8) u32 {
    const at = find(b[s2..e], key, 0) orelse return 0;
    var p = s2 + at + key.len;
    while (p < e and isSpace(b[p])) p += 1;
    if (p >= e) return 0;
    var n: u32 = 0;
    if (b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < e and b[p] != '>') : (p += 1) {
            const v = hexVal(b[p]) orelse continue;
            if (hi) |h| {
                if (n >= out.len) break;
                out[n] = (h << 4) | v;
                n += 1;
                hi = null;
            } else hi = v;
        }
        if (hi) |h| { if (n < out.len) { out[n] = h << 4; n += 1; } }
    } else if (b[p] == '(') {
        p += 1;
        while (p < e and b[p] != ')') : (p += 1) {
            if (n >= out.len) break;
            if (b[p] == '\\' and p + 1 < e) {
                p += 1;
                out[n] = switch (b[p]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'b' => 8,
                    'f' => 12,
                    else => b[p],
                };
            } else out[n] = b[p];
            n += 1;
        }
    }
    return n;
}

/// 판 6 의 해시 2.B
fn hash2B(pwd: []const u8, salt: []const u8, udata: []const u8, out: *[32]u8) void {
    var k: [64]u8 = undefined;
    var klen: usize = 32;
    var k32: [32]u8 = undefined;
    crypt.sha256(&[_][]const u8{ pwd, salt, udata }, &k32);
    @memcpy(k[0..32], &k32);
    var round: u32 = 0;
    var e_last: u8 = 0;
    while (true) {
        // K1 = (암호 + K + udata) 를 64 번
        const one = pwd.len + klen + udata.len;
        if (one == 0 or one * 64 > 8192) break;
        var k1: [8192]u8 = undefined;
        var w: usize = 0;
        var r: u32 = 0;
        while (r < 64) : (r += 1) {
            @memcpy(k1[w..][0..pwd.len], pwd);
            w += pwd.len;
            @memcpy(k1[w..][0..klen], k[0..klen]);
            w += klen;
            if (udata.len > 0) {
                @memcpy(k1[w..][0..udata.len], udata);
                w += udata.len;
            }
        }
        const body = k1[0 .. w - (w % 16)];
        crypt.aesCbcEncrypt(k[0..16], k[16..32], body);
        var sum: u32 = 0;
        var i: usize = 0;
        while (i < 16) : (i += 1) sum += body[i];
        e_last = body[body.len - 1];
        switch (sum % 3) {
            0 => {
                crypt.sha256(&[_][]const u8{body}, &k32);
                @memcpy(k[0..32], &k32);
                klen = 32;
            },
            1 => {
                var k48: [48]u8 = undefined;
                crypt.sha384(&[_][]const u8{body}, &k48);
                @memcpy(k[0..48], &k48);
                klen = 48;
            },
            else => {
                var k64: [64]u8 = undefined;
                crypt.sha512(&[_][]const u8{body}, &k64);
                @memcpy(k[0..64], &k64);
                klen = 64;
            },
        }
        round += 1;
        if (round >= 64 and e_last <= round - 32) break;
        if (round > 256) break;
    }
    @memcpy(out, k[0..32]);
}

/// 화면에서 받아 둔 문서 암호 (읽기용)
var rd_pw: [128]u8 = undefined;
var rd_pw_len: u32 = 0;
/// 암호가 맞지 않아 화면이 물어봐야 하는 상태
var enc_need_pw: bool = false;

export fn clearPassword() void {
    rd_pw_len = 0;
    enc_need_pw = false;
}
/// 암호 한 글자 (utf-8 로 담는다)
export fn addPasswordChar(c: u32) void {
    if (c < 0x80) {
        if (rd_pw_len + 1 > rd_pw.len) return;
        rd_pw[rd_pw_len] = @intCast(c);
        rd_pw_len += 1;
    } else if (c < 0x800) {
        if (rd_pw_len + 2 > rd_pw.len) return;
        rd_pw[rd_pw_len] = @intCast(0xC0 | (c >> 6));
        rd_pw[rd_pw_len + 1] = @intCast(0x80 | (c & 63));
        rd_pw_len += 2;
    } else {
        if (rd_pw_len + 3 > rd_pw.len) return;
        rd_pw[rd_pw_len] = @intCast(0xE0 | (c >> 12));
        rd_pw[rd_pw_len + 1] = @intCast(0x80 | ((c >> 6) & 63));
        rd_pw[rd_pw_len + 2] = @intCast(0x80 | (c & 63));
        rd_pw_len += 3;
    }
}
/// 1 이면 암호가 틀렸거나 아직 안 받았다
export fn needPassword() u32 {
    return if (enc_need_pw) 1 else 0;
}
/// 1 이면 이 문서는 잠겨 있었다
export fn isEncrypted() u32 {
    return if (enc_on) 1 else 0;
}

fn sameBytes(a: []const u8, c: []const u8) bool {
    if (a.len != c.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (a[i] != c[i]) return false;
    return true;
}

/// 암호를 32 바이트로 덧댄다 (판 2~4 의 절차 2)
fn padPw(pw: []const u8, out: *[32]u8) void {
    const m = @min(pw.len, 32);
    var i: usize = 0;
    while (i < m) : (i += 1) out[i] = pw[i];
    while (i < 32) : (i += 1) out[i] = PAD[i - m];
}

/// 이 열쇠로 만든 /U 가 파일의 것과 같은지 본다 (판 2~4)
fn userValueOk(key: []const u8, r: u32, id: []const u8, u: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (r == 2) {
        @memcpy(&buf, &PAD);
        crypt.rc4(key, &buf);
        return u.len >= 32 and sameBytes(buf[0..32], u[0..32]);
    }
    var md: [16]u8 = undefined;
    crypt.md5(&[_][]const u8{ &PAD, id }, &md);
    @memcpy(buf[0..16], &md);
    crypt.rc4(key, buf[0..16]);
    var i: u8 = 1;
    while (i <= 19) : (i += 1) {
        var k2: [16]u8 = undefined;
        var j: usize = 0;
        while (j < key.len) : (j += 1) k2[j] = key[j] ^ i;
        crypt.rc4(k2[0..key.len], buf[0..16]);
    }
    // 판 3 이상은 앞 16 바이트만 뜻이 있다 (뒤는 채움값)
    return u.len >= 16 and sameBytes(buf[0..16], u[0..16]);
}

/// 소유자 암호에서 사용자 암호를 끄집어낸다 (판 2~4 의 절차 7)
fn ownerToUser(o: []const u8, pw: []const u8, n: u32, r: u32, out: *[32]u8) bool {
    if (o.len < 32) return false;
    var p32: [32]u8 = undefined;
    padPw(pw, &p32);
    var md: [16]u8 = undefined;
    crypt.md5(&[_][]const u8{&p32}, &md);
    if (r >= 3) {
        var k: u32 = 0;
        while (k < 50) : (k += 1) {
            var m2: [16]u8 = undefined;
            crypt.md5(&[_][]const u8{md[0..n]}, &m2);
            @memcpy(&md, &m2);
        }
    }
    var buf: [32]u8 = undefined;
    @memcpy(&buf, o[0..32]);
    if (r == 2) {
        crypt.rc4(md[0..n], &buf);
    } else {
        var i: i32 = 19;
        while (i >= 0) : (i -= 1) {
            var k2: [16]u8 = undefined;
            var j: usize = 0;
            while (j < n) : (j += 1) k2[j] = md[j] ^ @as(u8, @intCast(i));
            crypt.rc4(k2[0..n], &buf);
        }
    }
    @memcpy(out, &buf);
    return true;
}

/// /Encrypt 를 찾아 파일 열쇠를 만든다. 받아 둔 암호(없으면 빈 암호)를 쓴다.
fn setupEncryption(b: []const u8) void {
    enc_on = false;
    enc_need_pw = false;
    enc_aes = false;
    enc_key_len = 0;
    enc_obj = 0;
    doc_perm = -1;
    const ea = trailerKeyOrScan(b, "/Encrypt") orelse return;
    var p = ea + 8;
    while (p < b.len and isSpace(b[p])) p += 1;
    if (p >= b.len or !isDigit(b[p])) return;
    enc_obj = readUint(b, &p);
    const eb = findObj(b, enc_obj) orelse return;
    const ee = objDictEnd(b, eb);

    // 권한 비트(/P). 판을 가리지 않고 담아 둔다 — 뷰어가 인쇄·복사 단추를
    // 흐리게 하려면 알아야 한다. 음수로 적히는 것이 보통이다.
    doc_perm = signedAfter(b, eb, ee, "/P") orelse -1;

    const v = intAfter(b, eb, ee, "/V") orelse 1;
    const r = intAfter(b, eb, ee, "/R") orelse 2;
    const length = intAfter(b, eb, ee, "/Length") orelse 40;
    enc_v = v;
    if (v == 4 or v == 5) {
        enc_aes = find(b[eb..ee], "/AESV2", 0) != null or find(b[eb..ee], "/AESV3", 0) != null;
    }

    var o_buf: [48]u8 = undefined;
    var u_buf: [48]u8 = undefined;
    const o_len = readPdfString(b, eb, ee, "/O", &o_buf);
    const u_len = readPdfString(b, eb, ee, "/U", &u_buf);
    if (o_len == 0 or u_len == 0) return;

    if (v >= 5) {
        // AES-256 — 암호로 중간 열쇠를 만들고 /UE(또는 /OE)를 풀어 파일 열쇠를 얻는다
        if (u_len < 48) return;
        const pw = rd_pw[0..rd_pw_len];
        var chk: [32]u8 = undefined;
        var inter: [32]u8 = undefined;
        var wrapped: [48]u8 = undefined;
        var got = false;

        // 사용자 암호
        if (r == 5) {
            crypt.sha256(&[_][]const u8{ pw, u_buf[32..40] }, &chk);
        } else {
            hash2B(pw, u_buf[32..40], &[_]u8{}, &chk);
        }
        if (sameBytes(&chk, u_buf[0..32])) {
            if (r == 5) {
                crypt.sha256(&[_][]const u8{ pw, u_buf[40..48] }, &inter);
            } else {
                hash2B(pw, u_buf[40..48], &[_]u8{}, &inter);
            }
            if (readPdfString(b, eb, ee, "/UE", &wrapped) >= 32) got = true;
        }

        // 소유자 암호
        if (!got and o_len >= 48) {
            if (r == 5) {
                crypt.sha256(&[_][]const u8{ pw, o_buf[32..40], u_buf[0..48] }, &chk);
            } else {
                hash2B(pw, o_buf[32..40], u_buf[0..48], &chk);
            }
            if (sameBytes(&chk, o_buf[0..32])) {
                if (r == 5) {
                    crypt.sha256(&[_][]const u8{ pw, o_buf[40..48], u_buf[0..48] }, &inter);
                } else {
                    hash2B(pw, o_buf[40..48], u_buf[0..48], &inter);
                }
                if (readPdfString(b, eb, ee, "/OE", &wrapped) >= 32) got = true;
            }
        }

        if (!got) {
            // 암호가 맞지 않는다. 그래도 빈 암호로 풀어 보고 화면에는 물어보라고 알린다.
            enc_need_pw = true;
            if (r == 5) {
                crypt.sha256(&[_][]const u8{ pw, u_buf[40..48] }, &inter);
            } else {
                hash2B(pw, u_buf[40..48], &[_]u8{}, &inter);
            }
            if (readPdfString(b, eb, ee, "/UE", &wrapped) < 32) return;
        }

        crypt.aesCbcNoIvDecrypt(&inter, wrapped[0..32]);
        @memcpy(enc_key[0..32], wrapped[0..32]);
        enc_key_len = 32;
        enc_aes = true;
        enc_on = true;
        return;
    }

    // 판 2~4
    var n = length / 8;
    if (v == 1) n = 5;
    if (n < 5) n = 5;
    if (n > 16) n = 16;
    const perm = blk: {
        // /P 는 음수일 수 있다
        const at = find(b[eb..ee], "/P", 0) orelse break :blk @as(i32, -1);
        var q = eb + at + 2;
        while (q < ee and isSpace(b[q])) q += 1;
        var neg = false;
        if (q < ee and b[q] == '-') { neg = true; q += 1; }
        if (q >= ee or !isDigit(b[q])) break :blk @as(i32, -1);
        const val: i64 = readUint(b, &q);
        break :blk @as(i32, @truncate(if (neg) -val else val));
    };
    var pbytes: [4]u8 = undefined;
    const pu: u32 = @bitCast(perm);
    var i: usize = 0;
    while (i < 4) : (i += 1) pbytes[i] = @truncate(pu >> @intCast(8 * i));

    // /ID 배열의 첫 문자열
    var id_buf: [64]u8 = undefined;
    var id_len: u32 = 0;
    if (trailerKeyOrScan(b, "/ID")) |ia| {
        var q = ia + 3;
        while (q < b.len and b[q] != '[') q += 1;
        q += 1;
        while (q < b.len and isSpace(b[q])) q += 1;
        if (q < b.len and b[q] == '<') {
            q += 1;
            var hi: ?u8 = null;
            while (q < b.len and b[q] != '>') : (q += 1) {
                const hv = hexVal(b[q]) orelse continue;
                if (hi) |h| {
                    if (id_len >= id_buf.len) break;
                    id_buf[id_len] = (h << 4) | hv;
                    id_len += 1;
                    hi = null;
                } else hi = hv;
            }
        } else if (q < b.len and b[q] == '(') {
            q += 1;
            while (q < b.len and b[q] != ')' and id_len < id_buf.len) : (q += 1) {
                if (b[q] == '\\' and q + 1 < b.len) q += 1;
                id_buf[id_len] = b[q];
                id_len += 1;
            }
        }
    }

    var meta_extra: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF };
    const no_meta = r >= 4 and find(b[eb..ee], "/EncryptMetadata", 0) != null and
        find(b[eb..ee], "false", 0) != null;

    // 사용자 암호로 먼저 해 보고, 안 맞으면 소유자 암호로 보고 다시 한다.
    var pw32: [32]u8 = undefined;
    padPw(rd_pw[0..rd_pw_len], &pw32);
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        var md: [16]u8 = undefined;
        if (no_meta) {
            crypt.md5(&[_][]const u8{ &pw32, o_buf[0..o_len], &pbytes, id_buf[0..id_len], &meta_extra }, &md);
        } else {
            crypt.md5(&[_][]const u8{ &pw32, o_buf[0..o_len], &pbytes, id_buf[0..id_len] }, &md);
        }
        if (r >= 3) {
            var k: u32 = 0;
            while (k < 50) : (k += 1) {
                var m2: [16]u8 = undefined;
                crypt.md5(&[_][]const u8{md[0..n]}, &m2);
                @memcpy(&md, &m2);
            }
        }
        @memcpy(enc_key[0..n], md[0..n]);
        enc_key_len = n;
        enc_on = true;
        if (userValueOk(md[0..n], r, id_buf[0..id_len], u_buf[0..u_len])) return;
        if (attempt == 1) break;
        if (!ownerToUser(o_buf[0..o_len], rd_pw[0..rd_pw_len], n, r, &pw32)) break;
    }
    // 안 맞아도 열쇠는 그대로 두고 화면에 물어보라고 알린다
    enc_need_pw = true;
}

/// 객체 하나의 자료를 푼다. 푼 길이를 준다.
///
/// 남는 자리에서 풀고 volatile 로 되돌려 놓는다. 제자리에서 풀면 최적화가
/// "이 메모리는 아무도 안 읽는다"고 보고 쓰기를 통째로 지운다 — 실제로
/// ReleaseSmall 에서 RC4 결과가 사라졌다. Debug 에서만 되던 이유가 이것이다.
fn decryptBytes(num: u32, gen: u32, off: usize, len: usize) u32 {
    if (!enc_on or len == 0) return @intCast(len);
    // 여벌보다 큰 스트림이면 메모리 끝을 잠깐 빌린다. 예전에는 그냥 넘겨,
    // 그 스트림만 암호글 그대로 남아 깨진 그림이 되었다.
    const scratch = if (len <= b2_cap)
        @as([*]u8, @ptrFromInt(b2_off))[0..len]
    else
        (bigScratch(len) orelse return @intCast(len));
    const src = @as([*]const u8, @ptrFromInt(heapBase() + off))[0..len];
    @memcpy(scratch, src);

    var dec_len: u32 = @intCast(len);
    if (enc_v >= 5) {
        dec_len = crypt.aesCbcDecrypt(enc_key[0..32], scratch);
    } else {
        var tmp: [32]u8 = undefined;
        const n = enc_key_len;
        @memcpy(tmp[0..n], enc_key[0..n]);
        tmp[n] = @truncate(num);
        tmp[n + 1] = @truncate(num >> 8);
        tmp[n + 2] = @truncate(num >> 16);
        tmp[n + 3] = @truncate(gen);
        tmp[n + 4] = @truncate(gen >> 8);
        var used: usize = n + 5;
        if (enc_aes) {
            tmp[used] = 0x73;
            tmp[used + 1] = 0x41;
            tmp[used + 2] = 0x6C;
            tmp[used + 3] = 0x54;
            used += 4;
        }
        var md: [16]u8 = undefined;
        crypt.md5(&[_][]const u8{tmp[0..used]}, &md);
        const klen = @min(n + 5, 16);
        if (enc_aes) {
            dec_len = crypt.aesCbcDecrypt(md[0..klen], scratch);
        } else {
            crypt.rc4(md[0..klen], scratch);
        }
    }
    const dst: [*]volatile u8 = @ptrFromInt(heapBase() + off);
    var k: usize = 0;
    while (k < dec_len) : (k += 1) dst[k] = scratch[k];
    return dec_len;
}

/// 모든 스트림을 제자리에서 푼다. 객체 스트림을 펼치기 전에 해야 한다.
fn decryptAllStreams(b: []u8) void {
    if (!enc_on) return;
    var num: u32 = 1;
    while (num < obj_cap) : (num += 1) {
        if (objRankTable()[num] == 0) continue;
        if (num == enc_obj) continue;
        const body = objOff()[num];
        const e = find(b, "endobj", body) orelse b.len;
        const sp2 = find(b, "stream", body) orelse continue;
        if (sp2 > e) continue;
        // XRef 스트림은 잠기지 않는다
        if (find(b[body..sp2], "/XRef", 0) != null) continue;
        const raw_len2 = lengthOf(b, body, sp2) orelse 0;
        var data = sp2 + 6;
        if (data < b.len and b[data] == '\r') data += 1;
        if (data < b.len and b[data] == '\n') data += 1;
        const length = fixStreamLen(b, data, raw_len2);
        if (length == 0 or data > b.len or length > b.len - data) continue;
        const got = decryptBytes(num, 0, data, length);
        if (got < length) {
            // 길이가 줄면 남는 자리를 공백으로 덮고 /Length 를 고친다
            var k = data + got;
            while (k < data + length) : (k += 1) b[k] = ' ';
            fixLength(b, body, sp2, got);
        }
    }
}

/// /Length 숫자를 새 값으로 고쳐 적는다 (자리 수가 맞을 때만)
fn fixLength(b: []u8, from: usize, to: usize, val: u32) void {
    var at_from: usize = 0;
    while (find(b[from..to], "/Length", at_from)) |at| {
        var p = from + at + 7;
        const c = if (p < to) b[p] else ' ';
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            at_from = at + 1;
            continue;
        }
        while (p < to and isSpace(b[p])) p += 1;
        const start = p;
        while (p < to and isDigit(b[p])) p += 1;
        const width = p - start;
        if (width == 0) return;
        var tmp: [12]u8 = undefined;
        var n: usize = 0;
        var x = val;
        if (x == 0) { tmp[0] = '0'; n = 1; }
        while (x > 0) : (x /= 10) { tmp[n] = @intCast('0' + (x % 10)); n += 1; }
        if (n > width) return;
        var k: usize = 0;
        while (k < width) : (k += 1) b[start + k] = ' ';
        k = 0;
        while (k < n) : (k += 1) b[start + width - n + k] = tmp[n - 1 - k];
        return;
    }
}

// ===== 문서 속성 =====

/// 딕셔너리에서 음수도 되는 정수 하나. /P 처럼 음수로 적히는 값에 쓴다.
fn signedAfter(b: []const u8, from: usize, to: usize, key: []const u8) ?i32 {
    const at = find(b[from..to], key, 0) orelse return null;
    var q = from + at + key.len;
    // 이름이 그 자리에서 끝나야 한다 (/P 가 /Parent 에 걸리지 않게)
    if (q < to and ((b[q] >= 'a' and b[q] <= 'z') or (b[q] >= 'A' and b[q] <= 'Z'))) return null;
    while (q < to and isSpace(b[q])) q += 1;
    var neg = false;
    if (q < to and b[q] == '-') { neg = true; q += 1; }
    if (q >= to or !isDigit(b[q])) return null;
    const v: i64 = readUint(b, &q);
    return @as(i32, @truncate(if (neg) -v else v));
}

/// 암호 사전의 권한 비트(/P). 암호가 없으면 -1 — 다 된다는 뜻이다.
var doc_perm: i32 = -1;
export fn permissions() i32 { return doc_perm; }

/// 카탈로그(/Root) 딕셔너리 자리.
fn catalogRange(b: []const u8) ?struct { s: usize, e: usize } {
    const at = trailerKeyOrScan(b, "/Root") orelse return null;
    var p2 = at + 5;
    while (p2 < b.len and isSpace(b[p2])) p2 += 1;
    if (p2 >= b.len or !isDigit(b[p2])) return null;
    const num = readUint(b, &p2);
    const cb = findObj(b, num) orelse return null;
    return .{ .s = cb, .e = objDictEnd(b, cb) };
}

// 문서 한 벌 정보 — 뷰어가 처음 열 때 쓰는 것들.
//
//   0 /PageMode      (UseOutlines·UseThumbs·FullScreen…) — 열 때 옆판을 펼칠지
//   1 /PageLayout    (SinglePage·TwoColumnLeft…)         — 한 쪽·두 쪽 보기
//   2 파일 지문       (/ID 첫 문자열, 16진수)              — 문서별 상태 저장 열쇠
//   3 태그 PDF 인가   ("1"·"0", /MarkInfo /Marked)
//   4 문서 언어       (/Lang)
var meta_buf: [512]u8 = undefined;
var meta_off: [5]u32 = undefined;
var meta_len: [5]u32 = undefined;
var meta_n: u32 = 0;
export fn metaCount() u32 { return meta_n; }
export fn metaOff(i: u32) u32 { return if (i < meta_n) meta_off[i] else 0; }
export fn metaLen(i: u32) u32 { return if (i < meta_n) meta_len[i] else 0; }
export fn metaTextPtr() [*]u8 { return &meta_buf; }

fn metaPut(used: *u32, i: usize, txt: []const u8) void {
    if (used.* + txt.len > meta_buf.len) return;
    meta_off[i] = used.*;
    meta_len[i] = @intCast(txt.len);
    @memcpy(meta_buf[used.*..][0..txt.len], txt);
    used.* += @intCast(txt.len);
}

/// 딕셔너리에서 /Key 뒤의 이름(/Foo)을 그대로 읽는다. 슬래시는 뺀다.
/// 이름이 **그 자리에서 끝나는** 첫 자리. /T 가 /Type 에, /C 가 /Contents 에
/// 걸려 엉뚱한 값을 읽던 것을 막는다.
fn keyPos(b: []const u8, from: usize, to: usize, key: []const u8) ?usize {
    var at_from: usize = 0;
    while (find(b[from..to], key, at_from)) |at| {
        const q = from + at + key.len;
        const c = if (q < to) b[q] else ' ';
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) {
            return from + at;
        }
        at_from = at + 1;
    }
    return null;
}

fn nameAfter(b: []const u8, from: usize, to: usize, key: []const u8, out: []u8) u32 {
    // 이름이 그 자리에서 끝나는 것만 고른다 — /S 가 /StructElem 에, /C 가
    // /Contents 에 먼저 걸려 값이 통째로 비던 자리다.
    const at = keyPos(b, from, to, key) orelse return 0;
    var q = at + key.len;
    while (q < to and isSpace(b[q])) q += 1;
    if (q >= to or b[q] != '/') return 0;
    q += 1;
    var n: u32 = 0;
    while (q < to and n < out.len and !isSpace(b[q]) and b[q] != '/' and b[q] != '>' and b[q] != ']') {
        out[n] = b[q];
        n += 1;
        q += 1;
    }
    return n;
}

// 쪽 라벨 — 표지가 i, ii, iii 이고 본문이 1 부터인 문서가 흔하다.
// /PageLabels 는 번호 나무다: [ 0 << /S /r >> 4 << /S /D /St 1 >> ] 처럼
// "이 쪽부터 이 방식" 을 적어 둔다.
var lbl_off_at: usize = 0;
var lbl_len_at: usize = 0;
var lbl_buf_at: usize = 0;
var lbl_buf_cap: usize = 0;
var label_n: u32 = 0;
fn label_off() []u32 { return u32sAt(lbl_off_at, if (pg_cap == 0) 0 else pg_cap); }
fn label_len() []u8 {
    if (lbl_len_at == 0 or pg_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(lbl_len_at))[0..pg_cap];
}
fn label_buf() []u8 {
    if (lbl_buf_at == 0 or lbl_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(lbl_buf_at))[0..lbl_buf_cap];
}
export fn pageLabelCount() u32 { return label_n; }
export fn pageLabelOff(i: u32) u32 { return if (i < label_n) label_off()[i] else 0; }
export fn pageLabelLen(i: u32) u32 { return if (i < label_n) label_len()[i] else 0; }
export fn pageLabelPtr() [*]u8 { return @ptrFromInt(if (lbl_buf_at == 0) heapBase() else lbl_buf_at); }

/// 로마 숫자. 1~3999 만 다룬다(그 밖은 십진수로 떨어뜨린다).
fn roman(n0: u32, upper: bool, out: []u8) u32 {
    if (n0 == 0 or n0 > 3999) return 0;
    const V = [_]u32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
    const SU = [_][]const u8{ "M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I" };
    const SL = [_][]const u8{ "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
    var n = n0;
    var w: u32 = 0;
    var i: usize = 0;
    while (i < V.len) : (i += 1) {
        while (n >= V[i]) {
            const t = if (upper) SU[i] else SL[i];
            if (w + t.len > out.len) return w;
            @memcpy(out[w..][0..t.len], t);
            w += @intCast(t.len);
            n -= V[i];
        }
    }
    return w;
}

/// A, B, … Z, AA, BB … (규격이 정한 방식이다 — 27번째는 AA 다)
fn alphaLabel(n: u32, upper: bool, out: []u8) u32 {
    if (n == 0) return 0;
    const idx: u8 = @intCast((n - 1) % 26);
    const rep: u32 = (n - 1) / 26 + 1;
    const c: u8 = (if (upper) @as(u8, 'A') else @as(u8, 'a')) + idx;
    var w: u32 = 0;
    while (w < rep and w < out.len) : (w += 1) out[w] = c;
    return w;
}

fn collectLabels(b: []const u8) void {
    label_n = 0;
    const cat = catalogRange(b) orelse return;
    const pa = find(b[cat.s..cat.e], "/PageLabels", 0) orelse return;
    // 값이 딴 객체를 가리키면 따라간다
    var ns = cat.s + pa + 11;
    var ne = cat.e;
    while (ns < ne and isSpace(b[ns])) ns += 1;
    if (ns < ne and isDigit(b[ns])) {
        var q = ns;
        const num = readUint(b, &q);
        const ob = findObj(b, num) orelse return;
        ns = ob;
        ne = objDictEnd(b, ob);
    }
    const na = find(b[ns..ne], "/Nums", 0) orelse return;
    var q = ns + na + 5;
    while (q < ne and b[q] != '[') q += 1;
    if (q >= ne) return;
    q += 1;

    const pages = page_count;
    if (pages == 0 or pages > label_off().len) return;
    var used: u32 = 0;
    var page: u32 = 0;

    // 마디를 차례로 읽으며 그 마디가 덮는 쪽들의 라벨을 만든다
    while (q < ne and page < pages) {
        while (q < ne and isSpace(b[q])) q += 1;
        if (q >= ne or b[q] == ']') break;
        if (!isDigit(b[q])) { q += 1; continue; }
        const start_page = readUint(b, &q);
        while (q < ne and isSpace(b[q])) q += 1;
        if (q >= ne or b[q] != '<') break;
        const ds = q;
        // 이 마디의 딕셔너리가 어디서 끝나는지 먼저 잡는다. 어림잡으면
        // 다음 마디의 /P 접두사가 이 마디까지 새어 들어온다(A-i 처럼).
        var de = ne;
        {
            var r = ds;
            var depth: u32 = 0;
            while (r < ne) : (r += 1) {
                if (b[r] == '<' and r + 1 < ne and b[r + 1] == '<') { depth += 1; r += 1; continue; }
                if (b[r] == '>' and r + 1 < ne and b[r + 1] == '>') {
                    if (depth > 0) depth -= 1;
                    r += 1;
                    if (depth == 0) break;
                    continue;
                }
            }
            de = @min(ne, r + 1);
        }
        // 이 마디의 스타일
        var st: [8]u8 = undefined;
        const sn = nameAfter(b, ds, de, "/S", &st);
        var pre: [32]u8 = undefined;
        var pn: u32 = 0;
        if (find(b[ds..de], "/P", 0)) |ppa| {
            var pq = ds + ppa + 2;
            while (pq < de and isSpace(b[pq])) pq += 1;
            if (pq < de and b[pq] == '(') {
                pq += 1;
                while (pq < de and b[pq] != ')' and pn < pre.len) : (pn += 1) { pre[pn] = b[pq]; pq += 1; }
            }
        }
        const first: u32 = if (intAfter(b, ds, de, "/St")) |v| v else 1;
        // 다음 마디의 시작 쪽까지가 이 마디의 범위다
        const scan = de;
        var next_start: u32 = pages;
        {
            var t = scan;
            while (t < ne and isSpace(b[t])) t += 1;
            if (t < ne and isDigit(b[t])) {
                var t2 = t;
                next_start = readUint(b, &t2);
            }
        }
        if (start_page > page) page = start_page;
        var idx: u32 = 0;
        while (page < pages and page < next_start) : ({ page += 1; idx += 1; }) {
            var one: [40]u8 = undefined;
            var w: u32 = 0;
            if (pn > 0 and pn <= one.len) {
                @memcpy(one[0..pn], pre[0..pn]);
                w = pn;
            }
            const nth = first + idx;
            if (sn > 0) {
                const c = st[0];
                if (c == 'D') {
                    var dtmp: [12]u8 = undefined;
                    var dn: u32 = 0;
                    var v = nth;
                    if (v == 0) { dtmp[0] = '0'; dn = 1; }
                    while (v > 0) : (v /= 10) { dtmp[dn] = @intCast('0' + v % 10); dn += 1; }
                    var k: u32 = 0;
                    while (k < dn and w < one.len) : (k += 1) { one[w] = dtmp[dn - 1 - k]; w += 1; }
                } else if (c == 'R' or c == 'r') {
                    w += roman(nth, c == 'R', one[w..]);
                } else if (c == 'A' or c == 'a') {
                    w += alphaLabel(nth, c == 'A', one[w..]);
                }
            }
            if (w == 0 or used + w > label_buf().len) {
                // 스타일이 없으면 접두사만 — 규격이 그렇게 정한다
                if (w == 0 and pn == 0) { label_off()[page] = used; label_len()[page] = 0; continue; }
            }
            if (used + w <= label_buf().len) {
                @memcpy(label_buf()[used..][0..w], one[0..w]);
                label_off()[page] = used;
                label_len()[page] = @intCast(@min(w, 255));
                used += w;
            }
        }
        q = scan;
    }
    label_n = pages;
}

fn collectMeta(b: []const u8) void {
    meta_n = 0;
    var used: u32 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) { meta_off[i] = 0; meta_len[i] = 0; }
    meta_n = 5;

    var tmp: [64]u8 = undefined;
    if (catalogRange(b)) |cat| {
        var n = nameAfter(b, cat.s, cat.e, "/PageMode", &tmp);
        if (n > 0) metaPut(&used, 0, tmp[0..n]);
        n = nameAfter(b, cat.s, cat.e, "/PageLayout", &tmp);
        if (n > 0) metaPut(&used, 1, tmp[0..n]);
        // /MarkInfo << /Marked true >>
        if (find(b[cat.s..cat.e], "/MarkInfo", 0)) |ma| {
            const ms = cat.s + ma;
            const me = @min(cat.e, ms + 120);
            metaPut(&used, 3, if (find(b[ms..me], "/Marked true", 0) != null) "1" else "0");
        }
        // /Lang (문자열)
        if (find(b[cat.s..cat.e], "/Lang", 0)) |la| {
            var q = cat.s + la + 5;
            while (q < cat.e and isSpace(b[q])) q += 1;
            if (q < cat.e and b[q] == '(') {
                q += 1;
                var n2: u32 = 0;
                while (q < cat.e and b[q] != ')' and n2 < tmp.len) : (n2 += 1) { tmp[n2] = b[q]; q += 1; }
                if (n2 > 0) metaPut(&used, 4, tmp[0..n2]);
            }
        }
    }
    // 파일 지문 — /ID 배열의 첫 문자열을 16진수로
    if (trailerKeyOrScan(b, "/ID")) |ia| {
        var q = ia + 3;
        while (q < b.len and b[q] != '[') q += 1;
        q += 1;
        while (q < b.len and isSpace(b[q])) q += 1;
        var hex: [64]u8 = undefined;
        var hn: u32 = 0;
        const HEXD = "0123456789abcdef";
        if (q < b.len and b[q] == '<') {
            q += 1;
            while (q < b.len and b[q] != '>' and hn < hex.len) : (hn += 1) { hex[hn] = b[q]; q += 1; }
        } else if (q < b.len and b[q] == '(') {
            q += 1;
            while (q < b.len and b[q] != ')' and hn + 2 <= hex.len) {
                hex[hn] = HEXD[b[q] >> 4];
                hex[hn + 1] = HEXD[b[q] & 15];
                hn += 2;
                q += 1;
            }
        }
        if (hn > 0) metaPut(&used, 2, hex[0..hn]);
    }
}


var info_buf: [2048]u8 = undefined;
var info_off: [8]u32 = undefined;
var info_len: [8]u32 = undefined;
var info_n: u32 = 0;

export fn infoCount() u32 { return info_n; }
export fn infoOff(i: u32) u32 { return if (i < info_n) info_off[i] else 0; }
export fn infoLen(i: u32) u32 { return if (i < info_n) info_len[i] else 0; }
export fn infoTextPtr() [*]u8 { return &info_buf; }

/// 트레일러의 /Info 를 읽는다. 차례는 제목·지은이·주제·만든 프로그램·
/// 만든 도구·만든 날짜·고친 날짜 이다. 없으면 길이 0.
fn collectInfo(b: []const u8) void {
    info_n = 0;
    var used: u32 = 0;
    const keys = [_][]const u8{ "/Title", "/Author", "/Subject", "/Creator", "/Producer", "/CreationDate", "/ModDate" };
    var is: usize = 0;
    var ie: usize = 0;
    if (trailerKey(b, "/Info")) |ia| {
        var p = ia + 5;
        while (p < b.len and isSpace(b[p])) p += 1;
        if (p < b.len and isDigit(b[p])) {
            const n = readUint(b, &p);
            if (findObj(b, n)) |ib| { is = ib; ie = objDictEnd(b, ib); }
        }
    }
    for (keys) |k| {
        const off: u32 = used;
        var len: u32 = 0;
        if (ie > is) {
            if (find(b[is..ie], k, 0)) |at| {
                len = copyPdfText(b, is + at + k.len, ie, &info_buf, used);
                used += len;
            }
        }
        info_off[info_n] = off;
        info_len[info_n] = len;
        info_n += 1;
        if (info_n >= info_off.len) break;
    }
}

// ===== 링크와 목차 =====

/// 쪽 하나의 링크. 세는 상한은 없다 — 필요한 만큼 늘어난다.
var link_at: usize = 0;
var link_cap: u32 = 0;
fn links() []Link {
    if (link_at == 0 or link_cap == 0) return &[_]Link{};
    return @as([*]Link, @ptrFromInt(link_at))[0..link_cap];
}
const Link = struct { rect: [4]f32, off: u32, len: u32, page: i32 };

var link_n: u32 = 0;
/// link_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var link_buf_at: usize = 0;
var link_buf_cap: u32 = 0;
fn link_buf() []u8 {
    if (link_buf_at == 0 or link_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(link_buf_at))[0..link_buf_cap];
}
fn link_bufRoom(want: u32) bool {
    return growTable(&link_buf_at, &link_buf_cap, want, 1, 16384);
}
var link_buf_n: u32 = 0;

export fn linkCount() u32 { return link_n; }
export fn linkRect(i: u32, k: u32) f32 { return if (i < link_n and k < 4) links()[i].rect[k] else 0; }
export fn linkOff(i: u32) u32 { return if (i < link_n) links()[i].off else 0; }
export fn linkLen(i: u32) u32 { return if (i < link_n) links()[i].len else 0; }
export fn linkPage(i: u32) i32 { return if (i < link_n) links()[i].page else -1; }
export fn linkTextPtr() [*]u8 { return @ptrFromInt(if (link_buf_at == 0) heapBase() else link_buf_at); }

/// 목차 줄 수. 세는 상한은 없다.
var mark_at: usize = 0;
var mark_cap: u32 = 0;
const Bookmark = struct { depth: u8, off: u32, len: u32, page: i32 };
fn marks() []Bookmark {
    if (mark_at == 0 or mark_cap == 0) return &[_]Bookmark{};
    return @as([*]Bookmark, @ptrFromInt(mark_at))[0..mark_cap];
}
var mark_n: u32 = 0;
/// mark_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var mark_buf_at: usize = 0;
var mark_buf_cap: u32 = 0;
fn mark_buf() []u8 {
    if (mark_buf_at == 0 or mark_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(mark_buf_at))[0..mark_buf_cap];
}
fn mark_bufRoom(want: u32) bool {
    return growTable(&mark_buf_at, &mark_buf_cap, want, 1, 32768);
}
var mark_buf_n: u32 = 0;

export fn outlineCount() u32 { return mark_n; }
export fn outlineDepth(i: u32) u32 { return if (i < mark_n) marks()[i].depth else 0; }
export fn outlineOff(i: u32) u32 { return if (i < mark_n) marks()[i].off else 0; }
export fn outlineLen(i: u32) u32 { return if (i < mark_n) marks()[i].len else 0; }
export fn outlinePage(i: u32) i32 { return if (i < mark_n) marks()[i].page else -1; }
export fn outlineTextPtr() [*]u8 { return @ptrFromInt(if (mark_buf_at == 0) heapBase() else mark_buf_at); }

/// 쪽 객체 번호를 쪽 차례로 바꾼다.
fn pageIndexOf(obj: u32) i32 {
    var i: u32 = 0;
    while (i < page_count) : (i += 1) if (page_objs()[i] == obj) return @intCast(i);
    return -1;
}

/// PDF 문자열을 UTF-8 로 옮겨 buf 에 담는다. 담은 길이.
///
/// 먼저 날바이트로 풀고(이스케이프·16진), 앞에 FE FF 가 있으면 UTF-16BE 로
/// 본다. 이스케이프된 상태로 표식을 찾으면 못 알아본다.
fn copyPdfText(b: []const u8, s2: usize, e: usize, buf: []u8, at: u32) u32 {
    var p = s2;
    while (p < e and isSpace(b[p])) p += 1;
    if (p >= e) return 0;
    var raw: [1024]u8 = undefined;
    var rn: usize = 0;
    if (b[p] == '(') {
        p += 1;
        var depth: u32 = 1;
        while (p < e and rn < raw.len) : (p += 1) {
            if (b[p] == '\\') {
                p += 1;
                if (p >= e) break;
                if (b[p] >= '0' and b[p] <= '7') {
                    var v3: u32 = 0;
                    var d3: u32 = 0;
                    while (d3 < 3 and p < e and b[p] >= '0' and b[p] <= '7') : (d3 += 1) {
                        v3 = v3 * 8 + (b[p] - '0');
                        p += 1;
                    }
                    p -= 1;
                    raw[rn] = @truncate(v3);
                    rn += 1;
                    continue;
                }
                raw[rn] = switch (b[p]) { 'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p] };
                rn += 1;
                continue;
            }
            if (b[p] == '(') depth += 1;
            if (b[p] == ')') { depth -= 1; if (depth == 0) break; }
            raw[rn] = b[p];
            rn += 1;
        }
    } else if (b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < e and b[p] != '>' and rn < raw.len) : (p += 1) {
            const v = hexVal(b[p]) orelse continue;
            if (hi) |h| { raw[rn] = (h << 4) | v; rn += 1; hi = null; } else hi = v;
        }
    } else return 0;

    var n: u32 = 0;
    const put = struct {
        fn go(dst: []u8, w: *u32, base: u32, cp: u32) void {
            if (base + w.* + 4 >= dst.len) return;
            const o = base + w.*;
            if (cp < 0x80) { dst[o] = @intCast(cp); w.* += 1; }
            else if (cp < 0x800) {
                dst[o] = @intCast(0xC0 | (cp >> 6));
                dst[o + 1] = @intCast(0x80 | (cp & 0x3F));
                w.* += 2;
            } else {
                dst[o] = @intCast(0xE0 | (cp >> 12));
                dst[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                dst[o + 2] = @intCast(0x80 | (cp & 0x3F));
                w.* += 3;
            }
        }
    }.go;
    if (rn >= 2 and raw[0] == 0xFE and raw[1] == 0xFF) {
        var i: usize = 2;
        while (i + 1 < rn) : (i += 2)
            put(buf, &n, at, (@as(u32, raw[i]) << 8) | raw[i + 1]);
    } else {
        var i: usize = 0;
        while (i < rn) : (i += 1) put(buf, &n, at, raw[i]);
    }
    return n;
}

/// /Dest 나 /A /D 에서 쪽을 알아낸다.
/// 이름으로 가리킨 목적지를 찾는다.
///
/// `/Dest /1장` 처럼 이름만 적힌 링크가 흔하다. 실제 자리는 카탈로그의
/// /Names /Dests 이름나무(또는 옛 꼴인 /Dests 딕셔너리)에 있다. 예전에는
/// 배열 꼴만 봐서 그런 링크와 목차가 통째로 안 먹었다.
fn destByName(b: []const u8, name: []const u8) i32 {
    if (name.len == 0 or doc_root == 0) return -1;
    const rb = findObj(b, doc_root) orelse return -1;
    const re = objDictEnd(b, rb);

    // 옛 꼴 — 카탈로그의 /Dests 딕셔너리
    if (find(b[rb..re], "/Dests", 0)) |da| {
        var p = rb + da + 6;
        while (p < re and isSpace(b[p])) p += 1;
        var ds = p;
        var de = re;
        if (p < re and isDigit(b[p])) {
            const n = readUint(b, &p);
            if (findObj(b, n)) |ob| { ds = ob; de = objDictEnd(b, ob); }
        }
        if (findKeyDest(b, ds, de, name)) |pg| return pg;
    }

    // 새 꼴 — /Names /Dests 이름나무
    const na = find(b[rb..re], "/Names", 0) orelse return -1;
    var p2 = rb + na + 6;
    while (p2 < re and isSpace(b[p2])) p2 += 1;
    var ns = p2;
    var ne = re;
    if (p2 < re and isDigit(b[p2])) {
        const n = readUint(b, &p2);
        if (findObj(b, n)) |ob| { ns = ob; ne = objDictEnd(b, ob); }
    }
    const da2 = find(b[ns..ne], "/Dests", 0) orelse return -1;
    var p3 = ns + da2 + 6;
    while (p3 < ne and isSpace(b[p3])) p3 += 1;
    if (p3 < ne and isDigit(b[p3])) {
        const n = readUint(b, &p3);
        return walkNameTree(b, n, name, 0);
    }
    if (p3 < ne and b[p3] == '<') return walkNameAt(b, p3, dictEnd(b, p3, ne), name, 0);
    return -1;
}

/// 이름나무 한 마디. /Names 가 있으면 거기서 찾고, 없으면 /Kids 로 내려간다.
fn walkNameTree(b: []const u8, num: u32, name: []const u8, depth: u8) i32 {
    const ob = findObj(b, num) orelse return -1;
    return walkNameAt(b, ob, objDictEnd(b, ob), name, depth);
}

fn walkNameAt(b: []const u8, ob: usize, oe: usize, name: []const u8, depth: u8) i32 {
    if (depth > 8) return -1;
    if (find(b[ob..oe], "/Names", 0)) |na| {
        var q = ob + na + 6;
        while (q < oe and b[q] != '[') q += 1;
        const end = arrayEnd(b, q, oe);
        if (findKeyDest(b, q, end, name)) |pg| return pg;
    }
    if (find(b[ob..oe], "/Kids", 0)) |ka| {
        var q = ob + ka + 5;
        while (q < oe and b[q] != '[') q += 1;
        const end = arrayEnd(b, q, oe);
        q += 1;
        var guard: u32 = 0;
        while (q < end and guard < 256) : (guard += 1) {
            while (q < end and isSpace(b[q])) q += 1;
            if (q >= end or !isDigit(b[q])) break;
            const kid = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and isDigit(b[q])) _ = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and b[q] == 'R') q += 1;
            const got = walkNameTree(b, kid, name, depth + 1);
            if (got >= 0) return got;
        }
    }
    return -1;
}

/// "(이름) 값" 이 늘어선 자리에서 이름을 찾아 그 값의 쪽을 준다.
// ===== 구조 나무 =====
//
// 태그 PDF 는 "이건 제목, 이건 문단, 이건 표의 칸" 을 따로 적어 둔다.
// 스크린리더가 읽는 차례와 뜻이 여기서 나온다(pdf.js 의 getStructTree).
// 나무를 그대로 옮기지 않고 깊이를 붙여 납작하게 준다 — 쓰는 쪽이 다시
// 세우기 쉽고, 재귀 자료를 wasm 경계 너머로 옮기지 않아도 된다.
const StructNode = struct {
    depth: u8 = 0,
    page: i32 = -1,
    mcid: i32 = -1,
    role_off: u32 = 0,
    role_len: u16 = 0,
    alt_off: u32 = 0,
    alt_len: u16 = 0,
};
/// 태그 구조 나무의 마디. 세는 상한은 없다.
var st_at: usize = 0;
var st_cap: u32 = 0;
fn st_nodes() []StructNode {
    if (st_at == 0 or st_cap == 0) return &[_]StructNode{};
    return @as([*]StructNode, @ptrFromInt(st_at))[0..st_cap];
}
var st_n: u32 = 0;
/// st_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var st_buf_at: usize = 0;
var st_buf_cap: u32 = 0;
fn st_buf() []u8 {
    if (st_buf_at == 0 or st_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(st_buf_at))[0..st_buf_cap];
}
fn st_bufRoom(want: u32) bool {
    return growTable(&st_buf_at, &st_buf_cap, want, 1, 32768);
}
var st_used: u32 = 0;

export fn structCount() u32 { return st_n; }
export fn structDepth(i: u32) u32 { return if (i < st_n) st_nodes()[i].depth else 0; }
export fn structPageOf(i: u32) i32 { return if (i < st_n) st_nodes()[i].page else -1; }
export fn structMcid(i: u32) i32 { return if (i < st_n) st_nodes()[i].mcid else -1; }
export fn structRoleOff(i: u32) u32 { return if (i < st_n) st_nodes()[i].role_off else 0; }
export fn structRoleLen(i: u32) u32 { return if (i < st_n) st_nodes()[i].role_len else 0; }
export fn structAltOff(i: u32) u32 { return if (i < st_n) st_nodes()[i].alt_off else 0; }
export fn structAltLen(i: u32) u32 { return if (i < st_n) st_nodes()[i].alt_len else 0; }
export fn structTextPtr() [*]u8 { return @ptrFromInt(if (st_buf_at == 0) heapBase() else st_buf_at); }

fn stPut(txt: []const u8) struct { off: u32, len: u16 } {
    _ = st_bufRoom(st_used + @as(u32, @intCast(txt.len)) + 64);
    if (txt.len == 0 or st_used + txt.len > st_buf().len or txt.len > 65535) return .{ .off = 0, .len = 0 };
    const off = st_used;
    @memcpy(st_buf()[off..][0..txt.len], txt);
    st_used += @intCast(txt.len);
    return .{ .off = off, .len = @intCast(txt.len) };
}

/// 구조 요소 하나와 그 아래를 훑는다. /K 는 숫자(MCID)·딕셔너리·배열 셋 다 온다.
fn walkStruct(b: []const u8, ob: usize, oe: usize, depth: u8, page_hint: i32) void {
    if (depth > 32) return;
    if (!growTable(&st_at, &st_cap, st_n, @sizeOf(StructNode), 256)) return;
    var node: StructNode = .{ .depth = depth, .page = page_hint };

    var tmp: [64]u8 = undefined;
    const rn = nameAfter(b, ob, oe, "/S", &tmp);
    if (rn > 0) {
        const put = stPut(tmp[0..rn]);
        node.role_off = put.off;
        node.role_len = put.len;
    } else if (depth == 0) {
        // 뿌리(StructTreeRoot)에는 /S 가 없다. pdf.js 처럼 이름을 붙여 준다.
        const put = stPut("Root");
        node.role_off = put.off;
        node.role_len = put.len;
    }
    // 대체 글(/Alt) — 그림에 붙는 설명이다
    if (keyPos(b, ob, oe, "/Alt")) |aa| {
        _ = st_bufRoom(st_used + 8192);
        const n2 = copyPdfText(b, aa + 4, oe, st_buf(), st_used);
        if (n2 > 0) {
            node.alt_off = st_used;
            node.alt_len = @intCast(n2);
            st_used += n2;
        }
    }
    // 이 요소가 어느 쪽에 놓였나 (/Pg)
    var page = page_hint;
    if (keyPos(b, ob, oe, "/Pg")) |pa| {
        var q = pa + 3;
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and isDigit(b[q])) page = pageIndexOf(readUint(b, &q));
    }
    node.page = page;
    const me = st_n;
    st_nodes()[st_n] = node;
    st_n += 1;

    // 아래를 훑는다
    const ka = keyPos(b, ob, oe, "/K") orelse return;
    var q = ka + 2;
    while (q < oe and isSpace(b[q])) q += 1;
    if (q >= oe) return;

    if (isDigit(b[q])) {
        // 숫자 하나면 MCID, "3 0 R" 이면 딴 객체다
        var q2 = q;
        const v = readUint(b, &q2);
        var q3 = q2;
        while (q3 < oe and isSpace(b[q3])) q3 += 1;
        const is_ref = q3 < oe and isDigit(b[q3]);
        if (is_ref) {
            if (findObj(b, v)) |kb| walkStruct(b, kb, objDictEnd(b, kb), depth + 1, page);
        } else {
            st_nodes()[me].mcid = @intCast(v);
        }
        return;
    }
    if (b[q] == '<') {
        walkStruct(b, q, dictEnd(b, q, oe), depth + 1, page);
        return;
    }
    if (b[q] != '[') return;
    const end = arrayEnd(b, q, oe);
    q += 1;
    var guard: u32 = 0;
    while (q < end and guard < 65536) : (guard += 1) {
        while (q < end and isSpace(b[q])) q += 1;
        if (q >= end or b[q] == ']') break;
        if (isDigit(b[q])) {
            const v = readUint(b, &q);
            var q3 = q;
            while (q3 < end and isSpace(b[q3])) q3 += 1;
            if (q3 < end and isDigit(b[q3])) {
                // "n 0 R" — 딴 객체
                _ = readUint(b, &q3);
                while (q3 < end and isSpace(b[q3])) q3 += 1;
                if (q3 < end and b[q3] == 'R') q3 += 1;
                q = q3;
                if (findObj(b, v)) |kb| walkStruct(b, kb, objDictEnd(b, kb), depth + 1, page);
            } else {
                // 그냥 MCID — 잎으로 담는다
                var leaf: StructNode = .{ .depth = depth + 1, .page = page, .mcid = @intCast(v) };
                leaf.role_off = st_nodes()[me].role_off;
                leaf.role_len = st_nodes()[me].role_len;
                st_nodes()[st_n] = leaf;
                st_n += 1;
            }
            continue;
        }
        if (b[q] == '<') {
            const de = dictEnd(b, q, end);
            walkStruct(b, q, de, depth + 1, page);
            q = de;
            continue;
        }
        q += 1;
    }
}

fn collectStruct(b: []const u8) void {
    st_n = 0;
    st_used = 0;
    const cat = catalogRange(b) orelse return;
    const sa = keyPos(b, cat.s, cat.e, "/StructTreeRoot") orelse return;
    var q = sa + 15;
    while (q < cat.e and isSpace(b[q])) q += 1;
    if (q < cat.e and isDigit(b[q])) {
        const n = readUint(b, &q);
        if (findObj(b, n)) |ob| walkStruct(b, ob, objDictEnd(b, ob), 0, -1);
    } else if (q < cat.e and b[q] == '<') {
        walkStruct(b, q, dictEnd(b, q, cat.e), 0, -1);
    }
}

// ===== 이름 목적지 · 뷰어 설정 · XMP =====
//
// 목차와 링크가 "3쪽" 대신 이름으로 가리키는 문서가 흔하다. 이름을 물어보면
// 풀어 주는 길은 있었는데(destByName) 목록을 통째로 내어 주는 길이 없었다.
/// dest_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var dest_buf_at: usize = 0;
var dest_buf_cap: u32 = 0;
fn dest_buf() []u8 {
    if (dest_buf_at == 0 or dest_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(dest_buf_at))[0..dest_buf_cap];
}
fn dest_bufRoom(want: u32) bool {
    return growTable(&dest_buf_at, &dest_buf_cap, want, 1, 32768);
}
/// 이름 목적지. 256 이던 것을 올렸다 — 책 한 권은 그보다 많다.
/// 이름 붙은 자리의 이름 위치. 필요한 만큼 늘어난다(세는 상한 없음).
var dest_off_at: usize = 0;
var dest_off_cap: u32 = 0;
fn dest_offBuf() []u32 {
    if (dest_off_at == 0 or dest_off_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(dest_off_at))[0..dest_off_cap];
}
fn dest_offRoom(want: u32) bool { return growTable(&dest_off_at, &dest_off_cap, want, @sizeOf(u32), 256); }
/// 그 이름의 길이. 필요한 만큼 늘어난다(세는 상한 없음).
var dest_len_at: usize = 0;
var dest_len_cap: u32 = 0;
fn dest_lenBuf() []u8 {
    if (dest_len_at == 0 or dest_len_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(dest_len_at))[0..dest_len_cap];
}
fn dest_lenRoom(want: u32) bool { return growTable(&dest_len_at, &dest_len_cap, want, @sizeOf(u8), 256); }
/// 그 자리가 가리키는 쪽. 256 개로 못박혀 있었다. 필요한 만큼 늘어난다(세는 상한 없음).
var dest_page_at: usize = 0;
var dest_page_cap: u32 = 0;
fn dest_pageBuf() []i32 {
    if (dest_page_at == 0 or dest_page_cap == 0) return &[_]i32{};
    return @as([*]i32, @ptrFromInt(dest_page_at))[0..dest_page_cap];
}
fn dest_pageRoom(want: u32) bool { return growTable(&dest_page_at, &dest_page_cap, want, @sizeOf(i32), 256); }
var dest_n: u32 = 0;
var dest_used: u32 = 0;

export fn destCount() u32 { return dest_n; }
export fn destNameOff(i: u32) u32 { return if (i < dest_n) dest_offBuf()[i] else 0; }
export fn destNameLen(i: u32) u32 { return if (i < dest_n) dest_lenBuf()[i] else 0; }
export fn destPageOf(i: u32) i32 { return if (i < dest_n) dest_pageBuf()[i] else -1; }
export fn destTextPtr() [*]u8 { return @ptrFromInt(if (dest_buf_at == 0) heapBase() else dest_buf_at); }

fn addDest(name: []const u8, page: i32) void {
    if (name.len == 0 or name.len > 255) return;
    if (!dest_offRoom(dest_n + 1) or !dest_lenRoom(dest_n + 1) or !dest_pageRoom(dest_n + 1)) return;
    _ = dest_bufRoom(dest_used + @as(u32, @intCast(name.len)) + 64);
    if (dest_used + name.len > dest_buf().len) return;
    dest_offBuf()[dest_n] = dest_used;
    dest_lenBuf()[dest_n] = @intCast(name.len);
    dest_pageBuf()[dest_n] = page;
    @memcpy(dest_buf()[dest_used..][0..name.len], name);
    dest_used += @intCast(name.len);
    dest_n += 1;
}

/// `(이름) [3 0 R /XYZ …]` 쌍을 죽 훑어 담는다. 이름 나무의 /Names 배열과
/// 옛 /Dests 사전이 같은 모양이라 한 함수로 본다.
fn scanDestPairs(b: []const u8, from: usize, to: usize) void {
    var p = from;
    var guard: u32 = 0;
    while (p < to and guard < 65536) : (guard += 1) {
        while (p < to and b[p] != '(' and b[p] != '/') p += 1;
        if (p >= to) break;
        var key: [128]u8 = undefined;
        var kn: u32 = 0;
        if (b[p] == '(') {
            p += 1;
            while (p < to and b[p] != ')' and kn < key.len) : (p += 1) {
                if (b[p] == '\\' and p + 1 < to) p += 1;
                key[kn] = b[p];
                kn += 1;
            }
            p += 1;
        } else {
            p += 1;
            while (p < to and !isSpace(b[p]) and b[p] != '/' and b[p] != '(' and
                b[p] != '[' and b[p] != '<' and kn < key.len) : (p += 1)
            {
                key[kn] = b[p];
                kn += 1;
            }
        }
        if (kn == 0) continue;
        // 나무 자체의 낱말은 목적지 이름이 아니다
        if (txEq(key[0..kn], "Names") or txEq(key[0..kn], "Kids") or txEq(key[0..kn], "Limits")) continue;
        var page: i32 = -1;
        while (p < to and isSpace(b[p])) p += 1;
        if (p < to and b[p] == '[') {
            page = destArray(b, p, to);
            p = arrayEnd(b, p, to);
        } else if (p < to and b[p] == '<') {
            const de = dictEnd(b, p, to);
            if (find(b[p..de], "/D", 0)) |dd| {
                var q = p + dd + 2;
                while (q < de and isSpace(b[q])) q += 1;
                if (q < de and b[q] == '[') page = destArray(b, q, de);
            }
            p = de;
        } else if (p < to and isDigit(b[p])) {
            const n = readUint(b, &p);
            if (findObj(b, n)) |ob| {
                const oe = objDictEnd(b, ob);
                var q = ob;
                while (q < oe and isSpace(b[q])) q += 1;
                if (q < oe and b[q] == '[') {
                    page = destArray(b, q, oe);
                } else if (find(b[ob..oe], "/D", 0)) |dd| {
                    var q2 = ob + dd + 2;
                    while (q2 < oe and isSpace(b[q2])) q2 += 1;
                    if (q2 < oe and b[q2] == '[') page = destArray(b, q2, oe);
                }
            }
            // "3 0 R" 의 나머지를 건너뛴다
            while (p < to and isSpace(b[p])) p += 1;
            if (p < to and isDigit(b[p])) _ = readUint(b, &p);
            while (p < to and isSpace(b[p])) p += 1;
            if (p < to and b[p] == 'R') p += 1;
        } else continue;
        addDest(key[0..kn], page);
    }
}

fn walkDestTree(b: []const u8, ob: usize, oe: usize, depth: u8) void {
    if (depth > 8) return;
    if (find(b[ob..oe], "/Names", 0)) |na| {
        var q = ob + na + 6;
        while (q < oe and b[q] != '[') q += 1;
        if (q < oe) scanDestPairs(b, q + 1, arrayEnd(b, q, oe));
    }
    if (find(b[ob..oe], "/Kids", 0)) |ka| {
        var q = ob + ka + 5;
        while (q < oe and b[q] != '[') q += 1;
        const end = arrayEnd(b, q, oe);
        q += 1;
        var guard: u32 = 0;
        while (q < end and guard < 256) : (guard += 1) {
            while (q < end and isSpace(b[q])) q += 1;
            if (q >= end or !isDigit(b[q])) break;
            const kid = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and isDigit(b[q])) _ = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and b[q] == 'R') q += 1;
            if (findObj(b, kid)) |kb| walkDestTree(b, kb, objDictEnd(b, kb), depth + 1);
        }
    }
}

fn collectDests(b: []const u8) void {
    dest_n = 0;
    dest_used = 0;
    const cat = catalogRange(b) orelse return;
    // 요즘 방식(/Names 이름 나무)을 **먼저** 본다. 카탈로그 안의 /Dests 는
    // 그 나무를 가리키는 것일 수도 있어(/Names << /Dests 7 0 R >>), 옛 방식으로
    // 잘못 읽으면 "Names" 같은 낱말이 목적지로 섞여 들어온다.
    if (keyPos(b, cat.s, cat.e, "/Names")) |na| {
        var q = na + 6;
        while (q < cat.e and isSpace(b[q])) q += 1;
        var ns = q;
        var ne = cat.e;
        if (q < cat.e and isDigit(b[q])) {
            const n = readUint(b, &q);
            if (findObj(b, n)) |ob| { ns = ob; ne = objDictEnd(b, ob); }
        }
        if (keyPos(b, ns, ne, "/Dests")) |dd| {
            var q2 = dd + 6;
            while (q2 < ne and isSpace(b[q2])) q2 += 1;
            if (q2 < ne and isDigit(b[q2])) {
                const n2 = readUint(b, &q2);
                if (findObj(b, n2)) |ob2| walkDestTree(b, ob2, objDictEnd(b, ob2), 0);
            } else if (q2 < ne and b[q2] == '<') {
                walkDestTree(b, q2, dictEnd(b, q2, ne), 0);
            }
        }
    }
    if (dest_n > 0) return;
    // 옛 방식 — /Dests 사전을 그대로 둔다
    if (keyPos(b, cat.s, cat.e, "/Dests")) |da| {
        var q = da + 6;
        while (q < cat.e and isSpace(b[q])) q += 1;
        if (q < cat.e and isDigit(b[q])) {
            const n = readUint(b, &q);
            if (findObj(b, n)) |ob| scanDestPairs(b, ob, objDictEnd(b, ob));
        } else if (q < cat.e and b[q] == '<') {
            scanDestPairs(b, q, dictEnd(b, q, cat.e));
        }
    }
}

// 뷰어 설정 — 도구줄을 감출지, 제목을 창에 띄울지 같은 것.
var vp_buf: [1024]u8 = undefined;
var vp_koff: [24]u32 = undefined;
var vp_klen: [24]u8 = undefined;
var vp_voff: [24]u32 = undefined;
var vp_vlen: [24]u8 = undefined;
var vp_n: u32 = 0;

export fn viewPrefCount() u32 { return vp_n; }
export fn viewPrefKeyOff(i: u32) u32 { return if (i < vp_n) vp_koff[i] else 0; }
export fn viewPrefKeyLen(i: u32) u32 { return if (i < vp_n) vp_klen[i] else 0; }
export fn viewPrefValOff(i: u32) u32 { return if (i < vp_n) vp_voff[i] else 0; }
export fn viewPrefValLen(i: u32) u32 { return if (i < vp_n) vp_vlen[i] else 0; }
export fn viewPrefTextPtr() [*]u8 { return &vp_buf; }

fn collectViewPrefs(b: []const u8) void {
    vp_n = 0;
    var used: u32 = 0;
    const cat = catalogRange(b) orelse return;
    const va = keyPos(b, cat.s, cat.e, "/ViewerPreferences") orelse return;
    var q = va + 18;
    while (q < cat.e and isSpace(b[q])) q += 1;
    var vs = q;
    var ve = cat.e;
    if (q < cat.e and isDigit(b[q])) {
        const n = readUint(b, &q);
        if (findObj(b, n)) |ob| { vs = ob; ve = objDictEnd(b, ob); }
    } else if (q < cat.e and b[q] == '<') {
        vs = q;
        ve = dictEnd(b, q, cat.e);
    } else return;

    var p = vs;
    while (p < ve and vp_n < vp_koff.len) {
        while (p < ve and b[p] != '/') p += 1;
        if (p >= ve) break;
        p += 1;
        var key: [32]u8 = undefined;
        var kn: u32 = 0;
        while (p < ve and !isSpace(b[p]) and b[p] != '/' and b[p] != '>' and b[p] != '[' and kn < key.len) : (p += 1) {
            key[kn] = b[p];
            kn += 1;
        }
        if (kn == 0) continue;
        while (p < ve and isSpace(b[p])) p += 1;
        var val: [48]u8 = undefined;
        var vn: u32 = 0;
        if (p < ve and b[p] == '/') {
            p += 1;
            while (p < ve and !isSpace(b[p]) and b[p] != '/' and b[p] != '>' and vn < val.len) : (p += 1) {
                val[vn] = b[p];
                vn += 1;
            }
        } else if (p < ve and b[p] == '[') {
            // 배열은 그대로 옮긴다 (/PrintPageRange 등)
            const ae = arrayEnd(b, p, ve);
            while (p <= ae and vn < val.len) : (p += 1) { val[vn] = b[p]; vn += 1; }
        } else {
            while (p < ve and !isSpace(b[p]) and b[p] != '/' and b[p] != '>' and vn < val.len) : (p += 1) {
                val[vn] = b[p];
                vn += 1;
            }
        }
        if (vn == 0 or used + kn + vn > vp_buf.len) continue;
        vp_koff[vp_n] = used;
        vp_klen[vp_n] = @intCast(kn);
        @memcpy(vp_buf[used..][0..kn], key[0..kn]);
        used += kn;
        vp_voff[vp_n] = used;
        vp_vlen[vp_n] = @intCast(vn);
        @memcpy(vp_buf[used..][0..vn], val[0..vn]);
        used += vn;
        vp_n += 1;
    }
}

// XMP — 요즘 문서는 제목·지은이를 여기에도 적는다(RDF/XML 덩어리).
// 통째로 내어 주고 뜯는 것은 쓰는 쪽에 맡긴다.
var xmp_n: u32 = 0;
var xmp_at: u32 = 0;
export fn xmpLen() u32 { return xmp_n; }
export fn xmpPtr() [*]const u8 {
    return @as([*]const u8, @ptrFromInt(xmp_at));
}

fn collectXmp(b: []const u8) void {
    xmp_n = 0;
    xmp_at = 0;
    const cat = catalogRange(b) orelse return;
    const ma = keyPos(b, cat.s, cat.e, "/Metadata") orelse return;
    var q = ma + 9;
    while (q < cat.e and isSpace(b[q])) q += 1;
    if (q >= cat.e or !isDigit(b[q])) return;
    const num = readUint(b, &q);
    const data = streamOf(b, num) orelse return;
    if (data.len == 0) return;
    xmp_at = @intFromPtr(data.ptr);
    xmp_n = @intCast(data.len);
}

fn findKeyDest(b: []const u8, from: usize, to: usize, name: []const u8) ?i32 {
    var p = from;
    var guard: u32 = 0;
    while (p < to and guard < 4096) : (guard += 1) {
        while (p < to and b[p] != '(' and b[p] != '/') p += 1;
        if (p >= to) break;
        var key: [128]u8 = undefined;
        var kn: u32 = 0;
        if (b[p] == '(') {
            p += 1;
            while (p < to and b[p] != ')' and kn < key.len) : (p += 1) {
                if (b[p] == '\\' and p + 1 < to) p += 1;
                key[kn] = b[p];
                kn += 1;
            }
            p += 1;
        } else {
            p += 1;
            while (p < to and !isSpace(b[p]) and b[p] != '/' and b[p] != '(' and
                b[p] != '[' and b[p] != '<' and kn < key.len) : (p += 1)
            {
                key[kn] = b[p];
                kn += 1;
            }
        }
        if (kn == 0) continue;
        if (!txEq(key[0..kn], name)) continue;
        // 값이 배열이면 그 안, 딕셔너리면 /D 를 본다
        while (p < to and isSpace(b[p])) p += 1;
        if (p < to and b[p] == '[') return destArray(b, p, to);
        if (p < to and b[p] == '<') {
            const de = dictEnd(b, p, to);
            if (find(b[p..de], "/D", 0)) |dd| {
                var q = p + dd + 2;
                while (q < de and isSpace(b[q])) q += 1;
                if (q < de and b[q] == '[') return destArray(b, q, de);
            }
            return null;
        }
        if (p < to and isDigit(b[p])) {
            const n = readUint(b, &p);
            if (findObj(b, n)) |ob| {
                const oe = objDictEnd(b, ob);
                var q = ob;
                while (q < oe and isSpace(b[q])) q += 1;
                if (q < oe and b[q] == '[') return destArray(b, q, oe);
                if (find(b[ob..oe], "/D", 0)) |dd| {
                    var q2 = ob + dd + 2;
                    while (q2 < oe and isSpace(b[q2])) q2 += 1;
                    if (q2 < oe and b[q2] == '[') return destArray(b, q2, oe);
                }
            }
            return null;
        }
        return null;
    }
    return null;
}

/// `[3 0 R /XYZ …]` 에서 쪽 번호를 뽑는다.
fn destArray(b: []const u8, at: usize, to: usize) i32 {
    var p = at + 1;
    while (p < to and isSpace(b[p])) p += 1;
    if (p < to and isDigit(b[p])) return pageIndexOf(readUint(b, &p));
    return -1;
}

// ===== 열 때 갈 자리 (/OpenAction) =====
//
// 문서가 "이 쪽 이 자리부터 보여라" 고 적어 두는 곳이다. 규격 12.3.2.
// 예전에는 아예 안 봐서, 3쪽부터 열라고 적힌 문서도 1쪽부터 열었다.
//
//   /OpenAction [3 0 R /XYZ 0 700 null]     — 배열로 바로
//   /OpenAction << /S /GoTo /D [3 0 R /Fit] >>  — 동작 딕셔너리
//   /OpenAction << /S /GoTo /D (장1) >>      — 이름 붙은 자리
//   /OpenAction 9 0 R                        — 그 둘 중 하나를 가리키는 참조
//
// /S 가 /GoTo 가 아니면(자바스크립트·소리·영화…) 갈 자리가 없다는 뜻이다.
/// 0 없음 · 1 XYZ · 2 Fit · 3 FitH · 4 FitV · 5 FitR · 6 FitB · 7 FitBH · 8 FitBV
var open_kind: u32 = 0;
var open_page: i32 = -1;
var open_x: f32 = 0;
var open_y: f32 = 0;
var open_zoom: f32 = 0;
export fn openPage() i32 { return open_page; }
export fn openKind() u32 { return open_kind; }
export fn openX() f32 { return open_x; }
export fn openY() f32 { return open_y; }
export fn openZoom() f32 { return open_zoom; }

fn nan() f32 {
    return @bitCast(@as(u32, 0x7FC00000));
}

/// `[3 0 R /XYZ 0 700 null]` 을 통째로 읽는다. 쪽·모양·자리를 다 담는다.
/// null 은 "그대로 두라" 는 뜻이라 NaN 으로 넘긴다.
fn readDestFull(b: []const u8, at: usize, to: usize) void {
    var p = at + 1;
    while (p < to and isSpace(b[p])) p += 1;
    if (p >= to or !isDigit(b[p])) return;
    const pg = pageIndexOf(readUint(b, &p));
    if (pg < 0) return;
    open_page = pg;
    open_kind = 2; // 이름이 없으면 쪽 맞춤으로 본다
    open_x = nan();
    open_y = nan();
    open_zoom = nan();
    // "0 R" 을 건너뛰고 이름을 찾는다
    while (p < to and b[p] != '/' and b[p] != ']') p += 1;
    if (p >= to or b[p] != '/') return;
    p += 1;
    const ns = p;
    while (p < to and !isSpace(b[p]) and b[p] != ']' and b[p] != '/') p += 1;
    const name = b[ns..p];
    const names = [_][]const u8{ "XYZ", "Fit", "FitH", "FitV", "FitR", "FitB", "FitBH", "FitBV" };
    open_kind = 2;
    for (names, 0..) |nm, i| {
        if (txEq(name, nm)) {
            open_kind = @intCast(i + 1);
            break;
        }
    }
    // 뒤따르는 숫자들 — XYZ 는 x y zoom, FitH·FitBH 는 y, FitV·FitBV 는 x
    var got: [4]f32 = .{ nan(), nan(), nan(), nan() };
    var gn: usize = 0;
    while (p < to and b[p] != ']' and gn < got.len) {
        while (p < to and isSpace(b[p])) p += 1;
        if (p >= to or b[p] == ']') break;
        if (isDigit(b[p]) or b[p] == '-' or b[p] == '+' or b[p] == '.') {
            got[gn] = readFloat(b, &p);
            gn += 1;
        } else {
            // null 도 한 자리를 차지한다
            if (p + 4 <= to and std_mem_eq(b[p .. p + 4], "null")) gn += 1;
            while (p < to and !isSpace(b[p]) and b[p] != ']') p += 1;
        }
    }
    switch (open_kind) {
        1 => { open_x = got[0]; open_y = got[1]; open_zoom = got[2]; },
        3, 7 => open_y = got[0],
        4, 8 => open_x = got[0],
        5 => { open_x = got[0]; open_y = got[1]; },
        else => {},
    }
}

/// 이름 붙은 자리를 이름표에서 찾는다. collectDests 가 먼저 돌아 있어야 한다.
fn openByName(name: []const u8) void {
    var i: u32 = 0;
    while (i < dest_n) : (i += 1) {
        const off = dest_offBuf()[i];
        const len = dest_lenBuf()[i];
        if (len != name.len) continue;
        const buf = dest_buf();
        if (off + len > buf.len) continue;
        if (!std_mem_eq(buf[off..][0..len], name)) continue;
        open_page = dest_pageBuf()[i];
        open_kind = 2;
        open_x = nan();
        open_y = nan();
        open_zoom = nan();
        return;
    }
}

/// 딕셔너리 하나를 동작으로 본다. /S 가 /GoTo 여야 갈 자리가 있다.
fn readOpenDict(b: []const u8, ds: usize, de: usize) void {
    if (keyPos(b, ds, de, "/S")) |sa| {
        var q = sa + 2;
        while (q < de and isSpace(b[q])) q += 1;
        if (q < de and b[q] == '/') {
            q += 1;
            const ns = q;
            while (q < de and !isSpace(b[q]) and b[q] != '/' and b[q] != '>') q += 1;
            if (!txEq(b[ns..q], "GoTo")) return; // 우리가 갈 수 있는 것만
        }
    }
    const da = keyPos(b, ds, de, "/D") orelse return;
    var q = da + 2;
    while (q < de and isSpace(b[q])) q += 1;
    if (q >= de) return;
    if (b[q] == '[') {
        readDestFull(b, q, arrayEnd(b, q, de));
    } else if (b[q] == '(') {
        q += 1;
        const ns = q;
        while (q < de and b[q] != ')') q += 1;
        openByName(b[ns..q]);
    } else if (b[q] == '/') {
        q += 1;
        const ns = q;
        while (q < de and !isSpace(b[q]) and b[q] != '/' and b[q] != '>') q += 1;
        openByName(b[ns..q]);
    } else if (isDigit(b[q])) {
        const n = readUint(b, &q);
        if (findObj(b, n)) |ob| {
            const oe = objDictEnd(b, ob);
            var q2 = ob;
            while (q2 < oe and isSpace(b[q2])) q2 += 1;
            if (q2 < oe and b[q2] == '[') readDestFull(b, q2, arrayEnd(b, q2, oe));
        }
    }
}

fn collectOpenAction(b: []const u8) void {
    open_kind = 0;
    open_page = -1;
    open_x = 0;
    open_y = 0;
    open_zoom = 0;
    const cat = catalogRange(b) orelse return;
    const oa = keyPos(b, cat.s, cat.e, "/OpenAction") orelse return;
    var p = oa + 11;
    while (p < cat.e and isSpace(b[p])) p += 1;
    if (p >= cat.e) return;
    if (b[p] == '[') {
        readDestFull(b, p, arrayEnd(b, p, cat.e));
    } else if (b[p] == '<') {
        readOpenDict(b, p, dictEnd(b, p, cat.e));
    } else if (isDigit(b[p])) {
        const n = readUint(b, &p);
        if (findObj(b, n)) |ob| {
            const oe = objDictEnd(b, ob);
            var q = ob;
            while (q < oe and isSpace(b[q])) q += 1;
            if (q < oe and b[q] == '[') readDestFull(b, q, arrayEnd(b, q, oe))
            else readOpenDict(b, ob, oe);
        }
    }
}

// ===== 딸린 파일 (첨부) =====
//
// 세금계산서나 계약서에 원본 파일을 통째로 넣어 두는 일이 흔하다.
// 카탈로그의 /Names /EmbeddedFiles 이름나무에 "이름 → 파일 스트림" 으로
// 들어 있다. 예전에는 아예 안 봐서, 첨부가 있는지조차 알 수 없었다.
/// 딸린 파일. 32 이던 것을 올렸다.
/// 딸린 파일 표 셋을 함께 늘린다.
fn attRoom(want: u32) bool {
    return att_objRoom(want) and att_name_offRoom(want) and att_name_lenRoom(want);
}
/// 딸린 파일의 객체 번호. 필요한 만큼 늘어난다(세는 상한 없음).
var att_obj_at: usize = 0;
var att_obj_cap: u32 = 0;
fn att_objBuf() []u32 {
    if (att_obj_at == 0 or att_obj_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(att_obj_at))[0..att_obj_cap];
}
fn att_objRoom(want: u32) bool { return growTable(&att_obj_at, &att_obj_cap, want, @sizeOf(u32), 64); }
/// 그 이름 위치. 필요한 만큼 늘어난다(세는 상한 없음).
var att_name_off_at: usize = 0;
var att_name_off_cap: u32 = 0;
fn att_name_offBuf() []u32 {
    if (att_name_off_at == 0 or att_name_off_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(att_name_off_at))[0..att_name_off_cap];
}
fn att_name_offRoom(want: u32) bool { return growTable(&att_name_off_at, &att_name_off_cap, want, @sizeOf(u32), 64); }
/// 그 이름 길이. 필요한 만큼 늘어난다(세는 상한 없음).
var att_name_len_at: usize = 0;
var att_name_len_cap: u32 = 0;
fn att_name_lenBuf() []u32 {
    if (att_name_len_at == 0 or att_name_len_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(att_name_len_at))[0..att_name_len_cap];
}
fn att_name_lenRoom(want: u32) bool { return growTable(&att_name_len_at, &att_name_len_cap, want, @sizeOf(u32), 64); }
var att_n: u32 = 0;
/// att_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var att_buf_at: usize = 0;
var att_buf_cap: u32 = 0;
fn att_buf() []u8 {
    if (att_buf_at == 0 or att_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(att_buf_at))[0..att_buf_cap];
}
fn att_bufRoom(want: u32) bool {
    return growTable(&att_buf_at, &att_buf_cap, want, 1, 8192);
}
var att_used: u32 = 0;

export fn attCount() u32 { return att_n; }
export fn attTextPtr() usize { return (if (att_buf_at == 0) heapBase() else att_buf_at); }
export fn attNameOff(i: u32) u32 { return if (i < att_n) att_name_offBuf()[i] else 0; }
export fn attNameLen(i: u32) u32 { return if (i < att_n) att_name_lenBuf()[i] else 0; }

/// 첨부 하나를 풀어 임시 자리에 놓는다. 길이를 준다(0 이면 못 꺼냄).
export fn attLoad(i: u32) u32 {
    if (i >= att_n) return 0;
    const b = searchSlice();
    const ob = findObj(b, att_objBuf()[i]) orelse return 0;
    const oe = objDictEnd(b, ob);
    // /EF << /F 12 0 R >> 가 진짜 파일 스트림이다
    const ea = find(b[ob..oe], "/EF", 0) orelse return 0;
    var p = ob + ea + 3;
    while (p < oe and isSpace(b[p])) p += 1;
    const de = if (p < oe and b[p] == '<') dictEnd(b, p, oe) else oe;
    const fa = find(b[p..de], "/F", 0) orelse return 0;
    var q = p + fa + 2;
    while (q < de and isSpace(b[q])) q += 1;
    if (q >= de or !isDigit(b[q])) return 0;
    const fnum = readUint(b, &q);
    const body = findObj(b, fnum) orelse return 0;
    const data = streamFrom(b, body) orelse return 0;
    if (data.len == 0) return 0;
    // 꺼낼 때 그 크기만큼 빌린다. 예전에는 32MB 짜리 정적 배열이라, 딸린
    // 파일이 없는 문서에서도 늘 32MB 를 들고 있었고 그보다 큰 붙임은
    // 아예 못 꺼냈다.
    const room = bigScratch(data.len) orelse return 0;
    att_at = @intFromPtr(room.ptr);
    @memcpy(room[0..data.len], data);
    return @intCast(data.len);
}
var att_at: usize = 0;
export fn attPtr() usize { return if (att_at == 0) heapBase() else att_at; }

/// 이름나무를 훑어 딸린 파일을 걷는다.
fn walkAttTree(b: []const u8, num: u32, depth: u8) void {
    const ob = findObj(b, num) orelse return;
    walkAttAt(b, ob, objDictEnd(b, ob), depth);
}

/// 이름나무 한 마디. 딴 객체로 가리키든 그 자리에 적혀 있든 여기로 온다.
fn walkAttAt(b: []const u8, ob: usize, oe: usize, depth: u8) void {
    if (depth > 8 or !attRoom(att_n + 1)) return;
    if (find(b[ob..oe], "/Names", 0)) |na| {
        var q = ob + na + 6;
        while (q < oe and b[q] != '[') q += 1;
        const end = arrayEnd(b, q, oe);
        var guard: u32 = 0;
        while (q < end and attRoom(att_n + 1) and guard < 4096) : (guard += 1) {
            while (q < end and b[q] != '(' and b[q] != '<') q += 1;
            if (q >= end) break;
            _ = att_bufRoom(att_used + 4096);
            const nm = sigPutStrTo(b, q, end, att_buf(), &att_used);
            // 이름 뒤의 값이 파일 명세다
            q = skipVal(b, q, end);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and isDigit(b[q])) {
                const fnum = readUint(b, &q);
                att_objBuf()[att_n] = fnum;
                att_name_offBuf()[att_n] = nm[0];
                att_name_lenBuf()[att_n] = nm[1];
                att_n += 1;
                while (q < end and isSpace(b[q])) q += 1;
                if (q < end and isDigit(b[q])) _ = readUint(b, &q);
                while (q < end and isSpace(b[q])) q += 1;
                if (q < end and b[q] == 'R') q += 1;
            } else if (q < end and b[q] == '<') {
                // 값이 그 자리에 적힌 꼴은 다루지 않는다 (드물다)
                q = dictEnd(b, q, end);
            }
        }
    }
    if (find(b[ob..oe], "/Kids", 0)) |ka| {
        var q = ob + ka + 5;
        while (q < oe and b[q] != '[') q += 1;
        const end = arrayEnd(b, q, oe);
        q += 1;
        var guard: u32 = 0;
        while (q < end and guard < 256) : (guard += 1) {
            while (q < end and isSpace(b[q])) q += 1;
            if (q >= end or !isDigit(b[q])) break;
            const kid = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and isDigit(b[q])) _ = readUint(b, &q);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and b[q] == 'R') q += 1;
            walkAttTree(b, kid, depth + 1);
        }
    }
}

/// XFA 양식인가 (/AcroForm /XFA).
///
/// XFA 는 PDF 안에 XML 로 든 딴 세상 양식이다. 순수 XFA 문서는 쪽 내용이
/// "이 문서는 Acrobat 으로 여세요" 한 줄뿐이라, 우리가 제대로 그려도 빈
/// 종이처럼 보인다. 그릴 수는 없어도 왜 그런지는 알려 줘야 한다.
var has_xfa: bool = false;
export fn isXfa() u32 { return if (has_xfa) 1 else 0; }

fn checkXfa(b: []const u8) void {
    has_xfa = false;
    if (doc_root == 0) return;
    const rb = findObj(b, doc_root) orelse return;
    const re = objDictEnd(b, rb);
    const aa = find(b[rb..re], "/AcroForm", 0) orelse return;
    var p = rb + aa + 9;
    while (p < re and isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = re;
    if (p < re and b[p] == '<') { ae = dictEnd(b, p, re); }
    else if (p < re and isDigit(b[p])) {
        const n = readUint(b, &p);
        if (findObj(b, n)) |ob| { as2 = ob; ae = objDictEnd(b, ob); }
    }
    has_xfa = find(b[as2..ae], "/XFA", 0) != null;
}

fn collectAttach(b: []const u8) void {
    att_n = 0;
    att_used = 0;
    if (doc_root == 0) return;
    const rb = findObj(b, doc_root) orelse return;
    const re = objDictEnd(b, rb);
    const na = find(b[rb..re], "/Names", 0) orelse return;
    var p = rb + na + 6;
    while (p < re and isSpace(b[p])) p += 1;
    var ns = p;
    var ne = re;
    if (p < re and isDigit(b[p])) {
        const n = readUint(b, &p);
        if (findObj(b, n)) |ob| { ns = ob; ne = objDictEnd(b, ob); }
    }
    const ea = find(b[ns..ne], "/EmbeddedFiles", 0) orelse return;
    var q = ns + ea + 14;
    while (q < ne and isSpace(b[q])) q += 1;
    if (q < ne and isDigit(b[q])) walkAttTree(b, readUint(b, &q), 0)
    else if (q < ne and b[q] == '<') walkAttAt(b, q, dictEnd(b, q, ne), 0);
}

fn destPage(b: []const u8, s2: usize, e: usize) i32 {
    var p = s2;
    while (p < e and isSpace(b[p])) p += 1;
    if (p < e and b[p] == '[') return destArray(b, p, e);
    // 이름으로 가리킨 꼴 — /Dest /1장 이나 /Dest (1장)
    if (p < e and (b[p] == '/' or b[p] == '(')) {
        var name: [128]u8 = undefined;
        var n: u32 = 0;
        if (b[p] == '(') {
            p += 1;
            while (p < e and b[p] != ')' and n < name.len) : (p += 1) {
                if (b[p] == '\\' and p + 1 < e) p += 1;
                name[n] = b[p];
                n += 1;
            }
        } else {
            p += 1;
            while (p < e and !isSpace(b[p]) and b[p] != '/' and b[p] != '>' and
                b[p] != ']' and n < name.len) : (p += 1)
            {
                name[n] = b[p];
                n += 1;
            }
        }
        if (n > 0) return destByName(b, name[0..n]);
    }
    // 딴 객체를 가리키는 꼴
    if (p < e and isDigit(b[p])) {
        const num = readUint(b, &p);
        var q = p;
        while (q < e and isSpace(b[q])) q += 1;
        if (q < e and isDigit(b[q])) {
            _ = readUint(b, &q);
            while (q < e and isSpace(b[q])) q += 1;
            if (q < e and b[q] == 'R') {
                if (findObj(b, num)) |ob| {
                    const oe = objDictEnd(b, ob);
                    var r = ob;
                    while (r < oe and isSpace(b[r])) r += 1;
                    if (r < oe and b[r] == '[') return destArray(b, r, oe);
                }
            }
        }
    }
    return -1;
}

/// 쪽의 링크 주석을 모은다.
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
var ann_at: usize = 0;
var ann_cap: u32 = 0;
fn anns() []Ann {
    if (ann_at == 0 or ann_cap == 0) return &[_]Ann{};
    return @as([*]Ann, @ptrFromInt(ann_at))[0..ann_cap];
}
var ann_n: u32 = 0;
/// ann_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var ann_buf_at: usize = 0;
var ann_buf_cap: u32 = 0;
fn ann_buf() []u8 {
    if (ann_buf_at == 0 or ann_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(ann_buf_at))[0..ann_buf_cap];
}
fn ann_bufRoom(want: u32) bool {
    return growTable(&ann_buf_at, &ann_buf_cap, want, 1, 65536);
}
var ann_used: u32 = 0;

export fn annCount() u32 { return ann_n; }
export fn annObj(i: u32) u32 { return if (i < ann_n) anns()[i].obj else 0; }
export fn annFlags(i: u32) u32 { return if (i < ann_n) anns()[i].flags else 0; }
export fn annRect(i: u32, k: u32) f32 { return if (i < ann_n and k < 4) anns()[i].rect[k] else 0; }
export fn annHasColor(i: u32) u32 { return if (i < ann_n and anns()[i].has_color) 1 else 0; }
export fn annColor(i: u32, k: u32) f32 { return if (i < ann_n and k < 3) anns()[i].color[k] else 0; }
export fn annTextPtr() [*]u8 { return @ptrFromInt(if (ann_buf_at == 0) heapBase() else ann_buf_at); }
export fn annSubOff(i: u32) u32 { return if (i < ann_n) anns()[i].sub_off else 0; }
export fn annSubLen(i: u32) u32 { return if (i < ann_n) anns()[i].sub_len else 0; }
export fn annBodyOff(i: u32) u32 { return if (i < ann_n) anns()[i].txt_off else 0; }
export fn annBodyLen(i: u32) u32 { return if (i < ann_n) anns()[i].txt_len else 0; }
export fn annAuthorOff(i: u32) u32 { return if (i < ann_n) anns()[i].au_off else 0; }
export fn annAuthorLen(i: u32) u32 { return if (i < ann_n) anns()[i].au_len else 0; }
export fn annDateOff(i: u32) u32 { return if (i < ann_n) anns()[i].dt_off else 0; }
export fn annDateLen(i: u32) u32 { return if (i < ann_n) anns()[i].dt_len else 0; }


/// 쪽에 달린 주석을 모두 걷는다. 링크·위젯도 포함한다 — 쓰는 쪽이 가린다.
fn collectAnnots(b: []const u8, body: usize, end: usize) void {
    ann_n = 0;
    ann_used = 0;
    const aa = find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') {
        as2 = p + 1;
        ae = arrayEnd(b, p, end);
    } else if (p < end and isDigit(b[p])) {
        const an = readUint(b, &p);
        if (findObj(b, an)) |ab| {
            const abe = find(b, "endobj", ab) orelse b.len;
            var q = ab;
            while (q < abe and b[q] != '[') q += 1;
            as2 = q + 1;
            ae = arrayEnd(b, q, abe);
        } else return;
    } else return;

    var q = as2;
    while (q < ae) {
        if (!growTable(&ann_at, &ann_cap, ann_n, @sizeOf(Ann), 128)) break;
        while (q < ae and isSpace(b[q])) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!isDigit(b[q])) { q += 1; continue; }
        const num = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and isDigit(b[q])) _ = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;

        const ab = findObj(b, num) orelse continue;
        const abe = objDictEnd(b, ab);
        var a: Ann = .{};
        a.obj = num;

        var name: [32]u8 = undefined;
        const nn = nameAfter(b, ab, abe, "/Subtype", &name);
        _ = ann_bufRoom(ann_used + nn + 64);
        if (nn > 0 and ann_used + nn <= ann_buf().len) {
            a.sub_off = ann_used;
            a.sub_len = nn;
            @memcpy(ann_buf()[ann_used..][0..nn], name[0..nn]);
            ann_used += nn;
        }
        if (find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) a.rect[i] = readFloat(b, &rp);
            if (a.rect[2] < a.rect[0]) { const t = a.rect[0]; a.rect[0] = a.rect[2]; a.rect[2] = t; }
            if (a.rect[3] < a.rect[1]) { const t = a.rect[1]; a.rect[1] = a.rect[3]; a.rect[3] = t; }
        }
        if (intAfter(b, ab, abe, "/F")) |fl| a.flags = fl;
        // /C [r g b] — 회색 하나나 CMYK 넷으로 적히기도 한다
        if (keyPos(b, ab, abe, "/C")) |ca| {
            var cp = ca + 2;
            {
                while (cp < abe and b[cp] != '[' and b[cp] != '/' and b[cp] != '>') cp += 1;
                if (cp < abe and b[cp] == '[') {
                    cp += 1;
                    var vals: [4]f32 = .{ 0, 0, 0, 0 };
                    var n2: u32 = 0;
                    while (n2 < 4 and cp < abe) {
                        while (cp < abe and isSpace(b[cp])) cp += 1;
                        if (cp >= abe or b[cp] == ']') break;
                        vals[n2] = readFloat(b, &cp);
                        n2 += 1;
                    }
                    if (n2 == 1) { a.color = .{ vals[0], vals[0], vals[0] }; a.has_color = true; }
                    if (n2 == 3) { a.color = .{ vals[0], vals[1], vals[2] }; a.has_color = true; }
                    if (n2 == 4) {
                        a.color = .{
                            (1 - @min(1, vals[0] + vals[3])),
                            (1 - @min(1, vals[1] + vals[3])),
                            (1 - @min(1, vals[2] + vals[3])),
                        };
                        a.has_color = true;
                    }
                }
            }
        }
        // 글(/Contents) · 쓴 이(/T) · 날짜(/M)
        if (find(b[ab..abe], "/Contents", 0)) |ta| {
            _ = ann_bufRoom(ann_used + 8192);
            const n2 = copyPdfText(b, ab + ta + 9, abe, ann_buf(), ann_used);
            if (n2 > 0) { a.txt_off = ann_used; a.txt_len = n2; ann_used += n2; }
        }
        if (keyPos(b, ab, abe, "/T")) |ta| {
            _ = ann_bufRoom(ann_used + 8192);
            const n2 = copyPdfText(b, ta + 2, abe, ann_buf(), ann_used);
            if (n2 > 0) { a.au_off = ann_used; a.au_len = n2; ann_used += n2; }
        }
        if (keyPos(b, ab, abe, "/M")) |da| {
            _ = ann_bufRoom(ann_used + 8192);
            const n2 = copyPdfText(b, da + 2, abe, ann_buf(), ann_used);
            if (n2 > 0) { a.dt_off = ann_used; a.dt_len = n2; ann_used += n2; }
        }
        anns()[ann_n] = a;
        ann_n += 1;
    }
}

fn collectLinks(b: []const u8, body: usize, end: usize) void {
    link_n = 0;
    link_buf_n = 0;
    const aa = find(b[body..end], "/Annots", 0) orelse return;
    var p = body + aa + 7;
    while (p < end and isSpace(b[p])) p += 1;
    var as2 = p;
    var ae = end;
    if (p < end and b[p] == '[') { as2 = p + 1; ae = arrayEnd(b, p, end); }
    else if (p < end and isDigit(b[p])) {
        const an = readUint(b, &p);
        if (findObj(b, an)) |ab| {
            const abe = find(b, "endobj", ab) orelse b.len;
            var q2 = ab;
            while (q2 < abe and b[q2] != '[') q2 += 1;
            as2 = q2 + 1;
            ae = arrayEnd(b, q2, abe);
        } else return;
    } else return;

    var q = as2;
    while (q < ae) {
        while (q < ae and isSpace(b[q])) q += 1;
        if (q >= ae or b[q] == ']') break;
        if (!isDigit(b[q])) { q += 1; continue; }
        const num = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and isDigit(b[q])) _ = readUint(b, &q);
        while (q < ae and isSpace(b[q])) q += 1;
        if (q < ae and b[q] == 'R') q += 1;

        const ab = findObj(b, num) orelse continue;
        const abe = find(b, "endobj", ab) orelse b.len;
        if (find(b[ab..abe], "/Link", 0) == null) continue;
        var rect: [4]f32 = .{ 0, 0, 0, 0 };
        if (find(b[ab..abe], "/Rect", 0)) |ra| {
            var rp = ab + ra + 5;
            while (rp < abe and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < abe) : (i += 1) rect[i] = readFloat(b, &rp);
        } else continue;
        if (rect[2] < rect[0]) { const t = rect[0]; rect[0] = rect[2]; rect[2] = t; }
        if (rect[3] < rect[1]) { const t = rect[1]; rect[1] = rect[3]; rect[3] = t; }

        var uoff: u32 = 0;
        var ulen: u32 = 0;
        var pg: i32 = -1;
        // /S /URI 처럼 이름으로 쓰인 것 말고, 값이 문자열인 /URI 를 찾는다
        var ufrom: usize = 0;
        while (find(b[ab..abe], "/URI", ufrom)) |ua| {
            var up = ab + ua + 4;
            while (up < abe and isSpace(b[up])) up += 1;
            if (up < abe and (b[up] == '(' or b[up] == '<')) {
                uoff = link_buf_n;
                _ = link_bufRoom(link_buf_n + 8192);
                ulen = copyPdfText(b, up, abe, link_buf(), link_buf_n);
                link_buf_n += ulen;
                break;
            }
            ufrom = ua + 4;
        }
        if (ulen > 0) {} else if (find(b[ab..abe], "/Dest", 0)) |da| {
            pg = destPage(b, ab + da + 5, abe);
        } else if (find(b[ab..abe], "/D", 0)) |da| {
            pg = destPage(b, ab + da + 2, abe);
        }
        if (ulen == 0 and pg < 0) continue;
        if (!growTable(&link_at, &link_cap, link_n, @sizeOf(Link), 128)) break;
        links()[link_n] = .{ .rect = rect, .off = uoff, .len = ulen, .page = pg };
        link_n += 1;
    }
}

/// 목차를 훑는다.
fn walkOutline(b: []const u8, first: u32, depth: u8) void {
    var num = first;
    var guard: u32 = 0;
    while (num != 0 and guard < 1 << 16) : (guard += 1) {
        const ob = findObj(b, num) orelse return;
        const oe = objDictEnd(b, ob);
        var off: u32 = 0;
        var len: u32 = 0;
        if (find(b[ob..oe], "/Title", 0)) |ta| {
            off = mark_buf_n;
            _ = mark_bufRoom(mark_buf_n + 8192);
            len = copyPdfText(b, ob + ta + 6, oe, mark_buf(), mark_buf_n);
            mark_buf_n += len;
        }
        var pg: i32 = -1;
        if (find(b[ob..oe], "/Dest", 0)) |da| pg = destPage(b, ob + da + 5, oe);
        if (pg < 0) {
            if (find(b[ob..oe], "/A", 0)) |aa| {
                var ap = ob + aa + 2;
                while (ap < oe and isSpace(b[ap])) ap += 1;
                var ds = ap;
                var de2 = oe;
                if (ap < oe and b[ap] == '<') { de2 = dictEnd(b, ap, oe); }
                else if (ap < oe and isDigit(b[ap])) {
                    const an2 = readUint(b, &ap);
                    if (findObj(b, an2)) |ab2| { ds = ab2; de2 = objDictEnd(b, ab2); }
                }
                if (find(b[ds..de2], "/D", 0)) |dd| pg = destPage(b, ds + dd + 2, de2);
            }
        }
        if (len > 0) {
            marks()[mark_n] = .{ .depth = depth, .off = off, .len = len, .page = pg };
            mark_n += 1;
        }
        // 자식
        if (find(b[ob..oe], "/First", 0)) |fa| {
            var fp = ob + fa + 6;
            while (fp < oe and isSpace(b[fp])) fp += 1;
            if (fp < oe and isDigit(b[fp]) and depth < 4) walkOutline(b, readUint(b, &fp), depth + 1);
        }
        // 다음 형제
        var nxt: u32 = 0;
        if (find(b[ob..oe], "/Next", 0)) |na| {
            var np = ob + na + 5;
            while (np < oe and isSpace(b[np])) np += 1;
            if (np < oe and isDigit(b[np])) nxt = readUint(b, &np);
        }
        if (nxt == num) return;
        num = nxt;
    }
}

fn collectOutline(b: []const u8, root: u32) void {
    mark_n = 0;
    mark_buf_n = 0;
    const rb = findObj(b, root) orelse return;
    const re2 = objDictEnd(b, rb);
    const oa = find(b[rb..re2], "/Outlines", 0) orelse return;
    var p = rb + oa + 9;
    while (p < re2 and isSpace(b[p])) p += 1;
    if (p >= re2 or !isDigit(b[p])) return;
    const on = readUint(b, &p);
    const ob = findObj(b, on) orelse return;
    const oe = objDictEnd(b, ob);
    if (find(b[ob..oe], "/First", 0)) |fa| {
        var fp = ob + fa + 6;
        while (fp < oe and isSpace(b[fp])) fp += 1;
        if (fp < oe and isDigit(b[fp])) walkOutline(b, readUint(b, &fp), 0);
    }
}

// ===== 셰이딩(그라데이션) =====
//
// /Shading 은 색을 함수로 준다. 함수를 몇 군데 찍어 색 마디를 만들고,
// 캔버스의 그라데이션에 그대로 넘긴다. 형식 2(지수)·3(이어붙임)·0(표본)을
// 본다.

const Shade = struct {
    name: [24]u8,
    name_len: u8,
    /// 1 함수 · 2 축 · 3 방사 · 4·5 삼각 그물 · 6·7 이음 조각
    kind: u8,
    /// 딕셔너리 자리. 그물은 그릴 때 스트림을 다시 읽는다.
    ds: u32,
    de: u32,
    /// 함수 자리 (없으면 0)
    fs: u32,
    fe: u32,
    /// 성분마다 함수가 따로 오기도 한다 — /Function [f1 f2 f3]
    fx: [4][2]u32,
    fxn: u8,
    /// 함수를 안 쓰는 그물의 색 성분 수
    ncomp: u8,
    /// 1형의 /Matrix, /Domain
    mat: [6]f32,
    dom: [4]f32,
    coords: [6]f32,
    ext0: bool,
    ext1: bool,
    stops: [8 * 4]f32, // t,r,g,b × 8
    stop_n: u8,
};
/// 이름 붙은 그늘. 필요한 만큼 늘어난다(세는 상한 없음).
var shades_at: usize = 0;
var shades_cap: u32 = 0;
fn shadesBuf() []Shade {
    if (shades_at == 0 or shades_cap == 0) return &[_]Shade{};
    return @as([*]Shade, @ptrFromInt(shades_at))[0..shades_cap];
}
fn shadesRoom(want: u32) bool { return growTable(&shades_at, &shades_cap, want, @sizeOf(Shade), 16); }
var shade_n: u32 = 0;

/// 타일 무늬는 아직 깔지 못한다. 대표 색만 뽑아 단색으로 칠한다 —
/// 검정으로 덮는 것보다 훨씬 원본에 가깝다.
const Tile = struct {
    name: [24]u8,
    name_len: u8,
    r: f32,
    g: f32,
    b: f32,
    obj: u32,
    mat: [6]f32,
    xstep: f32,
    ystep: f32,
};
/// 이름 붙은 타일 무늬. 필요한 만큼 늘어난다(세는 상한 없음).
var tiles_at: usize = 0;
var tiles_cap: u32 = 0;
fn tilesBuf() []Tile {
    if (tiles_at == 0 or tiles_cap == 0) return &[_]Tile{};
    return @as([*]Tile, @ptrFromInt(tiles_at))[0..tiles_cap];
}
fn tilesRoom(want: u32) bool { return growTable(&tiles_at, &tiles_cap, want, @sizeOf(Tile), 16); }
var tile_n: u32 = 0;

/// 꺼 놓은 레이어(/OCProperties /D /OFF)의 객체 번호
/// 레이어. 64 이던 것을 올렸다 — 도면은 그보다 많다.
/// 레이어 객체 번호. 필요한 만큼 늘어난다(세는 상한 없음).
var ocg_off_list_at: usize = 0;
var ocg_off_list_cap: u32 = 0;
fn ocg_off_listBuf() []u32 {
    if (ocg_off_list_at == 0 or ocg_off_list_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(ocg_off_list_at))[0..ocg_off_list_cap];
}
fn ocg_off_listRoom(want: u32) bool { return growTable(&ocg_off_list_at, &ocg_off_list_cap, want, @sizeOf(u32), 64); }
var ocg_off_n: u32 = 0;
/// 이름 → 레이어 객체 (/Properties)
const Prop = struct { name: [24]u8, name_len: u8, obj: u32 };
/// 이름 붙은 레이어(/Properties). 필요한 만큼 늘어난다(세는 상한 없음).
var props_at: usize = 0;
var props_cap: u32 = 0;
fn propsBuf() []Prop {
    if (props_at == 0 or props_cap == 0) return &[_]Prop{};
    return @as([*]Prop, @ptrFromInt(props_at))[0..props_cap];
}
fn propsRoom(want: u32) bool { return growTable(&props_at, &props_cap, want, @sizeOf(Prop), 16); }
var prop_n: u32 = 0;

/// 레이어 목록 — 화면이 켜고 끌 수 있게 이름과 상태를 들고 있는다
/// 레이어 표 넷을 함께 늘린다.
fn ocRoom(want: u32) bool {
    return oc_objRoom(want) and oc_name_offRoom(want) and oc_name_lenRoom(want) and oc_onRoom(want);
}
/// 레이어 객체. 필요한 만큼 늘어난다(세는 상한 없음).
var oc_obj_at: usize = 0;
var oc_obj_cap: u32 = 0;
fn oc_objBuf() []u32 {
    if (oc_obj_at == 0 or oc_obj_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(oc_obj_at))[0..oc_obj_cap];
}
fn oc_objRoom(want: u32) bool { return growTable(&oc_obj_at, &oc_obj_cap, want, @sizeOf(u32), 64); }
/// 레이어 이름 위치. 필요한 만큼 늘어난다(세는 상한 없음).
var oc_name_off_at: usize = 0;
var oc_name_off_cap: u32 = 0;
fn oc_name_offBuf() []u32 {
    if (oc_name_off_at == 0 or oc_name_off_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(oc_name_off_at))[0..oc_name_off_cap];
}
fn oc_name_offRoom(want: u32) bool { return growTable(&oc_name_off_at, &oc_name_off_cap, want, @sizeOf(u32), 64); }
/// 레이어 이름 길이. 필요한 만큼 늘어난다(세는 상한 없음).
var oc_name_len_at: usize = 0;
var oc_name_len_cap: u32 = 0;
fn oc_name_lenBuf() []u32 {
    if (oc_name_len_at == 0 or oc_name_len_cap == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(oc_name_len_at))[0..oc_name_len_cap];
}
fn oc_name_lenRoom(want: u32) bool { return growTable(&oc_name_len_at, &oc_name_len_cap, want, @sizeOf(u32), 64); }
/// 레이어를 켜 두었나. 필요한 만큼 늘어난다(세는 상한 없음).
var oc_on_at: usize = 0;
var oc_on_cap: u32 = 0;
fn oc_onBuf() []bool {
    if (oc_on_at == 0 or oc_on_cap == 0) return &[_]bool{};
    return @as([*]bool, @ptrFromInt(oc_on_at))[0..oc_on_cap];
}
fn oc_onRoom(want: u32) bool { return growTable(&oc_on_at, &oc_on_cap, want, @sizeOf(bool), 64); }
var oc_n: u32 = 0;
/// oc_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
var oc_buf_at: usize = 0;
var oc_buf_cap: u32 = 0;
fn oc_buf() []u8 {
    if (oc_buf_at == 0 or oc_buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(oc_buf_at))[0..oc_buf_cap];
}
fn oc_bufRoom(want: u32) bool {
    return growTable(&oc_buf_at, &oc_buf_cap, want, 1, 8192);
}
var oc_used: u32 = 0;

export fn ocCount() u32 { return oc_n; }
export fn ocTextPtr() usize { return (if (oc_buf_at == 0) heapBase() else oc_buf_at); }
export fn ocNameOff(i: u32) u32 { return if (i < oc_n) oc_name_offBuf()[i] else 0; }
export fn ocNameLen(i: u32) u32 { return if (i < oc_n) oc_name_lenBuf()[i] else 0; }
export fn ocIsOn(i: u32) u32 { return if (i < oc_n and oc_onBuf()[i]) 1 else 0; }
/// 화면에서 레이어를 켜고 끈다. 다음 renderPage 부터 먹는다.
export fn setOcOn(i: u32, on: u32) void {
    if (i < oc_n) oc_onBuf()[i] = on != 0;
}

fn ocgHidden(obj: u32) bool {
    // 화면에서 손댄 것이 있으면 그쪽이 먼저다
    var k: u32 = 0;
    while (k < oc_n) : (k += 1) if (oc_objBuf()[k] == obj) return !oc_onBuf()[k];
    var i: u32 = 0;
    while (i < ocg_off_n) : (i += 1) if (ocg_off_listBuf()[i] == obj) return true;
    return false;
}
fn propObj(name: []const u8) u32 {
    var i: u32 = 0;
    while (i < prop_n) : (i += 1)
        if (txEq(propsBuf()[i].name[0..propsBuf()[i].name_len], name)) return propsBuf()[i].obj;
    return 0;
}

fn findTile(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < tile_n) : (i += 1)
        if (txEq(tilesBuf()[i].name[0..tilesBuf()[i].name_len], name)) return @intCast(i);
    return -1;
}

fn findShade(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < shade_n) : (i += 1)
        if (txEq(shadesBuf()[i].name[0..shadesBuf()[i].name_len], name)) return @intCast(i);
    return -1;
}

/// 딕셔너리의 숫자 배열을 읽는다. 읽은 개수를 준다.
fn readArr(b: []const u8, ds: usize, de: usize, key: []const u8, dst: []f32) u32 {
    const a = find(b[ds..de], key, 0) orelse return 0;
    var p = ds + a + key.len;
    while (p < de and isSpace(b[p])) p += 1;
    if (p >= de or b[p] != '[') return 0;
    p += 1;
    var n: u32 = 0;
    while (p < de and n < dst.len) {
        while (p < de and isSpace(b[p])) p += 1;
        if (p >= de or b[p] == ']') break;
        if (!(isDigit(b[p]) or b[p] == '-' or b[p] == '.' or b[p] == '+')) break;
        dst[n] = readFloat(b, &p);
        n += 1;
    }
    return n;
}

/// 표본 함수(/FunctionType 0)의 자료 곳간.
///
/// 셰이딩 하나를 그리는 데 함수를 수천 번 찍는다. 그때마다 스트림을 풀면
/// 느리기도 하거니와, 푸는 자리가 하나뿐이라 서로 덮어 버린다. 몇 개만
/// 담아 두고 돌려 쓴다.
const FN_SLOTS = 4;
const FN_POOL = 512 * 1024;
var fn_key: [FN_SLOTS]usize = .{0} ** FN_SLOTS;
var fn_at: [FN_SLOTS]u32 = .{0} ** FN_SLOTS;
var fn_ln: [FN_SLOTS]u32 = .{0} ** FN_SLOTS;
var fn_pool: [FN_POOL]u8 = undefined;
var fn_used: u32 = 0;
var fn_rr: u32 = 0;

fn fnReset() void {
    fn_used = 0;
    fn_rr = 0;
    var i: u32 = 0;
    while (i < FN_SLOTS) : (i += 1) { fn_key[i] = 0; fn_ln[i] = 0; }
}

fn sampleData(b: []const u8, fs: usize) ?[]const u8 {
    var i: u32 = 0;
    while (i < FN_SLOTS) : (i += 1) {
        if (fn_key[i] == fs and fn_ln[i] > 0) return fn_pool[fn_at[i]..][0..fn_ln[i]];
    }
    const d = streamFrom(b, fs) orelse return null;
    const n = @min(d.len, FN_POOL - fn_used);
    if (n == 0) return null;
    const slot = fn_rr % FN_SLOTS;
    fn_rr += 1;
    @memcpy(fn_pool[fn_used..][0..n], d[0..n]);
    fn_key[slot] = fs;
    fn_at[slot] = fn_used;
    fn_ln[slot] = @intCast(n);
    fn_used += @intCast(n);
    return fn_pool[fn_at[slot]..][0..n];
}

/// 자료에서 bit 자리부터 n 비트를 읽는다 (큰 자리가 앞).
fn bitsAt(d: []const u8, bit: u64, n: u32) u32 {
    var v: u32 = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const at = bit + k;
        const byte: usize = @intCast(at >> 3);
        if (byte >= d.len) return v << @intCast(n - k);
        const sh: u3 = @intCast(7 - (at & 7));
        v = (v << 1) | ((d[byte] >> sh) & 1);
    }
    return v;
}

fn lerp(x: f32, a0: f32, a1: f32, b0: f32, b1: f32) f32 {
    if (a1 == a0) return b0;
    return b0 + (x - a0) * (b1 - b0) / (a1 - a0);
}

// ===== 계산기 함수 (/FunctionType 4) =====
//
// 포스트스크립트 토막이 통째로 들어 있다. Separation·DeviceN 색이 잉크
// 농도를 실제 색으로 옮길 때, 셰이딩이 색을 계산할 때 쓴다. 읽지 않으면
// 그 색이 통째로 틀린다.

fn psTok(d: []const u8, p: *usize, end: usize) []const u8 {
    while (p.* < end and (isSpace(d[p.*]) or d[p.*] == '%')) {
        if (d[p.*] == '%') {
            while (p.* < end and d[p.*] != '\n') p.* += 1;
        } else p.* += 1;
    }
    if (p.* >= end) return &[_]u8{};
    const s0 = p.*;
    if (d[p.*] == '{' or d[p.*] == '}') {
        p.* += 1;
        return d[s0..p.*];
    }
    while (p.* < end and !isSpace(d[p.*]) and d[p.*] != '{' and d[p.*] != '}') p.* += 1;
    return d[s0..p.*];
}

/// 짝이 되는 닫는 괄호 자리
fn psMatch(d: []const u8, from: usize, end: usize) usize {
    var depth: u32 = 1;
    var p = from;
    while (p < end) : (p += 1) {
        if (d[p] == '{') depth += 1
        else if (d[p] == '}') { depth -= 1; if (depth == 0) return p; }
    }
    return end;
}

const PS = struct {
    st: [128]f32 = undefined,
    sp: usize = 0,
    fn push(s: *PS, v: f32) void {
        if (s.sp < s.st.len) { s.st[s.sp] = v; s.sp += 1; }
    }
    fn pop(s: *PS) f32 {
        if (s.sp == 0) return 0;
        s.sp -= 1;
        return s.st[s.sp];
    }
};

fn psExec(d: []const u8, from: usize, to: usize, s: *PS, depth: u32) void {
    if (depth > 32) return;
    var p = from;
    // if·ifelse 는 앞에 놓인 { } 토막을 받는다
    var pb: [4][2]usize = undefined;
    var pn: usize = 0;
    var guard: u32 = 0;
    while (p < to and guard < 100000) {
        guard += 1;
        const t = psTok(d, &p, to);
        if (t.len == 0) break;
        if (t[0] == '{') {
            const e = psMatch(d, p, to);
            if (pn < 4) { pb[pn] = .{ p, e }; pn += 1; }
            p = e + 1;
            continue;
        }
        if (t[0] == '}') continue;
        if (t[0] == '-' or t[0] == '.' or (t[0] >= '0' and t[0] <= '9')) {
            var q: usize = 0;
            s.push(readFloat(t, &q));
            continue;
        }
        const eq = struct {
            fn f(a: []const u8, w: []const u8) bool {
                if (a.len != w.len) return false;
                for (a, 0..) |ch, i| if (ch != w[i]) return false;
                return true;
            }
        }.f;
        if (eq(t, "add")) { const bv = s.pop(); s.push(s.pop() + bv); }
        else if (eq(t, "sub")) { const bv = s.pop(); s.push(s.pop() - bv); }
        else if (eq(t, "mul")) { const bv = s.pop(); s.push(s.pop() * bv); }
        else if (eq(t, "div")) { const bv = s.pop(); s.push(if (bv == 0) 0 else s.pop() / bv); }
        else if (eq(t, "idiv")) {
            const bv = s.pop();
            const av = s.pop();
            s.push(if (bv == 0) 0 else @trunc(av / bv));
        }
        else if (eq(t, "mod")) {
            const bv = s.pop();
            const av = s.pop();
            s.push(if (bv == 0) 0 else av - bv * @trunc(av / bv));
        }
        else if (eq(t, "neg")) s.push(-s.pop())
        else if (eq(t, "abs")) s.push(@abs(s.pop()))
        else if (eq(t, "ceiling")) s.push(@ceil(s.pop()))
        else if (eq(t, "floor")) s.push(@floor(s.pop()))
        else if (eq(t, "round")) s.push(@round(s.pop()))
        else if (eq(t, "truncate")) s.push(@trunc(s.pop()))
        else if (eq(t, "sqrt")) s.push(@sqrt(@max(0, s.pop())))
        else if (eq(t, "sin")) s.push(@sin(s.pop() * 3.14159265 / 180))
        else if (eq(t, "cos")) s.push(@cos(s.pop() * 3.14159265 / 180))
        else if (eq(t, "atan")) {
            const den = s.pop();
            const num = s.pop();
            var ang = atan2Deg(num, den);
            if (ang < 0) ang += 360;
            s.push(ang);
        }
        else if (eq(t, "exp")) {
            const e2 = s.pop();
            const bv = s.pop();
            s.push(powf(bv, e2));
        }
        else if (eq(t, "ln")) s.push(lnf(@max(1e-20, s.pop())))
        else if (eq(t, "log")) s.push(lnf(@max(1e-20, s.pop())) / 2.302585093)
        else if (eq(t, "cvi")) s.push(@trunc(s.pop()))
        else if (eq(t, "cvr")) {}
        else if (eq(t, "dup")) { const v = s.pop(); s.push(v); s.push(v); }
        else if (eq(t, "pop")) _ = s.pop()
        else if (eq(t, "exch")) { const bv = s.pop(); const av = s.pop(); s.push(bv); s.push(av); }
        else if (eq(t, "copy")) {
            const nv: usize = @intFromFloat(@max(0, @min(32, s.pop())));
            if (nv <= s.sp) {
                var kx: usize = 0;
                while (kx < nv) : (kx += 1) s.push(s.st[s.sp - nv]);
            }
        }
        else if (eq(t, "index")) {
            const nv: usize = @intFromFloat(@max(0, @min(127, s.pop())));
            s.push(if (nv < s.sp) s.st[s.sp - 1 - nv] else 0);
        }
        else if (eq(t, "roll")) {
            const j = s.pop();
            const nv: usize = @intFromFloat(@max(0, @min(64, s.pop())));
            if (nv > 0 and nv <= s.sp) {
                var ji: i32 = @intFromFloat(j);
                const ni: i32 = @intCast(nv);
                ji = @mod(ji, ni);
                if (ji < 0) ji += ni;
                var tmp: [64]f32 = undefined;
                var kx: usize = 0;
                while (kx < nv) : (kx += 1) {
                    const from2 = (kx + nv - @as(usize, @intCast(ji))) % nv;
                    tmp[kx] = s.st[s.sp - nv + from2];
                }
                kx = 0;
                while (kx < nv) : (kx += 1) s.st[s.sp - nv + kx] = tmp[kx];
            }
        }
        else if (eq(t, "eq")) { const bv = s.pop(); s.push(if (s.pop() == bv) 1 else 0); }
        else if (eq(t, "ne")) { const bv = s.pop(); s.push(if (s.pop() != bv) 1 else 0); }
        else if (eq(t, "gt")) { const bv = s.pop(); s.push(if (s.pop() > bv) 1 else 0); }
        else if (eq(t, "ge")) { const bv = s.pop(); s.push(if (s.pop() >= bv) 1 else 0); }
        else if (eq(t, "lt")) { const bv = s.pop(); s.push(if (s.pop() < bv) 1 else 0); }
        else if (eq(t, "le")) { const bv = s.pop(); s.push(if (s.pop() <= bv) 1 else 0); }
        else if (eq(t, "and")) {
            const bv: i32 = @intFromFloat(s.pop());
            const av: i32 = @intFromFloat(s.pop());
            s.push(@floatFromInt(av & bv));
        }
        else if (eq(t, "or")) {
            const bv: i32 = @intFromFloat(s.pop());
            const av: i32 = @intFromFloat(s.pop());
            s.push(@floatFromInt(av | bv));
        }
        else if (eq(t, "xor")) {
            const bv: i32 = @intFromFloat(s.pop());
            const av: i32 = @intFromFloat(s.pop());
            s.push(@floatFromInt(av ^ bv));
        }
        else if (eq(t, "not")) {
            const av = s.pop();
            s.push(if (av == 0) 1 else if (av == 1) 0 else @floatFromInt(~@as(i32, @intFromFloat(av))));
        }
        else if (eq(t, "bitshift")) {
            const sh = s.pop();
            const av: i32 = @intFromFloat(s.pop());
            const k: i32 = @intFromFloat(sh);
            const kk: u5 = @intCast(@min(31, @abs(k)));
            s.push(@floatFromInt(if (k >= 0) av << kk else av >> kk));
        }
        else if (eq(t, "true")) s.push(1)
        else if (eq(t, "false")) s.push(0)
        else if (eq(t, "if")) {
            const cond = s.pop();
            if (pn >= 1) {
                if (cond != 0) psExec(d, pb[pn - 1][0], pb[pn - 1][1], s, depth + 1);
                pn -= 1;
            }
        }
        else if (eq(t, "ifelse")) {
            const cond = s.pop();
            if (pn >= 2) {
                const blk = if (cond != 0) pb[pn - 2] else pb[pn - 1];
                psExec(d, blk[0], blk[1], s, depth + 1);
                pn -= 2;
            }
        }
    }
}

fn atan2Deg(y: f32, x: f32) f32 {
    if (x == 0 and y == 0) return 0;
    const pi: f32 = 3.14159265;
    var r: f32 = 0;
    if (x > 0) r = atanf(y / x)
    else if (x < 0) r = atanf(y / x) + (if (y >= 0) pi else -pi)
    else r = if (y > 0) pi / 2 else -pi / 2;
    return r * 180 / pi;
}
fn atanf(v: f32) f32 {
    // 급수 몇 개면 색을 정하기에 넉넉하다
    const a = @abs(v);
    if (a > 1) return (if (v > 0) @as(f32, 1.5707963) else @as(f32, -1.5707963)) - atanf(1 / v);
    const x2 = v * v;
    return v * (1 - x2 * (0.3333333 - x2 * (0.2 - x2 * (0.1428571 - x2 * 0.1111111))));
}
fn lnf(v: f32) f32 {
    // v = m * 2^e 로 갈라 급수로 센다
    var m = v;
    var e: f32 = 0;
    while (m > 2) { m /= 2; e += 1; }
    while (m < 1) { m *= 2; e -= 1; }
    const z = (m - 1) / (m + 1);
    const z2 = z * z;
    const l = 2 * z * (1 + z2 * (0.3333333 + z2 * (0.2 + z2 * 0.1428571)));
    return l + e * 0.6931472;
}
fn powf(b: f32, e: f32) f32 {
    if (b <= 0) return 0;
    return expf(e * lnf(b));
}
fn expf(v: f32) f32 {
    if (v > 60) return 1e26;
    if (v < -60) return 0;
    var n: i32 = @intFromFloat(@round(v / 0.6931472));
    const r = v - @as(f32, @floatFromInt(n)) * 0.6931472;
    var s2: f32 = 1 + r * (1 + r * (0.5 + r * (0.1666667 + r * (0.0416667 + r * 0.0083333))));
    while (n > 0) : (n -= 1) s2 *= 2;
    while (n < 0) : (n += 1) s2 *= 0.5;
    return s2;
}

/// 함수를 t 에서 찍어 색을 낸다. 성분 수만큼 out 에 담는다.
fn evalFn(b: []const u8, fs: usize, fe: usize, t: f32, out: *[4]f32) u32 {
    return evalFnN(b, fs, fe, &[_]f32{t}, out);
}

/// 들어가는 값이 둘인 함수(셰이딩 1형)까지 받는 판.
fn evalFnN(b: []const u8, fs: usize, fe: usize, in: []const f32, out: *[4]f32) u32 {
    const t = in[0];
    const ft = intAfter(b, fs, fe, "/FunctionType") orelse return 0;
    if (ft == 2) {
        var c0: [4]f32 = .{ 0, 0, 0, 0 };
        var c1: [4]f32 = .{ 1, 1, 1, 1 };
        var n0: u32 = 1;
        var n1: u32 = 1;
        if (find(b[fs..fe], "/C0", 0)) |a| {
            var p = fs + a + 3;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            n0 = 0;
            while (n0 < 4 and p < fe and b[p] != ']') : (n0 += 1) {
                while (p < fe and isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                c0[n0] = readFloat(b, &p);
            }
        }
        if (find(b[fs..fe], "/C1", 0)) |a| {
            var p = fs + a + 3;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            n1 = 0;
            while (n1 < 4 and p < fe and b[p] != ']') : (n1 += 1) {
                while (p < fe and isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                c1[n1] = readFloat(b, &p);
            }
        }
        const n = @max(@max(n0, n1), 1);
        var i: u32 = 0;
        while (i < n and i < 4) : (i += 1) out[i] = c0[i] + t * (c1[i] - c0[i]);
        return n;
    }
    if (ft == 3) {
        // 이어붙임 — 경계로 나눠 하위 함수에 넘긴다
        var bounds: [8]f32 = undefined;
        var nb: u32 = 0;
        if (find(b[fs..fe], "/Bounds", 0)) |a| {
            var p = fs + a + 7;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            while (nb < 8 and p < fe) {
                while (p < fe and isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                bounds[nb] = readFloat(b, &p);
                nb += 1;
            }
        }
        var subs: [9]u32 = undefined;
        var ns: u32 = 0;
        if (find(b[fs..fe], "/Functions", 0)) |a| {
            var p = fs + a + 10;
            while (p < fe and b[p] != '[') p += 1;
            p += 1;
            while (ns < 9 and p < fe and b[p] != ']') {
                while (p < fe and isSpace(b[p])) p += 1;
                if (p >= fe or b[p] == ']') break;
                if (!isDigit(b[p])) { p += 1; continue; }
                subs[ns] = readUint(b, &p);
                ns += 1;
                while (p < fe and isSpace(b[p])) p += 1;
                if (p < fe and isDigit(b[p])) _ = readUint(b, &p);
                while (p < fe and isSpace(b[p])) p += 1;
                if (p < fe and b[p] == 'R') p += 1;
            }
        }
        if (ns == 0) return 0;
        var k: u32 = 0;
        while (k < nb and t >= bounds[k]) k += 1;
        if (k >= ns) k = ns - 1;
        const lo: f32 = if (k == 0) 0 else bounds[k - 1];
        const hi: f32 = if (k >= nb) 1 else bounds[k];
        const tt = if (hi > lo) (t - lo) / (hi - lo) else 0;
        if (findObj(b, subs[k])) |sb2| {
            const se2 = objDictEnd(b, sb2);
            return evalFn(b, sb2, se2, tt, out);
        }
        return 0;
    }
    if (ft == 0) {
        // 표본 함수. 격자 위의 값을 스트림에 늘어놓은 것이다.
        //
        // 예전에는 이걸 읽지 않고 t 를 그대로 회색으로 봤다. 그러면 색이
        // 통째로 틀린다 — 파란 그라데이션이 회색 띠가 됐다.
        var rng: [32]f32 = undefined;
        const nr = readArr(b, fs, fe, "/Range", &rng);
        if (nr < 2) return 0;
        const nout = @min(nr / 2, 4);
        var size: [2]f32 = .{ 0, 0 };
        const nin = @min(readArr(b, fs, fe, "/Size", &size), 2);
        if (nin == 0 or size[0] < 1) return 0;
        const bps = intAfter(b, fs, fe, "/BitsPerSample") orelse 8;
        if (bps == 0 or bps > 32) return 0;
        var dom: [4]f32 = .{ 0, 1, 0, 1 };
        _ = readArr(b, fs, fe, "/Domain", &dom);
        var encp: [4]f32 = undefined;
        const ne = readArr(b, fs, fe, "/Encode", &encp);
        var dec: [32]f32 = undefined;
        const nd = readArr(b, fs, fe, "/Decode", &dec);
        const d = sampleData(b, fs) orelse return 0;

        // 들어온 값을 격자 자리로 옮긴다
        var idx: [2]u32 = .{ 0, 0 };
        var frac0: f32 = 0;
        var gi: u32 = 0;
        var k: u32 = 0;
        while (k < nin) : (k += 1) {
            const sz = @max(1, size[k]);
            const e0: f32 = if (ne >= (k + 1) * 2) encp[k * 2] else 0;
            const e1: f32 = if (ne >= (k + 1) * 2) encp[k * 2 + 1] else sz - 1;
            const x = if (k < in.len) in[k] else 0;
            var e = lerp(x, dom[k * 2], dom[k * 2 + 1], e0, e1);
            e = @max(0, @min(sz - 1, e));
            // 첫 축은 사이값을 이으므로 내림, 둘째 축은 가장 가까운 칸을 쓴다.
            // 내림으로 두면 마지막 칸에 영영 닿지 못해 색이 한 단 모자란다.
            idx[k] = if (k == 0) @intFromFloat(e) else @intFromFloat(@min(sz - 1, e + 0.5));
            if (k == 0) { gi = idx[0]; frac0 = e - @as(f32, @floatFromInt(idx[0])); }
        }
        const w0: u32 = @intFromFloat(@max(1, size[0]));
        const base: u64 = @as(u64, idx[0]) + @as(u64, idx[1]) * w0;
        // 첫 축만 사이값을 잇는다. 두 축짜리는 가장 가까운 칸을 쓴다.
        const nxt: u64 = if (nin == 1 and gi + 1 < w0) base + 1 else base;
        const maxv: f32 = @floatFromInt((@as(u64, 1) << @intCast(bps)) - 1);
        var c: u32 = 0;
        while (c < nout) : (c += 1) {
            const a = @as(f32, @floatFromInt(bitsAt(d, (base * nout + c) * bps, bps)));
            const bb = @as(f32, @floatFromInt(bitsAt(d, (nxt * nout + c) * bps, bps)));
            const raw = (a + (bb - a) * frac0) / maxv;
            const lo: f32 = if (nd >= (c + 1) * 2) dec[c * 2] else rng[c * 2];
            const hi: f32 = if (nd >= (c + 1) * 2) dec[c * 2 + 1] else rng[c * 2 + 1];
            out[c] = lo + raw * (hi - lo);
        }
        return nout;
    }
    if (ft == 4) {
        // 계산기 — 스트림 안 포스트스크립트를 돌린다
        var rng: [32]f32 = undefined;
        const nr = readArr(b, fs, fe, "/Range", &rng);
        if (nr < 2) return 0;
        const nout = @min(nr / 2, 4);
        const d = sampleData(b, fs) orelse return 0;
        var p2: usize = 0;
        while (p2 < d.len and d[p2] != '{') p2 += 1;
        if (p2 >= d.len) return 0;
        var ps = PS{};
        for (in) |v| ps.push(v);
        psExec(d, p2 + 1, psMatch(d, p2 + 1, d.len), &ps, 0);
        var c: u32 = 0;
        while (c < nout) : (c += 1) {
            const idx = nout - 1 - c;
            const v = ps.pop();
            out[idx] = @max(rng[idx * 2], @min(rng[idx * 2 + 1], v));
        }
        return nout;
    }
    return 0;
}

fn rgbFrom(comps: u32, v: [4]f32, out: *[3]f32) void {
    if (comps >= 4) {
        out[0] = 1 - @min(@as(f32, 1), v[0] + v[3]);
        out[1] = 1 - @min(@as(f32, 1), v[1] + v[3]);
        out[2] = 1 - @min(@as(f32, 1), v[2] + v[3]);
    } else if (comps == 3) {
        out[0] = v[0];
        out[1] = v[1];
        out[2] = v[2];
    } else {
        out[0] = v[0];
        out[1] = v[0];
        out[2] = v[0];
    }
}

/// 셰이딩 딕셔너리 하나를 읽는다.
fn readShade(b: []const u8, ds: usize, de: usize, name: []const u8) void {
    if (!shadesRoom(shade_n + 1)) return;
    const st2 = intAfter(b, ds, de, "/ShadingType") orelse return;
    if (st2 < 1 or st2 > 7) return;
    const sh = &shadesBuf()[shade_n];
    sh.ds = @intCast(ds);
    sh.de = @intCast(de);
    sh.fs = 0;
    sh.fe = 0;
    sh.fxn = 0;
    sh.mat = .{ 1, 0, 0, 1, 0, 0 };
    sh.dom = .{ 0, 1, 0, 1 };
    sh.ncomp = 3;
    const nl = @min(name.len, 24);
    var k: usize = 0;
    while (k < nl) : (k += 1) sh.name[k] = name[k];
    sh.name_len = @intCast(nl);
    sh.kind = @intCast(st2);
    sh.ext0 = false;
    sh.ext1 = false;
    sh.stop_n = 0;
    var i: u32 = 0;
    while (i < 6) : (i += 1) sh.coords[i] = 0;
    if (find(b[ds..de], "/Coords", 0)) |a| {
        var p = ds + a + 7;
        while (p < de and b[p] != '[') p += 1;
        p += 1;
        const want: u32 = if (st2 == 2) 4 else 6;
        i = 0;
        while (i < want and p < de) : (i += 1) sh.coords[i] = readFloat(b, &p);
    }
    if (find(b[ds..de], "/Extend", 0)) |a| {
        var p = ds + a + 7;
        while (p < de and b[p] != '[') p += 1;
        p += 1;
        while (p < de and isSpace(b[p])) p += 1;
        sh.ext0 = p + 4 <= de and std_mem_eq(b[p .. p + 4], "true");
        while (p < de and !isSpace(b[p])) p += 1;
        while (p < de and isSpace(b[p])) p += 1;
        sh.ext1 = p + 4 <= de and std_mem_eq(b[p .. p + 4], "true");
    }
    // 함수 자리를 찾아 둔다. 2·3형은 여기서 여덟 군데를 찍고,
    // 그물은 그릴 때 꼭짓점마다 찍는다.
    var fs: usize = 0;
    var fe: usize = 0;
    if (find(b[ds..de], "/Function", 0)) |a| {
        var p = ds + a + 9;
        while (p < de and isSpace(b[p])) p += 1;
        const arr = p < de and b[p] == '[';
        if (arr) p += 1;
        var got: u32 = 0;
        while (got < 4) {
            while (p < de and isSpace(b[p])) p += 1;
            if (p >= de or b[p] == ']') break;
            var s2: usize = 0;
            var e2: usize = 0;
            if (b[p] == '<') {
                s2 = p;
                e2 = dictEnd(b, p, de);
                p = e2;
            } else if (isDigit(b[p])) {
                const fnum = readUint(b, &p);
                while (p < de and isSpace(b[p])) p += 1;
                if (p < de and isDigit(b[p])) _ = readUint(b, &p);
                while (p < de and isSpace(b[p])) p += 1;
                if (p < de and b[p] == 'R') p += 1;
                if (findObj(b, fnum)) |fb| { s2 = fb; e2 = objDictEnd(b, fb); }
            } else break;
            if (e2 > s2) {
                sh.fx[got] = .{ @intCast(s2), @intCast(e2) };
                got += 1;
                if (got == 1) { fs = s2; fe = e2; }
            }
            if (!arr) break;
        }
        sh.fxn = @intCast(got);
    }
    sh.fs = @intCast(fs);
    sh.fe = @intCast(fe);

    if (st2 != 2 and st2 != 3) {
        // 1형은 x·y 를 받는 함수 하나로 칠한다
        if (st2 == 1) {
            _ = readArr(b, ds, de, "/Domain", &sh.dom);
            var m: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
            if (readArr(b, ds, de, "/Matrix", &m) == 6) sh.mat = m;
            if (fe <= fs) return;
        } else if (fe <= fs) {
            // 함수가 없으면 색을 꼭짓점이 직접 들고 있다.
            // 성분 수는 색 공간이 정한다.
            sh.ncomp = shadeComps(b, ds, de);
        }
        sh.stop_n = 0;
        shade_n += 1;
        return;
    }

    if (fe <= fs) return;
    i = 0;
    while (i < 8) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 7;
        var v: [4]f32 = .{ 0, 0, 0, 0 };
        const nc = shadeFn(b, sh, t, &v);
        var rgb3: [3]f32 = .{ 0, 0, 0 };
        rgbFrom(nc, v, &rgb3);
        sh.stops[i * 4] = t;
        sh.stops[i * 4 + 1] = rgb3[0];
        sh.stops[i * 4 + 2] = rgb3[1];
        sh.stops[i * 4 + 3] = rgb3[2];
    }
    sh.stop_n = 8;
    shade_n += 1;
}

/// 셰이딩의 함수를 t 에서 찍는다.
///
/// 함수가 여럿 오면 성분마다 하나씩이다 — 각각 값을 하나만 낸다.
fn shadeFn(b: []const u8, sh: *const Shade, t: f32, out: *[4]f32) u32 {
    if (sh.fxn > 1) {
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < sh.fxn and i < 4) : (i += 1) {
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            if (evalFn(b, sh.fx[i][0], sh.fx[i][1], t, &v) == 0) return 0;
            out[i] = v[0];
            n += 1;
        }
        return n;
    }
    if (sh.fe <= sh.fs) return 0;
    return evalFn(b, sh.fs, sh.fe, t, out);
}

/// 색 공간의 성분 수. 그물 셰이딩이 꼭짓점 색을 몇 개씩 들고 있는지 정한다.
fn shadeComps(b: []const u8, ds: usize, de: usize) u8 {
    const a = find(b[ds..de], "/ColorSpace", 0) orelse return 3;
    var p = ds + a + 11;
    while (p < de and isSpace(b[p])) p += 1;
    var s2 = p;
    var e2 = de;
    if (p < de and isDigit(b[p])) {
        const n = readUint(b, &p);
        if (findObj(b, n)) |ob| { s2 = ob; e2 = objDictEnd(b, ob); }
    }
    const w = b[s2..@min(e2, s2 + 64)];
    if (findIn(w, "DeviceCMYK", 0) != null) return 4;
    if (findIn(w, "DeviceGray", 0) != null or findIn(w, "CalGray", 0) != null) return 1;
    if (findIn(w, "DeviceRGB", 0) != null or findIn(w, "CalRGB", 0) != null or
        findIn(w, "Lab", 0) != null) return 3;
    if (findIn(w, "ICCBased", 0) != null) {
        // /N 이 성분 수다
        var q = s2;
        while (q < e2 and isDigit(b[q]) == false and b[q] != '/') q += 1;
        if (intAfter(b, s2, @min(e2, s2 + 256), "/N")) |n2| return @intCast(@max(1, @min(4, n2)));
        return 3;
    }
    return 3;
}

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
        const v = bitsAt(self.d, self.bit, n);
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
fn meshColor(sh: *const Shade, r: *MeshR, bpc: u32, dec: []const f32, nd: u32) [3]f32 {
    var out: [3]f32 = .{ 0, 0, 0 };
    if (sh.fe > sh.fs) {
        // 함수를 쓰면 값 하나가 곧 매개변수다
        const lo: f32 = if (nd >= 6) dec[4] else 0;
        const hi: f32 = if (nd >= 6) dec[5] else 1;
        const t = meshVal(r.get(bpc), bpc, lo, hi);
        var v: [4]f32 = .{ 0, 0, 0, 0 };
        const nc = shadeFn(doc, sh, t, &v);
        rgbFrom(nc, v, &out);
        return out;
    }
    var v: [4]f32 = .{ 0, 0, 0, 0 };
    var c: u32 = 0;
    while (c < sh.ncomp and c < 4) : (c += 1) {
        const lo: f32 = if (nd >= 4 + (c + 1) * 2) dec[4 + c * 2] else 0;
        const hi: f32 = if (nd >= 4 + (c + 1) * 2) dec[5 + c * 2] else 1;
        v[c] = meshVal(r.get(bpc), bpc, lo, hi);
    }
    rgbFrom(sh.ncomp, v, &out);
    return out;
}

/// 삼각형 하나를 색이 고르게 보일 만큼 쪼개 칠한다.
fn meshTri(p: [3][2]f32, c: [3][3]f32, depth: u32) void {
    if (opsRoomLow()) return;
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
    emitOp(11, &[_]f32{ avg[0], avg[1], avg[2] });
    emitOp(1, &[_]f32{ cx + (p[0][0] - cx) * g, cy + (p[0][1] - cy) * g });
    emitOp(2, &[_]f32{ cx + (p[1][0] - cx) * g, cy + (p[1][1] - cy) * g });
    emitOp(2, &[_]f32{ cx + (p[2][0] - cx) * g, cy + (p[2][1] - cy) * g });
    emitOp(4, &[_]f32{});
    emitOp(6, &[_]f32{0});
}

/// 4·5형 — 삼각형 그물
fn paintTriMesh(sh: *const Shade) void {
    const b = doc;
    const ds = sh.ds;
    const de = sh.de;
    const bpco = intAfter(b, ds, de, "/BitsPerCoordinate") orelse return;
    const bpc = intAfter(b, ds, de, "/BitsPerComponent") orelse return;
    if (bpco == 0 or bpco > 32 or bpc == 0 or bpc > 16) return;
    const bpf = intAfter(b, ds, de, "/BitsPerFlag") orelse 8;
    var dec: [16]f32 = undefined;
    const nd = readArr(b, ds, de, "/Decode", &dec);
    if (nd < 4) return;
    const data = streamFrom(b, ds) orelse return;
    var r = MeshR{ .d = data };

    const rowlen = intAfter(b, ds, de, "/VerticesPerRow") orelse 0;
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
        while (r.left() >= (bpco * 2 + bpc) and made < 8000 and !opsRoomLow()) : (row += 1) {
            var i: u32 = 0;
            while (i < rowlen and r.left() >= bpco * 2) : (i += 1) {
                cur_p[i] = readPt(&r, bpco, &dec);
                cur_c[i] = meshColor(sh, &r, bpc, &dec, nd);
            }
            if (i < rowlen) break;
            if (row > 0) {
                var j: u32 = 0;
                while (j + 1 < rowlen and made < 8000 and !opsRoomLow()) : (j += 1) {
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
    while (r.left() >= bpf + bpco * 2 and made < 8000 and !opsRoomLow()) {
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
fn paintPatchMesh(sh: *const Shade) void {
    const b = doc;
    const ds = sh.ds;
    const de = sh.de;
    const bpco = intAfter(b, ds, de, "/BitsPerCoordinate") orelse return;
    const bpc = intAfter(b, ds, de, "/BitsPerComponent") orelse return;
    if (bpco == 0 or bpco > 32 or bpc == 0 or bpc > 16) return;
    const bpf = intAfter(b, ds, de, "/BitsPerFlag") orelse 8;
    var dec: [16]f32 = undefined;
    const nd = readArr(b, ds, de, "/Decode", &dec);
    if (nd < 4) return;
    const data = streamFrom(b, ds) orelse return;
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

    while (r.left() >= bpf and made < 512 and !opsRoomLow()) {
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
        while (a < N and !opsRoomLow()) : (a += 1) {
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
                emitOp(11, &[_]f32{ cm[0], cm[1], cm[2] });
                emitOp(1, &[_]f32{ gx + (p00[0] - gx) * g, gy + (p00[1] - gy) * g });
                emitOp(2, &[_]f32{ gx + (p01[0] - gx) * g, gy + (p01[1] - gy) * g });
                emitOp(2, &[_]f32{ gx + (p11[0] - gx) * g, gy + (p11[1] - gy) * g });
                emitOp(2, &[_]f32{ gx + (p10[0] - gx) * g, gy + (p10[1] - gy) * g });
                emitOp(4, &[_]f32{});
                emitOp(6, &[_]f32{0});
            }
        }
        P = NP;
        C = NC;
        first = false;
        made += 1;
    }
}

/// 1형 — x·y 를 받는 함수. 정의역을 격자로 훑어 칠한다.
fn paintFnShade(sh: *const Shade) void {
    if (sh.fe <= sh.fs) return;
    const b = doc;
    emitOp(14, &[_]f32{});
    emitOp(16, &[_]f32{ sh.mat[0], sh.mat[1], sh.mat[2], sh.mat[3], sh.mat[4], sh.mat[5] });
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
            const nc = evalFnN(b, sh.fs, sh.fe, &[_]f32{ (x0 + x1) / 2, (y0 + y1) / 2 }, &v);
            if (nc == 0) continue;
            var rgb3: [3]f32 = .{ 0, 0, 0 };
            rgbFrom(nc, v, &rgb3);
            emitOp(11, &[_]f32{ rgb3[0], rgb3[1], rgb3[2] });
            emitOp(5, &[_]f32{ x0, y0, (x1 - x0) * 1.02, (y1 - y0) * 1.02 });
            emitOp(6, &[_]f32{0});
        }
    }
    emitOp(15, &[_]f32{});
}

/// 그물의 대표 색 — 무늬를 칠하기 색으로 쓸 때 쓴다.
fn shadeAvg(sh: *const Shade, out: *[3]f32) bool {
    if (sh.fe > sh.fs) {
        var acc: [3]f32 = .{ 0, 0, 0 };
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            var v: [4]f32 = .{ 0, 0, 0, 0 };
            const nc = shadeFn(doc, sh, @as(f32, @floatFromInt(i)) / 4, &v);
            if (nc == 0) return false;
            var c3: [3]f32 = .{ 0, 0, 0 };
            rgbFrom(nc, v, &c3);
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
fn emitShade(sh: *const Shade, code: f32) void {
    if (sh.kind == 1 or sh.kind >= 4) {
        // 캔버스 그라데이션으로는 못 그린다. 잘게 쪼개 메운다.
        if (code == 28) {
            // 칠하기 색 자리에는 대표 색만 놓는다
            var c3: [3]f32 = .{ 0.5, 0.5, 0.5 };
            _ = shadeAvg(sh, &c3);
            emitOp(11, &[_]f32{ c3[0], c3[1], c3[2] });
            return;
        }
        if (sh.kind == 1) paintFnShade(sh)
        else if (sh.kind == 4 or sh.kind == 5) paintTriMesh(sh)
        else paintPatchMesh(sh);
        return;
    }
    emitShadeGrad(sh, code);
}

fn emitShadeGrad(sh: *const Shade, code: f32) void {
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
    emitOp(code, arg[0 .. 10 + @as(usize, sh.stop_n) * 4]);
}

// ===== Type1 글꼴 =====
//
// FontFile 은 옛 Type1 프로그램이다. 앞은 평문 포스트스크립트, 뒤는 eexec 로
// 암호화된 부분이고 그 안에 글리프마다 다시 암호화된 charstring 이 들어 있다.
// CFF 로 바꾸는 길도 있지만(PDF.js 가 그렇게 한다), 우리는 Type3 처럼
// 외곽선을 바로 해석해 그린다 — 그리기 명령을 이미 갖고 있어 훨씬 짧다.

const T1Range = struct { off: u32, len: u32 };
var t1_pool: [8192]T1Range = undefined;
var t1_pool_n: u32 = 0;

/// 코드 → 글리프 이름 (지금 읽고 있는 글꼴 하나에만 쓰는 임시 자리)
var enc_off: [256]u16 = undefined;
var enc_len: [256]u8 = undefined;
var enc_buf: [8192]u8 = undefined;
var enc_buf_n: u16 = 0;

fn encSet(code: u32, name: []const u8) void {
    if (code > 255 or name.len == 0 or name.len > 63) return;
    if (@as(usize, enc_buf_n) + name.len > enc_buf.len) return;
    @memcpy(enc_buf[enc_buf_n..][0..name.len], name);
    enc_off[code] = enc_buf_n;
    enc_len[code] = @intCast(name.len);
    enc_buf_n += @intCast(name.len);
}
fn encGet(code: u32) []const u8 {
    if (code > 255 or enc_len[code] == 0) return &[_]u8{};
    return enc_buf[enc_off[code]..][0..enc_len[code]];
}

/// 표준 인코딩의 이름들. 글자·숫자는 규칙적이라 기호만 적어 둔다.
const STD_PUNCT = "space exclam quotedbl numbersign dollar percent ampersand quoteright " ++
    "parenleft parenright asterisk plus comma hyphen period slash";
const STD_PUNCT2 = "colon semicolon less equal greater question at";
const STD_PUNCT3 = "bracketleft backslash bracketright asciicircum underscore quoteleft";
const STD_PUNCT4 = "braceleft bar braceright asciitilde";
const STD_DIGIT = "zero one two three four five six seven eight nine";

fn nthWord(s: []const u8, n: u32) []const u8 {
    var i: usize = 0;
    var k: u32 = 0;
    while (i < s.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        const st = i;
        while (i < s.len and s[i] != ' ') i += 1;
        if (k == n) return s[st..i];
        k += 1;
    }
    return &[_]u8{};
}

/// 표준 인코딩을 채운다 (아스키 구간만 — 실제로 쓰이는 곳이다)
/// 표준 인코딩에서 코드 하나의 이름
fn stdName(c: u32, buf: *[1]u8) []const u8 {
    if (c >= 32 and c <= 47) return nthWord(STD_PUNCT, c - 32);
    if (c >= 48 and c <= 57) return nthWord(STD_DIGIT, c - 48);
    if (c >= 58 and c <= 64) return nthWord(STD_PUNCT2, c - 58);
    if ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)) { buf[0] = @intCast(c); return buf[0..1]; }
    if (c >= 91 and c <= 96) return nthWord(STD_PUNCT3, c - 91);
    if (c >= 123 and c <= 126) return nthWord(STD_PUNCT4, c - 123);
    return &[_]u8{};
}

fn fillStandardEncoding() void {
    var c: u32 = 32;
    while (c <= 47) : (c += 1) encSet(c, nthWord(STD_PUNCT, c - 32));
    c = 48;
    while (c <= 57) : (c += 1) encSet(c, nthWord(STD_DIGIT, c - 48));
    c = 58;
    while (c <= 64) : (c += 1) encSet(c, nthWord(STD_PUNCT2, c - 58));
    var buf: [1]u8 = undefined;
    c = 65;
    while (c <= 90) : (c += 1) { buf[0] = @intCast(c); encSet(c, buf[0..1]); }
    c = 91;
    while (c <= 96) : (c += 1) encSet(c, nthWord(STD_PUNCT3, c - 91));
    c = 97;
    while (c <= 122) : (c += 1) { buf[0] = @intCast(c); encSet(c, buf[0..1]); }
    c = 123;
    while (c <= 126) : (c += 1) encSet(c, nthWord(STD_PUNCT4, c - 123));
}

/// eexec 및 charstring 풀기. 앞의 skip 바이트는 버린다.
fn t1Decrypt(src: []const u8, dst: []u8, r0: u16, skip: usize) u32 {
    var r: u16 = r0;
    var n: u32 = 0;
    for (src, 0..) |c, i| {
        const plain: u8 = c ^ @as(u8, @truncate(r >> 8));
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
        if (i >= skip) {
            if (n >= dst.len) break;
            dst[n] = plain;
            n += 1;
        }
    }
    return n;
}

fn isHexRun(b: []const u8) bool {
    var seen: u32 = 0;
    var i: usize = 0;
    while (i < b.len and seen < 4) : (i += 1) {
        if (isSpace(b[i])) continue;
        if (hexVal(b[i]) == null) return false;
        seen += 1;
    }
    return seen == 4;
}

/// "이름 길이 RD <이진>" 을 읽는다. 이진의 시작과 길이를 준다.
fn t1Entry(d: []const u8, p: *usize) ?struct { name: []const u8, off: usize, len: usize } {
    var i = p.*;
    while (i < d.len and d[i] != '/') i += 1;
    if (i >= d.len) { p.* = d.len; return null; }
    const ns = i + 1;
    var nq = ns;
    while (nq < d.len and !isSpace(d[nq]) and d[nq] != '(' and d[nq] != '/') nq += 1;
    // 무엇이 되든 이름 뒤로는 넘어간다 — 안 그러면 제자리를 맴돈다
    p.* = @max(nq, ns);
    i = nq;
    while (i < d.len and isSpace(d[i])) i += 1;
    if (i >= d.len or !isDigit(d[i])) return null;
    const len = readUint(d, &i);
    while (i < d.len and isSpace(d[i])) i += 1;
    // RD 나 -| 같은 토큰 하나
    while (i < d.len and !isSpace(d[i])) i += 1;
    i += 1; // 공백 하나
    if (len == 0 or i + len > d.len) return null;
    p.* = i + len;
    return .{ .name = d[ns..nq], .off = i, .len = len };
}

/// Type1 프로그램을 읽어 글리프 프로그램을 풀어 둔다.
fn attachType1(b: []const u8, fbody: usize, fend: usize, data: []const u8) void {
    if (font_n == 0 or t1Area() == 0) return;
    const f = &fontsBuf()[font_n - 1];
    if (data.len < 64) return;

    // 평문 구간에서 eexec 자리를 찾는다
    const ee = findIn(data, "eexec", 0) orelse return;
    var es = ee + 5;
    while (es < data.len and (data[es] == '\r' or data[es] == '\n' or data[es] == ' ' or data[es] == '\t')) es += 1;
    if (es >= data.len) return;

    const room = t1_cap - t1_used;
    if (room < 65536) return;
    const area = @as([*]u8, @ptrFromInt(t1Area() + t1_used))[0..room];

    // 16진으로 적힌 것도 있다
    var enc_src = data[es..];
    var hexbuf_len: u32 = 0;
    if (isHexRun(enc_src)) {
        var w: u32 = 0;
        var hi: ?u8 = null;
        for (enc_src) |c| {
            const v = hexVal(c) orelse continue;
            if (hi) |h| {
                if (w >= area.len / 2) break;
                area[w] = (h << 4) | v;
                w += 1;
                hi = null;
            } else hi = v;
        }
        hexbuf_len = w;
        enc_src = area[0..w];
    }
    const dec_at = if (hexbuf_len > 0) hexbuf_len else 0;
    const dec = area[dec_at..];
    const dn = t1Decrypt(enc_src, dec, 55665, 4);
    if (dn < 32) return;
    const priv = dec[0..dn];

    var leniv: usize = 4;
    if (findIn(priv, "/lenIV", 0)) |li| {
        var q = li + 6;
        while (q < priv.len and isSpace(priv[q])) q += 1;
        if (q < priv.len and isDigit(priv[q])) leniv = readUint(priv, &q);
        if (leniv > 16) leniv = 4;
    }

    // 코드 → 이름: PDF 의 Differences 가 가장 세고, 없으면 프로그램의 Encoding,
    // 그것도 없으면 표준 인코딩.
    @memset(&enc_len, 0);
    enc_buf_n = 0;
    if (findIn(data[0..es], "StandardEncoding", 0) != null) fillStandardEncoding();
    {
        // dup <코드> /<이름> put
        var q: usize = 0;
        while (findIn(data[0..es], "dup ", q)) |at| {
            var r = at + 4;
            while (r < es and isSpace(data[r])) r += 1;
            if (r < es and isDigit(data[r])) {
                const code = readUint(data, &r);
                while (r < es and isSpace(data[r])) r += 1;
                if (r < es and data[r] == '/') {
                    const ns = r + 1;
                    var nq = ns;
                    while (nq < es and !isSpace(data[nq]) and data[nq] != '/') nq += 1;
                    encSet(code, data[ns..nq]);
                }
            }
            q = at + 4;
        }
    }
    // PDF 쪽 Differences 가 있으면 덮어쓴다
    {
        var es2 = fbody;
        var ee2 = fend;
        if (find(b[fbody..fend], "/Encoding", 0)) |ea| {
            var q = fbody + ea + 9;
            while (q < fend and isSpace(b[q])) q += 1;
            if (q < fend and b[q] == '<') { es2 = q; ee2 = dictEnd(b, q, fend); }
            else if (q < fend and isDigit(b[q])) {
                const n2 = readUint(b, &q);
                if (findObj(b, n2)) |eb| { es2 = eb; ee2 = find(b, "endobj", eb) orelse b.len; }
            }
        }
        if (find(b[es2..ee2], "/Differences", 0)) |da| {
            var q = es2 + da + 12;
            while (q < ee2 and b[q] != '[') q += 1;
            q += 1;
            var code: u32 = 0;
            while (q < ee2 and b[q] != ']') {
                while (q < ee2 and isSpace(b[q])) q += 1;
                if (q >= ee2 or b[q] == ']') break;
                if (isDigit(b[q])) { code = readUint(b, &q); continue; }
                if (b[q] != '/') { q += 1; continue; }
                const ns = q + 1;
                var nq = ns;
                while (nq < ee2 and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != ']') nq += 1;
                encSet(code, b[ns..nq]);
                code += 1;
                q = nq;
            }
        }
    }

    // 글리프 프로그램을 풀 자리
    var w_at: u32 = dec_at + dn;
    if (w_at + 4096 > area.len) return;
    if (t1_pool_n + 256 + 512 > t1_pool.len) return;
    f.t1_cs = @intCast(t1_pool_n);
    var i: u32 = 0;
    while (i < 256) : (i += 1) { t1_pool[t1_pool_n + i] = .{ .off = 0, .len = 0 }; }
    t1_pool_n += 256;
    f.t1_sub = @intCast(t1_pool_n);
    f.t1_sub_n = 0;
    @memset(&f.t1_std, 0);

    const stash = struct {
        fn go(ar: []u8, wp: *u32, src: []const u8, iv: usize) T1Range {
            const cap = ar.len - wp.*;
            if (cap < src.len + 8) return .{ .off = 0, .len = 0 };
            const n = t1Decrypt(src, ar[wp.*..], 4330, iv);
            const r = T1Range{ .off = wp.*, .len = n };
            wp.* += n;
            return r;
        }
    }.go;

    // Subrs
    if (findIn(priv, "/Subrs", 0)) |sa| {
        var q = sa + 6;
        while (q < priv.len and isSpace(priv[q])) q += 1;
        const cnt = if (q < priv.len and isDigit(priv[q])) readUint(priv, &q) else 0;
        var k: u32 = 0;
        while (k < cnt and k < 512) : (k += 1) {
            const at = findIn(priv, "dup ", q) orelse break;
            var r = at + 4;
            while (r < priv.len and isSpace(priv[r])) r += 1;
            if (r >= priv.len or !isDigit(priv[r])) { q = at + 4; continue; }
            const idx = readUint(priv, &r);
            while (r < priv.len and isSpace(priv[r])) r += 1;
            if (r >= priv.len or !isDigit(priv[r])) { q = at + 4; continue; }
            const len = readUint(priv, &r);
            while (r < priv.len and isSpace(priv[r])) r += 1;
            while (r < priv.len and !isSpace(priv[r])) r += 1;
            r += 1;
            if (r + len > priv.len) break;
            if (idx < 512) {
                const rr = stash(area, &w_at, priv[r .. r + len], leniv);
                t1_pool[f.t1_sub + idx] = rr;
                if (idx + 1 > f.t1_sub_n) f.t1_sub_n = @intCast(idx + 1);
            }
            q = r + len;
        }
        t1_pool_n += 512;
    } else {
        t1_pool_n += 512;
    }

    // CharStrings — 코드에 이름이 맞는 것만 담는다
    var got: u32 = 0;
    if (findIn(priv, "/CharStrings", 0)) |ca| {
        var q = ca + 12;
        var guard: u32 = 0;
        while (q < priv.len and guard < 4096) {
            guard += 1;
            const e = t1Entry(priv, &q) orelse continue;
            if (e.len == 0 or e.len > 65535) continue;
            var c: u32 = 0;
            var used = false;
            while (c < 256) : (c += 1) {
                if (enc_len[c] == 0) continue;
                if (!txEq(encGet(c), e.name)) continue;
                if (!used) {
                    const rr = stash(area, &w_at, priv[e.off .. e.off + e.len], leniv);
                    if (rr.len == 0) break;
                    t1_pool[f.t1_cs + c] = rr;
                    used = true;
                    got += 1;
                } else {
                    t1_pool[f.t1_cs + c] = t1_pool[f.t1_cs + c - 1];
                }
            }
            if (used) {
                // 표준 인코딩 이름과도 맞춰 둔다 (seac 가 그 코드로 부른다)
                var sc2: u32 = 32;
                var nb: [1]u8 = undefined;
                while (sc2 < 127) : (sc2 += 1) {
                    if (!txEq(stdName(sc2, &nb), e.name)) continue;
                    var c3: u32 = 0;
                    while (c3 < 256) : (c3 += 1) {
                        if (enc_len[c3] == 0 or !txEq(encGet(c3), e.name)) continue;
                        if (t1_pool[f.t1_cs + c3].len > 0) f.t1_std[sc2] = @intCast(c3);
                        break;
                    }
                }
                // 같은 이름이 여러 코드에 걸리면 앞의 것을 나눠 쓴다
                var c2: u32 = 0;
                var first: ?T1Range = null;
                while (c2 < 256) : (c2 += 1) {
                    if (enc_len[c2] == 0 or !txEq(encGet(c2), e.name)) continue;
                    if (first == null) first = t1_pool[f.t1_cs + c2] else t1_pool[f.t1_cs + c2] = first.?;
                }
            }
        }
    }
    if (got == 0) return;
    t1_used += (w_at + 3) & ~@as(u32, 3);
    f.t1 = true;
    f.kind |= 1024;
    if (find(b[fbody..fend], "/FontMatrix", 0)) |ma| {
        var q = fbody + ma + 11;
        while (q < fend and b[q] != '[') q += 1;
        q += 1;
        var k: u32 = 0;
        while (k < 6 and q < fend) : (k += 1) f.fm[k] = readFloat(b, &q);
    }
}

/// Type1 charstring 을 돌려 외곽선을 그리기 명령으로 낸다.
const T1State = struct {
    x: f32 = 0,
    y: f32 = 0,
    st: [48]f32 = undefined,
    sp: usize = 0,
    ps: [32]f32 = undefined,
    ps_head: usize = 0,
    ps_n: usize = 0,
    flex: bool = false,
    fx: [8]f32 = undefined,
    fy: [8]f32 = undefined,
    fn_: usize = 0,
    drew: bool = false,
    done: bool = false,
    sb: f32 = 0,
    seac: bool = false,
    asb: f32 = 0,
    adx: f32 = 0,
    ady: f32 = 0,
    bchar: u32 = 0,
    achar: u32 = 0,
};

fn t1Push(s: *T1State, v: f32) void {
    if (s.sp < s.st.len) { s.st[s.sp] = v; s.sp += 1; }
}
fn t1Pop(s: *T1State) f32 {
    if (s.sp == 0) return 0;
    s.sp -= 1;
    return s.st[s.sp];
}
fn t1PsPush(s: *T1State, v: f32) void {
    if (s.ps_n < s.ps.len) { s.ps[s.ps_n] = v; s.ps_n += 1; }
}
fn t1PsPop(s: *T1State) f32 {
    if (s.ps_head >= s.ps_n) return 0;
    const v = s.ps[s.ps_head];
    s.ps_head += 1;
    return v;
}

fn t1Slice(r: T1Range) []const u8 {
    if (r.len == 0 or t1Area() == 0) return &[_]u8{};
    return @as([*]const u8, @ptrFromInt(t1Area() + r.off))[0..r.len];
}

/// 이동 — flex 중이면 점만 모은다
fn t1Move(s: *T1State, dx: f32, dy: f32) void {
    s.x += dx;
    s.y += dy;
    if (s.flex) {
        if (s.fn_ < 8) { s.fx[s.fn_] = s.x; s.fy[s.fn_] = s.y; s.fn_ += 1; }
        return;
    }
    emitOp(1, &[_]f32{ s.x, s.y });
    s.drew = true;
}

fn t1Run(f: *const FontMap, r: T1Range, s: *T1State, dep: u32) void {
    if (dep > 10) return;
    const d = t1Slice(r);
    var i: usize = 0;
    while (i < d.len and !s.done) {
        const v = d[i];
        if (v >= 32) {
            if (v <= 246) {
                t1Push(s, @as(f32, @floatFromInt(@as(i32, v) - 139)));
                i += 1;
            } else if (v <= 250) {
                if (i + 2 > d.len) return;
                t1Push(s, @floatFromInt((@as(i32, v) - 247) * 256 + @as(i32, d[i + 1]) + 108));
                i += 2;
            } else if (v <= 254) {
                if (i + 2 > d.len) return;
                t1Push(s, @floatFromInt(-(@as(i32, v) - 251) * 256 - @as(i32, d[i + 1]) - 108));
                i += 2;
            } else {
                if (i + 5 > d.len) return;
                t1Push(s, @floatFromInt(@as(i32, @bitCast(be32(d, i + 1)))));
                i += 5;
            }
            continue;
        }
        i += 1;
        switch (v) {
            13 => { // hsbw: 왼쪽 여백과 폭
                if (s.sp >= 1) { s.x = s.st[0]; s.sb = s.st[0]; }
                s.y = 0;
                s.sp = 0;
            },
            9 => { emitOp(4, &[_]f32{}); s.sp = 0; }, // closepath
            21 => { if (s.sp >= 2) t1Move(s, s.st[s.sp - 2], s.st[s.sp - 1]); s.sp = 0; },
            22 => { if (s.sp >= 1) t1Move(s, s.st[s.sp - 1], 0); s.sp = 0; },
            4 => { if (s.sp >= 1) t1Move(s, 0, s.st[s.sp - 1]); s.sp = 0; },
            5 => {
                if (s.sp >= 2) { s.x += s.st[0]; s.y += s.st[1]; emitOp(2, &[_]f32{ s.x, s.y }); s.drew = true; }
                s.sp = 0;
            },
            6 => {
                if (s.sp >= 1) { s.x += s.st[0]; emitOp(2, &[_]f32{ s.x, s.y }); s.drew = true; }
                s.sp = 0;
            },
            7 => {
                if (s.sp >= 1) { s.y += s.st[0]; emitOp(2, &[_]f32{ s.x, s.y }); s.drew = true; }
                s.sp = 0;
            },
            8 => { // rrcurveto
                if (s.sp >= 6) {
                    const x1 = s.x + s.st[0];
                    const y1 = s.y + s.st[1];
                    const x2 = x1 + s.st[2];
                    const y2 = y1 + s.st[3];
                    s.x = x2 + s.st[4];
                    s.y = y2 + s.st[5];
                    emitOp(3, &[_]f32{ x1, y1, x2, y2, s.x, s.y });
                    s.drew = true;
                }
                s.sp = 0;
            },
            30 => { // vhcurveto
                if (s.sp >= 4) {
                    const x1 = s.x;
                    const y1 = s.y + s.st[0];
                    const x2 = x1 + s.st[1];
                    const y2 = y1 + s.st[2];
                    s.x = x2 + s.st[3];
                    s.y = y2;
                    emitOp(3, &[_]f32{ x1, y1, x2, y2, s.x, s.y });
                    s.drew = true;
                }
                s.sp = 0;
            },
            31 => { // hvcurveto
                if (s.sp >= 4) {
                    const x1 = s.x + s.st[0];
                    const y1 = s.y;
                    const x2 = x1 + s.st[1];
                    const y2 = y1 + s.st[2];
                    s.x = x2;
                    s.y = y2 + s.st[3];
                    emitOp(3, &[_]f32{ x1, y1, x2, y2, s.x, s.y });
                    s.drew = true;
                }
                s.sp = 0;
            },
            10 => { // callsubr
                const idx = t1Pop(s);
                const k: i32 = @intFromFloat(idx);
                if (k >= 0 and @as(u32, @intCast(k)) < f.t1_sub_n)
                    t1Run(f, t1_pool[f.t1_sub + @as(u32, @intCast(k))], s, dep + 1);
            },
            11 => return, // return
            14 => { s.done = true; return; }, // endchar
            1, 3 => s.sp = 0, // hstem/vstem
            12 => {
                if (i >= d.len) return;
                const v2 = d[i];
                i += 1;
                switch (v2) {
                    12 => { // div
                        const bb = t1Pop(s);
                        const aa = t1Pop(s);
                        t1Push(s, if (bb == 0) 0 else aa / bb);
                    },
                    16 => { // callothersubr
                        const othr: i32 = @intFromFloat(t1Pop(s));
                        const cnt: i32 = @intFromFloat(t1Pop(s));
                        var n: usize = if (cnt > 0) @intCast(cnt) else 0;
                        if (n > s.sp) n = s.sp;
                        s.ps_head = 0;
                        s.ps_n = 0;
                        if (othr == 1) {
                            s.flex = true;
                            s.fn_ = 0;
                            s.sp -= n;
                        } else if (othr == 0) {
                            // flex 끝 — 모은 점 여섯 개가 곡선 두 개다
                            if (s.fn_ >= 7) {
                                emitOp(3, &[_]f32{ s.fx[1], s.fy[1], s.fx[2], s.fy[2], s.fx[3], s.fy[3] });
                                emitOp(3, &[_]f32{ s.fx[4], s.fy[4], s.fx[5], s.fy[5], s.fx[6], s.fy[6] });
                                s.x = s.fx[6];
                                s.y = s.fy[6];
                                s.drew = true;
                            }
                            s.flex = false;
                            s.sp -= n;
                            t1PsPush(s, s.x);
                            t1PsPush(s, s.y);
                        } else if (othr == 3) {
                            const arg = if (n >= 1) s.st[s.sp - 1] else 3;
                            s.sp -= n;
                            t1PsPush(s, arg);
                        } else {
                            var k: usize = 0;
                            while (k < n) : (k += 1) t1PsPush(s, s.st[s.sp - n + k]);
                            s.sp -= n;
                        }
                    },
                    17 => t1Push(s, t1PsPop(s)), // pop
                    33 => { // setcurrentpoint
                        if (s.sp >= 2) { s.x = s.st[0]; s.y = s.st[1]; }
                        s.sp = 0;
                    },
                    6 => { // seac — 밑글자에 악센트를 얹는다
                        if (s.sp >= 5) {
                            s.asb = s.st[s.sp - 5];
                            s.adx = s.st[s.sp - 4];
                            s.ady = s.st[s.sp - 3];
                            s.bchar = @intFromFloat(@max(0, @min(126, s.st[s.sp - 2])));
                            s.achar = @intFromFloat(@max(0, @min(126, s.st[s.sp - 1])));
                            s.seac = true;
                        }
                        s.sp = 0;
                        s.done = true;
                        return;
                    },
                    else => s.sp = 0, // dotsection·stem3 등
                }
            },
            else => s.sp = 0,
        }
    }
}

/// 코드 하나를 외곽선으로 그린다. 그렸으면 true.
fn drawType1(f: *const FontMap, code: u32) bool {
    if (!f.t1 or code > 255) return false;
    const r = t1_pool[f.t1_cs + code];
    if (r.len == 0) return false;
    var s = T1State{};
    t1Run(f, r, &s, 0);
    if (s.seac) {
        // 밑글자와 악센트를 따로 그린다
        const bi = if (s.bchar < 128) f.t1_std[s.bchar] else 0;
        const ai = if (s.achar < 128) f.t1_std[s.achar] else 0;
        var drew = false;
        if (bi != 0 and t1_pool[f.t1_cs + bi].len > 0) {
            var sb2 = T1State{};
            t1Run(f, t1_pool[f.t1_cs + bi], &sb2, 0);
            if (sb2.drew) { emitOp(4, &[_]f32{}); emitOp(6, &[_]f32{0}); drew = true; }
        }
        if (ai != 0 and t1_pool[f.t1_cs + ai].len > 0) {
            emitOp(14, &[_]f32{});
            emitOp(16, &[_]f32{ 1, 0, 0, 1, s.sb - s.asb + s.adx, s.ady });
            var sa2 = T1State{};
            t1Run(f, t1_pool[f.t1_cs + ai], &sa2, 0);
            if (sa2.drew) { emitOp(4, &[_]f32{}); emitOp(6, &[_]f32{0}); drew = true; }
            emitOp(15, &[_]f32{});
        }
        return drew;
    }
    if (!s.drew) return false;
    emitOp(4, &[_]f32{}); // closepath
    emitOp(6, &[_]f32{0}); // 채우기 (비영 감김)
    return true;
}

// ===== CFF 를 OpenType 으로 감싸기 =====
//
// PDF 의 FontFile3 은 대개 맨 CFF 다 — sfnt 껍데기가 없어 FontFace 가 받지
// 않는다. PDF.js 도 같은 일을 한다: CFF 를 그대로 'CFF ' 표에 넣고, 규격이
// 요구하는 나머지 표(head·hhea·maxp·hmtx·OS/2·name·post)를 지어 붙인다.
// 글자 폭은 PDF 가 이미 알려 준 /W·/Widths 를 쓴다.

fn readOff(b: []const u8, at: usize, n: u8) u32 {
    var v: u32 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (at + i >= b.len) return 0;
        v = (v << 8) | b[at + i];
    }
    return v;
}

/// INDEX 의 끝 위치 (CFF1)
fn cffIndexEnd(b: []const u8, at: usize) ?usize {
    if (at + 2 > b.len) return null;
    const count = be16(b, at);
    if (count == 0) return at + 2;
    if (at + 3 > b.len) return null;
    const os = b[at + 2];
    if (os < 1 or os > 4) return null;
    const offs = at + 3;
    const last_at = offs + @as(usize, count) * os;
    if (last_at + os > b.len) return null;
    const last = readOff(b, last_at, os);
    const data = offs + (@as(usize, count) + 1) * os - 1;
    if (data > b.len or last > b.len - data) return null;
    return data + last;
}

fn cffIndexItem(b: []const u8, at: usize, i: u32) ?[]const u8 {
    if (at + 3 > b.len) return null;
    const count = be16(b, at);
    if (i >= count) return null;
    const os = b[at + 2];
    if (os < 1 or os > 4) return null;
    const offs = at + 3;
    const o1 = readOff(b, offs + @as(usize, i) * os, os);
    const o2 = readOff(b, offs + (@as(usize, i) + 1) * os, os);
    const data = offs + (@as(usize, count) + 1) * os - 1;
    if (o2 < o1 or data > b.len or o2 > b.len - data or o1 == 0) return null;
    return b[data + o1 .. data + o2];
}

/// Top DICT 에서 연산자 하나의 마지막 피연산자를 읽는다.
fn cffDictInt(d: []const u8, want: u16) ?i32 {
    var i: usize = 0;
    var last: i32 = 0;
    var have = false;
    while (i < d.len) {
        const b0 = d[i];
        if (b0 <= 21) {
            var key: u16 = b0;
            i += 1;
            if (b0 == 12) {
                if (i >= d.len) return null;
                key = 0x0C00 | @as(u16, d[i]);
                i += 1;
            }
            if (key == want and have) return last;
            have = false;
            continue;
        }
        if (b0 == 28) {
            if (i + 3 > d.len) return null;
            last = @as(i16, @bitCast(be16(d, i + 1)));
            have = true;
            i += 3;
        } else if (b0 == 29) {
            if (i + 5 > d.len) return null;
            last = @bitCast(be32(d, i + 1));
            have = true;
            i += 5;
        } else if (b0 == 30) {
            // 실수 — 0xf 반니블이 끝을 알린다
            i += 1;
            while (i < d.len) : (i += 1) {
                const v = d[i];
                if ((v >> 4) == 0x0F or (v & 0x0F) == 0x0F) { i += 1; break; }
            }
            have = false;
        } else if (b0 >= 32 and b0 <= 246) {
            last = @as(i32, b0) - 139;
            have = true;
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            if (i + 2 > d.len) return null;
            last = (@as(i32, b0) - 247) * 256 + @as(i32, d[i + 1]) + 108;
            have = true;
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            if (i + 2 > d.len) return null;
            last = -(@as(i32, b0) - 251) * 256 - @as(i32, d[i + 1]) - 108;
            have = true;
            i += 2;
        } else {
            i += 1;
        }
    }
    return null;
}

/// CFF 의 글리프 수 (CharStrings INDEX 의 개수)
fn cffGlyphCount(cff: []const u8) u32 {
    if (cff.len < 8) return 0;
    if (cff[0] != 1) return 0; // CFF1 만
    var at: usize = cff[2]; // hdrSize
    at = cffIndexEnd(cff, at) orelse return 0; // Name INDEX
    const top_at = at;
    at = cffIndexEnd(cff, at) orelse return 0; // Top DICT INDEX
    const top = cffIndexItem(cff, top_at, 0) orelse return 0;
    const cs = cffDictInt(top, 17) orelse return 0;
    if (cs <= 0 or @as(usize, @intCast(cs)) + 2 > cff.len) return 0;
    return be16(cff, @intCast(cs));
}

fn wrStr(d: []u8, o: usize, s: []const u8) void {
    if (o + s.len > d.len) return;
    @memcpy(d[o..][0..s.len], s);
}

/// UTF-16BE 로 적는다 (아스키만)
fn wrU16Str(d: []u8, o: usize, s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (o + i * 2 + 2 > d.len) break;
        d[o + i * 2] = 0;
        d[o + i * 2 + 1] = s[i];
    }
    return s.len * 2;
}

/// name 표 하나를 짓는다. 쓴 바이트 수.
fn buildName(dst: []u8) u32 {
    const ids = [_]u16{ 1, 2, 3, 4, 6 };
    const count: u16 = ids.len;
    const str_off: u16 = 6 + count * 12;
    if (dst.len < str_off + 32) return 0;
    wr16(dst, 0, 0);
    wr16(dst, 2, count);
    wr16(dst, 4, str_off);
    const fam = "PDFEmbedded";
    const sub = "Regular";
    const fam_len = wrU16Str(dst, str_off, fam);
    const sub_len = wrU16Str(dst, str_off + fam_len, sub);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = 6 + i * 12;
        wr16(dst, r + 0, 3); // 윈도
        wr16(dst, r + 2, 1); // 유니코드 BMP
        wr16(dst, r + 4, 0x0409);
        wr16(dst, r + 6, ids[i]);
        if (ids[i] == 2) {
            wr16(dst, r + 8, @intCast(sub_len));
            wr16(dst, r + 10, @intCast(fam_len));
        } else {
            wr16(dst, r + 8, @intCast(fam_len));
            wr16(dst, r + 10, 0);
        }
    }
    return @intCast(str_off + fam_len + sub_len);
}

/// 맨 CFF 를 OTTO 로 감싼다. 성공하면 길이, 실패하면 0.
fn buildOtto(cff: []const u8, f: *FontMap, dst: []u8) u32 {
    const ng = cffGlyphCount(cff);
    if (ng == 0 or ng > 65535) return 0;
    if (dst.len < cff.len + 4096) return 0;
    const scratch = dst.len - (dst.len / 4);
    if (scratch <= cff.len + 1024) return 0;

    const cmap_len = buildFontCmap(f, @intCast(ng), dst[scratch..]);
    if (cmap_len == 0) return 0;

    // 표 아홉 개 — 태그 오름차순이어야 한다
    const out_n: u32 = 9;
    const dir = 12 + out_n * 16;
    var pos: u32 = (dir + 3) & ~@as(u32, 3);

    var tags: [9]u32 = undefined;
    var offs: [9]u32 = undefined;
    var lens: [9]u32 = undefined;
    var head_pos: u32 = 0;
    var t: u32 = 0;

    const put = struct {
        fn go(d: []u8, p: *u32, tg: *[9]u32, of: *[9]u32, ln: *[9]u32, idx: *u32,
             tag: u32, len: u32, limit: u32) bool
        {
            if (p.* + len > limit) return false;
            tg[idx.*] = tag;
            of[idx.*] = p.*;
            ln[idx.*] = len;
            idx.* += 1;
            const end = p.* + len;
            p.* = (end + 3) & ~@as(u32, 3);
            @memset(d[end..p.*], 0);
            return true;
        }
    }.go;

    // CFF
    if (pos + cff.len > scratch) return 0;
    @memcpy(dst[pos..][0..cff.len], cff);
    if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x43464620, @intCast(cff.len), @intCast(scratch))) return 0;

    // OS/2 (판 4)
    {
        const at = pos;
        @memset(dst[at .. at + 96], 0);
        wr16(dst, at + 0, 4);
        wr16(dst, at + 2, 500); // xAvgCharWidth
        wr16(dst, at + 4, 400); // usWeightClass
        wr16(dst, at + 6, 5); // usWidthClass
        wr16(dst, at + 30, 50); // yStrikeoutSize
        wr16(dst, at + 32, 300); // yStrikeoutPosition
        wrStr(dst, at + 58, "PDF ");
        wr16(dst, at + 62, 0x0040); // fsSelection = REGULAR
        wr16(dst, at + 64, 0x0020);
        wr16(dst, at + 66, 0xFFFF);
        wr16(dst, at + 68, 800); // sTypoAscender
        wr16(dst, at + 70, @as(u16, 0) -% 200); // sTypoDescender
        wr16(dst, at + 72, 200);
        wr16(dst, at + 74, 1000); // usWinAscent
        wr16(dst, at + 76, 300); // usWinDescent
        wr32(dst, at + 78, 1); // ulCodePageRange1
        wr16(dst, at + 86, 500); // sxHeight
        wr16(dst, at + 88, 700); // sCapHeight
        wr16(dst, at + 92, 0x20); // usBreakChar
        wr16(dst, at + 94, 1); // usMaxContext
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x4F532F32, 96, @intCast(scratch))) return 0;
    }

    // cmap
    if (pos + cmap_len > scratch) return 0;
    @memcpy(dst[pos..][0..cmap_len], dst[scratch..][0..cmap_len]);
    if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x636D6170, cmap_len, @intCast(scratch))) return 0;

    // head
    {
        const at = pos;
        head_pos = at;
        @memset(dst[at .. at + 54], 0);
        wr32(dst, at + 0, 0x00010000);
        wr32(dst, at + 4, 0x00010000);
        wr32(dst, at + 12, 0x5F0F3CF5); // magic
        wr16(dst, at + 16, 3); // flags
        wr16(dst, at + 18, 1000); // unitsPerEm
        wr16(dst, at + 36, @as(u16, 0) -% 500); // xMin
        wr16(dst, at + 38, @as(u16, 0) -% 500); // yMin
        wr16(dst, at + 40, 1500); // xMax
        wr16(dst, at + 42, 1500); // yMax
        wr16(dst, at + 46, 3); // lowestRecPPEM
        wr16(dst, at + 48, 2); // fontDirectionHint
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x68656164, 54, @intCast(scratch))) return 0;
    }

    // hhea
    {
        const at = pos;
        @memset(dst[at .. at + 36], 0);
        wr32(dst, at + 0, 0x00010000);
        wr16(dst, at + 4, 800); // ascender
        wr16(dst, at + 6, @as(u16, 0) -% 200); // descender
        wr16(dst, at + 10, 1000); // advanceWidthMax
        wr16(dst, at + 16, 1000); // xMaxExtent
        wr16(dst, at + 18, 1); // caretSlopeRise
        wr16(dst, at + 34, @intCast(ng)); // numberOfHMetrics
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x68686561, 36, @intCast(scratch))) return 0;
    }

    // hmtx — 폭은 PDF 가 알려 준 값을 쓴다
    {
        const at = pos;
        const len = ng * 4;
        if (at + len > scratch) return 0;
        var g: u32 = 0;
        while (g < ng) : (g += 1) {
            const w = widthOf(f, g);
            const wi: u16 = @intFromFloat(@max(0, @min(65535, w)));
            wr16(dst, at + g * 4, wi);
            wr16(dst, at + g * 4 + 2, 0);
        }
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x686D7478, len, @intCast(scratch))) return 0;
    }

    // maxp (CFF 는 0.5 판)
    {
        const at = pos;
        wr32(dst, at + 0, 0x00005000);
        wr16(dst, at + 4, @intCast(ng));
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x6D617870, 6, @intCast(scratch))) return 0;
    }

    // name
    {
        const at = pos;
        const len = buildName(dst[at..scratch]);
        if (len == 0) return 0;
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x6E616D65, len, @intCast(scratch))) return 0;
    }

    // post 3.0
    {
        const at = pos;
        @memset(dst[at .. at + 32], 0);
        wr32(dst, at + 0, 0x00030000);
        wr16(dst, at + 8, @as(u16, 0) -% 100); // underlinePosition
        wr16(dst, at + 10, 50);
        if (!put(dst, &pos, &tags, &offs, &lens, &t, 0x706F7374, 32, @intCast(scratch))) return 0;
    }

    // 표 목록
    wr32(dst, 0, 0x4F54544F); // 'OTTO'
    wr16(dst, 4, @intCast(out_n));
    var p2: u32 = 1;
    var es: u16 = 0;
    while (p2 * 2 <= out_n) : (p2 *= 2) es += 1;
    wr16(dst, 6, @intCast(p2 * 16));
    wr16(dst, 8, es);
    wr16(dst, 10, @intCast(out_n * 16 - p2 * 16));
    var k: u32 = 0;
    while (k < t) : (k += 1) {
        const r = 12 + k * 16;
        wr32(dst, r, tags[k]);
        wr32(dst, r + 4, sumTable(dst, offs[k], lens[k]));
        wr32(dst, r + 8, offs[k]);
        wr32(dst, r + 12, lens[k]);
    }
    if (head_pos != 0) {
        wr32(dst, head_pos + 8, 0);
        const whole = sumTable(dst, 0, pos);
        wr32(dst, head_pos + 8, 0xB1B0AFBA -% whole);
    }
    return pos;
}

/// 방금 등록한 글꼴에 파일을 붙인다.
fn attachFontFile(data: []const u8, is_cff: bool) void {
    if (font_n == 0 or fontArea() == 0) return;
    const f = &fontsBuf()[font_n - 1];
    const room = font_cap - font_used;
    if (room < 4096) return;
    const area = @as([*]u8, @ptrFromInt(fontArea() + font_used))[0..room];
    var n: u32 = 0;
    if (is_cff) {
        n = buildOtto(data, f, area);
        if (n == 0) return; // 껍데기를 못 지으면 싣지 않는다
        f.kind |= 512;
        f.file_off = font_used;
        f.file_len = n;
        font_used += (n + 3) & ~@as(u32, 3);
        return;
    }
    if (f.n > 0 or f.identity) n = patchFont(data, f, area);
    if (n == 0) {
        // 코드표가 없으면 파일의 cmap 을 그대로 믿는다. 다만 겉이라도 성한
        // 것만 싣는다 — 깨진 파일을 넘겨 봐야 FontFace 가 거절하고, 그동안
        // 메모리만 먹는다.
        if (data.len < 12 or data.len > room or data.len > 4 * 1024 * 1024) return;
        const tag = be32(data, 0);
        if (tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F) return;
        const num = be16(data, 4);
        if (num == 0 or num > 64 or 12 + @as(usize, num) * 16 > data.len) return;
        @memcpy(area[0..data.len], data);
        n = @intCast(data.len);
    }
    f.file_off = font_used;
    f.file_len = n;
    font_used += (n + 3) & ~@as(u32, 3);
}

/// 글자 하나만큼 자리를 옮긴다. 세로쓰기는 아래로 흐른다.
fn advance(f: ?*const FontMap, adv: f32, m: Mat) Mat {
    const vert = if (f) |ff| ff.vertical else false;
    if (vert) return matMul(.{ .e = 0, .f = -adv }, m);
    return matMul(.{ .e = adv, .f = 0 }, m);
}

// ===== CID → 글리프 번호 =====
//
// CID 글꼴은 대개 CID 가 곧 글리프 번호다(/CIDToGIDMap /Identity). 그런데
// 표를 스트림으로 주는 문서가 있다 — CID 하나에 두 바이트씩, 큰 자리가
// 앞이다. 이 표를 무시하면 글자가 통째로 엉뚱한 모양으로 나온다.
//
// 규격상 이 키는 CIDFontType2(트루타입 바탕)에만 쓴다. CFF 바탕인
// CIDFontType0 은 CFF 안 charset 이 그 몫을 한다.
const C2G_POOL = 1024 * 1024;
/// c2g_pool — 쓸 때 잡는다(그 갈래 문서가 아니면 안 잡는다)
var c2g_pool_at: usize = 0;
fn c2g_pool() []u8 {
    if (c2g_pool_at == 0) {
        c2g_pool_at = zoneAlloc(C2G_POOL) orelse 0;
        if (c2g_pool_at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(c2g_pool_at))[0..C2G_POOL];
}
var c2g_used: u32 = 0;

fn cidToGid(f: *const FontMap, cid: u32) u32 {
    if (f.c2g_len == 0) return cid;
    if (cid > 0xFFFF) return 0;
    const at = f.c2g_off + cid * 2;
    if (at + 1 >= f.c2g_off + f.c2g_len) return 0;
    return (@as(u32, c2g_pool()[at]) << 8) | c2g_pool()[at + 1];
}

// ===== 미리 정의된 CMap =====
//
// KSCms-UHC-H 같은 이름만 적힌 CMap 은 표가 PDF 안에 없다. 표는 Adobe 가
// 이름으로 배포한다. 다 싣기엔 7MB 라 wasm 에 넣지 않는다. 문서가 실제로
// 쓰는 이름만 화면 쪽이 받아 여기에 넣어 준다 — 한글 문서면 보통 4KB 하나다.
// 굽는 형식은 scripts/build-cmaps.mjs 에 있다.
const CMAP_POOL = 2 * 1024 * 1024;
/// cmap_pool — 쓸 때 잡는다(그 갈래 문서가 아니면 안 잡는다)
var cmap_pool_at: usize = 0;
fn cmap_pool() []u8 {
    if (cmap_pool_at == 0) {
        cmap_pool_at = zoneAlloc(CMAP_POOL) orelse 0;
        if (cmap_pool_at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(cmap_pool_at))[0..CMAP_POOL];
}
var cmap_used: u32 = 0;
const CMapT = struct { name: [32]u8, name_len: u8, off: u32, len: u32 };
/// 미리 정의된 CMap. 필요한 만큼 늘어난다(세는 상한 없음).
var cmaps_at: usize = 0;
var cmaps_cap: u32 = 0;
fn cmapsBuf() []CMapT {
    if (cmaps_at == 0 or cmaps_cap == 0) return &[_]CMapT{};
    return @as([*]CMapT, @ptrFromInt(cmaps_at))[0..cmaps_cap];
}
fn cmapsRoom(want: u32) bool { return growTable(&cmaps_at, &cmaps_cap, want, @sizeOf(CMapT), 8); }
var cmap_n: u32 = 0;

export fn cmapReset() void { cmap_n = 0; cmap_used = 0; }
/// 다음 표를 적을 자리. 화면 쪽이 여기에 바이트를 넣고 cmapAdd 를 부른다.
export fn cmapPtr() usize {
    // JS 가 표를 여기에 적는다. 자리를 여기서 잡으므로(메모리가 늘 수 있다)
    // 부르는 쪽은 이 값을 먼저 받고 나서 memory.buffer 를 잡아야 한다.
    const p = cmap_pool();
    if (p.len == 0) return heapBase();
    return @intFromPtr(p.ptr) + cmap_used;
}
export fn cmapRoom() u32 { return CMAP_POOL - cmap_used; }
/// 방금 cmapPtr 에 적은 len 바이트를, 목록의 idx 번째 이름으로 등록한다.
/// 이름을 따로 넘기지 않는 건 받을 것이 늘 그 목록에서 나오기 때문이다.
export fn cmapAdd(idx: u32, len: u32) u32 {
    if (!cmapsRoom(cmap_n + 1) or len == 0 or idx >= need_n) return 0;
    if (len > CMAP_POOL - cmap_used) return 0;
    const nm = need_buf[need_off[idx]..][0..need_lens[idx]];
    const t = &cmapsBuf()[cmap_n];
    const nl = @min(nm.len, 32);
    var i: u32 = 0;
    while (i < nl) : (i += 1) t.name[i] = nm[i];
    t.name_len = @intCast(nl);
    t.off = cmap_used;
    t.len = len;
    cmap_used += len;
    cmap_n += 1;
    return 1;
}

fn cmapFind(name: []const u8) i16 {
    var i: u32 = 0;
    while (i < cmap_n) : (i += 1) {
        const t = &cmapsBuf()[i];
        if (t.name_len == name.len and std_mem_eq(t.name[0..t.name_len], name)) return @intCast(i);
    }
    return -1;
}

fn le16(d: []const u8, at: u32) u32 { return @as(u32, d[at]) | (@as(u32, d[at + 1]) << 8); }
fn le32(d: []const u8, at: u32) u32 { return le16(d, at) | (le16(d, at + 2) << 16); }

/// 구운 표를 읽을 채비. 코드가 두 바이트 안에 드는 표는 칸이 절반이다.
const CM = struct {
    d: []const u8,
    wide: bool,
    ns: u32,
    nr: u32,
    cr: u32,
};

fn cmapOf(idx: i16) ?CM {
    if (idx < 0) return null;
    const u: u32 = @intCast(idx);
    if (u >= cmap_n) return null;
    const t = cmapsBuf()[u];
    const d = cmap_pool()[t.off..][0..t.len];
    if (d.len < 9 or d[0] != 'C' or d[1] != 'M' or d[2] != '1') return null;
    const wide = d[4] != 0;
    const ns = le16(d, 5);
    const nr = le16(d, 7);
    const sw: u32 = if (wide) 9 else 5;
    const rw: u32 = if (wide) 10 else 6;
    const cr = 9 + ns * sw;
    if (cr + nr * rw > d.len) return null;
    return CM{ .d = d, .wide = wide, .ns = ns, .nr = nr, .cr = cr };
}

const CmRange = struct { lo: u32, hi: u32, v: u32 };

fn cmSpace(cm: CM, i: u32) CmRange {
    const at = 9 + i * (if (cm.wide) @as(u32, 9) else 5);
    const nb = cm.d[at];
    if (cm.wide) return .{ .lo = le32(cm.d, at + 1), .hi = le32(cm.d, at + 5), .v = nb };
    return .{ .lo = le16(cm.d, at + 1), .hi = le16(cm.d, at + 3), .v = nb };
}

fn cmRange(cm: CM, i: u32) CmRange {
    const at = cm.cr + i * (if (cm.wide) @as(u32, 10) else 6);
    if (cm.wide) return .{ .lo = le32(cm.d, at), .hi = le32(cm.d, at + 4), .v = le16(cm.d, at + 8) };
    return .{ .lo = le16(cm.d, at), .hi = le16(cm.d, at + 2), .v = le16(cm.d, at + 4) };
}

/// 앞바이트만 보고 코드 폭을 정한다.
///
/// codespacerange 가 그 답을 갖고 있다. UHC 는 <00><80> 과 <8141><FEFE> 라,
/// 앞바이트가 0x81 이상이면 두 바이트다. 표마다 경계가 달라서 이름만으로
/// 어림잡으면 틀린다.
fn cmCodeLen(cm: CM, lead: u8) u32 {
    var i: u32 = 0;
    while (i < cm.ns) : (i += 1) {
        const r = cmSpace(cm, i);
        if (r.v == 0 or r.v > 4) continue;
        const sh: u5 = @intCast((r.v - 1) * 8);
        if (lead >= ((r.lo >> sh) & 0xFF) and lead <= ((r.hi >> sh) & 0xFF)) return r.v;
    }
    return 1;
}

/// 코드 → CID. 범위는 시작값 순으로 구워 두므로 반씩 좁혀 찾는다.
fn cmCid(cm: CM, code: u32) u32 {
    var lo: u32 = 0;
    var hi: u32 = cm.nr;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = cmRange(cm, mid);
        if (code < r.lo) hi = mid
        else if (code > r.hi) lo = mid + 1
        else return r.v + (code - r.lo);
    }
    return 0;
}

fn toCid(f: ?*const FontMap, code: u32) u32 {
    const ff = f orelse return code;
    const cm = cmapOf(ff.cm) orelse return code;
    return cmCid(cm, code);
}

/// CID 로 유니코드를 찾는다. ToUnicode 가 없는 문서를 복사할 때 쓴다.
fn cidUni(f: ?*const FontMap, cid: u32) ?u32 {
    const ff = f orelse return null;
    if (ff.uc < 0) return null;
    const u: u32 = @intCast(ff.uc);
    if (u >= cmap_n) return null;
    const t = cmapsBuf()[u];
    const d = cmap_pool()[t.off..][0..t.len];
    if (d.len < 4 or d[0] != 'C' or d[1] != 'U' or d[2] != '1') return null;
    const at = 4 + cid * 2;
    if (at + 1 >= d.len) return null;
    const v = le16(d, at);
    return if (v == 0) null else v;
}

// ===== 무엇을 받아야 하는가 =====

var need_buf: [512]u8 = undefined;
var need_off: [16]u32 = undefined;
var need_lens: [16]u32 = undefined;
var need_n: u32 = 0;
var need_used: u32 = 0;

export fn needCount() u32 { return need_n; }
export fn needOff(i: u32) u32 { return if (i < need_n) need_off[i] else 0; }
export fn needLen(i: u32) u32 { return if (i < need_n) need_lens[i] else 0; }
export fn needPtr() [*]u8 { return &need_buf; }

fn pushNeed(nm: []const u8) void {
    if (need_n >= 16 or nm.len == 0 or nm.len + need_used > need_buf.len) return;
    var i: u32 = 0;
    while (i < need_n) : (i += 1) {
        if (need_lens[i] == nm.len and
            std_mem_eq(need_buf[need_off[i]..][0..nm.len], nm)) return;
    }
    @memcpy(need_buf[need_used..][0..nm.len], nm);
    need_off[need_n] = need_used;
    need_lens[need_n] = @intCast(nm.len);
    need_used += @intCast(nm.len);
    need_n += 1;
}

/// 문서가 쓰는 미리 정의된 CMap 이름을 모은다.
///
/// 표가 PDF 안에 없으니 화면 쪽이 받아 와야 한다. 무엇이 필요한지 여기서
/// 알려 준다. Identity 는 표가 없어도 되니 뺀다. /Ordering 은 그 계열의
/// CID→유니코드 표를 뜻한다 — ToUnicode 가 없을 때 글자를 찾는 데 쓴다.
fn collectNeeds(b: []const u8) void {
    need_n = 0;
    need_used = 0;
    var p: usize = 0;
    while (p + 12 < b.len) : (p += 1) {
        if (b[p] != '/') continue;
        if (std_mem_eq(b[p..][0..9], "/Encoding")) {
            var q = p + 9;
            while (q < b.len and isSpace(b[q])) q += 1;
            if (q < b.len and b[q] == '/') {
                var e = q + 1;
                while (e < b.len and !isSpace(b[e]) and b[e] != '/' and
                    b[e] != '>' and b[e] != '[' and b[e] != '<') e += 1;
                const nm = b[q + 1 .. e];
                if (nm.len >= 3 and nm.len <= 32 and findIn(nm, "Identity", 0) == null)
                    pushNeed(nm);
            }
            p += 8;
            continue;
        }
        if (std_mem_eq(b[p..][0..9], "/Ordering")) {
            var q = p + 9;
            while (q < b.len and isSpace(b[q])) q += 1;
            if (q < b.len and b[q] == '(') {
                var e = q + 1;
                while (e < b.len and e < q + 24 and b[e] != ')') e += 1;
                const nm = b[q + 1 .. e];
                if (nm.len >= 2 and nm.len <= 20 and findIn(nm, "Identity", 0) == null) {
                    var tmp: [32]u8 = undefined;
                    @memcpy(tmp[0..nm.len], nm);
                    @memcpy(tmp[nm.len..][0..5], "-UCS2");
                    pushNeed(tmp[0 .. nm.len + 5]);
                }
            }
            p += 8;
        }
    }
}

/// 이 글꼴에서 다음 코드 하나가 몇 바이트인가.
///
/// Identity 나 UCS2 는 늘 두 바이트지만, EUC·UHC·Shift-JIS 는 앞 바이트를
/// 보고 정한다. 이걸 모르고 한 바이트씩 끊으면 글자가 통째로 깨진다.
fn codeLen(f: ?*const FontMap, lead: u8) u32 {
    // 표를 받아 뒀으면 codespacerange 가 정확한 답을 준다
    if (f) |ff| {
        if (cmapOf(ff.cm)) |cm| return cmCodeLen(cm, lead);
    }
    const k = if (f) |ff| ff.cmap_kind else 0;
    return switch (k) {
        1, 2 => 2,
        3 => if (lead >= 0x81) @as(u32, 2) else 1,
        4 => if ((lead >= 0x81 and lead <= 0x9F) or (lead >= 0xE0 and lead <= 0xFC)) @as(u32, 2) else 1,
        else => 1,
    };
}

/// 이름으로 미리 정의된 CMap 갈래를 알아본다.
fn cmapKindOf(name: []const u8) u8 {
    if (findIn(name, "Identity", 0) != null) return 1;
    if (findIn(name, "UCS2", 0) != null or findIn(name, "UTF16", 0) != null) return 2;
    if (findIn(name, "RKSJ", 0) != null) return 4;
    if (findIn(name, "EUC", 0) != null or findIn(name, "UHC", 0) != null or
        findIn(name, "B5", 0) != null or findIn(name, "GBK", 0) != null or
        findIn(name, "GBpc", 0) != null or findIn(name, "Johab", 0) != null) return 3;
    return 0;
}

/// 코드 하나를 그린 뒤 글자 자리가 나아가는 양 (텍스트 공간).
fn step(f: ?*const FontMap, code: u32, size: f32, tc: f32, tw: f32, th: f32) f32 {
    const w = if (f) |ff| widthOf(ff, code) else 500;
    const two = if (f) |ff| ff.two_byte else false;
    const word: f32 = if (code == 32 and !two) tw else 0;
    // Type3 의 폭은 글리프 공간 값이라 FontMatrix 로 텍스트 공간에 옮긴다.
    const unit: f32 = if (f) |ff| (if (ff.type3) ff.fm[0] else 0.001) else 0.001;
    return (w * unit * size + tc + word) * th;
}

/// 코드의 폭(1000 단위). 표에 없으면 기본값.
/// /BaseFont 이름으로 표준 14종을 알아본다.
///
/// 문서마다 표기가 갈린다 — "ABCDEF+Helvetica-Bold", "Arial,Bold",
/// "TimesNewRomanPS-ItalicMT" 처럼. 부분집합 앞머리를 떼고 소문자로 눕힌 뒤
/// 굵기·기울기를 따로 읽어 짝을 찾는다.
fn std14For(b: []const u8, fbody: usize, fend: usize) ?*const [256]u16 {
    var raw: [64]u8 = undefined;
    const n = nameAfter(b, fbody, fend, "/BaseFont", &raw);
    if (n == 0) return null;
    var low: [64]u8 = undefined;
    var ln: u32 = 0;
    var i: u32 = 0;
    // "ABCDEF+" 부분집합 앞머리는 뗀다
    var start: u32 = 0;
    if (n > 7 and raw[6] == '+') start = 7;
    while (i + start < n) : (i += 1) {
        const c = raw[i + start];
        if (c == '-' or c == ' ' or c == ',' or c == '_') continue;
        low[ln] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        ln += 1;
        if (ln >= low.len) break;
    }
    const name = low[0..ln];
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            if (needle.len > hay.len) return false;
            var k: usize = 0;
            while (k + needle.len <= hay.len) : (k += 1) {
                if (std_mem_eq(hay[k .. k + needle.len], needle)) return true;
            }
            return false;
        }
    }.f;

    const bold = has(name, "bold") or has(name, "black") or has(name, "heavy");
    const ital = has(name, "italic") or has(name, "oblique");
    var want: []const u8 = "";
    if (has(name, "courier") or has(name, "mono")) {
        want = if (bold and ital) "courierboldoblique" else if (bold) "courierbold" else if (ital) "courieroblique" else "courier";
    } else if (has(name, "times")) {
        want = if (bold and ital) "timesromanbolditalic" else if (bold) "timesromanbold" else if (ital) "timesromanitalic" else "timesroman";
    } else if (has(name, "zapf") or has(name, "dingbat")) {
        want = "zapfdingbats";
    } else if (has(name, "symbol")) {
        want = "symbol";
    } else if (has(name, "helvetica") or has(name, "arial")) {
        want = if (bold and ital) "helveticaboldoblique" else if (bold) "helveticabold" else if (ital) "helveticaoblique" else "helvetica";
    } else return null;

    for (std14.STD14) |e| {
        if (std_mem_eq(e.name, want)) return e.w;
    }
    return null;
}

fn widthOf(f: *const FontMap, code: u32) f32 {
    var i: u16 = 0;
    while (i < f.wn) : (i += 1) if (u16buf(f.wcodes_at, f.wcodes_cap)[i] == code) return @floatFromInt(u16buf(f.wvals_at, f.wvals_cap)[i]);
    // 표준 14종은 문서가 /Widths 를 안 적어도 된다. 그때는 Adobe 가 낸
    // AFM 값을 쓴다 — 없으면 글자마다 500 으로 잡아 자간이 통째로 어긋난다.
    if (f.std_w) |w| {
        if (code < 256 and w[code] > 0) return @floatFromInt(w[code]);
    }
    if (f.dw > 0) return f.dw;
    // 폭을 모르면 라틴은 반각, 두 바이트 글꼴은 전각으로 본다
    return if (f.two_byte) 1000 else 500;
}

fn pushWidth(f: *FontMap, code: u32, v: f32) void {
    if (code > 65535 or !widthRoom(f, f.wn + 1)) return;
    const c: f32 = @max(0, @min(65535, v));
    u16buf(f.wcodes_at, f.wcodes_cap)[f.wn] = @intCast(code);
    u16buf(f.wvals_at, f.wvals_cap)[f.wn] = @intFromFloat(c);
    f.wn += 1;
}

// ===== 단순 글꼴의 인코딩 =====
//
// 한 바이트 글꼴은 코드가 곧 글자가 아니다. /Encoding 이 정한다.
// ToUnicode 가 있으면 그게 낫지만, 없는 문서가 많다. 그때 코드를 그대로
// 유니코드로 보면 0x95(WinAnsi 의 가운뎃점 •)가 제어문자가 되어 사라지고,
// /Differences 를 쓰는 부분집합 글꼴은 글자가 통째로 엉뚱해진다.

/// WinAnsi 의 0x80~0x9F. 나머지는 라틴-1 과 같다.
const WIN_HI = [_]u16{
    0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
    0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
};

/// MacRoman 의 0x80~0xFF
const MAC_HI = [_]u16{
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
};

/// 글리프 이름 → 유니코드. /Differences 가 이름으로 온다.
const GNAMES =
    "space 32 exclam 33 quotedbl 34 numbersign 35 dollar 36 percent 37 ampersand 38 " ++
    "quotesingle 39 quoteright 8217 quoteleft 8216 parenleft 40 parenright 41 asterisk 42 " ++
    "plus 43 comma 44 hyphen 45 period 46 slash 47 zero 48 one 49 two 50 three 51 four 52 " ++
    "five 53 six 54 seven 55 eight 56 nine 57 colon 58 semicolon 59 less 60 equal 61 " ++
    "greater 62 question 63 at 64 bracketleft 91 backslash 92 bracketright 93 " ++
    "asciicircum 94 underscore 95 grave 96 braceleft 123 bar 124 braceright 125 " ++
    "asciitilde 126 bullet 8226 endash 8211 emdash 8212 quotedblleft 8220 " ++
    "quotedblright 8221 quotesinglbase 8218 quotedblbase 8222 dagger 8224 " ++
    "daggerdbl 8225 ellipsis 8230 perthousand 8240 guilsinglleft 8249 " ++
    "guilsinglright 8250 fraction 8260 florin 402 section 167 currency 164 yen 165 " ++
    "sterling 163 cent 162 copyright 169 registered 174 trademark 8482 degree 176 " ++
    "plusminus 177 mu 181 paragraph 182 periodcentered 183 onequarter 188 onehalf 189 " ++
    "threequarters 190 ordfeminine 170 ordmasculine 186 germandbls 223 ae 230 AE 198 " ++
    "oe 339 OE 338 oslash 248 Oslash 216 exclamdown 161 questiondown 191 " ++
    "guillemotleft 171 guillemotright 187 logicalnot 172 minus 8722 multiply 215 " ++
    "divide 247 nbspace 160 space 32 fi 64257 fl 64258 dotlessi 305 lslash 322 " ++
    "Lslash 321 scaron 353 Scaron 352 zcaron 382 Zcaron 381 ydieresis 255 " ++
    "Ydieresis 376 thorn 254 Thorn 222 eth 240 Eth 208 " ++
    "acute 180 circumflex 710 dieresis 168 caron 711 breve 728 tilde 732 " ++
    "macron 175 ring 730 cedilla 184 ogonek 731 dotaccent 729 hungarumlaut 733";

/// "aacute" 처럼 밑글자+악센트인 이름은 밑글자만이라도 살린다.
const ACCENTS = "acute grave circumflex tilde dieresis ring cedilla caron breve macron ogonek";

fn nameToUni(nm: []const u8) u32 {
    if (nm.len == 0) return 0;
    if (nm.len == 1) return nm[0];
    // uniXXXX · uXXXX
    if (nm.len >= 7 and std_mem_eq(nm[0..3], "uni")) {
        var v: u32 = 0;
        var i: usize = 3;
        while (i < 7) : (i += 1) v = (v << 4) | (hexVal(nm[i]) orelse return 0);
        return v;
    }
    if (nm[0] == 'u' and nm.len >= 5 and nm.len <= 7) {
        var v: u32 = 0;
        var i: usize = 1;
        while (i < nm.len) : (i += 1) v = (v << 4) | (hexVal(nm[i]) orelse return 0);
        if (v > 0) return v;
    }
    // 표에서 찾는다
    var p: usize = 0;
    while (p < GNAMES.len) {
        const s0 = p;
        while (p < GNAMES.len and GNAMES[p] != ' ') p += 1;
        const key = GNAMES[s0..p];
        while (p < GNAMES.len and GNAMES[p] == ' ') p += 1;
        const v0 = p;
        while (p < GNAMES.len and GNAMES[p] != ' ') p += 1;
        if (key.len == nm.len and std_mem_eq(key, nm)) {
            var q: usize = 0;
            return @intFromFloat(@max(0, readFloat(GNAMES[v0..p], &q)));
        }
        while (p < GNAMES.len and GNAMES[p] == ' ') p += 1;
    }
    // "Aacute" 처럼 밑글자 + 악센트
    if (nm.len >= 2) {
        var q: usize = 0;
        while (q < ACCENTS.len) {
            const s0 = q;
            while (q < ACCENTS.len and ACCENTS[q] != ' ') q += 1;
            const acc = ACCENTS[s0..q];
            while (q < ACCENTS.len and ACCENTS[q] == ' ') q += 1;
            if (nm.len == acc.len + 1 and std_mem_eq(nm[1..], acc)) return nm[0];
        }
    }
    return 0;
}

/// 한 바이트 글꼴의 코드 → 유니코드 표를 인코딩에서 짓는다.
fn attachEncoding(b: []const u8, fbody: usize, fend: usize, f: *FontMap) void {
    // ToUnicode 가 있으면 그게 낫다
    if (f.n > 0) return;
    var base: u8 = 0; // 0 표준 1 WinAnsi 2 MacRoman
    var ds: usize = 0;
    var de: usize = 0;
    if (find(b[fbody..fend], "/Encoding", 0)) |ea| {
        var q = fbody + ea + 9;
        while (q < fend and isSpace(b[q])) q += 1;
        if (q < fend and b[q] == '/') {
            const w = b[q..@min(fend, q + 20)];
            if (findIn(w, "WinAnsi", 0) != null) base = 1
            else if (findIn(w, "MacRoman", 0) != null) base = 2;
        } else if (q < fend and (b[q] == '<' or isDigit(b[q]))) {
            if (b[q] == '<') { ds = q; de = dictEnd(b, q, fend); }
            else {
                const on = readUint(b, &q);
                if (findObj(b, on)) |ob| { ds = ob; de = objDictEnd(b, ob); }
            }
            if (de > ds) {
                const w = b[ds..de];
                if (findIn(w, "WinAnsi", 0) != null) base = 1
                else if (findIn(w, "MacRoman", 0) != null) base = 2;
            }
        }
    }
    // 밑바탕 인코딩
    var c: u32 = 32;
    while (c < 256) : (c += 1) {
        var u: u32 = 0;
        if (c < 127) u = c
        else if (base == 2) u = MAC_HI[c - 128]
        else if (base == 1) u = if (c < 160) WIN_HI[c - 128] else c
        else if (c >= 160) u = c;
        if (u == 0) continue;
        if (!mapRoom(f, f.n + 1)) break;
        u16buf(f.codes_at, f.codes_cap)[f.n] = @intCast(c);
        u16buf(f.unis_at, f.unis_cap)[f.n] = @intCast(@min(u, 65535));
        f.n += 1;
    }
    // /Differences 가 있으면 덮어쓴다
    if (de <= ds) return;
    const da = find(b[ds..de], "/Differences", 0) orelse return;
    var p = ds + da + 12;
    while (p < de and b[p] != '[') p += 1;
    p += 1;
    var code: u32 = 0;
    while (p < de and b[p] != ']') {
        while (p < de and isSpace(b[p])) p += 1;
        if (p >= de or b[p] == ']') break;
        if (isDigit(b[p])) {
            code = readUint(b, &p);
            continue;
        }
        if (b[p] != '/') { p += 1; continue; }
        var e2 = p + 1;
        while (e2 < de and !isSpace(b[e2]) and b[e2] != '/' and b[e2] != ']') e2 += 1;
        const u = nameToUni(b[p + 1 .. e2]);
        if (u != 0 and code < 256) {
            var k: u32 = 0;
            var hit = false;
            while (k < f.n) : (k += 1) if (u16buf(f.codes_at, f.codes_cap)[k] == code) {
                u16buf(f.unis_at, f.unis_cap)[k] = @intCast(@min(u, 65535));
                hit = true;
                break;
            };
            if (!hit and mapRoom(f, f.n + 1)) {
                u16buf(f.codes_at, f.codes_cap)[f.n] = @intCast(code);
                u16buf(f.unis_at, f.unis_cap)[f.n] = @intCast(@min(u, 65535));
                f.n += 1;
            }
        }
        code += 1;
        p = e2;
    }
}

/// 단순 글꼴의 /Widths — FirstChar 부터 차례로 늘어놓은 배열
fn readSimpleWidths(f: *FontMap, b: []const u8, s: usize, e: usize, first: u32) void {
    var p = s;
    var code = first;
    while (p < e) {
        while (p < e and isSpace(b[p])) p += 1;
        if (p >= e or b[p] == ']') break;
        if (!(isDigit(b[p]) or b[p] == '-' or b[p] == '.')) break;
        pushWidth(f, code, readFloat(b, &p));
        code += 1;
    }
}

/// CID 글꼴의 /W — "c [w ...]" 또는 "c1 c2 w" 가 섞여 나온다
fn readCidWidths(f: *FontMap, b: []const u8, s: usize, e: usize) void {
    var p = s;
    while (p < e) {
        while (p < e and isSpace(b[p])) p += 1;
        if (p >= e or b[p] == ']') break;
        if (!isDigit(b[p])) { p += 1; continue; }
        const c1: u32 = @intFromFloat(@max(0, readFloat(b, &p)));
        while (p < e and isSpace(b[p])) p += 1;
        if (p < e and b[p] == '[') {
            p += 1;
            var code = c1;
            while (p < e) {
                while (p < e and isSpace(b[p])) p += 1;
                if (p >= e or b[p] == ']') { p += 1; break; }
                if (!(isDigit(b[p]) or b[p] == '-' or b[p] == '.')) { p += 1; continue; }
                pushWidth(f, code, readFloat(b, &p));
                code += 1;
            }
        } else {
            if (p >= e or !isDigit(b[p])) continue;
            const c2: u32 = @intFromFloat(@max(0, readFloat(b, &p)));
            while (p < e and isSpace(b[p])) p += 1;
            if (p >= e or !(isDigit(b[p]) or b[p] == '-' or b[p] == '.')) continue;
            const v = readFloat(b, &p);
            var c = c1;
            while (c <= c2 and c - c1 < 65535) : (c += 1) pushWidth(f, c, v);
        }
    }
}

/// "[" 로 시작하는 배열의 끝을 찾는다 (안쪽 배열까지 센다)
fn arrayEnd(b: []const u8, s: usize, limit: usize) usize {
    var p = s;
    var depth: u32 = 0;
    while (p < limit) : (p += 1) {
        if (b[p] == '[') depth += 1;
        if (b[p] == ']') { depth -= 1; if (depth == 0) return p; }
    }
    return limit;
}

/// Type0 이면 자손 글꼴 딕셔너리 범위를 준다.
fn descendantOf(b: []const u8, fbody: usize, fend: usize) ?[2]usize {
    const da = find(b[fbody..fend], "/DescendantFonts", 0) orelse return null;
    var p = fbody + da + 16;
    while (p < fend and (isSpace(b[p]) or b[p] == '[')) p += 1;
    if (p >= fend or !isDigit(b[p])) return null;
    const dn = readUint(b, &p);
    const db = findObj(b, dn) orelse return null;
    return .{ db, find(b, "endobj", db) orelse b.len };
}

/// 방금 등록한 글꼴에 폭 표를 채운다.
fn attachWidths(b: []const u8, fbody: usize) void {
    if (font_n == 0) return;
    const f = &fontsBuf()[font_n - 1];
    const fend = find(b, "endobj", fbody) orelse b.len;
    // Identity-H 는 두 바이트 코드가 곧 CID 다
    if (find(b[fbody..fend], "/Encoding", 0)) |ea2| {
        var q = fbody + ea2 + 9;
        while (q < fend and isSpace(b[q])) q += 1;
        if (q < fend and b[q] == '/') {
            var nq = q + 1;
            while (nq < fend and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>') nq += 1;
            const nm = b[q + 1 .. nq];
            f.cmap_kind = cmapKindOf(nm);
            if (f.cmap_kind == 1) f.identity = true;
            if (f.cmap_kind != 0) f.two_byte = true;
            if (nm.len >= 2 and nm[nm.len - 1] == 'V') f.vertical = true;
            // 받아 둔 표가 있으면 어림짐작 대신 그걸 쓴다
            f.cm = cmapFind(nm);
            if (f.cm >= 0) f.two_byte = true;
        }
    }

    if (descendantOf(b, fbody, fend)) |d| {
        const db = d[0];
        const de = d[1];
        // CIDToGIDMap 이 스트림이면 CID 와 글리프 번호가 다르다.
        // 표를 읽어 두면 번호로 글리프를 그대로 집을 수 있다.
        if (find(b[db..de], "/CIDToGIDMap", 0)) |ca| {
            var q = db + ca + 12;
            while (q < de and isSpace(b[q])) q += 1;
            if (q < de and isDigit(b[q])) {
                const gn = readUint(b, &q);
                // streamOf 의 결과는 다음 호출이 덮으므로 바로 옮겨 둔다
                if (streamOf(b, gn)) |m| {
                    const room = C2G_POOL - c2g_used;
                    const n = @min(m.len, room);
                    if (n >= 2) {
                        @memcpy(c2g_pool()[c2g_used..][0..n], m[0..n]);
                        f.c2g_off = c2g_used;
                        f.c2g_len = @intCast(n);
                        c2g_used += @intCast(n);
                        // 표가 있으면 CID 로 글리프를 집을 수 있다
                        f.identity = true;
                    } else f.identity = false;
                } else f.identity = false;
            }
        }
        // 이 글꼴이 어느 계열인지 — CID 로 글자를 찾을 때 쓴다
        if (find(b[db..de], "/Ordering", 0)) |oa| {
            var q = db + oa + 9;
            while (q < de and isSpace(b[q])) q += 1;
            if (q < de and b[q] == '(') {
                var e = q + 1;
                while (e < de and e < q + 24 and b[e] != ')') e += 1;
                const on = b[q + 1 .. e];
                if (on.len <= 20) {
                    var tmp: [32]u8 = undefined;
                    @memcpy(tmp[0..on.len], on);
                    @memcpy(tmp[on.len..][0..5], "-UCS2");
                    f.uc = cmapFind(tmp[0 .. on.len + 5]);
                }
            }
        }
        if (intAfter(b, db, de, "/DW")) |dw| f.dw = @floatFromInt(dw);
        if (find(b[db..de], "/W", 0)) |wa| {
            var p = db + wa + 2;
            while (p < de and isSpace(b[p])) p += 1;
            if (p < de and b[p] == '[') readCidWidths(f, b, p + 1, arrayEnd(b, p, de));
        }
        if (f.dw == 0) f.dw = 1000; // 규격 기본값
        return;
    }
    // 한 바이트 글꼴이면 인코딩으로 코드→글자 표를 짓는다
    attachEncoding(b, fbody, fend, f);
    // 표준 14종이면 폭 표를 달아 둔다. /Widths 가 있으면 그쪽이 이긴다.
    f.std_w = std14For(b, fbody, fend);
    const first = intAfter(b, fbody, fend, "/FirstChar") orelse 0;
    const wa = find(b[fbody..fend], "/Widths", 0) orelse return;
    var p = fbody + wa + 7;
    while (p < fend and isSpace(b[p])) p += 1;
    if (p < fend and b[p] == '[') {
        readSimpleWidths(f, b, p + 1, arrayEnd(b, p, fend), first);
    } else if (p < fend and isDigit(b[p])) {
        const wn = readUint(b, &p);
        if (findObj(b, wn)) |wb| {
            const we = find(b, "endobj", wb) orelse b.len;
            var q = wb;
            while (q < we and b[q] != '[') q += 1;
            if (q < we) readSimpleWidths(f, b, q + 1, arrayEnd(b, q, we), first);
        }
    }
}

/// "<<" 로 시작하는 딕셔너리의 끝(">>" 다음)을 찾는다.
fn dictEnd(b: []const u8, s: usize, limit: usize) usize {
    var p = s;
    var depth: u32 = 0;
    while (p + 1 < limit) : (p += 1) {
        if (b[p] == '<' and b[p + 1] == '<') { depth += 1; p += 1; continue; }
        if (b[p] == '>' and b[p + 1] == '>') {
            depth -= 1;
            if (depth == 0) return p + 2;
            p += 1;
            continue;
        }
    }
    return limit;
}

/// 딕셔너리 구간에서 "/이름 N 0 R" 의 N 을 찾는다.
fn keyRef(b: []const u8, s: usize, e: usize, name: []const u8) ?u32 {
    var p = s;
    while (p + name.len + 1 < e) : (p += 1) {
        if (b[p] != '/') continue;
        if (!std_mem_eq(b[p + 1 .. p + 1 + name.len], name)) continue;
        const after = b[p + 1 + name.len];
        if (!isSpace(after) and after != '/' and after != '>') continue;
        var q = p + 1 + name.len;
        while (q < e and isSpace(b[q])) q += 1;
        if (q < e and isDigit(b[q])) return readUint(b, &q);
        return null;
    }
    return null;
}

/// Type3 글꼴의 글리프 그림을 찾아 코드마다 이어 둔다.
///
/// Type3 는 글리프가 글꼴 파일이 아니라 작은 콘텐츠 스트림으로 들어 있다.
/// 크롬이 맥에서 만든 PDF 의 한글이 그렇고, 관공서 문서의 바코드도 대개
/// 그렇다. 실을 글꼴이 없으니 시스템 글꼴로 때우면 엉뚱한 그림이 된다.
/// 우리는 콘텐츠 해석기를 이미 갖고 있으므로 그 스트림을 그대로 돌린다.
fn attachType3(b: []const u8, fbody: usize) void {
    if (font_n == 0) return;
    const f = &fontsBuf()[font_n - 1];
    const fend = find(b, "endobj", fbody) orelse b.len;
    if (find(b[fbody..fend], "/Subtype", 0)) |sa| {
        var q = fbody + sa + 8;
        while (q < fend and isSpace(q_at(b, q))) q += 1;
        if (!(q + 6 <= fend and std_mem_eq(b[q .. q + 6], "/Type3"))) return;
    } else return;
    f.type3 = true;
    f.kind |= 32;

    if (find(b[fbody..fend], "/FontMatrix", 0)) |ma| {
        var p = fbody + ma + 11;
        while (p < fend and b[p] != '[') p += 1;
        p += 1;
        var i: u32 = 0;
        while (i < 6 and p < fend) : (i += 1) f.fm[i] = readFloat(b, &p);
    }

    // CharProcs 구간
    var cs: usize = 0;
    var ce: usize = 0;
    if (find(b[fbody..fend], "/CharProcs", 0)) |ca| {
        var p = fbody + ca + 10;
        while (p < fend and isSpace(b[p])) p += 1;
        if (p < fend and b[p] == '<') { cs = p; ce = dictEnd(b, p, fend); }
        else if (p < fend and isDigit(b[p])) {
            const n = readUint(b, &p);
            if (findObj(b, n)) |cb| {
                const cend = find(b, "endobj", cb) orelse b.len;
                var q = cb;
                while (q < cend and b[q] != '<') q += 1;
                cs = q;
                ce = dictEnd(b, q, cend);
            }
        }
    }
    if (ce <= cs) return;

    // Encoding 의 Differences 로 코드→이름을 걷는다
    var es = fbody;
    var ee = fend;
    if (find(b[fbody..fend], "/Encoding", 0)) |ea| {
        var p = fbody + ea + 9;
        while (p < fend and isSpace(b[p])) p += 1;
        if (p < fend and b[p] == '<') { es = p; ee = dictEnd(b, p, fend); }
        else if (p < fend and isDigit(b[p])) {
            const n = readUint(b, &p);
            if (findObj(b, n)) |eb| { es = eb; ee = find(b, "endobj", eb) orelse b.len; }
        }
    }
    const da = find(b[es..ee], "/Differences", 0) orelse return;
    var p = es + da + 12;
    while (p < ee and b[p] != '[') p += 1;
    p += 1;
    var code: u32 = 0;
    var seen: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var distinct: u32 = 0;
    var assigned: u32 = 0;
    while (p < ee and b[p] != ']') {
        while (p < ee and isSpace(b[p])) p += 1;
        if (p >= ee or b[p] == ']') break;
        if (isDigit(b[p])) { code = readUint(b, &p); continue; }
        if (b[p] != '/') { p += 1; continue; }
        const ns = p + 1;
        var nq = ns;
        while (nq < ee and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != ']') nq += 1;
        // .notdef 는 건너뛴다.
        //
        // 글리프 번호 0 은 규격상 .notdef 이고, 크롬은 그것을 /g0 으로 적는다.
        // 내용은 X 를 친 빈 네모다. 그대로 그리면 글자 대신 네모가 나오므로
        // 시스템 글꼴로 대신 그리게 비워 둔다.
        const nm = b[ns..nq];
        const is_notdef = txEq(nm, "g0") or txEq(nm, ".notdef");
        if (code < 256 and nq > ns and !is_notdef) {
            if (keyRef(b, cs, ce, nm)) |on| {
                f.t3[code] = on;
                assigned += 1;
                var k: u32 = 0;
                var found = false;
                while (k < distinct and k < seen.len) : (k += 1) if (seen[k] == on) { found = true; break; };
                if (!found and distinct < seen.len) { seen[distinct] = on; distinct += 1; }
            }
        }
        code += 1;
        p = nq;
    }

    // 글리프가 사실상 하나뿐이면 껍데기다.
    //
    // 크롬이 맥에서 만든 PDF 가 그렇다 — 모든 코드가 빈 네모(notdef) 하나를
    // 가리키고, 진짜 글꼴은 읽는 쪽 컴퓨터에 있으리라 기대한다. 그대로 그리면
    // 글자마다 X 친 네모가 나오므로, 그럴 때는 시스템 글꼴로 대신 그린다.
    if (distinct <= 1 and assigned > 8) {
        @memset(&f.t3, 0);
        f.kind |= 256;
    }
}

fn q_at(b: []const u8, i: usize) u8 { return if (i < b.len) b[i] else ' '; }

/// 글꼴 딕셔너리에서 박힌 글꼴 파일을 찾아 붙인다.
/// Type0 이면 자손 글꼴을 한 번 더 따라간다.
fn attachEmbedded(b: []const u8, fbody: usize) void {
    if (font_n == 0) return;
    const f = &fontsBuf()[font_n - 1];
    const fend = find(b, "endobj", fbody) orelse b.len;
    var db = fbody;
    var de = fend;
    if (descendantOf(b, fbody, de)) |d| { db = d[0]; de = d[1]; }
    const fd = find(b[db..de], "/FontDescriptor", 0) orelse return;
    var p = db + fd + 15;
    while (p < de and isSpace(b[p])) p += 1;
    if (p >= de or !isDigit(b[p])) return;
    const dn = readUint(b, &p);
    const sb = findObj(b, dn) orelse return;
    const se = find(b, "endobj", sb) orelse b.len;

    var fobj: u32 = 0;
    var is_cff = false;
    if (find(b[fbody..fend], "/Type3", 0) != null) f.kind |= 32;
    if (find(b[sb..se], "/FontFile2", 0) == null and
        find(b[sb..se], "/FontFile3", 0) == null and
        find(b[sb..se], "/FontFile", 0) == null) f.kind |= 128;
    if (find(b[sb..se], "/FontFile2", 0)) |a| {
        var q = sb + a + 10;
        while (q < se and isSpace(b[q])) q += 1;
        if (q < se and isDigit(b[q])) fobj = readUint(b, &q);
    } else if (find(b[sb..se], "/FontFile3", 0) == null and
        find(b[sb..se], "/FontFile", 0) != null)
    {
        // 옛 Type1. "/FontFile" 은 접두사라 3·2 를 다 삼키므로 마지막에 본다.
        const a1 = find(b[sb..se], "/FontFile", 0) orelse return;
        var q = sb + a1 + 9;
        while (q < se and isSpace(b[q])) q += 1;
        if (q < se and isDigit(b[q])) {
            const n1 = readUint(b, &q);
            if (streamOf(b, n1)) |t1data| {
                attachType1(b, fbody, fend, t1data);
            }
        }
        if (!f.t1) f.kind |= 64;
        return;
    } else if (find(b[sb..se], "/FontFile3", 0)) |a| {
        // 형식 3 은 OpenType 로 싸여 있기도 하고 맨 CFF 이기도 하다.
        // 맨 CFF 는 우리가 OpenType 껍데기를 지어 씌운다.
        var q = sb + a + 10;
        while (q < se and isSpace(b[q])) q += 1;
        if (q < se and isDigit(b[q])) {
            const n3 = readUint(b, &q);
            if (findObj(b, n3)) |o3| {
                const e3 = objDictEnd(b, o3);
                if (find(b[o3..e3], "/OpenType", 0) != null) {
                    fobj = n3;
                } else if (find(b[o3..e3], "/Type1C", 0) != null or
                    find(b[o3..e3], "/CIDFontType0C", 0) != null)
                {
                    fobj = n3;
                    is_cff = true;
                } else {
                    f.kind |= 16;
                }
            }
        }
    }
    if (fobj == 0) return;
    const data = streamOf(b, fobj) orelse return;
    attachFontFile(data, is_cff);
    if (is_cff and f.file_len == 0) f.kind |= 16; // 껍데기를 못 지었다
}

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
fn b2_pages() []u32 { return u32sAt(b2_at, b2_cap_n); }
var b2_page_n: u32 = 0;
var b2_max_obj: u32 = 0;

fn b2Slice() []u8 {
    return @as([*]u8, @ptrFromInt(b2_off))[0..b2_len];
}

/// 두 번째 문서를 읽어 페이지 목록과 최대 객체 번호를 센다.
export fn parseSecond(len: usize) u32 {
    b2_len = len;
    b2_page_n = 0;
    b2_max_obj = 0;
    const b = b2Slice();
    if (len < 8 or !std_mem_eq(b[0..5], "%PDF-")) return 0;

    // 최대 객체 번호
    var i: usize = 0;
    while (i + 4 < b.len) {
        const at = find(b, " obj", i) orelse break;
        var j = at;
        while (j > 0 and isSpace(b[j - 1])) j -= 1;
        while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
        var k = j;
        while (k > 0 and isSpace(b[k - 1])) k -= 1;
        var st = k;
        while (st > 0 and b[st - 1] >= '0' and b[st - 1] <= '9') st -= 1;
        if (st < k) {
            var p: usize = st;
            const n = readUint(b, &p);
            if (n > b2_max_obj) b2_max_obj = n;
        }
        i = at + 4;
    }

    // 페이지 트리
    var root: u32 = 0;
    if (trailerKeyOrScan(b, "/Root")) |at| {
        var p = at + 5;
        root = readUint(b, &p);
    }
    var pgs: u32 = 0;
    if (root != 0) {
        if (findObj(b, root)) |body| {
            const end = find(b, "endobj", body) orelse b.len;
            if (dictInt(b, body, end, "/Pages")) |x| pgs = x;
        }
    }
    if (pgs == 0) return 0;
    // 둘째 문서의 쪽은 제 자리에 바로 담는다. 예전에는 page_objs 를 잠시
    // 빌려 쓰고 앞 64 개만 되돌렸다 — 첫 문서가 64 쪽을 넘으면 그 뒤가
    // 둘째 문서의 번호로 덮인 채 남았다.
    // 둘째 문서를 걷는 동안 첫 문서의 "잘렸다" 표시를 건드리지 않는다
    const cut_keep = pages_cut;
    const keep_at = walk_at;
    const keep_cap = walk_cap;
    const keep_ceil = walk_ceil;
    if (!walkStart(b.len)) return 0;
    b2_page_n = 0;
    collectPages(b, pgs, 0, &b2_page_n);
    b2_at = walk_at;
    b2_cap_n = b2_page_n;
    zoneShrink(b2_at + @as(usize, b2_page_n) * 4);
    pages_cut = cut_keep;
    walk_at = keep_at;
    walk_cap = keep_cap;
    walk_ceil = keep_ceil;
    return if (b2_page_n > 0) 1 else 0;
}

export fn secondPageCount() u32 { return b2_page_n; }
/// 지금 잡아 둔 출력 자리와 원본 길이 — 이어 붙이기 전에 모자란지 보라고 준다
export fn outCapacity() usize { return out_cap; }
export fn inputLen() usize { return in_len; }

/// 숫자를 output 에 적는다.
fn writeNum(pos: *usize, v: u32) void { appendNum(pos, v); }

/// 두 문서를 이어 붙인다. 결과 길이를 돌려주고 0이면 실패.
export fn merge() usize {
    out_len = 0;
    if (b2_len == 0 or b2_page_n == 0 or pages_obj == 0) return 0;
    const a = searchSlice();
    const b = b2Slice();
    const shift = 1000000; // A 의 번호와 겹치지 않게 넉넉히 민다

    // 이어 붙이면 두 문서를 합친 만큼이 필요하다. 자리가 모자라면 여기서
    // 접는다 — 예전에는 그냥 넘겨 썼고, 그 뒤에는 쪽 표가 있다.
    if (!outRoom(in_len + b.len, 64 * 1024)) return 0;
    @memcpy(outBuf()[0..in_len], a[0..in_len]);
    var pos: usize = in_len;
    if (pos > 0 and outBuf()[pos - 1] != '\n') { outBuf()[pos] = '\n'; pos += 1; }

    const xr_keep = zoneTop();
    defer zoneShrink(xr_keep);
    // 둘째 문서의 객체 수는 미리 모르니 파일 크기로 어림잡는다(객체 하나에
    // 최소 열여섯 바이트). 예전에는 8192 로 묶여, 그보다 많은 객체를 가진
    // 문서를 붙이면 뒤가 조용히 빠진 채 /Kids 만 남았다.
    const xr = xrefTables(b.len / 16 + page_count + 128) orelse return 0;
    const new_offsets = xr.offs;
    const new_nums = xr.nums;
    var new_n: usize = 0;

    // B 의 객체를 번호를 밀어 다시 적는다
    var i: usize = 0;
    while (i + 4 < b.len and new_n < new_nums.len - 8) {
        const at = find(b, " obj", i) orelse break;
        i = at + 4;
        var j = at;
        while (j > 0 and isSpace(b[j - 1])) j -= 1;
        while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
        var k = j;
        while (k > 0 and isSpace(b[k - 1])) k -= 1;
        var st = k;
        while (st > 0 and b[st - 1] >= '0' and b[st - 1] <= '9') st -= 1;
        if (st >= k) continue;
        var np: usize = st;
        const num = readUint(b, &np);
        const body = at + 4;
        const end = find(b, "endobj", body) orelse b.len;

        new_offsets[new_n] = pos;
        new_nums[new_n] = num + shift;
        new_n += 1;

        writeNum(&pos, num + shift);
        appendStr(&pos, " 0 obj");

        // 딕셔너리 구간과 스트림 구간을 나눈다
        const sm = find(b[body..end], "stream", 0);
        const dict_end = if (sm) |x| body + x else end;

        // 딕셔너리: "N G R" 의 N 을 민다
        var q = body;
        while (q < dict_end) {
            if (b[q] >= '0' and b[q] <= '9') {
                var r = q;
                const n1 = readUint(b, &r);
                var r2 = r;
                while (r2 < dict_end and isSpace(b[r2])) r2 += 1;
                const gen_start = r2;
                var has_gen = false;
                while (r2 < dict_end and b[r2] >= '0' and b[r2] <= '9') { r2 += 1; has_gen = true; }
                var r3 = r2;
                while (r3 < dict_end and isSpace(b[r3])) r3 += 1;
                if (has_gen and r3 < dict_end and b[r3] == 'R' and
                    (r3 + 1 >= dict_end or !(b[r3 + 1] >= 'a' and b[r3 + 1] <= 'z')))
                {
                    writeNum(&pos, n1 + shift);
                    appendStr(&pos, " ");
                    if (!outCopy(&pos, b[gen_start .. r3 + 1])) return 0;
                    q = r3 + 1;
                    continue;
                }
                // 참조가 아니면 그대로
                if (!outCopy(&pos, b[q..r])) return 0;
                q = r;
                continue;
            }
            if (!outRoom(pos, 1)) return 0;
            outBuf()[pos] = b[q];
            pos += 1;
            q += 1;
        }
        // 스트림 구간은 손대지 않는다
        if (dict_end < end) {
            if (!outCopy(&pos, b[dict_end..end])) return 0;
        }
        appendStr(&pos, "endobj\n");
    }

    // 새 페이지 트리 — A 의 쪽 뒤에 B 의 쪽을 잇는다
    new_offsets[new_n] = pos;
    new_nums[new_n] = pages_obj;
    new_n += 1;
    writeNum(&pos, pages_obj);
    appendStr(&pos, " 0 obj\n<< /Type /Pages /Count ");
    writeNum(&pos, page_count + b2_page_n);
    appendStr(&pos, " /Kids [");
    var t: u32 = 0;
    while (t < page_count) : (t += 1) {
        appendStr(&pos, " ");
        writeNum(&pos, page_objs()[t]);
        appendStr(&pos, " 0 R");
    }
    t = 0;
    while (t < b2_page_n) : (t += 1) {
        appendStr(&pos, " ");
        writeNum(&pos, b2_pages()[t] + shift);
        appendStr(&pos, " 0 R");
    }
    appendStr(&pos, " ] >>\nendobj\n");

    // B 쪽 페이지의 부모를 A 의 트리로 바꾼다
    t = 0;
    while (t < b2_page_n and new_n < new_nums.len - 2) : (t += 1) {
        const obj = b2_pages()[t];
        const body = findObj(b, obj) orelse continue;
        const end = find(b, "endobj", body) orelse b.len;
        new_offsets[new_n] = pos;
        new_nums[new_n] = obj + shift;
        new_n += 1;
        writeNum(&pos, obj + shift);
        appendStr(&pos, " 0 obj\n<< /Type /Page /Parent ");
        writeNum(&pos, pages_obj);
        appendStr(&pos, " 0 R");
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
                if (!outCopy(&pos, b[st2..q])) return 0;
                continue;
            }
            if (b[q] == '<' and q + 1 < end and b[q + 1] == '<') {
                depth += 1;
                appendStr(&pos, "<<");
                q += 2;
                continue;
            }
            if (b[q] == '<') {
                // 16진 글자열 <AB12> — 닫는 '>' 까지 그대로 옮긴다
                const st2 = q;
                q += 1;
                while (q < end and b[q] != '>') q += 1;
                if (q < end) q += 1;
                if (!outCopy(&pos, b[st2..q])) return 0;
                continue;
            }
            if (b[q] == '>' and q + 1 < end and b[q + 1] == '>') {
                if (depth == 0) break; // 바깥 딕셔너리의 끝
                depth -= 1;
                appendStr(&pos, ">>");
                q += 2;
                continue;
            }
            if (b[q] == '/' and q + 7 <= end and std_mem_eq(b[q .. q + 7], "/Parent")) {
                q += 7;
                while (q < end and isSpace(b[q])) q += 1;
                _ = readUint(b, &q);
                while (q < end and isSpace(b[q])) q += 1;
                _ = readUint(b, &q);
                while (q < end and isSpace(b[q])) q += 1;
                if (q < end and b[q] == 'R') q += 1;
                continue;
            }
            if (b[q] >= '0' and b[q] <= '9') {
                var r = q;
                const n1 = readUint(b, &r);
                var r2 = r;
                while (r2 < end and isSpace(b[r2])) r2 += 1;
                var has_gen = false;
                while (r2 < end and b[r2] >= '0' and b[r2] <= '9') { r2 += 1; has_gen = true; }
                var r3 = r2;
                while (r3 < end and isSpace(b[r3])) r3 += 1;
                if (has_gen and r3 < end and b[r3] == 'R') {
                    writeNum(&pos, n1 + shift);
                    appendStr(&pos, " 0 R");
                    q = r3 + 1;
                    continue;
                }
                if (!outCopy(&pos, b[q..r])) return 0;
                q = r;
                continue;
            }
            if (!outRoom(pos, 1)) return 0;
            outBuf()[pos] = b[q];
            pos += 1;
            q += 1;
        }
        appendStr(&pos, " >>\nendobj\n");
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
    appendStr(&pos, "xref\n");
    var w: usize = 0;
    while (w < new_n) : (w += 1) {
        writeNum(&pos, new_nums[w]);
        appendStr(&pos, " 1\n");
        var off = new_offsets[w];
        var digits: [10]u8 = undefined;
        var d: usize = 10;
        while (d > 0) : (d -= 1) { digits[d - 1] = @intCast('0' + (off % 10)); off /= 10; }
        if (!outRoom(pos, 10)) return 0;
        @memcpy(outBuf()[pos..][0..10], &digits);
        pos += 10;
        appendStr(&pos, " 00000 n \n");
    }
    var prev: u32 = 0;
    if (rfindTail(a[0..in_len], "startxref")) |at| {
        var p = at + 9;
        prev = readUint(a, &p);
    }
    var root: u32 = 0;
    if (rfind(a, "/Root", a.len - 1)) |at| {
        var p = at + 5;
        root = readUint(a, &p);
    }
    appendStr(&pos, "trailer\n<< /Size 2000000 /Root ");
    writeNum(&pos, root);
    appendStr(&pos, " 0 R /Prev ");
    writeNum(&pos, prev);
    appendStr(&pos, " >>\nstartxref\n");
    writeNum(&pos, @intCast(xref_pos));
    appendStr(&pos, "\n%%EOF\n");

    stripEncryptOut(pos);
    out_len = pos;
    return pos;
}


// ===== 다시 쓰기(압축) =====
//
// 증분 업데이트는 원본을 통째로 두고 뒤에 덧붙이므로, 페이지를 지워도 파일이
// 줄지 않는다. 실제로 줄이려면 살아남은 쪽이 쓰는 객체만 골라 새 문서로 다시
// 써야 한다. 안 쓰는 쪽의 그림·글꼴이 통째로 빠지므로 스캔 문서에서 특히 크게
// 준다.
//
// 도달 가능성은 Catalog 에서 시작해 참조("N 0 R")를 따라가며 표시한다.
// 스트림 안의 이진 데이터에는 참조처럼 보이는 바이트가 있을 수 있으므로
// 딕셔너리 구간만 훑는다.

/// 어느 객체가 살아 있는가. 문서에서 본 가장 큰 번호에 맞춰 잡는다 —
/// 예전에는 [65536] 고정이라, 번호가 그보다 큰 객체는 살아 있어도
/// 조용히 버려졌다(compact 로 낸 파일에서 그 객체만 사라졌다).
var reach_at: usize = 0;
var reach_n: usize = 0;
fn reachTable() []bool {
    if (reach_at == 0 or reach_n == 0) return &[_]bool{};
    return @as([*]bool, @ptrFromInt(reach_at))[0..reach_n];
}

fn objRange(b: []const u8, num: u32) ?struct { start: usize, dict_end: usize, end: usize } {
    const body = findObj(b, num) orelse return null;
    const end = find(b, "endobj", body) orelse b.len;
    const sm = find(b[body..end], "stream", 0);
    const de = if (sm) |x| body + x else end;
    return .{ .start = body, .dict_end = de, .end = end };
}

fn markReach(b: []const u8, num: u32, depth: u32) void {
    const reach = reachTable();
    if (num >= reach.len or depth > 64) return;
    if (reach[num]) return;
    reach[num] = true;
    const r = objRange(b, num) orelse return;
    var q = r.start;
    while (q < r.dict_end) {
        if (b[q] >= '0' and b[q] <= '9') {
            var p2 = q;
            const n1 = readUint(b, &p2);
            var p3 = p2;
            while (p3 < r.dict_end and isSpace(b[p3])) p3 += 1;
            var has_gen = false;
            while (p3 < r.dict_end and b[p3] >= '0' and b[p3] <= '9') { p3 += 1; has_gen = true; }
            var p4 = p3;
            while (p4 < r.dict_end and isSpace(b[p4])) p4 += 1;
            if (has_gen and p4 < r.dict_end and b[p4] == 'R') {
                markReach(b, n1, depth + 1);
                q = p4 + 1;
                continue;
            }
            q = p2;
            continue;
        }
        q += 1;
    }
}

// ===== 전자 서명 =====
//
// 서명 딕셔너리에는 /ByteRange 로 "어디부터 어디까지를 서명했는지" 가 적혀
// 있고, 그 사이의 구멍에 PKCS#7 뭉치(/Contents)가 들어간다. 원본 바이트가
// 있어야 다시 셈할 수 있으므로, 스트림을 풀기 전에 걷어 둔다.
//
// 뭉치를 뜯어 서명을 실제로 맞춰 보는 일은 화면 쪽이 한다 — 브라우저에
// 이미 서명 검증기(WebCrypto)가 있어 굳이 여기서 큰 수 셈을 다시 짤 까닭이
// 없다. 여기서는 자리와 바이트만 정확히 건네 준다.
const SigT = struct {
    obj: u32,
    range: [4]u32,
    der_off: u32,
    der_len: u32,
    name_off: u32,
    name_len: u32,
    date_off: u32,
    date_len: u32,
    reason_off: u32,
    reason_len: u32,
    sub_off: u32,
    sub_len: u32,
    covers: bool,
};
/// 서명. 16 이던 것을 올렸다 — 결재선이 긴 문서는 그보다 많다.
/// 전자 서명. 필요한 만큼 늘어난다(세는 상한 없음).
var sigs_at: usize = 0;
var sigs_cap: u32 = 0;
fn sigsBuf() []SigT {
    if (sigs_at == 0 or sigs_cap == 0) return &[_]SigT{};
    return @as([*]SigT, @ptrFromInt(sigs_at))[0..sigs_cap];
}
fn sigsRoom(want: u32) bool { return growTable(&sigs_at, &sigs_cap, want, @sizeOf(SigT), 8); }
var sig_n: u32 = 0;
const SIG_BUF = 1024 * 1024;
/// sig_buf — 쓸 때 잡는다(그 갈래 문서가 아니면 안 잡는다)
var sig_buf_at: usize = 0;
fn sig_buf() []u8 {
    if (sig_buf_at == 0) {
        sig_buf_at = zoneAlloc(SIG_BUF) orelse 0;
        if (sig_buf_at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(sig_buf_at))[0..SIG_BUF];
}
var sig_used: u32 = 0;

/// 글자열 하나를 주어진 곳간에 담는다. UTF-16BE 는 utf-8 로 옮긴다.
fn sigPutStrTo(b: []const u8, from: usize, to: usize, buf: []u8, used: *u32) [2]u32 {
    const start = used.*;
    var p = from;
    while (p < to and isSpace(b[p])) p += 1;
    if (p < to and b[p] == '(') {
        p += 1;
        var depth: u32 = 1;
        while (p < to and used.* + 4 < buf.len) : (p += 1) {
            if (b[p] == '\\' and p + 1 < to) {
                p += 1;
                buf[used.*] = switch (b[p]) {
                    'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p],
                };
                used.* += 1;
                continue;
            }
            if (b[p] == '(') depth += 1;
            if (b[p] == ')') { depth -= 1; if (depth == 0) break; }
            buf[used.*] = b[p];
            used.* += 1;
        }
    } else if (p < to and b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < to and b[p] != '>' and used.* + 4 < buf.len) : (p += 1) {
            const hv = hexVal(b[p]) orelse continue;
            if (hi) |h| { buf[used.*] = (h << 4) | hv; used.* += 1; hi = null; } else hi = hv;
        }
    }
    const n = used.* - start;
    if (n >= 2 and buf[start] == 0xFE and buf[start + 1] == 0xFF) {
        var tmp: [512]u8 = undefined;
        var w: u32 = 0;
        var i: u32 = start + 2;
        while (i + 1 < start + n and w + 4 < tmp.len) : (i += 2) {
            const cp: u32 = (@as(u32, buf[i]) << 8) | buf[i + 1];
            if (cp < 0x80) { tmp[w] = @intCast(cp); w += 1; }
            else if (cp < 0x800) {
                tmp[w] = @intCast(0xC0 | (cp >> 6));
                tmp[w + 1] = @intCast(0x80 | (cp & 63));
                w += 2;
            } else {
                tmp[w] = @intCast(0xE0 | (cp >> 12));
                tmp[w + 1] = @intCast(0x80 | ((cp >> 6) & 63));
                tmp[w + 2] = @intCast(0x80 | (cp & 63));
                w += 3;
            }
        }
        @memcpy(buf[start..][0..w], tmp[0..w]);
        used.* = start + w;
    }
    return .{ start, used.* - start };
}

fn sigPutStr(b: []const u8, from: usize, to: usize) [2]u32 {
    const start = sig_used;
    var p = from;
    while (p < to and isSpace(b[p])) p += 1;
    if (p < to and b[p] == '(') {
        p += 1;
        var depth: u32 = 1;
        while (p < to and sig_used + 4 < sig_buf().len) : (p += 1) {
            if (b[p] == '\\' and p + 1 < to) {
                p += 1;
                sig_buf()[sig_used] = switch (b[p]) {
                    'n' => '\n', 'r' => '\r', 't' => '\t', 'b' => 8, 'f' => 12, else => b[p],
                };
                sig_used += 1;
                continue;
            }
            if (b[p] == '(') depth += 1;
            if (b[p] == ')') { depth -= 1; if (depth == 0) break; }
            sig_buf()[sig_used] = b[p];
            sig_used += 1;
        }
    } else if (p < to and b[p] == '<') {
        p += 1;
        var hi: ?u8 = null;
        while (p < to and b[p] != '>' and sig_used + 4 < sig_buf().len) : (p += 1) {
            const hv = hexVal(b[p]) orelse continue;
            if (hi) |h| { sig_buf()[sig_used] = (h << 4) | hv; sig_used += 1; hi = null; } else hi = hv;
        }
    }
    // UTF-16BE 로 적힌 것은 utf-8 로 옮긴다
    const n = sig_used - start;
    if (n >= 2 and sig_buf()[start] == 0xFE and sig_buf()[start + 1] == 0xFF) {
        var tmp: [512]u8 = undefined;
        var w: u32 = 0;
        var i: u32 = start + 2;
        while (i + 1 < start + n and w + 4 < tmp.len) : (i += 2) {
            const cp: u32 = (@as(u32, sig_buf()[i]) << 8) | sig_buf()[i + 1];
            if (cp < 0x80) { tmp[w] = @intCast(cp); w += 1; }
            else if (cp < 0x800) {
                tmp[w] = @intCast(0xC0 | (cp >> 6));
                tmp[w + 1] = @intCast(0x80 | (cp & 63));
                w += 2;
            } else {
                tmp[w] = @intCast(0xE0 | (cp >> 12));
                tmp[w + 1] = @intCast(0x80 | ((cp >> 6) & 63));
                tmp[w + 2] = @intCast(0x80 | (cp & 63));
                w += 3;
            }
        }
        @memcpy(sig_buf()[start..][0..w], tmp[0..w]);
        sig_used = start + w;
    }
    return .{ start, sig_used - start };
}

fn collectSigs(b: []const u8) void {
    sig_n = 0;
    sig_used = 0;
    var num: u32 = 1;
    while (num < obj_cap and sigsRoom(sig_n + 1)) : (num += 1) {
        if (objRankTable()[num] == 0) continue;
        const body = objOff()[num];
        if (body >= b.len) continue;
        const e = objDictEnd(b, body);
        if (find(b[body..e], "/ByteRange", 0) == null) continue;
        const ca = find(b[body..e], "/Contents", 0) orelse continue;
        // /Contents 는 16진 문자열이어야 한다 (스트림 쪽 /Contents 와 가른다)
        var cp = body + ca + 9;
        while (cp < e and isSpace(b[cp])) cp += 1;
        if (cp >= e or b[cp] != '<' or (cp + 1 < e and b[cp + 1] == '<')) continue;

        const f = &sigsBuf()[sig_n];
        f.* = .{
            .obj = num, .range = .{ 0, 0, 0, 0 }, .der_off = 0, .der_len = 0,
            .name_off = 0, .name_len = 0, .date_off = 0, .date_len = 0,
            .reason_off = 0, .reason_len = 0, .sub_off = 0, .sub_len = 0, .covers = false,
        };
        // /ByteRange [a b c d]
        {
            const ra = find(b[body..e], "/ByteRange", 0).?;
            var rp = body + ra + 10;
            while (rp < e and b[rp] != '[') rp += 1;
            rp += 1;
            var i: u32 = 0;
            while (i < 4 and rp < e) : (i += 1) {
                while (rp < e and isSpace(b[rp])) rp += 1;
                if (rp >= e or !isDigit(b[rp])) break;
                f.range[i] = readUint(b, &rp);
            }
            if (i < 4) continue;
        }
        // 뭉치 — 16진을 날바이트로
        {
            const start = sig_used;
            var q = cp + 1;
            var hi: ?u8 = null;
            while (q < e and b[q] != '>' and sig_used + 4 < sig_buf().len) : (q += 1) {
                const hv = hexVal(b[q]) orelse continue;
                if (hi) |h| { sig_buf()[sig_used] = (h << 4) | hv; sig_used += 1; hi = null; } else hi = hv;
            }
            // 뒤쪽 0 채움은 덜어 낸다
            var n = sig_used - start;
            while (n > 0 and sig_buf()[start + n - 1] == 0) n -= 1;
            sig_used = start + n;
            f.der_off = start;
            f.der_len = n;
        }
        if (find(b[body..e], "/Name", 0)) |a| {
            const r = sigPutStr(b, body + a + 5, e);
            f.name_off = r[0];
            f.name_len = r[1];
        }
        if (find(b[body..e], "/M", 0)) |a| {
            if (keyIs(b, body + a, e, "/M")) {
                const r = sigPutStr(b, body + a + 2, e);
                f.date_off = r[0];
                f.date_len = r[1];
            }
        }
        if (find(b[body..e], "/Reason", 0)) |a| {
            const r = sigPutStr(b, body + a + 7, e);
            f.reason_off = r[0];
            f.reason_len = r[1];
        }
        if (find(b[body..e], "/SubFilter", 0)) |a| {
            var q = body + a + 10;
            while (q < e and isSpace(b[q])) q += 1;
            const start = sig_used;
            if (q < e and b[q] == '/') {
                q += 1;
                while (q < e and !isSpace(b[q]) and b[q] != '/' and b[q] != '>' and
                    sig_used + 4 < sig_buf().len) : (q += 1)
                {
                    sig_buf()[sig_used] = b[q];
                    sig_used += 1;
                }
            }
            f.sub_off = start;
            f.sub_len = sig_used - start;
        }
        // 서명이 파일 끝까지 덮는가 — 뒤에 덧붙은 고침이 있으면 아니다
        const tail = f.range[2] + f.range[3];
        f.covers = f.range[0] == 0 and tail <= b.len and b.len - tail <= 2;
        sig_n += 1;
    }
}

export fn sigCount() u32 { return sig_n; }
export fn sigRange(i: u32, k: u32) u32 { return if (i < sig_n and k < 4) sigsBuf()[i].range[k] else 0; }
export fn sigTextPtr() usize {
    const p = sig_buf();
    return if (p.len == 0) heapBase() else @intFromPtr(p.ptr);
}
export fn sigDerOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].der_off else 0; }
export fn sigDerLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].der_len else 0; }
export fn sigNameOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].name_off else 0; }
export fn sigNameLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].name_len else 0; }
export fn sigDateOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].date_off else 0; }
export fn sigDateLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].date_len else 0; }
export fn sigReasonOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].reason_off else 0; }
export fn sigReasonLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].reason_len else 0; }
export fn sigSubOff(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].sub_off else 0; }
export fn sigSubLen(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].sub_len else 0; }
export fn sigCovers(i: u32) u32 { return if (i < sig_n and sigsBuf()[i].covers) 1 else 0; }
export fn sigObj(i: u32) u32 { return if (i < sig_n) sigsBuf()[i].obj else 0; }

/// 고른 쪽만 남긴 문서를 처음부터 다시 쓴다. 결과 길이를 돌려준다.
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

export fn setEncrypt(on: u32) void {
    enc_want = on != 0;
    enc_pw_len = 0;
}
/// 사용자 암호 한 글자 (utf-8 로 담는다)
export fn addEncryptChar(c: u32) void {
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
export fn encRandomPtr() usize { return @intFromPtr(&enc_rand); }

/// 스트림·문자열마다 다른 IV. 열쇠와 차례로 만든다.
fn encIv(out: *[16]u8) void {
    enc_ctr +%= 1;
    var c4: [4]u8 = .{
        @truncate(enc_ctr), @truncate(enc_ctr >> 8),
        @truncate(enc_ctr >> 16), @truncate(enc_ctr >> 24),
    };
    var h: [32]u8 = undefined;
    crypt.sha256(&[_][]const u8{ &enc_fkey, &c4, enc_rand[48..64] }, &h);
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
    crypt.aesCbcEncrypt(&enc_fkey, &iv, dst[16..total]);
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
    if (n == 0 or !outRoom(pos.*, n * 2 + 8)) {
        appendStr(pos, "<>");
        return;
    }
    appendStr(pos, "<");
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const hi: u8 = seal_str[i] >> 4;
        const lo: u8 = seal_str[i] & 15;
        outBuf()[pos.*] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
        outBuf()[pos.* + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
        pos.* += 2;
    }
    appendStr(pos, ">");
}

/// 딕셔너리 한 조각을 옮겨 적으며 문자열은 암호화하고 /Length 는 건너뛴다.
fn copyDictSealed(b: []const u8, from: usize, to: usize, pos: *usize, skip_len: bool) void {
    var p = from;
    var tmp: [65536]u8 = undefined;
    while (p < to and outRoom(pos.*, 64)) {
        if (skip_len and b[p] == '/' and keyIs(b, p, to, "/Length")) {
            p = skipVal(b, p + 7, to);
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
            outBuf()[pos.*] = '<';
            outBuf()[pos.* + 1] = '<';
            pos.* += 2;
            p += 2;
            continue;
        }
        if (b[p] == '>' and p + 1 < to and b[p + 1] == '>') {
            outBuf()[pos.*] = '>';
            outBuf()[pos.* + 1] = '>';
            pos.* += 2;
            p += 2;
            continue;
        }
        if (b[p] == '<' and p + 1 < to and b[p + 1] != '<') {
            var n: usize = 0;
            var q = p + 1;
            var hi: ?u8 = null;
            while (q < to and b[q] != '>' and n < tmp.len) : (q += 1) {
                const hv = hexVal(b[q]) orelse continue;
                if (hi) |h| { tmp[n] = (h << 4) | hv; n += 1; hi = null; } else hi = hv;
            }
            if (hi) |h| { if (n < tmp.len) { tmp[n] = h << 4; n += 1; } }
            writeSealedString(pos, tmp[0..n]);
            p = q + 1;
            continue;
        }
        outBuf()[pos.*] = b[p];
        pos.* += 1;
        p += 1;
    }
}

export fn compact() usize {
    out_len = 0;
    if (pick_n == 0 or pages_obj == 0) return 0;
    const b = searchSlice();

    // 살아 있는 객체 표를 문서에서 본 가장 큰 번호에 맞춰 잡는다
    const reach_keep = zoneTop();
    defer zoneShrink(reach_keep);
    reach_n = @as(usize, max_obj) + 64;
    reach_at = zoneAlloc(reach_n) orelse { reach_n = 0; return 0; };
    const reach = reachTable();
    @memset(reach, false);

    // 옛 페이지 트리를 먼저 방문한 것으로 막는다. 이렇게 하지 않으면
    // Catalog → Pages → 모든 쪽으로 내려가 버려서, 버리려던 쪽까지 전부
    // 살아남는다(= 파일이 하나도 줄지 않는다).
    if (pages_obj < reach.len) reach[pages_obj] = true;

    var root: u32 = 0;
    if (trailerKeyOrScan(b, "/Root")) |at| {
        var p = at + 5;
        root = readUint(b, &p);
    }
    if (root != 0) markReach(b, root, 0);

    // 고른 쪽과 그 아래 딸린 것들만 표시한다
    var i: usize = 0;
    while (i < pick_n) : (i += 1) markReach(b, page_objs()[pick()[i]], 0);

    var pos: usize = 0;
    appendStr(&pos, "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n");
    if (enc_want) {
        @memcpy(&enc_fkey, enc_rand[0..32]);
        enc_ctr = 0;
    }

    const xr_keep = zoneTop();
    defer zoneShrink(xr_keep);
    const xr = xrefTables(@as(usize, max_obj) + 64) orelse return 0;
    const new_offsets = xr.offs;
    const new_nums = xr.nums;
    var new_n: usize = 0;

    // 살아남은 객체를 번호를 그대로 두고 옮긴다. 번호를 다시 매기면 모든
    // 참조를 고쳐야 하는데, 얻는 건 상호참조표 몇 바이트뿐이다.
    var num: u32 = 1;
    while (num < reach.len and new_n < new_nums.len - 4) : (num += 1) {
        if (!reach[num]) continue;
        if (num == pages_obj) continue;
        const r = objRange(b, num) orelse continue;
        new_offsets[new_n] = pos;
        new_nums[new_n] = num;
        new_n += 1;
        appendNum(&pos, num);
        appendStr(&pos, " 0 obj");
        if (!enc_want) {
            if (!outRoom(pos, r.end - r.start)) break;
            if (!outRoom(pos, r.end - r.start)) return 0;
            @memcpy(outBuf()[pos..][0 .. r.end - r.start], b[r.start..r.end]);
            pos += r.end - r.start;
        } else {
            // 스트림과 문자열을 암호화해 다시 적는다
            const sp2 = find(b[r.start..r.end], "stream", 0);
            var dict_to = r.end;
            var sealed: u32 = 0;
            var sealed_at: []u8 = &[_]u8{};
            if (sp2) |sa| {
                dict_to = r.start + sa;
                const length = lengthOf(b, r.start, dict_to) orelse 0;
                var d2 = r.start + sa + 6;
                if (d2 < b.len and b[d2] == '\r') d2 += 1;
                if (d2 < b.len and b[d2] == '\n') d2 += 1;
                if (length > 0 and d2 + length <= b.len) {
                    // 스트림 크기에 맞춰 메모리 끝을 빌린다. 못 빌리면 여기서
                    // 접는다 — 스트림 없이 /Length 만 적힌 파일을 내느니
                    // 만들기를 실패로 돌리는 편이 낫다.
                    sealed_at = bigScratch(length + 64) orelse return 0;
                    sealed = aesSeal(b[d2..][0..length], sealed_at);
                }
            }
            // 딕셔너리
            var ds5 = r.start;
            while (ds5 < dict_to and b[ds5] != '<') ds5 += 1;
            const de5 = if (ds5 < dict_to) dictEnd(b, ds5, dict_to) else dict_to;
            if (de5 > ds5 + 2) {
                appendStr(&pos, "\n<<");
                copyDictSealed(b, ds5 + 2, de5 - 2, &pos, sealed > 0);
                if (sealed > 0) {
                    appendStr(&pos, " /Length ");
                    appendNum(&pos, sealed);
                }
                appendStr(&pos, " >>");
            } else {
                copyDictSealed(b, r.start, dict_to, &pos, false);
            }
            if (sealed > 0 and outRoom(pos, sealed + 64)) {
                appendStr(&pos, "\nstream\n");
                if (!outRoom(pos, sealed)) return 0;
                @memcpy(outBuf()[pos..][0..sealed], sealed_at[0..sealed]);
                pos += sealed;
                appendStr(&pos, "\nendstream\n");
            } else appendStr(&pos, "\n");
        }
        appendStr(&pos, "endobj\n");
    }

    // 새 페이지 트리
    new_offsets[new_n] = pos;
    new_nums[new_n] = pages_obj;
    new_n += 1;
    appendNum(&pos, pages_obj);
    appendStr(&pos, " 0 obj\n<< /Type /Pages /Count ");
    appendNum(&pos, @intCast(pick_n));
    appendStr(&pos, " /Kids [");
    i = 0;
    while (i < pick_n) : (i += 1) {
        appendStr(&pos, " ");
        appendNum(&pos, page_objs()[pick()[i]]);
        appendStr(&pos, " 0 R");
    }
    appendStr(&pos, " ] >>\nendobj\n");

    // 암호 딕셔너리 — 열쇠를 확인할 값들을 담는다 (V5·R6)
    var enc_obj_num: u32 = 0;
    if (enc_want) {
        enc_obj_num = new_nums[new_n - 1] + 1;
        var m: u32 = 0;
        while (m < new_n) : (m += 1) if (new_nums[m] >= enc_obj_num) { enc_obj_num = new_nums[m] + 1; };
        const pw = enc_pw[0..enc_pw_len];
        var uval: [48]u8 = undefined;
        hash2B(pw, enc_rand[32..40], &[_]u8{}, uval[0..32]);
        @memcpy(uval[32..40], enc_rand[32..40]);
        @memcpy(uval[40..48], enc_rand[40..48]);
        var ikey: [32]u8 = undefined;
        hash2B(pw, enc_rand[40..48], &[_]u8{}, &ikey);
        var ue: [32]u8 = enc_fkey;
        crypt.aesCbcEncrypt(&ikey, &[_]u8{0} ** 16, &ue);
        var oval: [48]u8 = undefined;
        hash2B(pw, enc_rand[48..56], uval[0..48], oval[0..32]);
        @memcpy(oval[32..40], enc_rand[48..56]);
        @memcpy(oval[40..48], enc_rand[56..64]);
        var okey: [32]u8 = undefined;
        hash2B(pw, enc_rand[56..64], uval[0..48], &okey);
        var oe: [32]u8 = enc_fkey;
        crypt.aesCbcEncrypt(&okey, &[_]u8{0} ** 16, &oe);
        // 권한 — 인쇄·복사까지 다 허용한다 (-1 에서 예약 비트만 맞춘다)
        const perm: i32 = -4;
        var pblk: [16]u8 = .{
            @truncate(@as(u32, @bitCast(perm))), @truncate(@as(u32, @bitCast(perm)) >> 8),
            @truncate(@as(u32, @bitCast(perm)) >> 16), @truncate(@as(u32, @bitCast(perm)) >> 24),
            0xFF, 0xFF, 0xFF, 0xFF, 'T', 'a', 'd', 'b',
            enc_rand[0], enc_rand[1], enc_rand[2], enc_rand[3],
        };
        crypt.aesCbcEncrypt(&enc_fkey, &[_]u8{0} ** 16, &pblk);

        new_offsets[new_n] = pos;
        new_nums[new_n] = enc_obj_num;
        new_n += 1;
        appendNum(&pos, enc_obj_num);
        appendStr(&pos, " 0 obj\n<< /Filter /Standard /V 5 /R 6 /Length 256");
        appendStr(&pos, " /CF << /StdCF << /CFM /AESV3 /Length 32 /AuthEvent /DocOpen >> >>");
        appendStr(&pos, " /StmF /StdCF /StrF /StdCF /EncryptMetadata true /P ");
        appendStr(&pos, "-4");
        const hexOut = struct {
            fn f(pp: *usize, key: []const u8, d: []const u8) void {
                appendStr(pp, key);
                appendStr(pp, " <");
                var za: usize = 0;
                while (za < d.len and outRoom(pp.*, 8)) : (za += 1) {
                    const hi: u8 = d[za] >> 4;
                    const lo: u8 = d[za] & 15;
                    outBuf()[pp.*] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
                    outBuf()[pp.* + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
                    pp.* += 2;
                }
                appendStr(pp, ">");
            }
        }.f;
        hexOut(&pos, " /U", uval[0..48]);
        hexOut(&pos, " /UE", &ue);
        hexOut(&pos, " /O", oval[0..48]);
        hexOut(&pos, " /OE", &oe);
        hexOut(&pos, " /Perms", &pblk);
        appendStr(&pos, " >>\nendobj\n");
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
    appendStr(&pos, "xref\n0 1\n0000000000 65535 f \n");
    i = 0;
    while (i < new_n) : (i += 1) {
        appendNum(&pos, new_nums[i]);
        appendStr(&pos, " 1\n");
        var off = new_offsets[i];
        var digits: [10]u8 = undefined;
        var d: usize = 10;
        while (d > 0) : (d -= 1) { digits[d - 1] = @intCast('0' + (off % 10)); off /= 10; }
        if (!outRoom(pos, 10)) return 0;
        @memcpy(outBuf()[pos..][0..10], &digits);
        pos += 10;
        appendStr(&pos, " 00000 n \n");
    }
    appendStr(&pos, "trailer\n<< /Size ");
    appendNum(&pos, new_nums[new_n - 1] + 1);
    appendStr(&pos, " /Root ");
    appendNum(&pos, root);
    appendStr(&pos, " 0 R");
    if (enc_want and enc_obj_num != 0) {
        appendStr(&pos, " /Encrypt ");
        appendNum(&pos, enc_obj_num);
        appendStr(&pos, " 0 R /ID [<");
        var zb: usize = 0;
        while (zb < 16) : (zb += 1) {
            const hi: u8 = enc_rand[zb] >> 4;
            const lo: u8 = enc_rand[zb] & 15;
            outBuf()[pos] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
            outBuf()[pos + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
            pos += 2;
        }
        appendStr(&pos, "> <");
        zb = 0;
        while (zb < 16) : (zb += 1) {
            const hi: u8 = enc_rand[zb] >> 4;
            const lo: u8 = enc_rand[zb] & 15;
            outBuf()[pos] = if (hi < 10) '0' + hi else 'A' + (hi - 10);
            outBuf()[pos + 1] = if (lo < 10) '0' + lo else 'A' + (lo - 10);
            pos += 2;
        }
        appendStr(&pos, ">]");
    }
    appendStr(&pos, " >>\nstartxref\n");
    appendNum(&pos, @intCast(xref_pos));
    appendStr(&pos, "\n%%EOF\n");

    stripEncryptOut(pos);
    out_len = pos;
    return pos;
}
