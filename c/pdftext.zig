// PDF 페이지에서 글자와 위치를 뽑는다.
//
// 브라우저 내장 뷰어를 쓰지 않고 캔버스에 직접 그리기 위한 최소 렌더러다.
// 콘텐츠 스트림의 텍스트 연산자만 해석한다 — 벡터 그래픽과 이미지는 다루지
// 않으므로 "무슨 페이지인지 알아볼 정도"를 목표로 한다.
//
// 한글이 걸림돌이다. 콘텐츠에는 <A1> 같은 글꼴 내부 코드로 들어 있어서,
// 폰트의 ToUnicode CMap 을 읽어야 실제 글자가 나온다.

const MAX_ITEMS = 4096;
const MAX_TEXT = 256 * 1024;
const MAX_FONTS = 32;
const MAX_MAP = 2048;

/// 한 번에 그릴 글자 조각
const Item = struct { x: f32, y: f32, size: f32, off: u32, len: u32 };
var items: [MAX_ITEMS]Item = undefined;
var item_n: u32 = 0;
var text: [MAX_TEXT]u8 = undefined;
var text_n: u32 = 0;

/// 폰트 하나의 코드→유니코드 표 (희소)
const FontMap = struct {
    name: [24]u8,
    name_len: u8,
    two_byte: bool,
    codes: [MAX_MAP]u16,
    unis: [MAX_MAP]u16,
    n: u16,
};
var fonts: [MAX_FONTS]FontMap = undefined;
var font_n: u8 = 0;
var cur_font: i32 = -1;

var page_w: f32 = 612;
var page_h: f32 = 792;

export fn itemCount() u32 { return item_n; }
export fn itemX(i: u32) f32 { return items[i].x; }
export fn itemY(i: u32) f32 { return items[i].y; }
export fn itemSize(i: u32) f32 { return items[i].size; }
export fn itemOff(i: u32) u32 { return items[i].off; }
export fn itemLen(i: u32) u32 { return items[i].len; }
export fn textPtr() [*]u8 { return &text; }
export fn pageWidth() f32 { return page_w; }
export fn pageHeight() f32 { return page_h; }

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0 or c == 12;
}
fn isDigit(c: u8) bool { return c >= '0' and c <= '9'; }
fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| if (c != b[i]) return false;
    return true;
}
fn findIn(h: []const u8, n: []const u8, from: usize) ?usize {
    if (n.len == 0 or n.len > h.len) return null;
    var i = from;
    while (i + n.len <= h.len) : (i += 1) if (eq(h[i .. i + n.len], n)) return i;
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

/// UTF-8 로 한 글자 쓴다
fn putUtf8(cp: u32) void {
    if (text_n + 4 >= MAX_TEXT) return;
    if (cp < 0x80) {
        text[text_n] = @intCast(cp);
        text_n += 1;
    } else if (cp < 0x800) {
        text[text_n] = @intCast(0xC0 | (cp >> 6));
        text[text_n + 1] = @intCast(0x80 | (cp & 0x3F));
        text_n += 2;
    } else {
        text[text_n] = @intCast(0xE0 | (cp >> 12));
        text[text_n + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        text[text_n + 2] = @intCast(0x80 | (cp & 0x3F));
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
        while (p < end and f.n < MAX_MAP) {
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
            f.codes[f.n] = @truncate(src);
            f.unis[f.n] = @truncate(dst);
            f.n += 1;
        }
        at = end + 1;
    }

    // beginbfrange: <lo> <hi> <dst>
    at = 0;
    while (findIn(cm, "beginbfrange", at)) |br| {
        var p = br + 12;
        const end = findIn(cm, "endbfrange", p) orelse cm.len;
        while (p < end and f.n < MAX_MAP) {
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
            while (c <= hi and f.n < MAX_MAP) : (c += 1) {
                f.codes[f.n] = @truncate(c);
                f.unis[f.n] = @truncate(dst + (c - lo));
                f.n += 1;
            }
        }
        at = end + 1;
    }
}

fn lookup(f: *const FontMap, code: u32) u32 {
    var i: u16 = 0;
    while (i < f.n) : (i += 1) if (f.codes[i] == code) return f.unis[i];
    // 표에 없으면 코드를 그대로 본다 (라틴 폰트는 대개 맞는다)
    return code;
}

export fn resetPage(w: f32, h: f32) void {
    item_n = 0;
    text_n = 0;
    font_n = 0;
    cur_font = -1;
    page_w = w;
    page_h = h;
}

/// 폰트 하나를 등록한다. cmap 이 비어 있으면 코드=유니코드로 본다.
export fn addFont(name: [*]const u8, name_len: u32, cmap: [*]const u8, cmap_len: u32) void {
    if (font_n >= MAX_FONTS) return;
    const f = &fonts[font_n];
    const nl = @min(name_len, 24);
    var i: u32 = 0;
    while (i < nl) : (i += 1) f.name[i] = name[i];
    f.name_len = @intCast(nl);
    f.n = 0;
    f.two_byte = false;
    if (cmap_len > 0) parseCMap(f, cmap[0..cmap_len]);
    font_n += 1;
}

fn selectFont(name: []const u8) void {
    var i: u8 = 0;
    while (i < font_n) : (i += 1) {
        if (eq(fonts[i].name[0..fonts[i].name_len], name)) {
            cur_font = i;
            return;
        }
    }
    cur_font = -1;
}

/// 문자열 하나를 항목으로 남긴다.
fn emit(x: f32, y: f32, size: f32, start: u32) void {
    if (item_n >= MAX_ITEMS or text_n <= start) return;
    items[item_n] = .{ .x = x, .y = y, .size = size, .off = start, .len = text_n - start };
    item_n += 1;
}

/// 콘텐츠 스트림을 훑어 글자와 위치를 모은다.
export fn runContent(buf: [*]const u8, len: u32) u32 {
    const b = buf[0..len];
    var p: usize = 0;
    // 텍스트 행렬: 위치와 크기만 쓴다
    var tx: f32 = 0;
    var ty: f32 = 0;
    var size: f32 = 12;
    var lead: f32 = 0;
    var name_buf: [24]u8 = undefined;

    while (p < b.len) {
        const c = b[p];
        if (c == '(') {
            // 리터럴 문자열
            const start = text_n;
            p += 1;
            var depth: u32 = 1;
            while (p < b.len) : (p += 1) {
                if (b[p] == '\\' and p + 1 < b.len) { p += 1; putUtf8(b[p]); continue; }
                if (b[p] == '(') depth += 1;
                if (b[p] == ')') { depth -= 1; if (depth == 0) break; }
                if (cur_font >= 0 and fonts[@intCast(cur_font)].n > 0)
                    putUtf8(lookup(&fonts[@intCast(cur_font)], b[p]))
                else putUtf8(b[p]);
            }
            p += 1;
            emit(tx, ty, size, start);
            continue;
        }
        if (c == '<' and p + 1 < b.len and b[p + 1] != '<') {
            // 16진 문자열
            const start = text_n;
            p += 1;
            var acc: u32 = 0;
            var nd: u32 = 0;
            const two = if (cur_font >= 0) fonts[@intCast(cur_font)].two_byte else false;
            const want: u32 = if (two) 4 else 2;
            while (p < b.len and b[p] != '>') : (p += 1) {
                if (hexVal(b[p])) |h| {
                    acc = (acc << 4) | h;
                    nd += 1;
                    if (nd == want) {
                        if (cur_font >= 0) putUtf8(lookup(&fonts[@intCast(cur_font)], acc))
                        else putUtf8(acc);
                        acc = 0;
                        nd = 0;
                    }
                }
            }
            p += 1;
            emit(tx, ty, size, start);
            continue;
        }
        if (c == '/') {
            // 이름 — 폰트 선택에 쓴다
            var q = p + 1;
            var n: usize = 0;
            while (q < b.len and !isSpace(b[q]) and b[q] != '/' and b[q] != '[' and
                b[q] != '(' and b[q] != '<' and n < 24) : (q += 1)
            {
                name_buf[n] = b[q];
                n += 1;
            }
            // 다음 토큰이 Tf 면 이 이름이 폰트다
            var r = q;
            while (r < b.len and isSpace(b[r])) r += 1;
            const num_start = r;
            _ = readFloat(b, &r);
            while (r < b.len and isSpace(b[r])) r += 1;
            if (r + 1 < b.len and b[r] == 'T' and b[r + 1] == 'f') {
                selectFont(name_buf[0..n]);
                var rp = num_start;
                size = readFloat(b, &rp);
                p = r + 2;
                continue;
            }
            p = q;
            continue;
        }
        // 연산자
        if (c == 'T' and p + 1 < b.len) {
            const op = b[p + 1];
            if (op == 'm') {
                // 앞의 여섯 수 중 마지막 둘이 위치
                var back = p;
                var cnt: u32 = 0;
                while (back > 0 and cnt < 6) {
                    back -= 1;
                    while (back > 0 and isSpace(b[back])) back -= 1;
                    while (back > 0 and (isDigit(b[back]) or b[back] == '.' or b[back] == '-')) back -= 1;
                    cnt += 1;
                }
                var q = back;
                var v: [6]f32 = undefined;
                var i: u32 = 0;
                while (i < 6) : (i += 1) v[i] = readFloat(b, &q);
                tx = v[4];
                ty = v[5];
                // 행렬의 세로 배율이 실제 글자 크기다
                const sy = if (v[3] < 0) -v[3] else v[3];
                if (sy > 0.01) size = size * sy / (if (sy > 3) sy else 1);
                p += 2;
                continue;
            }
            if (op == 'd' or op == 'D') {
                var back = p;
                var cnt: u32 = 0;
                while (back > 0 and cnt < 2) {
                    back -= 1;
                    while (back > 0 and isSpace(b[back])) back -= 1;
                    while (back > 0 and (isDigit(b[back]) or b[back] == '.' or b[back] == '-')) back -= 1;
                    cnt += 1;
                }
                var q = back;
                const dx = readFloat(b, &q);
                const dy = readFloat(b, &q);
                tx += dx;
                ty += dy;
                if (op == 'D') lead = -dy;
                p += 2;
                continue;
            }
            if (op == '*') {
                ty += lead;
                p += 2;
                continue;
            }
        }
        p += 1;
    }
    return item_n;
}
