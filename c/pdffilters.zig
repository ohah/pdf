// PDF 스트림 필터들.
//
// Flate 는 miniz 가 하고, 나머지는 여기서 푼다. 필터는 배열로 여러 개가
// 이어 붙기도 한다 — [/ASCII85Decode /FlateDecode] 처럼.

/// 16진 — 공백은 무시하고 '>' 에서 끝난다
pub fn asciiHex(src: []const u8, dst: []u8) u32 {
    var n: u32 = 0;
    var hi: ?u8 = null;
    for (src) |c| {
        if (c == '>') break;
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (hi) |h| {
            if (n >= dst.len) return n;
            dst[n] = (h << 4) | v;
            n += 1;
            hi = null;
        } else hi = v;
    }
    if (hi) |h| {
        if (n < dst.len) { dst[n] = h << 4; n += 1; }
    }
    return n;
}

/// 85진 — 다섯 글자가 네 바이트가 된다. 'z' 는 0 네 개, '~>' 에서 끝난다
pub fn ascii85(src: []const u8, dst: []u8) u32 {
    var n: u32 = 0;
    var tuple: u32 = 0;
    var count: u32 = 0;
    var i: usize = 0;
    // 앞의 <~ 는 건너뛴다
    if (src.len >= 2 and src[0] == '<' and src[1] == '~') i = 2;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '~') break;
        if (c == 'z' and count == 0) {
            if (n + 4 > dst.len) return n;
            dst[n] = 0; dst[n + 1] = 0; dst[n + 2] = 0; dst[n + 3] = 0;
            n += 4;
            continue;
        }
        if (c < '!' or c > 'u') continue;
        tuple = tuple *% 85 +% (c - '!');
        count += 1;
        if (count == 5) {
            if (n + 4 > dst.len) return n;
            dst[n] = @truncate(tuple >> 24);
            dst[n + 1] = @truncate(tuple >> 16);
            dst[n + 2] = @truncate(tuple >> 8);
            dst[n + 3] = @truncate(tuple);
            n += 4;
            tuple = 0;
            count = 0;
        }
    }
    if (count > 1) {
        var k = count;
        while (k < 5) : (k += 1) tuple = tuple *% 85 +% 84;
        var j: u32 = 0;
        while (j < count - 1) : (j += 1) {
            if (n >= dst.len) break;
            dst[n] = @truncate(tuple >> @intCast(24 - 8 * j));
            n += 1;
        }
    }
    return n;
}

/// 이어지는 값 압축 — 길이 바이트 하나에 자료가 따른다
pub fn runLength(src: []const u8, dst: []u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < src.len) {
        const l = src[i];
        i += 1;
        if (l == 128) break;
        if (l < 128) {
            const cnt = @as(usize, l) + 1;
            if (i + cnt > src.len or n + cnt > dst.len) break;
            var k: usize = 0;
            while (k < cnt) : (k += 1) dst[n + k] = src[i + k];
            n += @intCast(cnt);
            i += cnt;
        } else {
            if (i >= src.len) break;
            const cnt = 257 - @as(usize, l);
            if (n + cnt > dst.len) break;
            var k: usize = 0;
            while (k < cnt) : (k += 1) dst[n + k] = src[i];
            n += @intCast(cnt);
            i += 1;
        }
    }
    return n;
}

/// LZW — PDF 판. 부호 폭이 9 에서 12 까지 늘어난다.
pub fn lzw(src: []const u8, dst: []u8, early: u32) u32 {
    const CLEAR: u16 = 256;
    const EOD: u16 = 257;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var len_of: [4096]u16 = undefined;
    var next: u16 = 258;
    var width: u5 = 9;
    var prev: i32 = -1;
    var n: u32 = 0;
    var bitpos: usize = 0;
    var stack: [4096]u8 = undefined;

    var i: u16 = 0;
    while (i < 256) : (i += 1) { prefix[i] = 0xFFFF; suffix[i] = @intCast(i); len_of[i] = 1; }

    while (true) {
        if ((bitpos + width) > src.len * 8) break;
        var code: u16 = 0;
        var k: u5 = 0;
        while (k < width) : (k += 1) {
            const p = bitpos + k;
            const bit: u16 = (src[p / 8] >> @intCast(7 - (p % 8))) & 1;
            code = (code << 1) | bit;
        }
        bitpos += width;
        if (code == EOD) break;
        if (code == CLEAR) {
            next = 258;
            width = 9;
            prev = -1;
            continue;
        }
        var out_code = code;
        var first: u8 = 0;
        if (code >= next) {
            if (prev < 0) break;
            out_code = @intCast(prev);
        }
        // 사슬을 되짚어 쌓는다
        var sn: usize = 0;
        var c = out_code;
        var guard: u32 = 0;
        while (guard < 4096) : (guard += 1) {
            if (sn >= stack.len) break;
            stack[sn] = suffix[c];
            sn += 1;
            if (prefix[c] == 0xFFFF) break;
            c = prefix[c];
        }
        first = stack[sn - 1];
        if (code >= next) {
            // 아직 없는 부호 — 앞 것에 첫 글자를 붙인 것이다
            if (sn >= stack.len) break;
            var m = sn;
            while (m > 0) : (m -= 1) stack[m] = stack[m - 1];
            stack[0] = first;
            sn += 1;
        }
        var w = sn;
        while (w > 0) : (w -= 1) {
            if (n >= dst.len) return n;
            dst[n] = stack[w - 1];
            n += 1;
        }
        if (prev >= 0 and next < 4096) {
            prefix[next] = @intCast(prev);
            suffix[next] = first;
            len_of[next] = len_of[@intCast(prev)] + 1;
            next += 1;
        }
        prev = code;
        const limit: u16 = if (early != 0) 1 else 0;
        if (next + limit >= (@as(u16, 1) << @as(u4, @intCast(width))) and width < 12) width += 1;
    }
    return n;
}

/// PNG·TIFF 예측기를 되돌린다.
pub fn unpredict(buf: []u8, pred: u32, colors: u32, bpc: u32, columns: u32) u32 {
    if (pred < 2) return @intCast(buf.len);
    const bpp = @max(1, (colors * bpc + 7) / 8);
    const row = (columns * colors * bpc + 7) / 8;
    if (row == 0) return @intCast(buf.len);
    if (pred == 2) {
        // TIFF — 앞 화소를 더한다 (8비트만)
        if (bpc != 8) return @intCast(buf.len);
        var y: usize = 0;
        while ((y + 1) * row <= buf.len) : (y += 1) {
            var x: usize = bpp;
            while (x < row) : (x += 1) buf[y * row + x] +%= buf[y * row + x - bpp];
        }
        return @intCast(buf.len);
    }
    // PNG — 줄마다 앞에 방식 바이트가 하나 붙는다
    const in_row = row + 1;
    var out: u32 = 0;
    var y: usize = 0;
    while ((y + 1) * in_row <= buf.len) : (y += 1) {
        const ft = buf[y * in_row];
        const src = y * in_row + 1;
        var x: usize = 0;
        while (x < row) : (x += 1) {
            const raw = buf[src + x];
            const a: u8 = if (x >= bpp) buf[out + x - bpp] else 0;
            const b: u8 = if (y > 0) buf[out + x - row] else 0;
            const c: u8 = if (y > 0 and x >= bpp) buf[out + x - row - bpp] else 0;
            const v: u8 = switch (ft) {
                0 => raw,
                1 => raw +% a,
                2 => raw +% b,
                3 => raw +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => blk: {
                    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
                    const pa = if (p > a) p - @as(i32, a) else @as(i32, a) - p;
                    const pb = if (p > b) p - @as(i32, b) else @as(i32, b) - p;
                    const pc = if (p > c) p - @as(i32, c) else @as(i32, c) - p;
                    break :blk raw +% (if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c);
                },
                else => raw,
            };
            buf[out + x] = v;
        }
        out += row;
    }
    return out;
}
