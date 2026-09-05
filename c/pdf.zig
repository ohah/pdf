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
pub extern fn pw_inflate(src: [*]const u8, src_len: c_uint, dst: [*]u8, dst_cap: c_uint) c_int;

const PAGE: usize = 64 * 1024;
pub var in_len: usize = 0;
pub var outbuf: struct {
    len: usize = 0,
    off: usize = 0,
    cap: usize = 0,
} = .{};
/// 객체 스트림(ObjStm)을 풀어 평문 객체로 펼쳐 두는 자리.
var exp: struct {
    /// 원본 뒤에 이어 두고, 객체를 찾을 때 원본과 이 영역을 모두 훑는다.
    off: usize = 0,
    len: usize = 0,
    cap: usize = 0,
} = .{};
pub var bin2: struct {
    /// 병합할 두 번째 문서
    off: usize = 0,
    len: usize = 0,
    cap: usize = 0,
    /// 이어 붙일 문서를 담으려면 이만큼은 있어야 한다 — 다음 reserve 에서 본다
    want: usize = 0,
} = .{};
var img: struct {
    /// 페이지에서 꺼낸 그림 한 장을 두는 자리
    off: usize = 0,
    cap: usize = 0,
    len: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    /// 0=없음 1=RGB 2=흑백 3=JPEG(브라우저가 푼다)
    kind: u32 = 0,
    n: u32 = 0,
    used: u32 = 0,
    off_first: u32 = 0,
} = .{};
/// JBIG2 낱장 곳간 — 문서마다 한 번 잡는다
var jb_pool_at: usize = 0;
pub var fontarea: struct {
    off: usize = 0,
    cap: usize = 0,
    n: u8 = 0,
    /// 글꼴 영역에서 이번 쪽이 쓴 만큼
    used: u32 = 0,
} = .{};
var inl: struct {
    off: usize = 0,
    cap: usize = 0,
    used: u32 = 0,
} = .{};
pub var subs: struct {
    off: usize = 0,
    cap: usize = 0,
} = .{};
pub var t1s: struct {
    off: usize = 0,
    cap: usize = 0,
    used: u32 = 0,
} = .{};

pub fn heapBase() usize { return @intFromPtr(&__heap_base); }

/// 입력·출력에 쓸 자리를 확보한다. 모자라면 메모리를 늘린다.
export fn reserve(want_in: usize, want_out: usize) u32 {
    // 원본 · 펼친 객체 · 출력 순으로 잡는다. 펼친 객체는 원본만큼 여유를 준다.
    exp.cap = want_in + 1024 * 1024;
    // 여벌 자리.
    //
    // 이어 붙일 둘째 문서를 담기도 하고, 스트림 하나를 풀거나 푸는 동안
    // 중간 결과를 두는 데도 쓴다. 파일만큼 잡아 두었더니 300MB 문서를
    // 보기만 해도 300MB 를 더 들고 있었다 — 붙이지도 않는데. 스트림 하나에
    // 맞춰 잡고, 이어 붙일 때만 setSecondRoom 으로 늘린다.
    bin2.cap = @max(@min(want_in + 1024 * 1024, 128 * 1024 * 1024), bin2.want);
    // 아래 다섯은 여기서 안 잡는다. 글자만 있는 계약서를 열어도 그림 자리
    // 48MB 를, 글꼴이 안 박힌 문서도 글꼴 자리 8MB 를 들고 있었다 —
    // 문서가 실제로 그것을 쓸 때 잡는다(areaOf).
    img.cap = 48 * 1024 * 1024;
    fontarea.cap = 8 * 1024 * 1024;
    inl.cap = 8 * 1024 * 1024;
    subs.cap = 6 * 1024 * 1024; // 폼·글리프 그림용, 깊이마다 2MB
    t1s.cap = 4 * 1024 * 1024; // Type1 글리프 프로그램
    img.off = 0;
    jb_pool_at = 0;
    fontarea.off = 0;
    inl.off = 0;
    subs.off = 0;
    t1s.off = 0;
    const need = heapBase() + want_in + exp.cap + bin2.cap + want_out;
    const have = @wasmMemorySize(0) * PAGE;
    if (need > have) {
        const more = (need - have + PAGE - 1) / PAGE;
        if (@wasmMemoryGrow(0, more) < 0) return 0;
    }
    exp.off = heapBase() + want_in;
    bin2.off = exp.off + exp.cap;
    outbuf.off = bin2.off + bin2.cap;
    outbuf.cap = want_out;
    return 1;
}


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
fn imgArea() usize { return areaOf(&img.off, img.cap); }
pub fn fontArea() usize { return areaOf(&fontarea.off, fontarea.cap); }
fn inlArea() usize { return areaOf(&inl.off, inl.cap); }
fn subArea() usize { return areaOf(&subs.off, subs.cap); }
pub fn t1Area() usize { return areaOf(&t1s.off, t1s.cap); }

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
fn zoneBase() usize { return outbuf.off + outbuf.cap; }
pub fn zoneTop() usize { return if (zone_top < zoneBase()) zoneBase() else zone_top; }
fn zoneReset() void { zone_top = zoneBase(); }
/// 자리를 떼어 준다. 못 늘리면 null.
pub fn zoneAlloc(bytes: usize) ?usize {
    if (outbuf.off == 0) return null;
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
pub fn zoneShrink(to: usize) void { if (to >= zoneBase()) zone_top = to; }

var big: struct {
    /// 큰 임시 자리 하나. 돌려 쓴다.
    ///
    /// 예전에는 "구역 끝 너머를 빌린다" 였다. 자리를 잡아 두지 않으므로,
    /// 빌린 것을 쓰는 동안 누가 zoneAlloc 을 하면 그 위에 겹쳐 앉았다.
    /// 실제로 봉인한 스트림 한가운데가 남의 표로 덮여 나왔다. 이제는 구역에
    /// 제 몫으로 잡아 두고, 더 큰 것이 필요할 때만 늘린다.
    at: usize = 0,
    cap: u32 = 0,
} = .{};
pub fn bigScratch(want: usize) ?[]u8 {
    if (outbuf.off == 0 or want == 0 or want > 0xF000_0000) return null;
    if (!growTableTo(&big.at, &big.cap, @intCast(want), 1, 1 << 16, 1 << 30)) return null;
    return @as([*]u8, @ptrFromInt(big.at))[0..want];
}

export fn secondPtr() usize { return bin2.off; }
/// 이어 붙이기 전에 "이만큼 담을 자리가 필요하다" 고 알린다
export fn setSecondRoom(n: usize) void { bin2.want = n; }
export fn maxSecond() usize { return bin2.cap; }

fn expBuf() [*]u8 { return @ptrFromInt(exp.off); }

/// 원본과 펼친 객체를 한 덩어리로 본다. findObj 가 둘 다 훑도록.
pub fn searchSlice() []u8 {
    return @as([*]u8, @ptrFromInt(heapBase()))[0 .. in_len + exp.len];
}


/// 페이지 객체 번호들 (문서 순서). 자리는 parse 가 쪽 수에 맞춰 잡는다.
pub var pgs: Table(u32, 0) = .{};
pub var cpage: struct {
    count: u32 = 0,
    x0: f32 = 0,
    y0: f32 = 0,
    rotate: i32 = 0,
    w: f32 = 612,
    h: f32 = 792,
} = .{};
pub var pagest: struct {
    /// 담을 자리가 모자라 뒤를 잘랐는가 — 화면에 알려 주기 위한 것이다.
    cut: bool = false,
    /// Pages 트리 루트 객체 번호
    obj: u32 = 0,
} = .{};

pub fn u32sAt(at: usize, n: u32) []u32 {
    if (at == 0 or n == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(at))[0..n];
}
pub var doc: struct {
    /// Catalog 객체 번호 — 만들 때 /AcroForm 을 손대는 데 쓴다
    root: u32 = 0,
    /// 문서 전체 (폼·글리프 그림을 꺼내려면 필요하다)
    items: []const u8 = &[_]u8{},
    /// 암호 사전의 권한 비트(/P). 암호가 없으면 -1 — 다 된다는 뜻이다.
    perm: i32 = -1,
} = .{};
pub var pick: struct {
    /// 사용자가 고른 순서
    items: Table(u32, 0) = .{},
    n: usize = 0,
} = .{};
pub var rotate: i32 = 0;
pub var wm: struct {
    /// 워터마크 문구 (라틴 문자만 — 표준 글꼴을 쓰므로 한글은 넣을 수 없다)
    items: [128]u8 = undefined,
    len: usize = 0,
    /// 워터마크 글자를 코드 그대로 담는다. 1바이트로 자르면 한글이 엉뚱한
    /// 라틴 글자가 된다 — ㅁ(U+3141) 이 'A'(0x41) 로 보였다.
    cp: [64]u32 = undefined,
    n: usize = 0,
} = .{};

export fn clearWatermark() void { wm.len = 0; wm.n = 0; pdfapply.wm_mlen = 0; pdfapply.wm_mobj = 0; }
export fn addWatermarkChar(c: u32) void {
    if (c < 32 or c == 127) return;
    if (wm.n < wm.cp.len) { wm.cp[wm.n] = c; wm.n += 1; }
    // 표준 글꼴로 찍을 때 쓸 아스키 판
    if (wm.len < wm.items.len and c >= 32 and c < 127 and c != '(' and c != ')' and c != '\\') {
        wm.items[wm.len] = @truncate(c);
        wm.len += 1;
    }
}
/// 워터마크가 아스키만인가
pub fn wmIsAscii() bool {
    var i: usize = 0;
    while (i < wm.n) : (i += 1) if (wm.cp[i] > 126) return false;
    return true;
}

export fn inputPtr() usize { return heapBase(); }
export fn outputPtr() usize { return outbuf.off; }
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
export fn outputLen() usize { return outbuf.len; }
export fn pageCount() u32 { return cpage.count; }
/// 쪽이 너무 많아 뒤를 잘랐는가
export fn pagesTruncated() u32 { return if (pagest.cut) 1 else 0; }

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0 or c == 12;
}

/// haystack 에서 needle 을 뒤에서부터 찾는다.
/// 뒤에서부터 찾는다. find 와 같은 수를 쓰되 방향만 반대다 —
/// 여덟 바이트를 한 번에 읽어 첫 글자가 없으면 여덟 칸을 건너뛴다.
/// /Root · /Encrypt 처럼 파일 끝에 적히는 것을 찾는 데 쓰므로 뜨겁다.
pub fn rfind(h: []const u8, n: []const u8, from: usize) ?usize {
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
pub fn rfindTail(h: []const u8, n: []const u8) ?usize {
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
pub fn trailerKeyOrScan(b: []const u8, key: []const u8) ?usize {
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

/// PDF 바이트가 얼마나 드문가 — 클수록 드물다.
///
/// 여덟 바이트씩 건너뛰는 수법은 걸림 글자가 드물어야 값이 난다. 견본 268개
/// 87MB 를 세어 잦기의 로그를 0~255 로 편 표다. 공백은 15.6% 라 0 점,
/// 'b' 는 0.39% 라 150 점이다. 흔하다/드물다로 둘로만 가르면 "/Annots" 처럼
/// 고를 것이 다 고만고만한 말에서 되레 나쁜 글자를 집는다 — 점수로 견준다.
const RARITY: [256]u8 = .{
     45, 238, 250, 232, 243, 250, 235, 238, 210, 241,  86, 229, 240, 227, 233, 226,
    236, 235, 212, 240, 228, 211, 216, 239, 237, 251, 229, 244, 223, 233, 241, 233,
      0, 235, 245, 226, 232, 221, 241, 248, 159, 162, 238, 243, 228, 230, 190, 108,
     53,  58,  96, 109,  96, 105, 107, 112, 115, 122, 227, 225, 128, 217, 130, 230,
    249,  81, 155, 196, 238, 162, 147, 216, 224, 231, 255, 239, 199, 199, 240, 209,
    183, 228, 135, 219, 100, 207, 229, 190, 235, 236, 250, 191, 249, 188, 215, 229,
    243, 109, 150, 112, 111,  54, 105, 114, 189, 103, 132, 231, 106,  96,  98,  75,
    121, 218,  67,  90,  77, 111, 209, 219,  39, 182, 229, 232, 250, 235, 232,  49,
     77, 249, 232, 220, 223, 232, 240, 238, 235, 240, 215, 250, 214, 246, 215, 244,
    246, 242, 209, 226, 252, 235, 184, 250, 212, 246, 235, 215, 248, 249, 229, 238,
    229, 244, 241, 207, 235, 250, 244, 233, 234, 239, 235, 236, 243, 244, 245, 239,
    241, 226, 240, 207, 240, 249, 211, 231, 255, 238, 215, 233, 251, 241, 242, 241,
    250, 235, 227, 228, 241, 242, 240, 196, 241, 238, 234, 241, 219, 252, 242, 240,
    243, 195, 242, 219, 243, 234, 215, 232, 247, 221, 239, 242, 244, 214, 230, 247,
    234, 207, 211, 251, 209, 241, 254, 243, 233, 253, 222, 245, 229, 232, 231, 244,
    231, 220, 187, 239, 201, 236, 202, 244, 237, 245, 232, 244, 237, 220, 238, 202,
};

/// 엔진에서 가장 뜨거운 고리다. 문서 하나를 여는 동안 파일 크기의 몇 배를
/// 이 함수로 훑는다.
///
/// 한 바이트씩 밀며 비교하면 바이트마다 서너 클럭이 든다. 그 대신 찾을 말에서
/// 글자 하나를 걸림돌로 골라, 여덟 바이트를 u64 로 한 번에 읽어 그 안에 걸림돌이
/// 있는지 본다 — 없으면 여덟 칸을 통째로 건너뛴다. 답은 같고 훑는 값만 준다.
///
/// 그러니 걸림돌이 드물수록 값이 난다. 예전에는 첫 글자로 못박혀 있었는데,
/// 가장 많이 찾는 말이 " obj" 라 걸림돌이 공백이었다. 여덟 바이트 묶음의
/// 82% 에 공백이 들어 사실상 한 칸씩 기어갔다.
pub fn find(h: []const u8, n: []const u8, from: usize) ?usize {
    if (n.len == 0 or n.len > h.len) return null;
    const last = h.len - n.len;
    if (from > last) return null;
    // 찾을 말에서 가장 드문 글자를 걸림돌로 삼는다.
    //
    // 짧은 구간에서는 고르는 값이 아끼는 값보다 크다. 건너뛸 거리가 있을
    // 때만 고른다.
    var k: usize = 0;
    if (last - from >= 256) {
        var best = RARITY[n[0]];
        var j: usize = 1;
        while (j < n.len) : (j += 1) {
            if (RARITY[n[j]] > best) {
                best = RARITY[n[j]];
                k = j;
            }
        }
    }
    const ck = n[k];
    const ones: u64 = 0x0101010101010101;
    const highs: u64 = 0x8080808080808080;
    const spread: u64 = ones *% @as(u64, ck);
    // 걸림돌이 놓일 수 있는 자리
    const end = last + k;
    var i: usize = from + k;
    while (i <= end) {
        // 여덟 바이트 중에 걸림돌이 있는지 — 없으면 여덟 칸 건너뛴다
        while (i + 8 <= end) {
            const w: u64 = @bitCast(h[i..][0..8].*);
            const x = w ^ spread;
            const hit = (x -% ones) & ~x & highs;
            if (hit != 0) {
                i += @ctz(hit) >> 3;
                break;
            }
            i += 8;
        }
        if (i > end) return null;
        if (h[i] == ck and std_mem_eq(h[i - k ..][0..n.len], n)) return i - k;
        i += 1;
    }
    return null;
}
pub fn std_mem_eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

pub fn readUint(b: []const u8, p: *usize) u32 {
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
pub var max_obj: u32 = 0;

/// 색인은 문서에 맞춰 늘어난다.
///
/// 예전에는 [65536] 고정이었다. 번호가 그보다 큰 객체는 색인에 못 들어가고,
/// 그것을 찾을 때마다 파일을 통째로 훑었다 — 3만 쪽 문서 46ms 가 4만 쪽에서
/// 89초가 되는 벼랑이 상수 하나에 걸려 있었다. 처음 6만 5천 개로 시작해
/// 더 큰 번호를 만나면 배로 늘린다.
const OBJ_IDX_START: u32 = 65536;
/// 여기서 멈춘다 — 번호가 끝없이 큰 망가진 파일에 끌려가지 않기 위한 것
const OBJ_IDX_LIMIT: u32 = 1 << 22;
pub var objix: struct {
    at: usize = 0,
    cap: u32 = 0,
    /// 색인을 만든 버퍼 길이 (0 이면 없음)
    idx_len: usize = 0,
} = .{};
var rank_at: usize = 0;

pub fn objOff() []u32 {
    if (objix.at == 0) return &[_]u32{};
    return @as([*]u32, @ptrFromInt(objix.at))[0..objix.cap];
}
pub fn objRankTable() []u8 {
    if (rank_at == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(rank_at))[0..objix.cap];
}

/// num 번까지 담을 자리를 마련한다. 못 늘리면 false — 그 번호는 색인에
/// 안 들어가고 찾을 때 훑는다(예전과 같은 길).

/// 표 하나를 문서에 맞춰 늘린다.
///
/// 고정 배열로 두면 그 숫자가 곧 상한이 되고, 넘는 문서는 뒤가 조용히
/// 잘린다. 자리잡개에서 떼어 쓰고 모자라면 배로 늘린다 — 늘릴 때 앞자리는
/// 버리므로 최대 두 배까지 더 쓰지만, 세는 상한이 사라진다.
/// (pdf.js 는 JS 배열이라 이런 상한이 아예 없다.)
/// 늘어나는 표. `X_at`/`X_cap` 두 전역과 `X_Buf()`/`X_Room()` 두 함수를 손으로
/// 되풀이해 쓰던 것을 하나로 접었다 — 같은 것이 57벌 있었다. 자리는 wasm 선형
/// 메모리의 주소라 슬라이스가 아니라 usize 로 들고 있다(구역이 되감기면
/// growTable 이 알아서 버린다).
pub fn Table(comptime T: type, comptime START: u32) type {
    return struct {
        at: usize = 0,
        cap: u32 = 0,

        const Self = @This();

        /// 표 전체를 슬라이스로 본다. 아직 자리를 안 잡았으면 빈 것을 준다.
        pub fn all(self: *const Self) []T {
            if (self.at == 0 or self.cap == 0) return &[_]T{};
            return @as([*]T, @ptrFromInt(self.at))[0..self.cap];
        }

        /// want 번째까지 들어갈 자리를 만든다. 처음 잡을 개수는 선언에
        /// 적힌 START 다 — 부르는 자리마다 되풀이하면 한 곳만 고쳤을 때
        /// 조용히 어긋난다.
        pub fn room(self: *Self, want: u32) bool {
            return growTable(&self.at, &self.cap, want, @sizeOf(T), START);
        }
    };
}

pub fn growTable(at: *usize, cap: *u32, want: u32, elem: usize, start: u32) bool {
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
    // 맨 위에 있는 표는 뒤로 늘리기만 하면 된다 — 옮기지도, 앞엣것을
    // 버리지도 않는다. 배로 늘리는 표가 여럿 쌓이면 그 버린 자리가 꽤 된다
    // (무늬를 잔뜩 그리는 쪽에서 6MB 였다).
    if (at.* != 0 and at.* + @as(usize, cap.*) * elem == zoneTop()) {
        const want_end = at.* + @as(usize, n) * elem;
        const have = @wasmMemorySize(0) * PAGE;
        if (want_end > have) {
            const more = (want_end - have + PAGE - 1) / PAGE;
            if (@wasmMemoryGrow(0, more) < 0) return false;
        }
        zone_top = want_end;
        cap.* = n;
        return true;
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
    if (num < objix.cap) return true;
    if (num >= OBJ_IDX_LIMIT) return false;
    var want: u32 = if (objix.cap == 0) OBJ_IDX_START else objix.cap;
    while (want <= num) : (want *|= 2) {
        if (want >= OBJ_IDX_LIMIT) return false;
    }
    const off_at = zoneAlloc(@as(usize, want) * 4) orelse return false;
    const rk_at = zoneAlloc(want) orelse return false;
    const new_off = @as([*]u32, @ptrFromInt(off_at))[0..want];
    const new_rank = @as([*]u8, @ptrFromInt(rk_at))[0..want];
    @memset(new_rank, 0);
    if (objix.cap > 0) {
        @memcpy(new_off[0..objix.cap], objOff());
        @memcpy(new_rank[0..objix.cap], objRankTable());
    }
    objix.at = off_at;
    rank_at = rk_at;
    objix.cap = want;
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
    objix.at = 0;
    rank_at = 0;
    objix.cap = 0;
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
            if (h.num < objix.cap or growIndex(h.num)) {
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
    objix.idx_len = b.len;
}

pub fn findObj(b: []const u8, num: u32) ?usize {
    // 본 버퍼는 색인으로 바로 찾는다. 병합용 두 번째 버퍼는 색인이 없다.
    if (objix.idx_len != 0 and b.len == objix.idx_len and
        b.ptr == @as([*]const u8, @ptrFromInt(heapBase())) and num < objix.cap)
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
pub fn objDictEnd(b: []const u8, ob: usize) usize {
    const e1 = find(b, "endobj", ob) orelse b.len;
    const e2 = find(b, "stream", ob) orelse b.len;
    return @min(e1, e2);
}

/// 딕셔너리 안에서 /Key 뒤의 정수를 읽는다.
pub fn dictInt(b: []const u8, start: usize, end: usize, key: []const u8) ?u32 {
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
pub var walk: struct {
    /// 것이 이 표뿐이므로 뒤로 이어 붙이면 옮길 일 없이 늘어난다.
    at: usize = 0,
    cap: u32 = 0,
    ceil: u32 = 0,
} = .{};

/// 걷어 담을 자리를 처음 잡는다. 천장은 파일 크기로 묶는다 — 고리처럼
/// 얽힌 쪽 트리를 만나도 훑는 양이 파일 크기를 넘지 않게 한다.
pub fn walkStart(total: usize) bool {
    walk.ceil = @intCast(@max(@as(usize, 64), @min(total / 4 + 64, 1 << 22)));
    walk.cap = 0;
    walk.at = zoneAlloc(256 * 4) orelse return false;
    walk.cap = 256;
    return true;
}

fn walkPush(n: *u32, obj: u32) bool {
    if (n.* >= walk.cap) {
        if (walk.cap >= walk.ceil) { pagest.cut = true; return false; }
        // 두 배씩. 짝수로 잡아 다음 자리가 여덟 바이트에 맞게 둔다.
        var want: u32 = @min(walk.ceil, walk.cap * 2);
        want += want & 1;
        if (want <= walk.cap) { pagest.cut = true; return false; }
        if (zoneAlloc(@as(usize, want - walk.cap) * 4) == null) { pagest.cut = true; return false; }
        walk.cap = want;
    }
    u32sAt(walk.at, walk.cap)[n.*] = obj;
    n.* += 1;
    return true;
}

/// Kids 배열에서 "N 0 R" 들을 걷어 페이지 객체를 모은다. 중첩 트리도 따라간다.
pub fn collectPages(b: []const u8, obj: u32, depth: u32, n: *u32) void {
    if (depth > 16 or pagest.cut) return;
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
pub fn lengthOf(b: []const u8, from: usize, to: usize) ?u32 {
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
pub fn fixStreamLen(b: []const u8, data: usize, length: u32) u32 {
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

pub fn intAfter(b: []const u8, from: usize, to: usize, key: []const u8) ?u32 {
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
    exp.len = 0;
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
        if (exp.len + 1024 >= exp.cap) return;
        const tmp_off = exp.len + (exp.cap - exp.len) / 2;
        const room = exp.cap - tmp_off;
        const got = pw_inflate(b[data..].ptr, @intCast(length), expBuf() + tmp_off, @intCast(room));
        if (got <= 0) continue;
        const dec = expBuf()[tmp_off .. tmp_off + @as(usize, @intCast(got))];

        var write = exp.len;
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
        exp.len = write;
    }
}

pub export fn parse(len: usize) u32 {
    in_len = len;
    objix.idx_len = 0;
    cpage.count = 0;
    pagest.obj = 0;
    if (len < 8) return 0;
    // 색인도 쪽 표도 이 자리를 쓴다. 문서를 새로 열 때 한 번만 비운다.
    zoneReset();
    // 자리잡개를 비웠으니 거기서 떼어 쓰던 것들도 다시 잡아야 한다.
    // 안 그러면 앞 문서가 쓰던 자리를 가리킨 채 새 문서의 색인이 그 위에 얹힌다.
    img.off = 0;
    fontarea.off = 0;
    inl.off = 0;
    subs.off = 0;
    t1s.off = 0;
    maskt.at = 0;
    maskt.used = 0;
    att.at = 0;
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
    doc.root = root;
    if (root != 0) {
        if (findObj(b, root)) |body| {
            const end = find(b, "endobj", body) orelse total;
            if (dictInt(b, body, end, "/Pages")) |pg| pagest.obj = pg;
        }
    }
    // /Root 로 못 찾으면 /Type /Pages 를 직접 뒤진다
    if (pagest.obj == 0) {
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
            pagest.obj = readUint(b, &p);
        }
    }
    // 꺼 놓은 레이어 (/OCProperties /D /OFF)
    ocg.off_n = 0;
    oc.n = 0;
    oc.used = 0;
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
                    while (q < oe2 and b[q] != ']' and ocRoom(oc.n + 1)) {
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q >= oe2 or b[q] == ']') break;
                        if (!isDigit(b[q])) { q += 1; continue; }
                        const num8 = readUint(b, &q);
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q < oe2 and isDigit(b[q])) _ = readUint(b, &q);
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q < oe2 and b[q] == 'R') q += 1;
                        // 이름은 그 객체의 /Name 에 있다
                        var noff: u32 = oc.used;
                        var nlen: u32 = 0;
                        if (findObj(b, num8)) |gb| {
                            const ge = objDictEnd(b, gb);
                            if (find(b[gb..ge], "/Name", 0)) |na| {
                                _ = (oc.buf.room(oc.used + 4096));
                                const r2 = sigPutStrTo(b, gb + na + 5, ge, oc.buf.all(), &oc.used);
                                noff = r2[0];
                                nlen = r2[1];
                            }
                        }
                        oc.obj.all()[oc.n] = num8;
                        oc.name_off.all()[oc.n] = noff;
                        oc.name_len.all()[oc.n] = nlen;
                        oc.on.all()[oc.n] = true;
                        oc.n += 1;
                    }
                }
                if (find(b[os2..oe2], "/OFF", 0)) |fa2| {
                    var q = os2 + fa2 + 4;
                    while (q < oe2 and b[q] != '[') q += 1;
                    q += 1;
                    while (q < oe2 and b[q] != ']' and ocg.off_list.room(ocg.off_n + 1)) {
                        while (q < oe2 and isSpace(b[q])) q += 1;
                        if (q >= oe2 or b[q] == ']') break;
                        if (!isDigit(b[q])) { q += 1; continue; }
                        const off8 = readUint(b, &q);
                        ocg.off_list.all()[ocg.off_n] = off8;
                        ocg.off_n += 1;
                        var k8: u32 = 0;
                        while (k8 < oc.n) : (k8 += 1) if (oc.obj.all()[k8] == off8) { oc.on.all()[k8] = false; };
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
    if (pagest.obj == 0) return 0;

    // 쪽 표 자리를 잡는다.
    //
    // 쪽 수는 걷어 봐야 알지만 쪽 하나는 반드시 객체 하나이므로, 문서에서
    // 본 가장 큰 객체 번호가 상한이 된다. 파일 크기로도 한 번 더 묶는다 —
    // 고리처럼 얽힌 쪽 트리를 만나도 훑는 양이 파일 크기를 넘지 않게 한다.
    // 넉넉히 잡아 채운 뒤 실제로 쓴 만큼으로 줄인다.
    pagest.cut = false;
    if (!walkStart(total)) return 0;
    cpage.count = 0;
    collectPages(b, pagest.obj, 0, &cpage.count);
    // 쓴 만큼만 남기고 나머지 표를 그 뒤에 잇는다
    pgs.at = walk.at;
    pgs.cap = cpage.count;
    zoneShrink(pgs.at + @as(usize, cpage.count) * 4);
    {
        // 고른 쪽은 같은 쪽을 두 번 넣을 수도 있어 넉넉히 잡는다
        pick.items.cap = cpage.count * 2 + 64;
        pick.items.at = zoneAlloc(@as(usize, pick.items.cap) * 4) orelse return 0;
        pick.n = 0;
        rot.at = zoneAlloc(@as(usize, cpage.count) * 2 + 2) orelse return 0;
        rot.cap = cpage.count;
        clearPageRotate();
        lbl.off_at = zoneAlloc(@as(usize, cpage.count) * 4 + 4) orelse return 0;
        lbl.len_at = zoneAlloc(@as(usize, cpage.count) + 4) orelse return 0;
        // 0 으로 채운다. 예전에는 .bss 라 저절로 0 이었지만 지금은 앞 문서가
        // 쓰던 자리를 물려받는다 — 라벨이 안 붙은 쪽에서 남의 자리·길이를
        // 읽어 엉뚱한 글자를 내놓거나 아예 열다 죽었다.
        @memset(u32sAt(lbl.off_at, cpage.count + 1), 0);
        @memset(@as([*]u8, @ptrFromInt(lbl.len_at))[0 .. cpage.count + 4], 0);
        lbl.buf_cap = @max(@as(usize, 1024), @as(usize, cpage.count) * 16);
        lbl.buf_at = zoneAlloc(lbl.buf_cap) orelse return 0;
        label_n = 0;
    }
    if (root != 0) collectOutline(b, root);
    collectInfo(b);
    collectMeta(b);
    collectDests(b);
    collectOpenAction(b); // 이름 붙은 자리를 찾으려면 dests 뒤여야 한다
    collectCalcOrder(b);
    collectViewPrefs(b);
    collectXmp(b);
    collectStruct(b);
    collectLabels(b);
    return if (cpage.count > 0) 1 else 0;
}

export fn clearPick() void { pick.n = 0; }
export fn addPick(i: u32) void {
    if (pick.n < pick.items.cap and i < cpage.count) { pick.items.all()[pick.n] = i; pick.n += 1; }
}
export fn setRotate(deg: i32) void { rotate = deg; }

/// 쪽마다 따로 돌리기. -1 은 "정하지 않음" 이라 전체 회전을 따른다.
var rot: Table(i16, 0) = .{};
export fn clearPageRotate() void {
    for (rot.all()) |*r| r.* = -1;
}
export fn setPageRotate(page: u32, deg: i32) void {
    if (page >= rot.cap) return;
    const d = @mod(deg, 360);
    rot.all()[page] = @intCast(if (d < 0) d + 360 else d);
}
pub fn rotOf(page: u32) i32 {
    if (page < rot.cap and rot.all()[page] >= 0) return rot.all()[page];
    return rotate;
}
pub fn anyPageRotate() bool {
    for (rot.all()) |r| if (r >= 0) return true;
    return false;
}

pub fn outBuf() [*]u8 { return @ptrFromInt(outbuf.off); }

/// 출력 자리가 남았나. 넘겨 쓰면 wasm 이 통째로 죽는다 — 입력 칸을 천 개
/// 채우면 실제로 그랬다.
/// 출력에 그대로 옮겨 적는다. 자리가 모자라면 안 적고 false.
pub fn outCopy(pos: *usize, src: []const u8) bool {
    if (!outRoom(pos.*, src.len)) return false;
    @memcpy(outBuf()[pos.*..][0..src.len], src);
    pos.* += src.len;
    return true;
}

pub fn outRoom(pos: usize, need: usize) bool {
    return pos + need + 64 <= outbuf.cap;
}

pub fn appendStr(pos: *usize, s: []const u8) void {
    if (!outRoom(pos.*, s.len)) return;
    @memcpy(outBuf()[pos.*..][0..s.len], s);
    pos.* += s.len;
}
pub fn appendNum(pos: *usize, v: u32) void {
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
pub fn wmCode(f: *const FontMap, uni: u32) ?u32 {
    var i: u16 = 0;
    while (i < f.n) : (i += 1) if (f.unis.all()[i] == uni) return f.codes.all()[i];
    return null;
}

/// 숫자를 적고 쓴 자릿수를 준다.
pub fn putNum(dst: []u8, v: u32) usize {
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
pub fn putFrac(dst: []u8, v: f32) usize {
    const c: u32 = @intFromFloat(@max(0, @min(1, v)) * 100 + 0.5);
    const n = putNum(dst, c / 100);
    if (n + 3 > dst.len) return n;
    dst[n] = '.';
    dst[n + 1] = '0' + @as(u8, @intCast((c / 10) % 10));
    dst[n + 2] = '0' + @as(u8, @intCast(c % 10));
    return n + 3;
}

// ===== 문서를 다시 써 내보낸다 — 라벨·워터마크를 얹고 xref 를 새로 적는다 (c/pdfapply.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfapply = @import("pdfapply.zig");
pub const keyIs = pdfapply.keyIs;
pub const skipVal = pdfapply.skipVal;
pub const stripEncryptOut = pdfapply.stripEncryptOut;
pub const xrefTables = pdfapply.xrefTables;
export fn clearLabels() void { pdfapply.clearLabels(); }
export fn addLabel(page: u32, x: f32, y: f32, size: f32, r: f32, g: f32, bb: f32) u32 { return pdfapply.addLabel(page, x, y, size, r, g, bb); }
export fn setLabelMask(w: u32, h: u32, len: u32, pw: f32, ph: f32) u32 { return pdfapply.setLabelMask(w, h, len, pw, ph); }
export fn setWatermarkMask(w: u32, h: u32, len: u32, pw: f32, ph: f32) u32 { return pdfapply.setWatermarkMask(w, h, len, pw, ph); }
export fn addLabelChar(c: u32) void { pdfapply.addLabelChar(c); }
export fn apply() usize { return pdfapply.apply(); }

// ===== 텍스트 렌더링 =====
//
// 브라우저 내장 뷰어를 쓰지 않고 캔버스에 직접 그리기 위한 최소 렌더러.
// 콘텐츠 스트림의 텍스트 연산자만 해석한다. 한글은 폰트의 ToUnicode CMap 을
// 읽어야 실제 글자가 나온다.

/// 쪽 하나에서 뽑을 글자 덩이 수.
///
/// 4096 이던 것을 올렸다. 표가 촘촘한 쪽은 그 수를 넘겨, textItems() 가
/// 뒤를 조용히 잃었다(text.items() 는 따로 담아 두어 멀쩡했다). 덩이 하나가
/// 24 바이트라 16384 개도 384KB 다.

/// 한 번에 그릴 글자 조각
// 글꼴 번호(fonts 의 자리)와 세로쓰기 여부까지 함께 남긴다. pdf.js 의
// TextItem 이 fontName·dir 을 주는 자리다 — 글자층이 글꼴을 맞춰 눕히거나
// 세로쓰기를 알아보는 데 쓴다.
const Item = struct { x: f32, y: f32, size: f32, off: u32, len: u32, font: i32 = -1, vert: bool = false };
/// 글자 조각. 필요한 만큼 늘어난다(세는 상한 없음).
var items: Table(Item, 4096) = .{};
var item_n: u32 = 0;

// --- 그리기 명령 목록 ---
// PDF.js 의 OperatorList 와 같은 생각이다. 파싱 결과를 명령으로 쌓아 넘기고
// 그리기는 캔버스가 맡는다. 좌표 변환을 우리가 곱하지 않고 그대로 넘겨야
// 선 굵기·클리핑·글자 크기가 함께 변환된다.
var ops: struct {
    /// 명령 자리는 필요한 만큼 늘어난다(세는 상한 없음). 예전에는 524288 개로
    /// 못박아 두어, 자리 다 다른 네모 20만 개를 그리면 절반에서 잘렸다.
    /// LIMIT 은 growTable 이 정하는 4M 개(=16MB)다 — 그 위는 문서가 망가진 것으로 본다.
    items: Table(f32, 65536) = .{},
    n: u32 = 0,
} = .{};
/// 그물 셰이딩이 명령 자리를 다 먹으면 그 뒤 그림이 통째로 사라진다.
/// 망가진 파일은 삼각형을 수만 개 뱉으므로 더 못 늘릴 때만 그만둔다.
pub fn opsRoomLow() bool { return !ops.items.room(ops.n + 4096); }
/// 숨긴 레이어를 지나는 동안 명령을 내지 않는다
var emit_mute: bool = false;
// ===== 글자 묶음 =====
//
// 글자를 하나씩 명령으로 내면, 문서 글꼴을 못 실어 다른 글꼴로 대신 그릴 때
// 좁은 글자마다 틈이 벌어진다("Pri ncess Dai sy"). 이어지는 글자를 한 묶음
// 으로 내고 묶음 전체 폭에 맞춰 늘이거나 줄이면 눈에 띄지 않는다.
// PDF.js 도 문자열 단위로 그린다.
var trun: struct {
    on: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    m: [4]f32 = .{ 1, 0, 0, 1 },
    size: f32 = 0,
    off: u32 = 0,
    roff: u32 = 0,
    adv: f32 = 0,
    font: i32 = -1,
    mode: i32 = 0,
} = .{};
var cur: struct {
    /// 지금 걸린 채우기 투명도와 섞기 방식. 투명 그룹을 겹칠 때 쓴다.
    alpha: f32 = 1,
    bm: i32 = 0,
    font: i32 = -1,
} = .{};

fn runFlush() void {
    if (!trun.on) return;
    trun.on = false;
    if (dtext.n <= trun.off) return;
    emitOp(17, &[_]f32{
        trun.x, trun.y, trun.size,
        @floatFromInt(trun.off), @floatFromInt(dtext.n - trun.off),
        @floatFromInt(trun.font + 1),
        trun.m[0], trun.m[1], trun.m[2], trun.m[3], trun.adv,
        @floatFromInt(trun.mode),
        // 글자층에 얹을 글자 자리 — 그리는 글자와 다르다
        @floatFromInt(trun.roff), @floatFromInt(rtext.n - trun.roff),
    });
}
var path: struct {
    /// 지금 그리는 경로가 차지하는 범위. 타일 무늬를 깔 자리를 정하는 데 쓴다.
    x0: f32 = 1e30,
    y0: f32 = 1e30,
    x1: f32 = -1e30,
    y1: f32 = -1e30,
} = .{};
fn pathTouch(x: f32, y: f32) void {
    if (x < path.x0) path.x0 = x;
    if (x > path.x1) path.x1 = x;
    if (y < path.y0) path.y0 = y;
    if (y > path.y1) path.y1 = y;
}
fn pathReset() void {
    path.x0 = 1e30;
    path.y0 = 1e30;
    path.x1 = -1e30;
    path.y1 = -1e30;
}

pub fn emitOp(code: f32, args: []const f32) void {
    if (emit_mute) return;
    const need: u32 = ops.n + 2 + @as(u32, @intCast(args.len));
    if (!ops.items.room(need)) return;
    const buf = ops.items.all();
    buf[ops.n] = code;
    buf[ops.n + 1] = @floatFromInt(args.len);
    ops.n += 2;
    for (args) |a| {
        buf[ops.n] = a;
        ops.n += 1;
    }
}

export fn opsPtr() [*]f32 {
    return if (ops.items.at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(ops.items.at);
}
export fn opsLen() u32 { return ops.n; }
var text: struct {
    /// 뽑아 내는 글자. 필요한 만큼 늘어난다(세는 상한 없음) — 예전에는 256KB 에서
    /// 잘려, 빽빽한 쪽의 뒷글자가 소리 없이 사라졌다.
    items: Table(u8, 65536) = .{},
    n: u32 = 0,
} = .{};
var dtext: struct {
    /// 화면에 찍을 글자. text.items 와 다를 수 있다.
    ///
    /// 부분집합 글꼴은 ToUnicode 가 여러 코드를 같은 글자로 보내는 일이 흔하다.
    /// 바코드 글꼴이 특히 그렇다 — 막대 무늬 수십 개가 같은 한 글자를 가리킨다.
    /// 그 글자를 그리면 무늬 대신 글자가 겹쳐 찍힌다. 그래서 글꼴 파일을 실을 수
    /// 있으면 cmap 을 "사용자 영역 → 글리프 번호"로 새로 적고, 여기에는 그 사용자
    /// 영역 문자를 담아 글리프를 번호로 곧장 집는다.
    /// 화면에 찍을 글자. 필요한 만큼 늘어난다(세는 상한 없음) — 예전에는 256KB 에서
    /// 잘려, 빽빽한 쪽의 뒷글자가 소리 없이 사라졌다.
    items: Table(u8, 65536) = .{},
    n: u32 = 0,
} = .{};
var rtext: struct {
    /// dtext.items 와 나란히 가는, 사람이 읽는 글자.
    ///
    /// 그리는 글자와 읽는 글자는 다르다. 번호로 집는 글꼴은 사용자 영역
    /// (U+E000+글리프번호)으로 찍어야 그려지는데, 그걸 그대로 글자층에 얹으면
    /// 긁어 붙였을 때 깨진 글자가 나온다. PDF.js 도 둘을 따로 둔다 — 캔버스는
    /// 글리프로 찍고, 글자층은 ToUnicode 로 되찾은 글자로 짓는다.
    /// 사람이 읽는 글자. 필요한 만큼 늘어난다(세는 상한 없음) — 예전에는 256KB 에서
    /// 잘려, 빽빽한 쪽의 뒷글자가 소리 없이 사라졌다.
    items: Table(u8, 65536) = .{},
    n: u32 = 0,
} = .{};

/// 폰트 하나의 코드→유니코드 표 (희소)
pub const FontMap = struct {
    name: [24]u8,
    name_len: u8,
    two_byte: bool,
    /// 코드→유니코드 표. 글꼴마다 따로 구역에서 잡고 필요한 만큼 늘린다.
    /// 예전에는 글꼴 하나에 2048 쌍으로 못박혀, 한자·전각 글꼴의 뒷부분이
    /// 조용히 빠졌다.
    codes: Table(u16, 256) = .{},
    unis: Table(u16, 256) = .{},
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
    wcodes: Table(u16, 256) = .{},
    wvals: Table(u16, 256) = .{},
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
    /// 글리프 프로그램 자리 (pdft1.t1_pool 의 첫 칸). 코드 256 개가 이어진다.
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
pub var fonts: Table(FontMap, 8) = .{};

/// 이 쪽이 그린 외부 객체(Do)의 수 — 그림과 폼을 함께 센다.
/// 글자가 없는데 이것이 있으면 스캔 문서다.
var draw_count: u32 = 0;
var formn: struct {
    /// 이 쪽이 가진 폼 XObject 의 수. 화면의 "문서 정보"가 보여 준다.
    ///
    /// 그리기는 한다 — Do 를 만나면 제 /Matrix 를 걸고 /BBox 로 자른 뒤 안을
    /// 펼쳐 그리고, 투명 그룹이면 딴 판에 그려 한 번에 겹친다. 이 값은 그와
    /// 별개로 "이 쪽에 폼이 몇 개 있나" 를 알려 주는 셈이다.
    n: u32 = 0,
    n2: u32 = 0,
} = .{};

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
    off: u32, // img.off 로부터
    len: u32,
    flip: u8, // /Decode [1 0] — 켜고 끄는 값이 뒤집혀 있다
    smask: u8, // 부드러운 마스크가 든 칸 번호 + 1
};
/// 쪽에 놓인 그림 칸. 필요한 만큼 늘어난다(세는 상한 없음).
var imgs: Table(Img, 16) = .{};
/// 쪽이 쓰는 폼 XObject. 콘텐츠 스트림을 제 변환·자르기로 그린다.
pub const Form = struct {
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
var forms: Table(Form, 16) = .{};

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
var gstates: Table(GState, 16) = .{};
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
const CSpace = struct {
    name: [24]u8,
    name_len: u8,
    kind: u8,
    comps: u8,
    /// ICC 프로파일 자리 (iccs.profs 의 번호). 없으면 -1.
    icc: i32 = -1,
};

// ===== ICC 색 프로파일 =====
//
// /ICCBased 는 "이 값은 이 프로파일 기준이다" 라고 알려 준다. 그걸 안 쓰고
// 단순식으로 넘기면 색이 어긋난다 — 마젠타 자리에 형광 마젠타가 찍혔다.
const icc = @import("pdficc.zig");
var iccs: struct {
    profs: Table(icc.Profile, 4) = .{},
    n: u32 = 0,
    /// 프로파일 바이트를 담아 두는 자리 — 스트림 임시 자리는 곧 덮이므로 옮긴다
    data: Table(u8, 65536) = .{},
    data_used: u32 = 0,
} = .{};

/// 프로파일 스트림을 읽어 담는다. 담은 번호, 못 읽으면 -1.
fn addIcc(bytes: []const u8) i32 {
    if (bytes.len < 132 or bytes.len > 8 * 1024 * 1024) return -1;
    if (!iccs.profs.room(iccs.n + 1)) return -1;
    const need = iccs.data_used + @as(u32, @intCast(bytes.len));
    if (!iccs.data.room(need)) return -1;
    const dst = @as([*]u8, @ptrFromInt(iccs.data.at))[0..iccs.data.cap];
    @memcpy(dst[iccs.data_used..][0..bytes.len], bytes);
    const mine = dst[iccs.data_used..][0..bytes.len];
    iccs.data_used = need;
    const p = icc.parse(mine);
    if (p.kind == .none) return -1;
    iccs.profs.all()[iccs.n] = p;
    iccs.n += 1;
    return @intCast(iccs.n - 1);
}

/// 성분 값을 프로파일로 옮긴다. 못 하면 false.
fn iccToRgb(ix: i32, in: []const f32, out: *[3]f32) bool {
    if (ix < 0 or @as(u32, @intCast(ix)) >= iccs.n) return false;
    return icc.toRgb(&iccs.profs.all()[@intCast(ix)], in, out);
}
/// 이름 붙은 색 공간. 필요한 만큼 늘어난다(세는 상한 없음).
var cspaces: Table(CSpace, 16) = .{};
var cs_n: u32 = 0;

fn findCs(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < cs_n) : (i += 1)
        if (txEq(cspaces.all()[i].name[0..cspaces.all()[i].name_len], name)) return @intCast(i);
    return -1;
}

fn findGs(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < gs_n) : (i += 1)
        if (txEq(gstates.all()[i].name[0..gstates.all()[i].name_len], name)) return @intCast(i);
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
    while (i < formn.n2) : (i += 1)
        if (txEq(forms.all()[i].name[0..forms.all()[i].name_len], name)) return @intCast(i);
    return -1;
}

export fn imageSlots() u32 { return img.n; }
export fn jbDbgN() u32 { return jbig2.dbg_n; }
export fn jbSymN() u32 { return jbig2.sym_n; }
/// 글자 사전이 만든 글자의 폭. 시험이 사전을 들여다보는 유일한 창이다 —
/// 부록 H 쪽1 의 글자 셋은 5·6·6 이어야 한다. 물려받기가 잘못돼 같은 글자가
/// 두 번 들어가면 5·5·6 이 된다.
export fn jbSymW(i: u32) u32 { return if (i < jbig2.sym_n) jbig2.syms[i].w else 0; }
export fn slotKind(i: u32) u32 { return if (i < img.n) imgs.all()[i].kind else 0; }
export fn slotWidth(i: u32) u32 { return if (i < img.n) imgs.all()[i].w else 0; }
export fn slotHeight(i: u32) u32 { return if (i < img.n) imgs.all()[i].h else 0; }
export fn slotOff(i: u32) u32 { return if (i < img.n) imgs.all()[i].off else 0; }
export fn slotLen(i: u32) u32 { return if (i < img.n) imgs.all()[i].len else 0; }
export fn slotFlip(i: u32) u32 { return if (i < img.n) imgs.all()[i].flip else 0; }
export fn slotSMask(i: u32) u32 { return if (i < img.n) imgs.all()[i].smask else 0; }

/// 그림 객체 하나를 풀어 그림 표에 담는다. 담은 칸 번호를 준다.
fn takeImage(b: []const u8, ob: usize, name: []const u8) ?u32 {
    if (!imgs.room(img.n + 2)) return null;
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

    // 그림에 붙은 색 프로파일 — /ColorSpace [/ICCBased 6 0 R]
    var img_icc: i32 = -1;
    if (find(b[ob..oe], "/ColorSpace", 0)) |ca2| {
        var q = ob + ca2 + 11;
        while (q < oe and isSpace(b[q])) q += 1;
        var cs_s = q;
        var cs_e = oe;
        if (q < oe and isDigit(b[q])) {
            const cn = readUint(b, &q);
            if (findObj(b, cn)) |cb| { cs_s = cb; cs_e = objDictEnd(b, cb); }
        }
        if (findIn(b[cs_s..@min(cs_e, cs_s + 128)], "ICCBased", 0) != null) {
            var w5 = cs_s;
            while (w5 < cs_e and !isDigit(b[w5])) w5 += 1;
            if (w5 < cs_e) {
                var w6 = w5;
                const pn5 = readUint(b, &w6);
                if (streamOf(b, pn5)) |prof| img_icc = addIcc(prof);
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

    const room = img.cap - img.used;
    if (room < 4096) return null;
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img.used));
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
            if (nfo.comps == 4 and nfo.w == w and nfo.h == h) {
                const px = @as(usize, nfo.w) * nfo.h;
                // 원본 뒤에 RGB 자리와 성분별 중간 자리를 잡는다.
                // 프로그레시브는 계수를 다 들고 있어야 해서 더 든다.
                const extra: usize = if (nfo.progressive) px * 7 else px * 5;
                if (got + px * 3 + extra <= room) {
                    const rgb = dst[got..][0 .. px * 3];
                    const scratch = dst[got + px * 3 ..][0..extra];
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
                if (img.used + got + n_px * 3 <= img.cap and got >= n_px) {
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
                if (comps == 4) {
                    // CMYK 다. 예전에는 3성분으로 읽어 화소가 통째로 밀렸다 —
                    // 시안이 빨강으로, 검정이 초록으로 나왔다.
                    got = cmykToRgb(dst, n_px, img_icc, flip);
                    kind = 1;
                } else if (comps >= 3) kind = 1 else if (comps >= 1) kind = 2;
            } else if (bpc == 16) {
                // 16비트는 높은 바이트만 남긴다. 화면은 8비트면 충분하고,
                // 안 펴 두면 성분 수를 잘못 세어 딴 그림이 된다.
                const half = got / 2;
                var hb: u32 = 0;
                while (hb < half) : (hb += 1) dst[hb] = dst[hb * 2];
                got = half;
                const n_px = @as(usize, w) * @as(usize, h);
                const comps = @as(usize, half) / (if (n_px == 0) 1 else n_px);
                if (comps == 4) {
                    got = cmykToRgb(dst, n_px, img_icc, flip);
                    kind = 1;
                } else if (comps >= 3) kind = 1 else if (comps >= 1) kind = 2;
            } else if (bpc == 2 or bpc == 4) {
                // 2·4비트 회색은 8비트로 펴 둔다
                const row_in = (w * bpc + 7) / 8;
                const need2 = w * h;
                if (img.used + got + need2 <= img.cap) {
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

    const im = &imgs.all()[img.n];
    const nl = @min(name.len, 24);
    var k: usize = 0;
    while (k < nl) : (k += 1) im.name[k] = name[k];
    im.name_len = @intCast(nl);
    im.kind = kind;
    im.w = w;
    im.h = h;
    im.off = img.used;
    im.len = got;
    im.flip = if (flip) 1 else 0;
    im.smask = 0;
    const slot = img.n;
    if (slot == 0) { img.kind = kind; img.w = w; img.h = h; img.off_first = img.used; img.len = got; }
    img.n += 1;
    img.used += (got + 3) & ~@as(u32, 3);

    // 부드러운 마스크 — 투명도가 여기 들어 있다
    if (find(b[ob..oe], "/SMask", 0)) |sa| {
        var q = ob + sa + 6;
        while (q < oe and isSpace(b[q])) q += 1;
        if (q < oe and isDigit(b[q])) {
            const sn = readUint(b, &q);
            if (findObj(b, sn)) |sb2| {
                if (takeImage(b, sb2, "")) |ms| imgs.all()[slot].smask = @intCast(ms + 1);
            }
        }
    }
    // 딱딱한 가리개(/Mask). 두 꼴이 있다.
    //
    //   · 스텐실 그림을 가리키면 그 그림의 1 인 자리가 뚫린다(투명).
    //   · [최소 최대 …] 배열이면 그 범위에 든 색이 뚫린다(색 키).
    //
    // 안 보면 투명해야 할 로고가 흰 네모로 나온다.
    if (imgs.all()[slot].smask == 0) {
        if (find(b[ob..oe], "/Mask", 0)) |ma| {
            var q = ob + ma + 5;
            while (q < oe and isSpace(b[q])) q += 1;
            if (q < oe and isDigit(b[q])) {
                const mn = readUint(b, &q);
                if (findObj(b, mn)) |mb| {
                    if (takeImage(b, mb, "")) |ms| {
                        // 스텐실은 1비트로 담겨 있고 1 이 "가린다" 는 뜻이다.
                        // 알파로 쓰려면 8비트로 펴면서 뒤집어야 한다.
                        if (stencilAlpha(ms)) |al| imgs.all()[slot].smask = @intCast(al + 1);
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
    if (mi >= img.n or !imgs.room(img.n + 1)) return null;
    const im = imgs.all()[mi];
    if (im.kind != 4 or im.w == 0 or im.h == 0) return null;
    const px = @as(usize, im.w) * im.h;
    if (px == 0 or px + 4 > img.cap - img.used) return null;
    const stride = (@as(usize, im.w) + 7) / 8;
    if (im.len < stride * im.h) return null;
    const src = @as([*]const u8, @ptrFromInt(imgArea() + im.off));
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img.used));
    var y: u32 = 0;
    while (y < im.h) : (y += 1) {
        var x: u32 = 0;
        while (x < im.w) : (x += 1) {
            const bit = (src[y * stride + x / 8] >> @intCast(7 - (x % 8))) & 1;
            const masked = if (im.flip == 1) bit == 0 else bit == 1;
            dst[@as(usize, y) * im.w + x] = if (masked) 0 else 255;
        }
    }
    const slot2 = img.n;
    imgs.all()[slot2] = .{
        .name_len = 0, .name = undefined, .kind = 2, .w = im.w, .h = im.h,
        .off = img.used, .len = @intCast(px), .flip = 0, .smask = 0,
    };
    img.n += 1;
    img.used += @intCast((px + 3) & ~@as(usize, 3));
    return slot2;
}

/// 색 키 가리개 — 범위에 든 화소를 투명으로 만드는 알파 판을 새 칸에 짓는다.
fn colorKeyMask(slot: u32, lo: []const u32, hi: []const u32) void {
    if (slot >= img.n or !imgs.room(img.n + 1)) return;
    const im = imgs.all()[slot];
    const px = @as(usize, im.w) * im.h;
    if (px == 0 or px > img.cap - img.used) return;
    const comps: u32 = if (im.kind == 1) 3 else 1;
    if (lo.len < comps) return;
    const src = @as([*]const u8, @ptrFromInt(imgArea() + im.off));
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img.used));
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
    imgs.all()[img.n] = .{
        .name_len = 0, .name = undefined, .kind = 2, .w = im.w, .h = im.h,
        .off = img.used, .len = @intCast(px), .flip = 0, .smask = 0,
    };
    imgs.all()[slot].smask = @intCast(img.n + 1);
    img.n += 1;
    img.used += @intCast((px + 3) & ~@as(usize, 3));
}

/// JPEG 칸을 엔진 안에서 풀어 RGB 칸을 새로 만든다. 새 칸 번호, 못 풀면 -1.
///
/// 브라우저에서는 브라우저가 JPEG 을 풀어 주므로 이 길로 오지 않는다.
/// Node 처럼 풀어 줄 사람이 없는 자리에서만 부른다 — 그러지 않으면 스캔
/// 문서가 흰 종이로 나온다. 베이스라인과 프로그레시브를 다 푼다.
export fn jpegToRgb(i: u32) i32 {
    if (i >= img.n) return -1;
    const im = imgs.all()[i];
    if (im.kind != 3 or im.w == 0 or im.h == 0) return -1;
    const px = @as(usize, im.w) * im.h;
    const need = px * 3;
    if (need + 4096 > img.cap - img.used) return -1;
    if (!imgs.room(img.n + 1)) return -1;
    const src = @as([*]const u8, @ptrFromInt(imgArea() + im.off))[0..im.len];
    const dst = @as([*]u8, @ptrFromInt(imgArea() + img.used))[0..need];
    // 성분마다 부표본 화소를 담을 자리. 프로그레시브는 계수를 다 들고
    // 있어야 해서 더 든다 — 화소당 여섯에 여유를 얹는다.
    const tmp = bigScratch(px * 6 + 4 * 1024 * 1024) orelse return -1;
    const got = jpeg.decodeAny(src, dst, tmp);
    if (got == 0) return -1;
    const slot = img.n;
    imgs.all()[slot] = .{
        .name_len = 0, .name = undefined, .kind = 1, .w = im.w, .h = im.h,
        .off = img.used, .len = @intCast(need), .flip = 0, .smask = im.smask,
    };
    img.n += 1;
    img.used += @intCast((need + 3) & ~@as(usize, 3));
    return @intCast(slot);
}

/// CMYK 화소를 제자리에서 RGB 로 편다. 편 바이트 수.
///
/// 프로파일이 있으면 그걸로 옮긴다. 화소마다 곡선·격자표를 다 타면 느리므로
/// (300만 화소면 억 단위 셈이다) 17^4 짜리 표를 한 번 만들어 두고 그 표에서
/// 사이값을 읽는다 — 비싼 일은 83,521 번만 하고 화소마다는 값만 섞는다.
/// CMYK 하나를 RGB 로 옮긴다 (0~1).
///
/// 규격(§8.6.4.4)이 적어 둔 셈은 R = 1 - min(1, C+K) 인데, 그대로 쓰면 시안이
/// (0,255,255) 네온으로 나온다. 잉크로 찍은 시안은 그런 색이 아니다 — 실제
/// 뷰어는 다들 코팅지 인쇄를 맞춘 근사를 쓴다.
///
/// 여기 쓴 이차식은 pdf.js 것이다(Apache-2.0, THIRD-PARTY-NOTICES.md 참고).
/// 박힌 ICC 프로파일이 있으면 그쪽이 먼저다 — 이건 프로파일이 없을 때다.
pub fn cmykRgb(c: f32, m: f32, y: f32, k: f32, out: *[3]f32) void {
    const r = 255 +
        c * (-4.387332384609988 * c + 54.48615194189176 * m + 18.82290502165302 * y +
            212.25662451639585 * k - 285.2331026137004) +
        m * (1.7149763477362134 * m - 5.6096736904047315 * y - 17.873870861415444 * k -
            5.497006427196366) +
        y * (-2.5217340131683033 * y - 21.248923337353073 * k + 17.5119270841813) +
        k * (-21.86122147463605 * k - 189.48180835922747);
    const g = 255 +
        c * (8.841041422036149 * c + 60.118027045597366 * m + 6.871425592049007 * y +
            31.159100130055922 * k - 79.2970844816548) +
        m * (-15.310361306967817 * m + 17.575251261109482 * y + 131.35250912493976 * k -
            190.9453302588951) +
        y * (4.444339102852739 * y + 9.8632861493405 * k - 24.86741582555878) +
        k * (-20.737325471181034 * k - 187.80453709719578);
    const b = 255 +
        c * (0.8842522430003296 * c + 8.078677503112928 * m + 30.89978309703729 * y -
            0.23883238689178934 * k - 14.183576799673286) +
        m * (10.49593273432072 * m + 63.02378494754052 * y + 50.606957656360734 * k -
            112.23884253719248) +
        y * (0.03296041114873217 * y + 115.60384449646641 * k - 193.58209356861505) +
        k * (-22.33816807309886 * k - 180.12613974708367);
    out[0] = @max(0, @min(1, r / 255));
    out[1] = @max(0, @min(1, g / 255));
    out[2] = @max(0, @min(1, b / 255));
}

fn cmykToRgb(dst: [*]u8, n_px: usize, ix: i32, invert: bool) u32 {
    const G: usize = 17;
    var lut: []u8 = &[_]u8{};
    if (ix >= 0) {
        if (iccLut(ix, G)) |t| lut = t;
    }
    var i: usize = 0;
    while (i < n_px) : (i += 1) {
        const s0 = i * 4;
        var c: f32 = @as(f32, @floatFromInt(dst[s0])) / 255.0;
        var m: f32 = @as(f32, @floatFromInt(dst[s0 + 1])) / 255.0;
        var y: f32 = @as(f32, @floatFromInt(dst[s0 + 2])) / 255.0;
        var k: f32 = @as(f32, @floatFromInt(dst[s0 + 3])) / 255.0;
        if (invert) { c = 1 - c; m = 1 - m; y = 1 - y; k = 1 - k; }
        var r: u8 = 0;
        var g: u8 = 0;
        var b2: u8 = 0;
        if (lut.len > 0) {
            var rgb: [3]f32 = .{ 0, 0, 0 };
            lutLookup(lut, G, c, m, y, k, &rgb);
            r = @intFromFloat(@max(0, @min(255, rgb[0] * 255)));
            g = @intFromFloat(@max(0, @min(255, rgb[1] * 255)));
            b2 = @intFromFloat(@max(0, @min(255, rgb[2] * 255)));
        } else {
            var rgb2: [3]f32 = .{ 0, 0, 0 };
            cmykRgb(c, m, y, k, &rgb2);
            r = @intFromFloat(@max(0, @min(255, rgb2[0] * 255)));
            g = @intFromFloat(@max(0, @min(255, rgb2[1] * 255)));
            b2 = @intFromFloat(@max(0, @min(255, rgb2[2] * 255)));
        }
        const d0 = i * 3;
        dst[d0] = r;
        dst[d0 + 1] = g;
        dst[d0 + 2] = b2;
    }
    return @intCast(n_px * 3);
}

var luts: struct {
    /// 프로파일마다 만들어 두는 CMYK→RGB 표 (17^4 × 3바이트 ≈ 250KB)
    at: usize = 0,
    cap: u32 = 0,
    /// 이 표가 어느 프로파일 것인가
    of: i32 = -1,
} = .{};
fn iccLut(ix: i32, g: usize) ?[]u8 {
    const need: u32 = @intCast(g * g * g * g * 3);
    if (luts.of == ix and luts.at != 0) {
        return @as([*]u8, @ptrFromInt(luts.at))[0..need];
    }
    if (!growTable(&luts.at, &luts.cap, need, 1, need)) return null;
    const t = @as([*]u8, @ptrFromInt(luts.at))[0..need];
    var idx: usize = 0;
    var ci: usize = 0;
    while (ci < g) : (ci += 1) {
        var mi: usize = 0;
        while (mi < g) : (mi += 1) {
            var yi: usize = 0;
            while (yi < g) : (yi += 1) {
                var ki: usize = 0;
                while (ki < g) : (ki += 1) {
                    const inv: f32 = @floatFromInt(g - 1);
                    const in = [_]f32{
                        @as(f32, @floatFromInt(ci)) / inv,
                        @as(f32, @floatFromInt(mi)) / inv,
                        @as(f32, @floatFromInt(yi)) / inv,
                        @as(f32, @floatFromInt(ki)) / inv,
                    };
                    var rgb: [3]f32 = .{ 0, 0, 0 };
                    if (!iccToRgb(ix, &in, &rgb)) return null;
                    t[idx] = @intFromFloat(@max(0, @min(255, rgb[0] * 255)));
                    t[idx + 1] = @intFromFloat(@max(0, @min(255, rgb[1] * 255)));
                    t[idx + 2] = @intFromFloat(@max(0, @min(255, rgb[2] * 255)));
                    idx += 3;
                }
            }
        }
    }
    luts.of = ix;
    return t;
}

/// 만들어 둔 표에서 사이값을 읽는다 (모서리 열여섯 개를 무게로 섞는다)
fn lutLookup(t: []const u8, g: usize, c: f32, m: f32, y: f32, k: f32, out: *[3]f32) void {
    const gf: f32 = @floatFromInt(g - 1);
    const v = [_]f32{
        @max(0, @min(1, c)) * gf, @max(0, @min(1, m)) * gf,
        @max(0, @min(1, y)) * gf, @max(0, @min(1, k)) * gf,
    };
    var lo: [4]usize = undefined;
    var fr: [4]f32 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const f0 = @floor(v[i]);
        lo[i] = @min(g - 1, @as(usize, @intFromFloat(f0)));
        fr[i] = v[i] - f0;
    }
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    var corner: u32 = 0;
    while (corner < 16) : (corner += 1) {
        var wgt: f32 = 1;
        var idx: usize = 0;
        var d: u3 = 0;
        while (d < 4) : (d += 1) {
            const up = (corner >> d) & 1 == 1;
            const at = if (up) @min(g - 1, lo[d] + 1) else lo[d];
            wgt *= if (up) fr[d] else 1 - fr[d];
            idx = idx * g + at;
        }
        if (wgt == 0) continue;
        const cell = idx * 3;
        if (cell + 2 >= t.len) continue;
        out[0] += wgt * @as(f32, @floatFromInt(t[cell])) / 255.0;
        out[1] += wgt * @as(f32, @floatFromInt(t[cell + 1])) / 255.0;
        out[2] += wgt * @as(f32, @floatFromInt(t[cell + 2])) / 255.0;
    }
}

fn findImg(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < img.n) : (i += 1)
        if (txEq(imgs.all()[i].name[0..imgs.all()[i].name_len], name)) return @intCast(i);
    return -1;
}

export fn itemCount() u32 { return item_n; }
export fn imageCount() u32 { return draw_count; }
export fn formCount() u32 { return formn.n; }
export fn imageWidth() u32 { return img.w; }
export fn imageHeight() u32 { return img.h; }
export fn imageKind() u32 { return img.kind; }
export fn imagePtr() usize { return (if (img.off == 0) heapBase() else img.off) + img.off_first; }
export fn imageAreaPtr() usize { return if (img.off == 0) heapBase() else img.off; }
export fn imageLen() usize { return img.len; }
export fn itemX(i: u32) f32 { return items.all()[i].x; }
export fn itemY(i: u32) f32 { return items.all()[i].y; }
export fn itemSize(i: u32) f32 { return items.all()[i].size; }
export fn itemOff(i: u32) u32 { return items.all()[i].off; }
/// 이 항목을 그린 글꼴 번호(1부터, 없으면 0). 이름은 fontNamePtr 로 읽는다.
export fn itemFont(i: u32) u32 {
    if (i >= item_n or items.all()[i].font < 0) return 0;
    return @as(u32, @intCast(items.all()[i].font)) + 1;
}
/// 세로쓰기 글꼴로 그렸나 — pdf.js 의 dir === "ttb" 자리다.
export fn itemVertical(i: u32) u32 { return if (i < item_n and items.all()[i].vert) 1 else 0; }
export fn itemLen(i: u32) u32 { return items.all()[i].len; }
export fn textPtr() [*]u8 { return if (text.items.at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(text.items.at); }
export fn textLen() u32 { return text.n; }
export fn drawPtr() [*]u8 { return if (dtext.items.at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(dtext.items.at); }
export fn drawLen() u32 { return dtext.n; }
export fn readPtr() [*]u8 { return if (rtext.items.at == 0) @ptrFromInt(heapBase()) else @ptrFromInt(rtext.items.at); }
export fn readLen() u32 { return rtext.n; }
export fn fontIsPua(i: u32) u32 { return if (i < fontarea.n and fonts.all()[i].pua) 1 else 0; }
export fn fontKind(i: u32) u32 {
    if (i >= fontarea.n) return 0;
    const f = &fonts.all()[i];
    var k: u32 = f.kind;
    if (f.identity) k |= 1;
    if (f.pua) k |= 2;
    if (f.file_len > 0) k |= 4;
    if (f.n > 0) k |= 8;
    return k;
}
export fn fontNamePtr(i: u32) [*]const u8 {
    return if (i < fontarea.n) &fonts.all()[i].name else &fonts.all()[0].name;
}
export fn fontNameLen(i: u32) u32 { return if (i < fontarea.n) fonts.all()[i].name_len else 0; }
export fn fontGlyphs(i: u32) u32 { return if (i < fontarea.n) fonts.all()[i].wn else 0; }
export fn fontCount() u32 { return fontarea.n; }
export fn fontFileOff(i: u32) u32 { return if (i < fontarea.n) fonts.all()[i].file_off else 0; }
export fn fontFileLen(i: u32) u32 { return if (i < fontarea.n) fonts.all()[i].file_len else 0; }
export fn fontAreaPtr() usize { return if (fontarea.off == 0) heapBase() else fontarea.off; }
export fn inlinePtr() usize { return if (inl.off == 0) heapBase() else inl.off; }
export fn pageOriginX() f32 { return cpage.x0; }
export fn pageOriginY() f32 { return cpage.y0; }
export fn pageRotate() i32 { return cpage.rotate; }
export fn pageWidth() f32 { return cpage.w; }
export fn pageHeight() f32 { return cpage.h; }

pub fn isDigit(c: u8) bool { return c >= '0' and c <= '9'; }
pub fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

pub fn txEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| if (c != b[i]) return false;
    return true;
}
pub fn findIn(h: []const u8, n: []const u8, from: usize) ?usize {
    if (n.len == 0 or n.len > h.len) return null;
    var i = from;
    while (i + n.len <= h.len) : (i += 1) if (txEq(h[i .. i + n.len], n)) return i;
    return null;
}

pub fn readFloat(b: []const u8, p: *usize) f32 {
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
    if (!rtext.items.room(rtext.n + 8)) return;
    if (cp < 0x80) {
        rtext.items.all()[rtext.n] = @intCast(cp);
        rtext.n += 1;
    } else if (cp < 0x800) {
        rtext.items.all()[rtext.n] = @intCast(0xC0 | (cp >> 6));
        rtext.items.all()[rtext.n + 1] = @intCast(0x80 | (cp & 0x3F));
        rtext.n += 2;
    } else {
        rtext.items.all()[rtext.n] = @intCast(0xE0 | (cp >> 12));
        rtext.items.all()[rtext.n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        rtext.items.all()[rtext.n + 2] = @intCast(0x80 | (cp & 0x3F));
        rtext.n += 3;
    }
}

/// UTF-8 로 한 글자 쓴다
fn putDraw(cp: u32) void {
    if (!dtext.items.room(dtext.n + 8)) return;
    if (cp < 0x80) {
        dtext.items.all()[dtext.n] = @intCast(cp);
        dtext.n += 1;
    } else if (cp < 0x800) {
        dtext.items.all()[dtext.n] = @intCast(0xC0 | (cp >> 6));
        dtext.items.all()[dtext.n + 1] = @intCast(0x80 | (cp & 0x3F));
        dtext.n += 2;
    } else {
        dtext.items.all()[dtext.n] = @intCast(0xE0 | (cp >> 12));
        dtext.items.all()[dtext.n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dtext.items.all()[dtext.n + 2] = @intCast(0x80 | (cp & 0x3F));
        dtext.n += 3;
    }
}

fn putUtf8(cp: u32) void {
    if (!text.items.room(text.n + 8)) return;
    if (cp < 0x80) {
        text.items.all()[text.n] = @intCast(cp);
        text.n += 1;
    } else if (cp < 0x800) {
        text.items.all()[text.n] = @intCast(0xC0 | (cp >> 6));
        text.items.all()[text.n + 1] = @intCast(0x80 | (cp & 0x3F));
        text.n += 2;
    } else {
        text.items.all()[text.n] = @intCast(0xE0 | (cp >> 12));
        text.items.all()[text.n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        text.items.all()[text.n + 2] = @intCast(0x80 | (cp & 0x3F));
        text.n += 3;
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
            f.codes.all()[f.n] = @truncate(src);
            f.unis.all()[f.n] = @truncate(dst);
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
                f.codes.all()[f.n] = @truncate(c);
                f.unis.all()[f.n] = @truncate(dst + (c - lo));
                f.n += 1;
            }
        }
        at = end + 1;
    }
}

fn mapCode(byte: u8) u32 {
    if (cur.font >= 0 and fonts.all()[@intCast(cur.font)].n > 0)
        return lookup(&fonts.all()[@intCast(cur.font)], byte);
    return byte;
}
fn mapCode2(code: u32) u32 {
    if (cur.font >= 0) return lookup(&fonts.all()[@intCast(cur.font)], code);
    return code;
}

fn lookup(f: *const FontMap, code: u32) u32 {
    var i: u16 = 0;
    while (i < f.n) : (i += 1) if (f.codes.all()[i] == code) return f.unis.all()[i];
    // 표에 없으면 코드를 그대로 본다 (라틴 폰트는 대개 맞는다)
    return code;
}

fn resetPage(w: f32, h: f32) void {
    subcReset();
    t3cReset();
    item_n = 0;
    text.n = 0;
    dtext.n = 0;
    rtext.n = 0;
    cur.alpha = 1;
    cur.bm = 0;
    draw_count = 0;
    formn.n = 0;
    formn.n2 = 0;
    gs_n = 0;
    cs_n = 0;
    shade_n = 0;
    tile_n = 0;
    prop_n = 0;
    img.n = 0;
    emit_mute = false;
    trun.on = false;
    pdfform.field_n = 0;
    pdfform.fld_used = 0;
    iccs.n = 0;
    iccs.data_used = 0;
    luts.of = -1;
    img.used = 0;
    inl.used = 0;
    ops.n = 0;
    fontarea.n = 0;
    fontarea.used = 0;
    c2g.used = 0;
    fnReset();
    cur.font = -1;
    cpage.w = w;
    cpage.h = h;
}

/// 코드→유니코드 짝을 want 개까지 담을 자리를 마련한다.
pub fn mapRoom(f: *FontMap, want: u32) bool {
    return f.codes.room(want) and
        f.unis.room(want);
}
/// 글자 폭 표도 같은 식으로.
fn widthRoom(f: *FontMap, want: u32) bool {
    return f.wcodes.room(want) and
        f.wvals.room(want);
}

/// 폰트 하나를 등록한다. cmap 이 비어 있으면 코드=유니코드로 본다.
fn addFont(name: [*]const u8, name_len: u32, cmap: [*]const u8, cmap_len: u32) void {
    if (!fonts.room(fontarea.n + 1)) return;
    const f = &fonts.all()[fontarea.n];
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
    fontarea.n += 1;
}

fn selectFont(name: []const u8) void {
    var i: u8 = 0;
    while (i < fontarea.n) : (i += 1) {
        if (txEq(fonts.all()[i].name[0..fonts.all()[i].name_len], name)) {
            cur.font = i;
            return;
        }
    }
    cur.font = -1;
}

/// 문자열 하나를 항목으로 남긴다.
fn emit(x: f32, y: f32, size: f32, start: u32) void {
    if (!items.room(item_n + 1) or text.n <= start) return;
    // CTM 을 적용한 좌표는 PDF 기준(아래가 원점)이므로 캔버스 기준으로 뒤집는다.
    // 다만 문서가 이미 위 기준으로 그리는 경우(세로 배율 음수)는 그대로 둔다.
    const cy = if (y > cpage.h or y < 0) y else cpage.h - y;
    items.all()[item_n] = .{
        .x = x, .y = cy, .size = size, .off = start, .len = text.n - start,
        .font = cur.font,
        .vert = cur.font >= 0 and fonts.all()[@intCast(cur.font)].vertical,
    };
    item_n += 1;
}

/// 콘텐츠 스트림을 훑어 글자와 위치를 모은다.
/// 2×3 아핀 행렬. PDF 의 [a b c d e f] 순서를 그대로 쓴다.
pub const Mat = struct {
    a: f32 = 1, b: f32 = 0, c: f32 = 0, d: f32 = 1, e: f32 = 0, f: f32 = 0,
};

/// m 을 n 에 이어 붙인다 (m 먼저, 그 다음 n).
pub fn matMul(m: Mat, n: Mat) Mat {
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
    if (need == 0 or inl.used + need > inl.cap) return;

    const dst = @as([*]u8, @ptrFromInt(inlArea() + inl.used))[0..(inl.cap - inl.used)];
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
        @floatFromInt(inl.used), @floatFromInt(need),
        if (flip) 1 else 0, @floatFromInt(comps),
    });
    inl.used += need;
}


/// 겹쳐 부르는 스트림을 담을 자리. 깊이마다 따로 둔다 — 같은 자리를 쓰면
/// 바깥에서 훑던 내용이 안쪽에서 덮인다.
/// 같은 스트림을 되풀이해 푸는 자리를 위한 쪽 단위 곳간.
///
/// Type3 글꼴은 글리프 하나하나가 작은 그리기 프로그램이다. 그래서 글자를
/// 찍을 때마다 그 스트림을 찾아 풀어야 하는데, 인쇄물 한 쪽에 글자가 수천이면
/// subStream 도 수천 번 불린다. 글리프 그림은 몇십 바이트짜리인데 그때마다
/// 객체를 뒤지고 필터를 풀고 옮긴다 — 여섯 쪽 문서 그리는 값의 절반이 여기서
/// 났다(46ms 중 23ms).
///
/// 쓰는 글리프는 글꼴 하나에 많아야 256 가지고, 그것이 수천 번 되풀이된다.
/// 그러니 한 번 푼 것을 들고 있으면 된다. 쪽마다 비우므로 문서가 바뀌어도
/// 묵은 것을 내주지 않는다.
/// 인쇄물 한 쪽이 글꼴 아흔 벌을 쓰기도 한다. 넉넉히 잡아 둔다.
const SUBC_N = 4096;
/// 한 칸에 담을 수 있는 크기. 글리프 그림은 이보다 훨씬 작다.
const SUBC_MAX = 4096;
const SUBC_POOL = 2 * 1024 * 1024;
var subc: struct {
    num: [SUBC_N]u32 = undefined,
    off: [SUBC_N]u32 = undefined,
    len: [SUBC_N]u32 = undefined,
    n: u32 = 0,
    used: u32 = 0,
    at: usize = 0,
} = .{};

fn subcPool() []u8 {
    if (subc.at == 0) {
        subc.at = zoneAlloc(SUBC_POOL) orelse 0;
        if (subc.at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(subc.at))[0..SUBC_POOL];
}

/// 쪽을 새로 그릴 때 비운다. 구역이 되감겼으면 곳간도 남의 자리다.
fn subcReset() void {
    subc.n = 0;
    subc.used = 0;
    if (subc.at != 0 and subc.at + SUBC_POOL > zoneTop()) subc.at = 0;
}

fn subcFind(num: u32) ?[]const u8 {
    var i: u32 = 0;
    while (i < subc.n) : (i += 1) {
        if (subc.num[i] == num) {
            const pool = subcPool();
            if (pool.len == 0) return null;
            return pool[subc.off[i]..][0..subc.len[i]];
        }
    }
    return null;
}

fn subcPut(num: u32, data: []const u8) void {
    if (subc.n >= SUBC_N or data.len > SUBC_MAX) return;
    const pool = subcPool();
    if (pool.len == 0 or subc.used + data.len > pool.len) return;
    @memcpy(pool[subc.used..][0..data.len], data);
    subc.num[subc.n] = num;
    subc.off[subc.n] = subc.used;
    subc.len[subc.n] = @intCast(data.len);
    subc.n += 1;
    subc.used += @intCast(data.len);
}

/// 글리프가 낸 그리기 명령을 받아 적어 두고 그대로 다시 쓴다.
///
/// 글리프 프로그램은 앞뒤로 행렬을 쌓았다 무르는 사이에서 돈다(14/16/16/16 …
/// 15). 그래서 글리프가 내는 명령 자체는 글자가 어디에 놓이든 똑같다 —
/// 자리와 크기는 앞의 행렬이 지고 간다. 한 번 받아 적어 두면 그다음부터는
/// 프로그램을 다시 읽을 것 없이 옮겨 붙이면 된다.
///
/// 다만 "늘 똑같다" 가 참이어야 한다. 글리프가 그림이나 글자를 품고 있으면
/// 명령 안에 그림 번호·글자 자리 같은 그때그때 값이 섞여 들어가 참이 아니다.
/// 그래서 처음 그릴 때 셈들을 앞뒤로 견줘, 하나라도 움직였으면 그 글리프는
/// 받아 적지 않고 늘 프로그램을 돌린다.
const T3C_N = 1024;
/// 글리프 하나가 낼 수 있는 명령 수. 넘으면 받아 적지 않는다.
const T3C_MAX = 1024;
const T3C_POOL = 1024 * 1024;
var t3c: struct {
    num: [T3C_N]u32 = undefined,
    off: [T3C_N]u32 = undefined,
    len: [T3C_N]u32 = undefined,
    /// 받아 적을 수 없다고 판가름 난 글리프
    ban: [T3C_N]bool = undefined,
    n: u32 = 0,
    used: u32 = 0,
    at: usize = 0,
} = .{};

fn t3cPool() []f32 {
    if (t3c.at == 0) {
        t3c.at = zoneAlloc(T3C_POOL) orelse 0;
        if (t3c.at == 0) return &[_]f32{};
    }
    return @as([*]f32, @ptrFromInt(t3c.at))[0 .. T3C_POOL / 4];
}

fn t3cReset() void {
    t3c.n = 0;
    t3c.used = 0;
    if (t3c.at != 0 and t3c.at + T3C_POOL > zoneTop()) t3c.at = 0;
}

/// 글리프를 그리는 동안 움직이면 안 되는 셈들.
const T3Snap = struct {
    item: u32, text: u32, dtext: u32, rtext: u32,
    draw: u32, form: u32, form2: u32, gs: u32,
    font: i32, alpha: f32, bm: i32, run: bool,
};

fn t3Snap() T3Snap {
    return .{
        .item = item_n, .text = text.n, .dtext = dtext.n, .rtext = rtext.n,
        .draw = draw_count, .form = formn.n, .form2 = formn.n2, .gs = gs_n,
        .font = cur.font, .alpha = cur.alpha, .bm = cur.bm, .run = trun.on,
    };
}

fn t3SnapEq(a: T3Snap) bool {
    const b2 = t3Snap();
    return a.item == b2.item and a.text == b2.text and a.dtext == b2.dtext and
        a.rtext == b2.rtext and a.draw == b2.draw and a.form == b2.form and
        a.form2 == b2.form2 and a.gs == b2.gs and a.font == b2.font and
        a.alpha == b2.alpha and a.bm == b2.bm and a.run == b2.run;
}

/// 받아 적어 둔 자리를 찾는다. 못 적는다고 판가름 난 것은 null 을 준다.
fn t3Find(num: u32) ?u32 {
    var i: u32 = 0;
    while (i < t3c.n) : (i += 1) {
        if (t3c.num[i] == num) return if (t3c.ban[i] or t3c.len[i] == 0) null else i;
    }
    return null;
}

fn t3Slot(num: u32) ?u32 {
    var i: u32 = 0;
    while (i < t3c.n) : (i += 1) if (t3c.num[i] == num) return i;
    if (t3c.n >= T3C_N) return null;
    t3c.num[t3c.n] = num;
    t3c.off[t3c.n] = 0;
    t3c.len[t3c.n] = 0;
    t3c.ban[t3c.n] = false;
    t3c.n += 1;
    return t3c.n - 1;
}

fn t3Replay(i: u32) void {
    const pool = t3cPool();
    const n = t3c.len[i];
    if (pool.len == 0 or n == 0) return;
    if (!ops.items.room(ops.n + n)) return;
    @memcpy(ops.items.all()[ops.n..][0..n], pool[t3c.off[i]..][0..n]);
    ops.n += n;
}

/// 방금 낸 명령을 받아 적는다. 셈이 움직였으면 못 적는 것으로 표시한다.
fn t3Record(num: u32, start: u32, snap: T3Snap) void {
    const i = t3Slot(num) orelse return;
    if (t3c.ban[i] or t3c.len[i] != 0) return;
    if (emit_mute or ops.n <= start or !t3SnapEq(snap)) {
        t3c.ban[i] = true;
        return;
    }
    const n = ops.n - start;
    const pool = t3cPool();
    if (n > T3C_MAX or pool.len == 0 or t3c.used + n > pool.len) {
        t3c.ban[i] = true;
        return;
    }
    @memcpy(pool[t3c.used..][0..n], ops.items.all()[start..][0..n]);
    t3c.off[i] = t3c.used;
    t3c.len[i] = n;
    t3c.used += n;
}

pub fn subStream(num: u32, depth: u32) ?[]const u8 {
    if (depth >= 3 or subArea() == 0) return null;
    if (subcFind(num)) |s| return s;
    const slot = subs.cap / 3;
    const cs = streamOf(doc.items, num) orelse return null;
    const n = @min(cs.len, slot);
    const dst = @as([*]u8, @ptrFromInt(subArea() + depth * slot));
    @memcpy(dst[0..n], cs[0..n]);
    subcPut(num, dst[0..n]);
    return dst[0..n];
}

pub fn runOps(b: []const u8, depth: u32) void {
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
            const fp: ?*const FontMap = if (cur.font >= 0) &fonts.all()[@intCast(cur.font)] else null;
            const start_text = text.n;
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
                        if (g.t1 and code < 256 and pdft1.t1_pool[g.t1_cs + code].len > 0) {
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
                            const gnum = g.t3[code];
                            // 받아 적어 둔 것이 있으면 프로그램을 다시 읽지 않는다
                            const rec = t3Find(gnum);
                            const gs_opt = if (rec == null) subStream(gnum, dep) else null;
                            if (rec != null or gs_opt != null) {
                                runFlush();
                                emitOp(14, &[_]f32{});
                                emitOp(16, &[_]f32{ m.a, m.b, m.c, m.d, ex2, ey2 });
                                emitOp(16, &[_]f32{ size * th2, 0, 0, size, 0, 0 });
                                emitOp(16, &[_]f32{ g.fm[0], g.fm[1], g.fm[2], g.fm[3], g.fm[4], g.fm[5] });
                                if (rec) |r| {
                                    t3Replay(r);
                                } else {
                                    const snap = t3Snap();
                                    const start = ops.n;
                                    runOps(gs_opt.?, dep + 1);
                                    t3Record(gnum, start, snap);
                                }
                                emitOp(15, &[_]f32{});
                                m.* = advance(ff, adv, m.*);
                                return;
                            }
                        }
                    }
                    // 이어지는 글자는 한 묶음으로 모은다. 글꼴·크기·기울기·
                    // 그리기 방식이 바뀌면 거기서 끊는다.
                    if (trun.on and (trun.font != cf or trun.size != size or trun.mode != mode or
                        trun.m[0] != m.a or trun.m[1] != m.b or trun.m[2] != m.c or trun.m[3] != m.d))
                    {
                        runFlush();
                    }
                    if (!trun.on) {
                        trun.on = true;
                        trun.x = ex2;
                        trun.y = ey2;
                        trun.size = size;
                        trun.m = .{ m.a, m.b, m.c, m.d };
                        trun.off = dtext.n;
                        trun.roff = rtext.n;
                        trun.adv = 0;
                        trun.font = cf;
                        trun.mode = mode;
                    }
                    // 사용자 영역은 U+E000~U+F8FF 6400 자리뿐이다
                    // 번호로 집는 글꼴은 CID 가 아니라 글리프 번호로 집는다
                    const gid = if (ff) |g| cidToGid(g, code) else code;
                    const pua = if (ff) |g| g.pua and gid < 6400 else false;
                    putDraw(if (pua) 0xE000 + gid else uni);
                    // 글자층은 읽을 수 있는 쪽을 쓴다. 되찾지 못한 글자는
                    // 자리만 지키게 빈칸으로 둔다 — 안 그러면 뒤 글자가 밀린다.
                    putRead(if (uni >= 0x20 and uni != 0xFFFD) uni else ' ');
                    trun.adv += adv;
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
                    emitGlyph(fp, cid, uni, tf_size, &tm, cur.font, tc, tw, th, depth, t_render, t_rise);
                    k += w;
                }
            }
            runFlush();
            // 뽑아 둔 글자는 문자열 단위로 묶는다 — 나중에 본문 검색에 쓴다
            if (text.n > start_text and items.room(item_n + 1)) {
                items.all()[item_n] = .{
                    .x = x0, .y = y0, .size = tf_size,
                    .off = start_text, .len = text.n - start_text,
                    // 어떤 글꼴로 그렸는지·세로쓰기인지도 함께 남긴다
                    .font = cur.font,
                    .vert = cur.font >= 0 and fonts.all()[@intCast(cur.font)].vertical,
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
            var rgb4: [3]f32 = .{ 0, 0, 0 };
            cmykRgb(st[0], st[1], st[2], st[3], &rgb4);
            emitOp(11, &[_]f32{ rgb4[0], rgb4[1], rgb4[2] });
        }
        else if (eqs(op, "K") and sp >= 4) {
            var rgb4: [3]f32 = .{ 0, 0, 0 };
            cmykRgb(st[0], st[1], st[2], st[3], &rgb4);
            emitOp(12, &[_]f32{ rgb4[0], rgb4[1], rgb4[2] });
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
            if (si >= 0) emitShade(&shades.all()[@intCast(si)], 27);
        }
        else if (eqs(op, "cs") or eqs(op, "CS")) {
            const ci = findCs(name_buf[0..name_len]);
            const stroke = op[0] == 'C';
            if (stroke) cur_cs_s = ci else cur_cs_f = ci;
            // 색 공간을 바꾸면 색은 검정(또는 첫 성분 0)으로 되돌아간다
            const k = if (ci >= 0) cspaces.all()[@intCast(ci)].kind else CS_RGB;
            if (k != CS_PATTERN) emitOp(if (stroke) 12 else 11, &[_]f32{ 0, 0, 0 });
        }
        else if (eqs(op, "sc") or eqs(op, "scn") or eqs(op, "SC") or eqs(op, "SCN")) {
            const stroke = op[0] == 'S';
            const ci = if (stroke) cur_cs_s else cur_cs_f;
            const kind: u8 = if (ci >= 0) cspaces.all()[@intCast(ci)].kind else CS_RGB;
            var r: f32 = 0;
            var g2: f32 = 0;
            var b3: f32 = 0;
            var ok = true;
            if (kind == CS_PATTERN or sp == 0) {
                const si = findShade(name_buf[0..name_len]);
                if (si >= 0 and !stroke) {
                    // 셰이딩 무늬 — 채우기 색 대신 그라데이션을 건다
                    emitShade(&shades.all()[@intCast(si)], 28);
                    sp = 0;
                    continue;
                }
                const ti = findTile(name_buf[0..name_len]);
                if (ti >= 0) {
                    if (!stroke and tiles.all()[@intCast(ti)].obj != 0 and depth < 2) {
                        pending_tile = ti;
                    }
                    r = tiles.all()[@intCast(ti)].r;
                    g2 = tiles.all()[@intCast(ti)].g;
                    b3 = tiles.all()[@intCast(ti)].b;
                } else {
                    r = 0.6;
                    g2 = 0.6;
                    b3 = 0.6;
                }
            } else if (ci >= 0 and cspaces.all()[@intCast(ci)].icc >= 0 and
                sp >= cspaces.all()[@intCast(ci)].comps)
            {
                // 프로파일이 있으면 그대로 옮긴다 — 단순식보다 훨씬 맞는다
                const cs2 = cspaces.all()[@intCast(ci)];
                var rgb: [3]f32 = .{ 0, 0, 0 };
                const from = sp - cs2.comps;
                if (iccToRgb(cs2.icc, st[from..sp], &rgb)) {
                    r = rgb[0];
                    g2 = rgb[1];
                    b3 = rgb[2];
                } else {
                    ok = false;
                }
            } else if (sp >= 4) {
                const cy = st[sp - 4];
                const m = st[sp - 3];
                const y2 = st[sp - 2];
                const k2 = st[sp - 1];
                var rgb5: [3]f32 = .{ 0, 0, 0 };
                cmykRgb(cy, m, y2, k2, &rgb5);
                r = rgb5[0];
                g2 = rgb5[1];
                b3 = rgb5[2];
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
                const g2 = &gstates.all()[@intCast(gi)];
                if (g2.ca >= 0) { emitOp(21, &[_]f32{g2.ca}); cur.alpha = g2.ca; }
                if (g2.CA >= 0) emitOp(23, &[_]f32{g2.CA});
                if (g2.lw >= 0) emitOp(13, &[_]f32{g2.lw});
                if (g2.bm >= 0) { emitOp(26, &[_]f32{@floatFromInt(g2.bm)}); cur.bm = g2.bm; }
                if (g2.sm_off) emitOp(32, &[_]f32{});
                if (g2.sm_obj != 0 and depth < 2) emitSMask(doc.items, g2, depth);
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
                const fo = &forms.all()[@intCast(fi)];
                // 투명 그룹은 통째로 딴 판에 그려 한 번에 겹친다. 안 그러면
                // 겹친 것끼리 각자 투명해져 겹친 데가 더 진해진다.
                const grp = fo.group and (cur.alpha < 0.999 or cur.bm > 0);
                if (grp) emitOp(33, &[_]f32{ cur.alpha, @floatFromInt(cur.bm) });
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
pub fn inheritedKey(b: []const u8, body0: usize, end0: usize, key: []const u8) ?Inh {
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
/// 무늬 칸을 그리는 명령에서 대표 색을 하나 집어 낸다. 첫 ` rg` 바로 앞의
/// 숫자 셋을 본다 — 무늬를 실제로 그리지 못할 때 그 색으로 메운다.
/// 셋을 못 모으면 null 이다(그때는 부르는 쪽이 기본 회색을 쓴다).
fn tileRgb(ts: []const u8) ?[3]f32 {
    const ra = findIn(ts, " rg", 0) orelse return null;
    var tp: usize = if (ra > 24) ra - 24 else 0;
    var vals: [3]f32 = .{ 0.6, 0.6, 0.6 };
    var vi: u32 = 0;
    while (tp < ra and vi < 3) {
        while (tp < ra and isSpace(ts[tp])) tp += 1;
        if (tp >= ra) break;
        if (!(isDigit(ts[tp]) or ts[tp] == '.' or ts[tp] == '-')) { tp += 1; vi = 0; continue; }
        vals[vi] = readFloat(ts, &tp);
        vi += 1;
    }
    return if (vi == 3) vals else null;
}

/// /Shading·/Pattern — 그러데이션과 무늬
fn scanShadings(b: []const u8, rs: usize, re_: usize) void {
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
                    } else if (pt == 1 and tiles.room(tile_n + 1)) {
                        // 타일 무늬 — 안에서 처음 나오는 색을 대표로 쓴다
                        const t2 = &tiles.all()[tile_n];
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
                                    if (tileRgb(ts)) |c| { t2.r = c[0]; t2.g = c[1]; t2.b = c[2]; }
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
}

/// /ColorSpace — 이름마다 성분 수와 갈래
fn scanColorSpaces(b: []const u8, rs: usize, re_: usize) void {
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
        while (q < ce2 and cspaces.room(cs_n + 1)) {
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
                var icc_ix: i32 = -1;
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
                    // 프로파일 자체를 읽어 둔다 — 색을 제대로 옮기려면 필요하다
                    var w3 = vs;
                    while (w3 < ve and !isDigit(b[w3])) w3 += 1;
                    if (w3 < ve) {
                        var w4 = w3;
                        const on5 = readUint(b, &w4);
                        if (streamOf(b, on5)) |prof| icc_ix = addIcc(prof);
                    }
                }
                const c2 = &cspaces.all()[cs_n];
                const nl4 = @min(nm4.len, 24);
                var k4: usize = 0;
                while (k4 < nl4) : (k4 += 1) c2.name[k4] = nm4[k4];
                c2.name_len = @intCast(nl4);
                c2.kind = kind;
                c2.comps = comps;
                c2.icc = icc_ix;
                cs_n += 1;
            }
            q = nq;
        }
    }
}

/// /Properties — BDC 가 가리키는 레이어 이름표
fn scanProperties(b: []const u8, rs: usize, re_: usize) void {
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
        while (q < pe2 and props.room(prop_n + 1)) {
            if (b[q] != '/') { q += 1; continue; }
            var nq = q + 1;
            while (nq < pe2 and !isSpace(b[nq]) and b[nq] != '/' and b[nq] != '>') nq += 1;
            var vp = nq;
            while (vp < pe2 and isSpace(b[vp])) vp += 1;
            if (vp < pe2 and isDigit(b[vp])) {
                const on6 = readUint(b, &vp);
                const pr = &props.all()[prop_n];
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
}

/// /ExtGState — 투명도(ca/CA)와 선 굵기(LW)
fn scanExtGStates(b: []const u8, rs: usize, re_: usize) void {
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
        while (q < gex and gstates.room(gs_n + 1)) {
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
                const g2 = &gstates.all()[gs_n];
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
}

/// /Font — 쪽에 쓰이는 글꼴
fn scanFonts(b: []const u8, rs: usize, re_: usize) void {
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
}

/// 폼 XObject 가 제 /Resources 를 갖고 있으면 그 안까지 들어간다. 사전을
/// 바로 적어 두기도 하고 다른 객체를 가리키기도 해서 두 갈래로 본다.
/// 폼 안의 글꼴을 등록해 두지 않으면 폼을 그릴 때 글자가 안 나온다.
fn scanFormResources(b: []const u8, ob: usize, oe: usize, depth: u32) void {
    const ra = find(b[ob..oe], "/Resources", 0) orelse return;
    var rp = ob + ra + 10;
    while (rp < oe and isSpace(b[rp])) rp += 1;
    if (rp < oe and b[rp] == '<') {
        scanResources(b, rp, dictEnd(b, rp, oe), depth + 1);
    } else if (rp < oe and isDigit(b[rp])) {
        const rn = readUint(b, &rp);
        if (findObj(b, rn)) |rb| scanResources(b, rb, find(b, "endobj", rb) orelse b.len, depth + 1);
    }
}

/// /XObject — 그림과 폼. 폼은 제 자원을 따로 갖는다
fn scanXObjects(b: []const u8, rs: usize, re_: usize, depth: u32) void {
    // 그림 한 장을 꺼낸다. 스캔 문서는 쪽마다 큰 그림 하나가 전부라,
    // 그것만 그려도 미리보기로는 충분하다.
    img.kind = 0;
    img.len = 0;
    img.w = 0;
    img.h = 0;
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
        // "/이름 N 0 R" 을 모두 걷어 그림과 폼을 담는다.
        //
        // 폼 XObject 는 이름으로 찾아 쓸 수 있게 따로 담는다(formsBuf). Do 가
        // 그 이름을 만나면 제 /Matrix·/BBox·투명 그룹을 걸고 안을 펼쳐 그린다.
        // formn.n 은 그와 별개로 개수만 세어 화면에 알린다.
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
                        formn.n += 1;
                        if (forms.room(formn.n2 + 1)) {
                            const fo = &forms.all()[formn.n2];
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
                            formn.n2 += 1;
                            // 폼 안의 글꼴·그림도 등록해 둔다
                            if (depth < 2) scanFormResources(b, ob, oe, depth);
                        }
                    }
                    _ = takeImage(b, ob, nm);
                }
            }
            q = nq;
        }
    }
}

pub fn scanResources(b: []const u8, rs: usize, re_: usize, depth: u32) void {
    scanShadings(b, rs, re_);
    scanColorSpaces(b, rs, re_);
    scanProperties(b, rs, re_);
    scanExtGStates(b, rs, re_);
    scanFonts(b, rs, re_);
    scanXObjects(b, rs, re_, depth);
}

/// 페이지의 폰트와 콘텐츠를 찾아 글자를 뽑는다. 항목 수를 돌려준다.
pub export fn renderPage(idx: u32) u32 {
    if (idx >= cpage.count) return 0;
    const b = searchSlice();
    const obj = pgs.all()[idx];
    const body = findObj(b, obj) orelse return 0;
    const end = find(b, "endobj", body) orelse b.len;

    // MediaBox 로 페이지 크기 (없으면 Letter). 상위 Pages 에서 물려받기도 한다.
    var pw: f32 = 612;
    var ph: f32 = 792;
    cpage.x0 = 0;
    cpage.y0 = 0;
    if (inheritedKey(b, body, end, "/MediaBox")) |n| {
        var p = n.at + 9;
        while (p < n.e and b[p] != '[') p += 1;
        p += 1;
        var v: [4]f32 = .{ 0, 0, 612, 792 };
        var i: u32 = 0;
        while (i < 4 and p < n.e) : (i += 1) v[i] = readFloat(b, &p);
        pw = v[2] - v[0];
        ph = v[3] - v[1];
        cpage.x0 = v[0];
        cpage.y0 = v[1];
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
        const mx0 = @max(cx0, cpage.x0);
        const my0 = @max(cy0, cpage.y0);
        const mx1 = @min(cx1, cpage.x0 + pw);
        const my1 = @min(cy1, cpage.y0 + ph);
        if (mx1 - mx0 > 1 and my1 - my0 > 1) {
            pw = mx1 - mx0;
            ph = my1 - my0;
            cpage.x0 = mx0;
            cpage.y0 = my0;
        }
    }
    // 쓰레기 값만 걸러 내고 나머지는 문서가 적은 대로 쓴다.
    //
    // 예전 조건은 pw <= 1 이었다. 그러면 높이가 1 인 쪽도 쓰레기로 보고
    // 레터로 되돌린다 — 규격이 권하는 최소치는 아니지만 문서가 그렇게 적었고
    // 다른 뷰어는 그대로 그린다. 우리만 128×1 쪽을 612×792 로 그렸다.
    //
    // !(pw > 0) 로 쓰는 것은 NaN 도 함께 걸러 내기 위해서다 — NaN 은 어떤
    // 견줌에도 거짓이라 pw <= 0 으로는 빠져나간다.
    if (!(pw > 0) or !(ph > 0) or pw > 20000 or ph > 20000) { pw = 612; ph = 792; }
    cpage.rotate = 0;
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
            cpage.rotate = @intCast(r - @mod(r, 90));
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
    doc.items = b;
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
pub var notes: Table(NoteT, 64) = .{};
pub var note: struct {
    n: u32 = 0,
    buf: [64 * 1024]u8 = undefined,
    used: u32 = 0,
    pts: [8192]f32 = undefined,
    pt_n: u32 = 0,
} = .{};

export fn clearNotes() void { note.n = 0; note.used = 0; note.pt_n = 0; }
export fn addNote(kind: u32, page: u32, x0: f32, y0: f32, x1: f32, y1: f32,
    r: f32, g: f32, b: f32) u32
{
    if (!notes.room(note.n)) return 0;
    notes.all()[note.n] = .{
        .kind = @intCast(@min(kind, 6)), .page = page,
        .rect = .{ @min(x0, x1), @min(y0, y1), @max(x0, x1), @max(y0, y1) },
        .col = .{ @max(0, @min(1, r)), @max(0, @min(1, g)), @max(0, @min(1, b)) },
        .off = note.used, .len = 0, .pts = 0, .obj = 0,
    };
    if (notes.all()[note.n].kind == 6) notes.all()[note.n].off = note.pt_n;
    note.n += 1;
    return 1;
}
/// 메모 글 한 글자 (utf-8 로 담는다)
export fn addNoteChar(c: u32) void {
    if (note.n == 0) return;
    const t = &notes.all()[note.n - 1];
    if (c < 0x80) {
        if (note.used + 1 > note.buf.len) return;
        note.buf[note.used] = @intCast(c);
        note.used += 1;
        t.len += 1;
    } else if (c < 0x800) {
        if (note.used + 2 > note.buf.len) return;
        note.buf[note.used] = @intCast(0xC0 | (c >> 6));
        note.buf[note.used + 1] = @intCast(0x80 | (c & 63));
        note.used += 2;
        t.len += 2;
    } else {
        if (note.used + 3 > note.buf.len) return;
        note.buf[note.used] = @intCast(0xE0 | (c >> 12));
        note.buf[note.used + 1] = @intCast(0x80 | ((c >> 6) & 63));
        note.buf[note.used + 2] = @intCast(0x80 | (c & 63));
        note.used += 3;
        t.len += 3;
    }
}
/// 자유선의 점 하나
export fn addNotePoint(x: f32, y: f32) void {
    if (note.n == 0 or note.pt_n + 2 > note.pts.len) return;
    note.pts[note.pt_n] = x;
    note.pts[note.pt_n + 1] = y;
    note.pt_n += 2;
    notes.all()[note.n - 1].pts += 1;
}

pub fn notesOnPage(page: u32) bool {
    var i: u32 = 0;
    while (i < note.n) : (i += 1) if (notes.all()[i].page == page) return true;
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
var maskt: struct {
    /// 마스크 곳간. 정적 배열로 두면 한글 워터마크 한 번 안 쓰는 문서에서도
    /// 모듈이 12MB 를 들고 시작한다 — 쓸 때 잡는다.
    at: usize = 0,
    used: u32 = 0,
} = .{};
pub fn maskBuf() []u8 {
    if (maskt.at == 0) {
        maskt.at = zoneAlloc(MASK_POOL) orelse return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(maskt.at))[0..MASK_POOL];
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
    return @intFromPtr(buf.ptr) + maskt.used;
}
export fn fieldMaskRoom() u32 { return if (maskt.at == 0) MASK_POOL else MASK_POOL - maskt.used; }

pub fn maskAlloc(len: u32, w: u32, h: u32) ?u32 {
    if (maskBuf().len == 0) return null;
    if (len == 0 or len > MASK_POOL - maskt.used) return null;
    if (w == 0 or h == 0 or w > 1 << 15 or h > 1 << 15) return null;
    const at = maskt.used;
    maskt.used += len;
    return at;
}

export fn setFieldEditMask(w: u32, h: u32, len: u32) u32 {
    if (edit.n == 0) return 0;
    const at = maskAlloc(len, w, h) orelse return 0;
    const e = &edits.all()[edit.n - 1];
    e.mw = w;
    e.mh = h;
    e.moff = at;
    e.mlen = len;
    return 1;
}
/// 사용자가 고친 입력 칸. 필요한 만큼 늘어난다(세는 상한 없음).
pub var edits: Table(EditT, 64) = .{};
pub var edit: struct {
    n: u32 = 0,
    buf: [96 * 1024]u8 = undefined,
    used: u32 = 0,
} = .{};

export fn clearFieldEdits() void { edit.n = 0; edit.used = 0; maskt.used = 0; }
/// kind 0 글상자 · 1 확인란 켜기 · 2 확인란 끄기 · 3 이름 바꾸기 · 4 지우기
export fn addFieldEdit(obj: u32, kind: u32) u32 {
    if (!edits.room(edit.n + 1)) return 0;
    edits.all()[edit.n] = .{ .obj = obj, .kind = @intCast(@min(kind, 4)), .off = edit.used, .len = 0,
        .mw = 0, .mh = 0, .moff = 0, .mlen = 0 };
    edit.n += 1;
    return 1;
}
/// 방금 만든 항목의 값에 글자 하나를 잇는다 (utf-8 로 담는다).
export fn addFieldEditChar(c: u32) void {
    if (edit.n == 0) return;
    const e = &edits.all()[edit.n - 1];
    if (c < 0x80) {
        if (edit.used + 1 > edit.buf.len) return;
        edit.buf[edit.used] = @intCast(c);
        edit.used += 1;
        e.len += 1;
    } else if (c < 0x800) {
        if (edit.used + 2 > edit.buf.len) return;
        edit.buf[edit.used] = @intCast(0xC0 | (c >> 6));
        edit.buf[edit.used + 1] = @intCast(0x80 | (c & 63));
        edit.used += 2;
        e.len += 2;
    } else {
        if (edit.used + 3 > edit.buf.len) return;
        edit.buf[edit.used] = @intCast(0xE0 | (c >> 12));
        edit.buf[edit.used + 1] = @intCast(0x80 | ((c >> 6) & 63));
        edit.buf[edit.used + 2] = @intCast(0x80 | (c & 63));
        edit.used += 3;
        e.len += 3;
    }
}

/// utf-8 한 글자를 읽고 코드포인트와 길이를 준다.
pub fn utf8At(d: []const u8, i: usize) [2]u32 {
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
pub var newf: struct {
    /// 사용자가 더한 것 — 세는 상한은 없다(자리잡개에서 늘어난다)
    items: Table(NewFieldT, 32) = .{},
    n: u32 = 0,
    buf: [16 * 1024]u8 = undefined,
    used: u32 = 0,
} = .{};

export fn clearNewFields() void {
    newf.n = 0;
    newf.used = 0;
}

export fn addNewField(page: u32, kind: u32, x0: f32, y0: f32, x1: f32, y1: f32) u32 {
    if (!newf.items.room(newf.n)) return 0;
    // 없는 쪽에 달라고 하면 그냥 안 단다. 예전에는 쪽 표가 [4096] 고정이라
    // 빈 자리(0)를 읽었지만, 지금은 그 뒤가 다른 표라 엉뚱한 번호를 집는다.
    if (page >= cpage.count) return 0;
    const lo_x = @min(x0, x1);
    const hi_x = @max(x0, x1);
    const lo_y = @min(y0, y1);
    const hi_y = @max(y0, y1);
    if (!(hi_x - lo_x > 1) or !(hi_y - lo_y > 1)) return 0;
    newf.items.all()[newf.n] = .{
        .page = page, .kind = @intCast(@min(kind, 1)),
        .rect = .{ lo_x, lo_y, hi_x, hi_y },
        .off = newf.used, .len = 0, .obj = 0,
    };
    newf.n += 1;
    return 1;
}

/// 방금 만든 칸의 이름에 글자 하나를 잇는다 (utf-8 로 담는다).
export fn addNewFieldChar(c: u32) void {
    if (newf.n == 0) return;
    const f = &newf.items.all()[newf.n - 1];
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
    if (newf.used + n > newf.buf.len) return;
    @memcpy(newf.buf[newf.used..][0..n], tmp[0..n]);
    newf.used += n;
    f.len += n;
}


/// 이 객체가 지울 칸인가
fn fieldDeleted(obj: u32) bool {
    var i: u32 = 0;
    while (i < edit.n) : (i += 1) if (edits.all()[i].kind == 4 and edits.all()[i].obj == obj) return true;
    return false;
}

/// 칸을 만들거나 지우면 쪽과 양식의 목록을 다시 써야 한다
pub fn anyFieldStruct() bool {
    if (newf.n > 0) return true;
    var i: u32 = 0;
    while (i < edit.n) : (i += 1) if (edits.all()[i].kind == 4) return true;
    return false;
}

/// PDF 글자열 하나를 적는다.
///
/// 라틴 밖 글자가 섞이면 UTF-16BE 로 담는다 — 괄호 문자열에는 한 바이트
/// 글자만 들어가 한글이 통째로 사라진다.
pub fn appendTextStr(pos: *usize, val: []const u8) void {
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
pub fn copyRefsKeeping(b: []const u8, from: usize, to: usize, pos: *usize) void {
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

// ===== 입력 칸(AcroForm) — 읽기와 채우기 (c/pdfform.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfform = @import("pdfform.zig");
const collectCalcOrder = pdfform.collectCalcOrder;
const collectContents = pdfform.collectContents;
const collectFields = pdfform.collectFields;
const decodeChain = pdfform.decodeChain;
const drawAnnots = pdfform.drawAnnots;
const keyAt = pdfform.keyAt;
const layoutScratch = pdfform.layoutScratch;
const paintTile = pdfform.paintTile;
const streamFrom = pdfform.streamFrom;
const streamOf = pdfform.streamOf;
export fn fieldCount() u32 { return pdfform.fieldCount(); }
export fn fieldObj(i: u32) u32 { return pdfform.fieldObj(i); }
export fn fieldRect(i: u32, k: u32) f32 { return pdfform.fieldRect(i, k); }
export fn fieldKind(i: u32) u32 { return pdfform.fieldKind(i); }
export fn fieldFlags(i: u32) u32 { return pdfform.fieldFlags(i); }
export fn fieldMaxLen(i: u32) u32 { return pdfform.fieldMaxLen(i); }
export fn fieldSize(i: u32) f32 { return pdfform.fieldSize(i); }
export fn fieldAlign(i: u32) u32 { return pdfform.fieldAlign(i); }
export fn fieldCalcOff(i: u32) u32 { return pdfform.fieldCalcOff(i); }
export fn fieldCalcLen(i: u32) u32 { return pdfform.fieldCalcLen(i); }
export fn fieldFmtOff(i: u32) u32 { return pdfform.fieldFmtOff(i); }
export fn fieldFmtLen(i: u32) u32 { return pdfform.fieldFmtLen(i); }
export fn fieldChecked(i: u32) u32 { return pdfform.fieldChecked(i); }
export fn fieldTextPtr() [*]u8 { return pdfform.fieldTextPtr(); }
export fn fieldNameOff(i: u32) u32 { return pdfform.fieldNameOff(i); }
export fn fieldNameLen(i: u32) u32 { return pdfform.fieldNameLen(i); }
export fn fieldValOff(i: u32) u32 { return pdfform.fieldValOff(i); }
export fn fieldValLen(i: u32) u32 { return pdfform.fieldValLen(i); }
export fn fieldOnOff(i: u32) u32 { return pdfform.fieldOnOff(i); }
export fn fieldOnLen(i: u32) u32 { return pdfform.fieldOnLen(i); }
export fn fieldOptsOff(i: u32) u32 { return pdfform.fieldOptsOff(i); }
export fn fieldOptsLen(i: u32) u32 { return pdfform.fieldOptsLen(i); }
export fn calcOrderCount() u32 { return pdfform.calcOrderCount(); }
export fn calcOrderObj(i: u32) u32 { return pdfform.calcOrderObj(i); }
export fn setFormLayer(on: u32) void { pdfform.setFormLayer(on); }

// ===== 문서에 박힌 글꼴 =====
//
// 브라우저에 글자를 맡기려면 글꼴 파일이 필요하다. PDF 안의 글꼴은 대개
// 부분집합이라, 파일이 그대로는 쓸 수 없다. Type0(Identity-H) 글꼴은 문자
// 코드가 곧 글리프 번호라서 파일 안의 cmap 이 우리가 넘길 유니코드와 맞지
// 않는다. 그래서 cmap 을 "유니코드 → 글리프 번호"로 다시 적어 끼운다.
// PDF.js 도 같은 일을 한다 — 글리프 외곽선을 직접 그리지 않고 글꼴을 고쳐
// FontFace 로 넘긴 뒤 평범한 fillText 를 쓴다.

/// 유니코드 → 글리프 번호. 0 은 없음으로 본다.
pub var uni2gid: [65536]u16 = undefined;

pub fn be16(b: []const u8, o: usize) u16 {
    if (o + 2 > b.len) return 0;
    return (@as(u16, b[o]) << 8) | b[o + 1];
}
pub fn be32(b: []const u8, o: usize) u32 {
    if (o + 4 > b.len) return 0;
    return (@as(u32, b[o]) << 24) | (@as(u32, b[o + 1]) << 16) |
        (@as(u32, b[o + 2]) << 8) | b[o + 3];
}
pub fn wr16(d: []u8, o: usize, v: u16) void {
    if (o + 2 > d.len) return;
    d[o] = @intCast(v >> 8);
    d[o + 1] = @truncate(v);
}
pub fn wr32(d: []u8, o: usize, v: u32) void {
    if (o + 4 > d.len) return;
    d[o] = @truncate(v >> 24);
    d[o + 1] = @truncate(v >> 16);
    d[o + 2] = @truncate(v >> 8);
    d[o + 3] = @truncate(v);
}
pub fn sumTable(d: []const u8, off: usize, len: usize) u32 {
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
pub fn buildPuaCmap(dst: []u8, nglyphs: u16) u32 {
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
pub fn buildCmap(dst: []u8, has: []const u16, has_n: u32) u32 {
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

// ===== 없는 폭 표·인코딩을 지어 채운다 (c/pdfsynth.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfsynth = @import("pdfsynth.zig");

// ===== 암호 =====
//
// 표준 보안 처리기. 빈 사용자 암호로 잠긴 파일이 대부분이라 그것만 푼다.
// 판 2~4 는 RC4·AES-128, 판 5~6 은 AES-256 이다.

pub const crypt = @import("pdfcrypt.zig");
const std14 = @import("pdfstd14.zig");
const ccitt = @import("pdfccitt.zig");
const jbig2 = @import("pdfjbig2.zig");
const jpx = @import("pdfjpx.zig");
const jpeg = @import("pdfjpeg.zig");
pub const filt = @import("pdffilters.zig");

const PAD = [32]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56,
    0xFF, 0xFA, 0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

pub var enc_on = false;
var enc_aes = false;
var encr: struct {
    key: [32]u8 = undefined,
    key_len: u32 = 0,
    obj: u32 = 0,
    v: u32 = 0,
    /// 암호가 맞지 않아 화면이 물어봐야 하는 상태
    need_pw: bool = false,
} = .{};

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
pub fn hash2B(pwd: []const u8, salt: []const u8, udata: []const u8, out: *[32]u8) void {
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

var rd: struct {
    /// 화면에서 받아 둔 문서 암호 (읽기용)
    pw: [128]u8 = undefined,
    pw_len: u32 = 0,
} = .{};

export fn clearPassword() void {
    rd.pw_len = 0;
    encr.need_pw = false;
}
/// 암호 한 글자 (utf-8 로 담는다)
export fn addPasswordChar(c: u32) void {
    if (c < 0x80) {
        if (rd.pw_len + 1 > rd.pw.len) return;
        rd.pw[rd.pw_len] = @intCast(c);
        rd.pw_len += 1;
    } else if (c < 0x800) {
        if (rd.pw_len + 2 > rd.pw.len) return;
        rd.pw[rd.pw_len] = @intCast(0xC0 | (c >> 6));
        rd.pw[rd.pw_len + 1] = @intCast(0x80 | (c & 63));
        rd.pw_len += 2;
    } else {
        if (rd.pw_len + 3 > rd.pw.len) return;
        rd.pw[rd.pw_len] = @intCast(0xE0 | (c >> 12));
        rd.pw[rd.pw_len + 1] = @intCast(0x80 | ((c >> 6) & 63));
        rd.pw[rd.pw_len + 2] = @intCast(0x80 | (c & 63));
        rd.pw_len += 3;
    }
}
/// 1 이면 암호가 틀렸거나 아직 안 받았다
export fn needPassword() u32 {
    return if (encr.need_pw) 1 else 0;
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
    encr.need_pw = false;
    enc_aes = false;
    encr.key_len = 0;
    encr.obj = 0;
    doc.perm = -1;
    const ea = trailerKeyOrScan(b, "/Encrypt") orelse return;
    var p = ea + 8;
    while (p < b.len and isSpace(b[p])) p += 1;
    if (p >= b.len or !isDigit(b[p])) return;
    encr.obj = readUint(b, &p);
    const eb = findObj(b, encr.obj) orelse return;
    const ee = objDictEnd(b, eb);

    // 권한 비트(/P). 판을 가리지 않고 담아 둔다 — 뷰어가 인쇄·복사 단추를
    // 흐리게 하려면 알아야 한다. 음수로 적히는 것이 보통이다.
    doc.perm = signedAfter(b, eb, ee, "/P") orelse -1;

    const v = intAfter(b, eb, ee, "/V") orelse 1;
    const r = intAfter(b, eb, ee, "/R") orelse 2;
    const length = intAfter(b, eb, ee, "/Length") orelse 40;
    encr.v = v;
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
        const pw = rd.pw[0..rd.pw_len];
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
            encr.need_pw = true;
            if (r == 5) {
                crypt.sha256(&[_][]const u8{ pw, u_buf[40..48] }, &inter);
            } else {
                hash2B(pw, u_buf[40..48], &[_]u8{}, &inter);
            }
            if (readPdfString(b, eb, ee, "/UE", &wrapped) < 32) return;
        }

        crypt.aesCbcNoIvDecrypt(&inter, wrapped[0..32]);
        @memcpy(encr.key[0..32], wrapped[0..32]);
        encr.key_len = 32;
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
    padPw(rd.pw[0..rd.pw_len], &pw32);
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
        @memcpy(encr.key[0..n], md[0..n]);
        encr.key_len = n;
        enc_on = true;
        if (userValueOk(md[0..n], r, id_buf[0..id_len], u_buf[0..u_len])) return;
        if (attempt == 1) break;
        if (!ownerToUser(o_buf[0..o_len], rd.pw[0..rd.pw_len], n, r, &pw32)) break;
    }
    // 안 맞아도 열쇠는 그대로 두고 화면에 물어보라고 알린다
    encr.need_pw = true;
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
    const scratch = if (len <= bin2.cap)
        @as([*]u8, @ptrFromInt(bin2.off))[0..len]
    else
        (bigScratch(len) orelse return @intCast(len));
    const src = @as([*]const u8, @ptrFromInt(heapBase() + off))[0..len];
    @memcpy(scratch, src);

    var dec_len: u32 = @intCast(len);
    if (encr.v >= 5) {
        dec_len = crypt.aesCbcDecrypt(encr.key[0..32], scratch);
    } else {
        var tmp: [32]u8 = undefined;
        const n = encr.key_len;
        @memcpy(tmp[0..n], encr.key[0..n]);
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
    while (num < objix.cap) : (num += 1) {
        if (objRankTable()[num] == 0) continue;
        if (num == encr.obj) continue;
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

export fn permissions() i32 { return doc.perm; }

/// 카탈로그(/Root) 딕셔너리 자리.
pub fn catalogRange(b: []const u8) ?struct { s: usize, e: usize } {
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
var meta: struct {
    buf: [512]u8 = undefined,
    off: [5]u32 = undefined,
    len: [5]u32 = undefined,
    n: u32 = 0,
} = .{};
export fn metaCount() u32 { return meta.n; }
export fn metaOff(i: u32) u32 { return if (i < meta.n) meta.off[i] else 0; }
export fn metaLen(i: u32) u32 { return if (i < meta.n) meta.len[i] else 0; }
export fn metaTextPtr() [*]u8 { return &meta.buf; }

fn metaPut(used: *u32, i: usize, txt: []const u8) void {
    if (used.* + txt.len > meta.buf.len) return;
    meta.off[i] = used.*;
    meta.len[i] = @intCast(txt.len);
    @memcpy(meta.buf[used.*..][0..txt.len], txt);
    used.* += @intCast(txt.len);
}

/// 딕셔너리에서 /Key 뒤의 이름(/Foo)을 그대로 읽는다. 슬래시는 뺀다.
/// 이름이 **그 자리에서 끝나는** 첫 자리. /T 가 /Type 에, /C 가 /Contents 에
/// 걸려 엉뚱한 값을 읽던 것을 막는다.
pub fn keyPos(b: []const u8, from: usize, to: usize, key: []const u8) ?usize {
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

pub fn nameAfter(b: []const u8, from: usize, to: usize, key: []const u8, out: []u8) u32 {
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
var lbl: struct {
    off_at: usize = 0,
    len_at: usize = 0,
    buf_at: usize = 0,
    buf_cap: usize = 0,
} = .{};
var label_n: u32 = 0;
fn label_off() []u32 { return u32sAt(lbl.off_at, if (pgs.cap == 0) 0 else pgs.cap); }
fn label_len() []u8 {
    if (lbl.len_at == 0 or pgs.cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(lbl.len_at))[0..pgs.cap];
}
fn label_buf() []u8 {
    if (lbl.buf_at == 0 or lbl.buf_cap == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(lbl.buf_at))[0..lbl.buf_cap];
}
export fn pageLabelCount() u32 { return label_n; }
export fn pageLabelOff(i: u32) u32 { return if (i < label_n) label_off()[i] else 0; }
export fn pageLabelLen(i: u32) u32 { return if (i < label_n) label_len()[i] else 0; }
export fn pageLabelPtr() [*]u8 { return @ptrFromInt(if (lbl.buf_at == 0) heapBase() else lbl.buf_at); }

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

    const pages = cpage.count;
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
    meta.n = 0;
    var used: u32 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) { meta.off[i] = 0; meta.len[i] = 0; }
    meta.n = 5;

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


var info: struct {
    buf: [2048]u8 = undefined,
    off: [8]u32 = undefined,
    len: [8]u32 = undefined,
    n: u32 = 0,
} = .{};

export fn infoCount() u32 { return info.n; }
export fn infoOff(i: u32) u32 { return if (i < info.n) info.off[i] else 0; }
export fn infoLen(i: u32) u32 { return if (i < info.n) info.len[i] else 0; }
export fn infoTextPtr() [*]u8 { return &info.buf; }

/// 트레일러의 /Info 를 읽는다. 차례는 제목·지은이·주제·만든 프로그램·
/// 만든 도구·만든 날짜·고친 날짜 이다. 없으면 길이 0.
fn collectInfo(b: []const u8) void {
    info.n = 0;
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
                len = copyPdfText(b, is + at + k.len, ie, &info.buf, used);
                used += len;
            }
        }
        info.off[info.n] = off;
        info.len[info.n] = len;
        info.n += 1;
        if (info.n >= info.off.len) break;
    }
}

// ===== 링크와 목차 =====

pub var link: struct {
    /// 쪽 하나의 링크. 세는 상한은 없다 — 필요한 만큼 늘어난다.
    items: Table(Link, 128) = .{},
    n: u32 = 0,
    /// link_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
    buf: Table(u8, 16384) = .{},
    buf_n: u32 = 0,
} = .{};
pub const Link = struct { rect: [4]f32, off: u32, len: u32, page: i32 };


export fn linkCount() u32 { return link.n; }
export fn linkRect(i: u32, k: u32) f32 { return if (i < link.n and k < 4) link.items.all()[i].rect[k] else 0; }
export fn linkOff(i: u32) u32 { return if (i < link.n) link.items.all()[i].off else 0; }
export fn linkLen(i: u32) u32 { return if (i < link.n) link.items.all()[i].len else 0; }
export fn linkPage(i: u32) i32 { return if (i < link.n) link.items.all()[i].page else -1; }
export fn linkTextPtr() [*]u8 { return @ptrFromInt(if (link.buf.at == 0) heapBase() else link.buf.at); }

pub var mark: struct {
    /// 목차 줄 수. 세는 상한은 없다.
    items: Table(Bookmark, 64) = .{},
    n: u32 = 0,
    /// mark_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
    buf: Table(u8, 32768) = .{},
    buf_n: u32 = 0,
} = .{};
pub const Bookmark = struct { depth: u8, off: u32, len: u32, page: i32 };

export fn outlineCount() u32 { return mark.n; }
export fn outlineDepth(i: u32) u32 { return if (i < mark.n) mark.items.all()[i].depth else 0; }
export fn outlineOff(i: u32) u32 { return if (i < mark.n) mark.items.all()[i].off else 0; }
export fn outlineLen(i: u32) u32 { return if (i < mark.n) mark.items.all()[i].len else 0; }
export fn outlinePage(i: u32) i32 { return if (i < mark.n) mark.items.all()[i].page else -1; }
export fn outlineTextPtr() [*]u8 { return @ptrFromInt(if (mark.buf.at == 0) heapBase() else mark.buf.at); }

/// 쪽 객체 번호를 쪽 차례로 바꾼다.
pub fn pageIndexOf(obj: u32) i32 {
    var i: u32 = 0;
    while (i < cpage.count) : (i += 1) if (pgs.all()[i] == obj) return @intCast(i);
    return -1;
}

/// PDF 문자열을 UTF-8 로 옮겨 buf 에 담는다. 담은 길이.
///
/// 먼저 날바이트로 풀고(이스케이프·16진), 앞에 FE FF 가 있으면 UTF-16BE 로
/// 본다. 이스케이프된 상태로 표식을 찾으면 못 알아본다.
pub fn copyPdfText(b: []const u8, s2: usize, e: usize, buf: []u8, at: u32) u32 {
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
pub fn destByName(b: []const u8, name: []const u8) i32 {
    if (name.len == 0 or doc.root == 0) return -1;
    const rb = findObj(b, doc.root) orelse return -1;
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
var stru: struct {
    /// 태그 구조 나무의 마디. 세는 상한은 없다.
    items: Table(StructNode, 256) = .{},
    n: u32 = 0,
    /// st_buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
    buf: Table(u8, 32768) = .{},
    used: u32 = 0,
} = .{};

export fn structCount() u32 { return stru.n; }
export fn structDepth(i: u32) u32 { return if (i < stru.n) stru.items.all()[i].depth else 0; }
export fn structPageOf(i: u32) i32 { return if (i < stru.n) stru.items.all()[i].page else -1; }
export fn structMcid(i: u32) i32 { return if (i < stru.n) stru.items.all()[i].mcid else -1; }
export fn structRoleOff(i: u32) u32 { return if (i < stru.n) stru.items.all()[i].role_off else 0; }
export fn structRoleLen(i: u32) u32 { return if (i < stru.n) stru.items.all()[i].role_len else 0; }
export fn structAltOff(i: u32) u32 { return if (i < stru.n) stru.items.all()[i].alt_off else 0; }
export fn structAltLen(i: u32) u32 { return if (i < stru.n) stru.items.all()[i].alt_len else 0; }
export fn structTextPtr() [*]u8 { return @ptrFromInt(if (stru.buf.at == 0) heapBase() else stru.buf.at); }

fn stPut(txt: []const u8) struct { off: u32, len: u16 } {
    _ = stru.buf.room(stru.used + @as(u32, @intCast(txt.len)) + 64);
    if (txt.len == 0 or stru.used + txt.len > stru.buf.all().len or txt.len > 65535) return .{ .off = 0, .len = 0 };
    const off = stru.used;
    @memcpy(stru.buf.all()[off..][0..txt.len], txt);
    stru.used += @intCast(txt.len);
    return .{ .off = off, .len = @intCast(txt.len) };
}

/// 구조 요소 하나와 그 아래를 훑는다. /K 는 숫자(MCID)·딕셔너리·배열 셋 다 온다.
fn walkStruct(b: []const u8, ob: usize, oe: usize, depth: u8, page_hint: i32) void {
    if (depth > 32) return;
    if (!stru.items.room(stru.n)) return;
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
        _ = stru.buf.room(stru.used + 8192);
        const n2 = copyPdfText(b, aa + 4, oe, stru.buf.all(), stru.used);
        if (n2 > 0) {
            node.alt_off = stru.used;
            node.alt_len = @intCast(n2);
            stru.used += n2;
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
    const me = stru.n;
    stru.items.all()[stru.n] = node;
    stru.n += 1;

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
            stru.items.all()[me].mcid = @intCast(v);
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
                leaf.role_off = stru.items.all()[me].role_off;
                leaf.role_len = stru.items.all()[me].role_len;
                stru.items.all()[stru.n] = leaf;
                stru.n += 1;
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
    stru.n = 0;
    stru.used = 0;
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

// ===== 이름 붙은 목적지·뷰어 설정·XMP (c/pdfdest.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfdest = @import("pdfdest.zig");
const collectDests = pdfdest.collectDests;
const collectViewPrefs = pdfdest.collectViewPrefs;
const collectXmp = pdfdest.collectXmp;
const destArray = pdfdest.destArray;
const findKeyDest = pdfdest.findKeyDest;
export fn destCount() u32 { return pdfdest.destCount(); }
export fn destNameOff(i: u32) u32 { return pdfdest.destNameOff(i); }
export fn destNameLen(i: u32) u32 { return pdfdest.destNameLen(i); }
export fn destPageOf(i: u32) i32 { return pdfdest.destPageOf(i); }
export fn destTextPtr() [*]u8 { return pdfdest.destTextPtr(); }
export fn viewPrefCount() u32 { return pdfdest.viewPrefCount(); }
export fn viewPrefKeyOff(i: u32) u32 { return pdfdest.viewPrefKeyOff(i); }
export fn viewPrefKeyLen(i: u32) u32 { return pdfdest.viewPrefKeyLen(i); }
export fn viewPrefValOff(i: u32) u32 { return pdfdest.viewPrefValOff(i); }
export fn viewPrefValLen(i: u32) u32 { return pdfdest.viewPrefValLen(i); }
export fn viewPrefTextPtr() [*]u8 { return pdfdest.viewPrefTextPtr(); }
export fn xmpLen() u32 { return pdfdest.xmpLen(); }
export fn xmpPtr() [*]const u8 { return pdfdest.xmpPtr(); }

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
var open: struct {
    /// 0 없음 · 1 XYZ · 2 Fit · 3 FitH · 4 FitV · 5 FitR · 6 FitB · 7 FitBH · 8 FitBV
    kind: u32 = 0,
    page: i32 = -1,
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 0,
} = .{};
export fn openPage() i32 { return open.page; }
export fn openKind() u32 { return open.kind; }
export fn openX() f32 { return open.x; }
export fn openY() f32 { return open.y; }
export fn openZoom() f32 { return open.zoom; }

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
    open.page = pg;
    open.kind = 2; // 이름이 없으면 쪽 맞춤으로 본다
    open.x = nan();
    open.y = nan();
    open.zoom = nan();
    // "0 R" 을 건너뛰고 이름을 찾는다
    while (p < to and b[p] != '/' and b[p] != ']') p += 1;
    if (p >= to or b[p] != '/') return;
    p += 1;
    const ns = p;
    while (p < to and !isSpace(b[p]) and b[p] != ']' and b[p] != '/') p += 1;
    const name = b[ns..p];
    const names = [_][]const u8{ "XYZ", "Fit", "FitH", "FitV", "FitR", "FitB", "FitBH", "FitBV" };
    open.kind = 2;
    for (names, 0..) |nm, i| {
        if (txEq(name, nm)) {
            open.kind = @intCast(i + 1);
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
    switch (open.kind) {
        1 => { open.x = got[0]; open.y = got[1]; open.zoom = got[2]; },
        3, 7 => open.y = got[0],
        4, 8 => open.x = got[0],
        5 => { open.x = got[0]; open.y = got[1]; },
        else => {},
    }
}

/// 이름 붙은 자리를 이름표에서 찾는다. collectDests 가 먼저 돌아 있어야 한다.
fn openByName(name: []const u8) void {
    var i: u32 = 0;
    while (i < pdfdest.dest_n) : (i += 1) {
        const off = pdfdest.dest_off.all()[i];
        const len = pdfdest.dest_len.all()[i];
        if (len != name.len) continue;
        const buf = pdfdest.dest_buf.all();
        if (off + len > buf.len) continue;
        if (!std_mem_eq(buf[off..][0..len], name)) continue;
        open.page = pdfdest.dest_page.all()[i];
        open.kind = 2;
        open.x = nan();
        open.y = nan();
        open.zoom = nan();
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
    open.kind = 0;
    open.page = -1;
    open.x = 0;
    open.y = 0;
    open.zoom = 0;
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
    return att.obj.room(want) and att.name_off.room(want) and att.name_len.room(want);
}
var att: struct {
    /// 딸린 파일의 객체 번호. 필요한 만큼 늘어난다(세는 상한 없음).
    obj: Table(u32, 64) = .{},
    /// 그 이름 위치. 필요한 만큼 늘어난다(세는 상한 없음).
    name_off: Table(u32, 64) = .{},
    /// 그 이름 길이. 필요한 만큼 늘어난다(세는 상한 없음).
    name_len: Table(u32, 64) = .{},
    n: u32 = 0,
    /// att.buf — 글자 곳간. 필요한 만큼 늘어난다(세는 상한 없음).
    buf: Table(u8, 8192) = .{},
    used: u32 = 0,
    at: usize = 0,
} = .{};

export fn attCount() u32 { return att.n; }
export fn attTextPtr() usize { return (if (att.buf.at == 0) heapBase() else att.buf.at); }
export fn attNameOff(i: u32) u32 { return if (i < att.n) att.name_off.all()[i] else 0; }
export fn attNameLen(i: u32) u32 { return if (i < att.n) att.name_len.all()[i] else 0; }

/// 첨부 하나를 풀어 임시 자리에 놓는다. 길이를 준다(0 이면 못 꺼냄).
export fn attLoad(i: u32) u32 {
    if (i >= att.n) return 0;
    const b = searchSlice();
    const ob = findObj(b, att.obj.all()[i]) orelse return 0;
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
    att.at = @intFromPtr(room.ptr);
    @memcpy(room[0..data.len], data);
    return @intCast(data.len);
}
export fn attPtr() usize { return if (att.at == 0) heapBase() else att.at; }

/// 이름나무를 훑어 딸린 파일을 걷는다.
fn walkAttTree(b: []const u8, num: u32, depth: u8) void {
    const ob = findObj(b, num) orelse return;
    walkAttAt(b, ob, objDictEnd(b, ob), depth);
}

/// 이름나무 한 마디. 딴 객체로 가리키든 그 자리에 적혀 있든 여기로 온다.
fn walkAttAt(b: []const u8, ob: usize, oe: usize, depth: u8) void {
    if (depth > 8 or !attRoom(att.n + 1)) return;
    if (find(b[ob..oe], "/Names", 0)) |na| {
        var q = ob + na + 6;
        while (q < oe and b[q] != '[') q += 1;
        const end = arrayEnd(b, q, oe);
        var guard: u32 = 0;
        while (q < end and attRoom(att.n + 1) and guard < 4096) : (guard += 1) {
            while (q < end and b[q] != '(' and b[q] != '<') q += 1;
            if (q >= end) break;
            _ = att.buf.room(att.used + 4096);
            const nm = sigPutStrTo(b, q, end, att.buf.all(), &att.used);
            // 이름 뒤의 값이 파일 명세다
            q = skipVal(b, q, end);
            while (q < end and isSpace(b[q])) q += 1;
            if (q < end and isDigit(b[q])) {
                const fnum = readUint(b, &q);
                att.obj.all()[att.n] = fnum;
                att.name_off.all()[att.n] = nm[0];
                att.name_len.all()[att.n] = nm[1];
                att.n += 1;
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
    if (doc.root == 0) return;
    const rb = findObj(b, doc.root) orelse return;
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
    if (has_xfa) collectXfa(b, as2, ae);
}

// ===== XFA 양식의 XML =====
//
// XFA 는 쪽 내용이 PDF 가 아니라 XML 로 들어 있다. /AcroForm /XFA 가
// 스트림 하나이거나, [(name) 스트림 (name) 스트림 …] 배열이다. 배열이면
// template·datasets 같은 조각이 이름마다 따로 들어 있어 이어 붙여야 한다.
// 여기서는 XML 을 통째로 꺼내 주고, 뜯어 그리는 것은 xfa.items.ts 가 한다.
var xfa: struct {
    items: Table(u8, 65536) = .{},
    used: u32 = 0,
} = .{};
export fn xfaXmlLen() u32 { return xfa.used; }
export fn xfaXmlPtr() usize { return if (xfa.items.at == 0) heapBase() else xfa.items.at; }

fn xfaAppend(part: []const u8) void {
    if (!xfa.items.room(xfa.used + @as(u32, @intCast(part.len)) + 2)) return;
    const buf = xfa.items.all();
    @memcpy(buf[xfa.used..][0..part.len], part);
    xfa.used += @intCast(part.len);
    buf[xfa.used] = '\n';
    xfa.used += 1;
}

fn collectXfa(b: []const u8, as2: usize, ae: usize) void {
    xfa.used = 0;
    const xa = keyAt(b, as2, ae, "/XFA") orelse return;
    var p = xa;
    while (p < ae and isSpace(b[p])) p += 1;
    if (p >= ae) return;
    if (isDigit(b[p])) {
        // 스트림 하나 — 그 안에 XML 이 통째로 들어 있다
        var q = p;
        const n = readUint(b, &q);
        if (streamOf(b, n)) |st| xfaAppend(st);
        return;
    }
    if (b[p] != '[') return;
    const end = arrayEnd(b, p, ae);
    p += 1;
    var guard: u32 = 0;
    while (p < end and guard < 64) : (guard += 1) {
        while (p < end and isSpace(b[p])) p += 1;
        if (p >= end or b[p] == ']') break;
        if (b[p] == '(') { // 조각 이름 — 건너뛴다
            while (p < end and b[p] != ')') p += 1;
            p += 1;
            continue;
        }
        if (!isDigit(b[p])) { p += 1; continue; }
        const n = readUint(b, &p);
        while (p < end and isSpace(b[p])) p += 1;
        if (p < end and isDigit(b[p])) _ = readUint(b, &p);
        while (p < end and isSpace(b[p])) p += 1;
        if (p < end and b[p] == 'R') p += 1;
        // 스트림을 푸는 자리는 하나뿐이라, 꺼내는 즉시 담아 둔다
        if (streamOf(b, n)) |st| xfaAppend(st);
    }
}

fn collectAttach(b: []const u8) void {
    att.n = 0;
    att.used = 0;
    if (doc.root == 0) return;
    const rb = findObj(b, doc.root) orelse return;
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

pub fn destPage(b: []const u8, s2: usize, e: usize) i32 {
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
// ===== 주석(하이라이트·메모·도형)을 읽고 쓴다 (c/pdfannot.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfannot = @import("pdfannot.zig");
const collectAnnots = pdfannot.collectAnnots;
const collectLinks = pdfannot.collectLinks;
const collectOutline = pdfannot.collectOutline;
export fn annCount() u32 { return pdfannot.annCount(); }
export fn annObj(i: u32) u32 { return pdfannot.annObj(i); }
export fn annFlags(i: u32) u32 { return pdfannot.annFlags(i); }
export fn annRect(i: u32, k: u32) f32 { return pdfannot.annRect(i, k); }
export fn annHasColor(i: u32) u32 { return pdfannot.annHasColor(i); }
export fn annColor(i: u32, k: u32) f32 { return pdfannot.annColor(i, k); }
export fn annTextPtr() [*]u8 { return pdfannot.annTextPtr(); }
export fn annSubOff(i: u32) u32 { return pdfannot.annSubOff(i); }
export fn annSubLen(i: u32) u32 { return pdfannot.annSubLen(i); }
export fn annBodyOff(i: u32) u32 { return pdfannot.annBodyOff(i); }
export fn annBodyLen(i: u32) u32 { return pdfannot.annBodyLen(i); }
export fn annAuthorOff(i: u32) u32 { return pdfannot.annAuthorOff(i); }
export fn annAuthorLen(i: u32) u32 { return pdfannot.annAuthorLen(i); }
export fn annDateOff(i: u32) u32 { return pdfannot.annDateOff(i); }
export fn annDateLen(i: u32) u32 { return pdfannot.annDateLen(i); }

// ===== 셰이딩(그라데이션) =====
//
// /Shading 은 색을 함수로 준다. 함수를 몇 군데 찍어 색 마디를 만들고,
// 캔버스의 그라데이션에 그대로 넘긴다. 형식 2(지수)·3(이어붙임)·0(표본)을
// 본다.

pub const Shade = struct {
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
pub var shades: Table(Shade, 16) = .{};
pub var shade_n: u32 = 0;

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
pub var tiles: Table(Tile, 16) = .{};
var tile_n: u32 = 0;

var ocg: struct {
    /// 꺼 놓은 레이어(/OCProperties /D /OFF)의 객체 번호
    /// 레이어. 64 이던 것을 올렸다 — 도면은 그보다 많다.
    /// 레이어 객체 번호. 필요한 만큼 늘어난다(세는 상한 없음).
    off_list: Table(u32, 64) = .{},
    off_n: u32 = 0,
} = .{};
/// 이름 → 레이어 객체 (/Properties)
const Prop = struct { name: [24]u8, name_len: u8, obj: u32 };
/// 이름 붙은 레이어(/Properties). 필요한 만큼 늘어난다(세는 상한 없음).
var props: Table(Prop, 16) = .{};
var prop_n: u32 = 0;

/// 레이어 목록 — 화면이 켜고 끌 수 있게 이름과 상태를 들고 있는다
/// 레이어 표 넷을 함께 늘린다.
fn ocRoom(want: u32) bool {
    return oc.obj.room(want) and oc.name_off.room(want) and
        oc.name_len.room(want) and oc.on.room(want);
}
/// 레이어(optional content). 표들은 필요한 만큼 늘어난다(세는 상한 없음).
var oc: struct {
    /// 레이어 객체 번호
    obj: Table(u32, 64) = .{},
    /// 레이어 이름의 곳간 안 위치와 길이
    name_off: Table(u32, 64) = .{},
    name_len: Table(u32, 64) = .{},
    /// 레이어를 켜 두었나
    on: Table(bool, 64) = .{},
    /// 이름 글자 곳간
    buf: Table(u8, 8192) = .{},
    n: u32 = 0,
    used: u32 = 0,
} = .{};

export fn ocCount() u32 { return oc.n; }
export fn ocTextPtr() usize { return (if (oc.buf.at == 0) heapBase() else oc.buf.at); }
export fn ocNameOff(i: u32) u32 { return if (i < oc.n) oc.name_off.all()[i] else 0; }
export fn ocNameLen(i: u32) u32 { return if (i < oc.n) oc.name_len.all()[i] else 0; }
export fn ocIsOn(i: u32) u32 { return if (i < oc.n and oc.on.all()[i]) 1 else 0; }
/// 화면에서 레이어를 켜고 끈다. 다음 renderPage 부터 먹는다.
export fn setOcOn(i: u32, on: u32) void {
    if (i < oc.n) oc.on.all()[i] = on != 0;
}

fn ocgHidden(obj: u32) bool {
    // 화면에서 손댄 것이 있으면 그쪽이 먼저다
    var k: u32 = 0;
    while (k < oc.n) : (k += 1) if (oc.obj.all()[k] == obj) return !oc.on.all()[k];
    var i: u32 = 0;
    while (i < ocg.off_n) : (i += 1) if (ocg.off_list.all()[i] == obj) return true;
    return false;
}
fn propObj(name: []const u8) u32 {
    var i: u32 = 0;
    while (i < prop_n) : (i += 1)
        if (txEq(props.all()[i].name[0..props.all()[i].name_len], name)) return props.all()[i].obj;
    return 0;
}

fn findTile(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < tile_n) : (i += 1)
        if (txEq(tiles.all()[i].name[0..tiles.all()[i].name_len], name)) return @intCast(i);
    return -1;
}

fn findShade(name: []const u8) i32 {
    var i: u32 = 0;
    while (i < shade_n) : (i += 1)
        if (txEq(shades.all()[i].name[0..shades.all()[i].name_len], name)) return @intCast(i);
    return -1;
}

/// 딕셔너리의 숫자 배열을 읽는다. 읽은 개수를 준다.
pub fn readArr(b: []const u8, ds: usize, de: usize, key: []const u8, dst: []f32) u32 {
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
var fnc: struct {
    key: [FN_SLOTS]usize = .{0} ** FN_SLOTS,
    at: [FN_SLOTS]u32 = .{0} ** FN_SLOTS,
    ln: [FN_SLOTS]u32 = .{0} ** FN_SLOTS,
    pool: [FN_POOL]u8 = undefined,
    used: u32 = 0,
    rr: u32 = 0,
} = .{};

fn fnReset() void {
    fnc.used = 0;
    fnc.rr = 0;
    var i: u32 = 0;
    while (i < FN_SLOTS) : (i += 1) { fnc.key[i] = 0; fnc.ln[i] = 0; }
}

pub fn sampleData(b: []const u8, fs: usize) ?[]const u8 {
    var i: u32 = 0;
    while (i < FN_SLOTS) : (i += 1) {
        if (fnc.key[i] == fs and fnc.ln[i] > 0) return fnc.pool[fnc.at[i]..][0..fnc.ln[i]];
    }
    const d = streamFrom(b, fs) orelse return null;
    const n = @min(d.len, FN_POOL - fnc.used);
    if (n == 0) return null;
    const slot = fnc.rr % FN_SLOTS;
    fnc.rr += 1;
    @memcpy(fnc.pool[fnc.used..][0..n], d[0..n]);
    fnc.key[slot] = fs;
    fnc.at[slot] = fnc.used;
    fnc.ln[slot] = @intCast(n);
    fnc.used += @intCast(n);
    return fnc.pool[fnc.at[slot]..][0..n];
}

/// 자료에서 bit 자리부터 n 비트를 읽는다 (큰 자리가 앞).
pub fn bitsAt(d: []const u8, bit: u64, n: u32) u32 {
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

pub fn lerp(x: f32, a0: f32, a1: f32, b0: f32, b1: f32) f32 {
    if (a1 == a0) return b0;
    return b0 + (x - a0) * (b1 - b0) / (a1 - a0);
}

// ===== 함수·셰이딩 읽기 (c/pdffn.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다.
const pdffn = @import("pdffn.zig");
pub const evalFnN = pdffn.evalFnN;
const readShade = pdffn.readShade;
pub const rgbFrom = pdffn.rgbFrom;
pub const shadeFn = pdffn.shadeFn;

// ===== 그물 셰이딩(4~7형) — 꼭짓점 삼각형·좌표 격자 (c/pdfmesh.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다.
const pdfmesh = @import("pdfmesh.zig");
const emitShade = pdfmesh.emitShade;

// ===== Type1 글꼴 — 외곽선 프로그램(charstring)을 푼다 (c/pdftype1.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다.
const pdft1 = @import("pdftype1.zig");
pub const attachType1 = pdft1.attachType1;
const drawType1 = pdft1.drawType1;

// ===== 맨 CFF 를 OpenType 으로 감싼다 (c/pdfcff.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다.
const pdfcff = @import("pdfcff.zig");
const advance = pdfcff.advance;
pub const attachFontFile = pdfcff.attachFontFile;

// ===== CID → 글리프 번호 =====
//
// CID 글꼴은 대개 CID 가 곧 글리프 번호다(/CIDToGIDMap /Identity). 그런데
// 표를 스트림으로 주는 문서가 있다 — CID 하나에 두 바이트씩, 큰 자리가
// 앞이다. 이 표를 무시하면 글자가 통째로 엉뚱한 모양으로 나온다.
//
// 규격상 이 키는 CIDFontType2(트루타입 바탕)에만 쓴다. CFF 바탕인
// CIDFontType0 은 CFF 안 charset 이 그 몫을 한다.
pub const C2G_POOL = 1024 * 1024;
pub var c2g: struct {
    /// c2g_pool — 쓸 때 잡는다(그 갈래 문서가 아니면 안 잡는다)
    pool_at: usize = 0,
    used: u32 = 0,
} = .{};
pub fn c2g_pool() []u8 {
    if (c2g.pool_at == 0) {
        c2g.pool_at = zoneAlloc(C2G_POOL) orelse 0;
        if (c2g.pool_at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(c2g.pool_at))[0..C2G_POOL];
}

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
var cmapp: struct {
    /// cmap_pool — 쓸 때 잡는다(그 갈래 문서가 아니면 안 잡는다)
    pool_at: usize = 0,
    used: u32 = 0,
    n: u32 = 0,
} = .{};
fn cmap_pool() []u8 {
    if (cmapp.pool_at == 0) {
        cmapp.pool_at = zoneAlloc(CMAP_POOL) orelse 0;
        if (cmapp.pool_at == 0) return &[_]u8{};
    }
    return @as([*]u8, @ptrFromInt(cmapp.pool_at))[0..CMAP_POOL];
}
const CMapT = struct { name: [32]u8, name_len: u8, off: u32, len: u32 };
/// 미리 정의된 CMap. 필요한 만큼 늘어난다(세는 상한 없음).
var cmaps: Table(CMapT, 8) = .{};

export fn cmapReset() void { cmapp.n = 0; cmapp.used = 0; }
/// 다음 표를 적을 자리. 화면 쪽이 여기에 바이트를 넣고 cmapAdd 를 부른다.
export fn cmapPtr() usize {
    // JS 가 표를 여기에 적는다. 자리를 여기서 잡으므로(메모리가 늘 수 있다)
    // 부르는 쪽은 이 값을 먼저 받고 나서 memory.buffer 를 잡아야 한다.
    const p = cmap_pool();
    if (p.len == 0) return heapBase();
    return @intFromPtr(p.ptr) + cmapp.used;
}
export fn cmapRoom() u32 { return CMAP_POOL - cmapp.used; }
/// 방금 cmapPtr 에 적은 len 바이트를, 목록의 idx 번째 이름으로 등록한다.
/// 이름을 따로 넘기지 않는 건 받을 것이 늘 그 목록에서 나오기 때문이다.
export fn cmapAdd(idx: u32, len: u32) u32 {
    if (!cmaps.room(cmapp.n + 1) or len == 0 or idx >= needs.n) return 0;
    if (len > CMAP_POOL - cmapp.used) return 0;
    const nm = needs.buf[needs.off[idx]..][0..needs.lens[idx]];
    const t = &cmaps.all()[cmapp.n];
    const nl = @min(nm.len, 32);
    var i: u32 = 0;
    while (i < nl) : (i += 1) t.name[i] = nm[i];
    t.name_len = @intCast(nl);
    t.off = cmapp.used;
    t.len = len;
    cmapp.used += len;
    cmapp.n += 1;
    return 1;
}

pub fn cmapFind(name: []const u8) i16 {
    var i: u32 = 0;
    while (i < cmapp.n) : (i += 1) {
        const t = &cmaps.all()[i];
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
    if (u >= cmapp.n) return null;
    const t = cmaps.all()[u];
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
    if (u >= cmapp.n) return null;
    const t = cmaps.all()[u];
    const d = cmap_pool()[t.off..][0..t.len];
    if (d.len < 4 or d[0] != 'C' or d[1] != 'U' or d[2] != '1') return null;
    const at = 4 + cid * 2;
    if (at + 1 >= d.len) return null;
    const v = le16(d, at);
    return if (v == 0) null else v;
}

// ===== 무엇을 받아야 하는가 =====

var needs: struct {
    buf: [512]u8 = undefined,
    off: [16]u32 = undefined,
    lens: [16]u32 = undefined,
    n: u32 = 0,
    used: u32 = 0,
} = .{};

export fn needCount() u32 { return needs.n; }
export fn needOff(i: u32) u32 { return if (i < needs.n) needs.off[i] else 0; }
export fn needLen(i: u32) u32 { return if (i < needs.n) needs.lens[i] else 0; }
export fn needPtr() [*]u8 { return &needs.buf; }

fn pushNeed(nm: []const u8) void {
    if (needs.n >= 16 or nm.len == 0 or nm.len + needs.used > needs.buf.len) return;
    var i: u32 = 0;
    while (i < needs.n) : (i += 1) {
        if (needs.lens[i] == nm.len and
            std_mem_eq(needs.buf[needs.off[i]..][0..nm.len], nm)) return;
    }
    @memcpy(needs.buf[needs.used..][0..nm.len], nm);
    needs.off[needs.n] = needs.used;
    needs.lens[needs.n] = @intCast(nm.len);
    needs.used += @intCast(nm.len);
    needs.n += 1;
}

/// 문서가 쓰는 미리 정의된 CMap 이름을 모은다.
///
/// 표가 PDF 안에 없으니 화면 쪽이 받아 와야 한다. 무엇이 필요한지 여기서
/// 알려 준다. Identity 는 표가 없어도 되니 뺀다. /Ordering 은 그 계열의
/// CID→유니코드 표를 뜻한다 — ToUnicode 가 없을 때 글자를 찾는 데 쓴다.
const NO_AT: usize = ~@as(usize, 0);

/// 다음 자리를 찾되, 예전 고리가 보지 않던 끝 열두 바이트는 그대로 안 본다.
fn seekNeed(h: []const u8, n: []const u8, from: usize) usize {
    const at = find(h, n, from) orelse return NO_AT;
    return if (at + 12 < h.len) at else NO_AT;
}

fn collectNeeds(b: []const u8) void {
    needs.n = 0;
    needs.used = 0;
    // 파일을 한 바이트씩 밀며 '/' 인지 보고 있었다. 34MB 문서면 3천4백만 번,
    // 그것만 12ms 다. 찾을 말을 통째로 주면 여덟 바이트씩 건너뛴다.
    //
    // 두 갈래를 따로 훑되 먼저 나온 쪽부터 처리해, 담기는 차례는 예전과 같게
    // 둔다 — 먼저 나온 이름이 먼저 들어가야 한다.
    var enc = seekNeed(b, "/Encoding", 0);
    var ord = seekNeed(b, "/Ordering", 0);
    while (enc != NO_AT or ord != NO_AT) {
        if (enc <= ord) {
            const p = enc;
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
            enc = seekNeed(b, "/Encoding", p + 9);
        } else {
            const p = ord;
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
            ord = seekNeed(b, "/Ordering", p + 9);
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
pub fn cmapKindOf(name: []const u8) u8 {
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
pub fn std14For(b: []const u8, fbody: usize, fend: usize) ?*const [256]u16 {
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

pub fn widthOf(f: *const FontMap, code: u32) f32 {
    var i: u16 = 0;
    while (i < f.wn) : (i += 1) if (f.wcodes.all()[i] == code) return @floatFromInt(f.wvals.all()[i]);
    // 표준 14종은 문서가 /Widths 를 안 적어도 된다. 그때는 Adobe 가 낸
    // AFM 값을 쓴다 — 없으면 글자마다 500 으로 잡아 자간이 통째로 어긋난다.
    if (f.std_w) |w| {
        if (code < 256 and w[code] > 0) return @floatFromInt(w[code]);
    }
    if (f.dw > 0) return f.dw;
    // 폭을 모르면 라틴은 반각, 두 바이트 글꼴은 전각으로 본다
    return if (f.two_byte) 1000 else 500;
}

pub fn pushWidth(f: *FontMap, code: u32, v: f32) void {
    if (code > 65535 or !widthRoom(f, f.wn + 1)) return;
    const c: f32 = @max(0, @min(65535, v));
    f.wcodes.all()[f.wn] = @intCast(code);
    f.wvals.all()[f.wn] = @intFromFloat(c);
    f.wn += 1;
}

// ===== 한 바이트 글꼴의 /Encoding 과 이름표 (c/pdfenc.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfenc = @import("pdfenc.zig");
pub const arrayEnd = pdfenc.arrayEnd;
const attachEmbedded = pdfenc.attachEmbedded;
const attachType3 = pdfenc.attachType3;
const attachWidths = pdfenc.attachWidths;
pub const dictEnd = pdfenc.dictEnd;
pub const q_at = pdfenc.q_at;

// ===== 다른 PDF 를 뒤에 이어 붙인다 (c/pdfmerge.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfmerge = @import("pdfmerge.zig");
export fn parseSecond(len: usize) u32 { return pdfmerge.parseSecond(len); }
export fn secondPageCount() u32 { return pdfmerge.secondPageCount(); }
export fn outCapacity() usize { return pdfmerge.outCapacity(); }
export fn inputLen() usize { return pdfmerge.inputLen(); }
pub export fn merge() usize { return pdfmerge.merge(); }

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

pub var reacht: struct {
    /// 어느 객체가 살아 있는가. 문서에서 본 가장 큰 번호에 맞춰 잡는다 —
    /// 예전에는 [65536] 고정이라, 번호가 그보다 큰 객체는 살아 있어도
    /// 조용히 버려졌다(compact 로 낸 파일에서 그 객체만 사라졌다).
    at: usize = 0,
    n: usize = 0,
} = .{};
pub fn reachTable() []bool {
    if (reacht.at == 0 or reacht.n == 0) return &[_]bool{};
    return @as([*]bool, @ptrFromInt(reacht.at))[0..reacht.n];
}

pub fn objRange(b: []const u8, num: u32) ?struct { start: usize, dict_end: usize, end: usize } {
    const body = findObj(b, num) orelse return null;
    const end = find(b, "endobj", body) orelse b.len;
    const sm = find(b[body..end], "stream", 0);
    const de = if (sm) |x| body + x else end;
    return .{ .start = body, .dict_end = de, .end = end };
}

pub fn markReach(b: []const u8, num: u32, depth: u32) void {
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

// ===== 전자 서명을 붙이고 확인한다 (c/pdfsign.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfsign = @import("pdfsign.zig");
const collectSigs = pdfsign.collectSigs;
const sigPutStrTo = pdfsign.sigPutStrTo;
export fn sigCount() u32 { return pdfsign.sigCount(); }
export fn sigRange(i: u32, k: u32) u32 { return pdfsign.sigRange(i, k); }
export fn sigTextPtr() usize { return pdfsign.sigTextPtr(); }
export fn sigDerOff(i: u32) u32 { return pdfsign.sigDerOff(i); }
export fn sigDerLen(i: u32) u32 { return pdfsign.sigDerLen(i); }
export fn sigNameOff(i: u32) u32 { return pdfsign.sigNameOff(i); }
export fn sigNameLen(i: u32) u32 { return pdfsign.sigNameLen(i); }
export fn sigDateOff(i: u32) u32 { return pdfsign.sigDateOff(i); }
export fn sigDateLen(i: u32) u32 { return pdfsign.sigDateLen(i); }
export fn sigReasonOff(i: u32) u32 { return pdfsign.sigReasonOff(i); }
export fn sigReasonLen(i: u32) u32 { return pdfsign.sigReasonLen(i); }
export fn sigSubOff(i: u32) u32 { return pdfsign.sigSubOff(i); }
export fn sigSubLen(i: u32) u32 { return pdfsign.sigSubLen(i); }
export fn sigCovers(i: u32) u32 { return pdfsign.sigCovers(i); }
export fn sigObj(i: u32) u32 { return pdfsign.sigObj(i); }

/// 고른 쪽만 남긴 문서를 처음부터 다시 쓴다. 결과 길이를 돌려준다.

// ===== 문서에 암호를 건다 (c/pdfencout.zig) =====
//
// 부르는 자리를 안 건드리도록 이름만 이어 둔다. JS 에 내보내는 것은
// 껍데기만 여기 두고 알맹이는 저쪽에 있다.
const pdfencout = @import("pdfencout.zig");
export fn setEncrypt(on: u32) void { pdfencout.setEncrypt(on); }
export fn addEncryptChar(c: u32) void { pdfencout.addEncryptChar(c); }
export fn encRandomPtr() usize { return pdfencout.encRandomPtr(); }
pub export fn compact() usize { return pdfencout.compact(); }
