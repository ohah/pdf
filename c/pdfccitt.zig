// CCITT G3/G4 팩스 그림 풀기.
//
// 스캔한 문서가 이 형식으로 들어 있는 일이 많다. 표는 ITU-T T.4 의 것을
// 그대로 옮겼다.

pub const Code = struct { len: u8, bits: u16, run: u16 };

pub const WHITE = [_]Code{
    .{ .len = 4, .bits = 7, .run = 2 },
    .{ .len = 4, .bits = 8, .run = 3 },
    .{ .len = 4, .bits = 11, .run = 4 },
    .{ .len = 4, .bits = 12, .run = 5 },
    .{ .len = 4, .bits = 14, .run = 6 },
    .{ .len = 4, .bits = 15, .run = 7 },
    .{ .len = 5, .bits = 7, .run = 10 },
    .{ .len = 5, .bits = 8, .run = 11 },
    .{ .len = 5, .bits = 18, .run = 128 },
    .{ .len = 5, .bits = 19, .run = 8 },
    .{ .len = 5, .bits = 20, .run = 9 },
    .{ .len = 5, .bits = 27, .run = 64 },
    .{ .len = 6, .bits = 3, .run = 13 },
    .{ .len = 6, .bits = 7, .run = 1 },
    .{ .len = 6, .bits = 8, .run = 12 },
    .{ .len = 6, .bits = 23, .run = 192 },
    .{ .len = 6, .bits = 24, .run = 1664 },
    .{ .len = 6, .bits = 42, .run = 16 },
    .{ .len = 6, .bits = 43, .run = 17 },
    .{ .len = 6, .bits = 52, .run = 14 },
    .{ .len = 6, .bits = 53, .run = 15 },
    .{ .len = 7, .bits = 3, .run = 22 },
    .{ .len = 7, .bits = 4, .run = 23 },
    .{ .len = 7, .bits = 8, .run = 20 },
    .{ .len = 7, .bits = 12, .run = 19 },
    .{ .len = 7, .bits = 19, .run = 26 },
    .{ .len = 7, .bits = 23, .run = 21 },
    .{ .len = 7, .bits = 24, .run = 28 },
    .{ .len = 7, .bits = 36, .run = 27 },
    .{ .len = 7, .bits = 39, .run = 18 },
    .{ .len = 7, .bits = 40, .run = 24 },
    .{ .len = 7, .bits = 43, .run = 25 },
    .{ .len = 7, .bits = 55, .run = 256 },
    .{ .len = 8, .bits = 2, .run = 29 },
    .{ .len = 8, .bits = 3, .run = 30 },
    .{ .len = 8, .bits = 4, .run = 45 },
    .{ .len = 8, .bits = 5, .run = 46 },
    .{ .len = 8, .bits = 10, .run = 47 },
    .{ .len = 8, .bits = 11, .run = 48 },
    .{ .len = 8, .bits = 18, .run = 33 },
    .{ .len = 8, .bits = 19, .run = 34 },
    .{ .len = 8, .bits = 20, .run = 35 },
    .{ .len = 8, .bits = 21, .run = 36 },
    .{ .len = 8, .bits = 22, .run = 37 },
    .{ .len = 8, .bits = 23, .run = 38 },
    .{ .len = 8, .bits = 26, .run = 31 },
    .{ .len = 8, .bits = 27, .run = 32 },
    .{ .len = 8, .bits = 36, .run = 53 },
    .{ .len = 8, .bits = 37, .run = 54 },
    .{ .len = 8, .bits = 40, .run = 39 },
    .{ .len = 8, .bits = 41, .run = 40 },
    .{ .len = 8, .bits = 42, .run = 41 },
    .{ .len = 8, .bits = 43, .run = 42 },
    .{ .len = 8, .bits = 44, .run = 43 },
    .{ .len = 8, .bits = 45, .run = 44 },
    .{ .len = 8, .bits = 50, .run = 61 },
    .{ .len = 8, .bits = 51, .run = 62 },
    .{ .len = 8, .bits = 52, .run = 63 },
    .{ .len = 8, .bits = 53, .run = 0 },
    .{ .len = 8, .bits = 54, .run = 320 },
    .{ .len = 8, .bits = 55, .run = 384 },
    .{ .len = 8, .bits = 74, .run = 59 },
    .{ .len = 8, .bits = 75, .run = 60 },
    .{ .len = 8, .bits = 82, .run = 49 },
    .{ .len = 8, .bits = 83, .run = 50 },
    .{ .len = 8, .bits = 84, .run = 51 },
    .{ .len = 8, .bits = 85, .run = 52 },
    .{ .len = 8, .bits = 88, .run = 55 },
    .{ .len = 8, .bits = 89, .run = 56 },
    .{ .len = 8, .bits = 90, .run = 57 },
    .{ .len = 8, .bits = 91, .run = 58 },
    .{ .len = 8, .bits = 100, .run = 448 },
    .{ .len = 8, .bits = 101, .run = 512 },
    .{ .len = 8, .bits = 103, .run = 640 },
    .{ .len = 8, .bits = 104, .run = 576 },
    .{ .len = 9, .bits = 152, .run = 1472 },
    .{ .len = 9, .bits = 153, .run = 1536 },
    .{ .len = 9, .bits = 154, .run = 1600 },
    .{ .len = 9, .bits = 155, .run = 1728 },
    .{ .len = 9, .bits = 204, .run = 704 },
    .{ .len = 9, .bits = 205, .run = 768 },
    .{ .len = 9, .bits = 210, .run = 832 },
    .{ .len = 9, .bits = 211, .run = 896 },
    .{ .len = 9, .bits = 212, .run = 960 },
    .{ .len = 9, .bits = 213, .run = 1024 },
    .{ .len = 9, .bits = 214, .run = 1088 },
    .{ .len = 9, .bits = 215, .run = 1152 },
    .{ .len = 9, .bits = 216, .run = 1216 },
    .{ .len = 9, .bits = 217, .run = 1280 },
    .{ .len = 9, .bits = 218, .run = 1344 },
    .{ .len = 9, .bits = 219, .run = 1408 },
    .{ .len = 11, .bits = 8, .run = 1792 },
    .{ .len = 11, .bits = 12, .run = 1856 },
    .{ .len = 11, .bits = 13, .run = 1920 },
    .{ .len = 12, .bits = 18, .run = 1984 },
    .{ .len = 12, .bits = 19, .run = 2048 },
    .{ .len = 12, .bits = 20, .run = 2112 },
    .{ .len = 12, .bits = 21, .run = 2176 },
    .{ .len = 12, .bits = 22, .run = 2240 },
    .{ .len = 12, .bits = 23, .run = 2304 },
    .{ .len = 12, .bits = 28, .run = 2368 },
    .{ .len = 12, .bits = 29, .run = 2432 },
    .{ .len = 12, .bits = 30, .run = 2496 },
    .{ .len = 12, .bits = 31, .run = 2560 },
};

pub const BLACK = [_]Code{
    .{ .len = 2, .bits = 2, .run = 3 },
    .{ .len = 2, .bits = 3, .run = 2 },
    .{ .len = 3, .bits = 2, .run = 1 },
    .{ .len = 3, .bits = 3, .run = 4 },
    .{ .len = 4, .bits = 2, .run = 6 },
    .{ .len = 4, .bits = 3, .run = 5 },
    .{ .len = 5, .bits = 3, .run = 7 },
    .{ .len = 6, .bits = 4, .run = 9 },
    .{ .len = 6, .bits = 5, .run = 8 },
    .{ .len = 7, .bits = 4, .run = 10 },
    .{ .len = 7, .bits = 5, .run = 11 },
    .{ .len = 7, .bits = 7, .run = 12 },
    .{ .len = 8, .bits = 4, .run = 13 },
    .{ .len = 8, .bits = 7, .run = 14 },
    .{ .len = 9, .bits = 24, .run = 15 },
    .{ .len = 10, .bits = 8, .run = 18 },
    .{ .len = 10, .bits = 15, .run = 64 },
    .{ .len = 10, .bits = 23, .run = 16 },
    .{ .len = 10, .bits = 24, .run = 17 },
    .{ .len = 10, .bits = 55, .run = 0 },
    .{ .len = 11, .bits = 8, .run = 1792 },
    .{ .len = 11, .bits = 12, .run = 1856 },
    .{ .len = 11, .bits = 13, .run = 1920 },
    .{ .len = 11, .bits = 23, .run = 24 },
    .{ .len = 11, .bits = 24, .run = 25 },
    .{ .len = 11, .bits = 40, .run = 23 },
    .{ .len = 11, .bits = 55, .run = 22 },
    .{ .len = 11, .bits = 103, .run = 19 },
    .{ .len = 11, .bits = 104, .run = 20 },
    .{ .len = 11, .bits = 108, .run = 21 },
    .{ .len = 12, .bits = 18, .run = 1984 },
    .{ .len = 12, .bits = 19, .run = 2048 },
    .{ .len = 12, .bits = 20, .run = 2112 },
    .{ .len = 12, .bits = 21, .run = 2176 },
    .{ .len = 12, .bits = 22, .run = 2240 },
    .{ .len = 12, .bits = 23, .run = 2304 },
    .{ .len = 12, .bits = 28, .run = 2368 },
    .{ .len = 12, .bits = 29, .run = 2432 },
    .{ .len = 12, .bits = 30, .run = 2496 },
    .{ .len = 12, .bits = 31, .run = 2560 },
    .{ .len = 12, .bits = 36, .run = 52 },
    .{ .len = 12, .bits = 39, .run = 55 },
    .{ .len = 12, .bits = 40, .run = 56 },
    .{ .len = 12, .bits = 43, .run = 59 },
    .{ .len = 12, .bits = 44, .run = 60 },
    .{ .len = 12, .bits = 51, .run = 320 },
    .{ .len = 12, .bits = 52, .run = 384 },
    .{ .len = 12, .bits = 53, .run = 448 },
    .{ .len = 12, .bits = 55, .run = 53 },
    .{ .len = 12, .bits = 56, .run = 54 },
    .{ .len = 12, .bits = 82, .run = 50 },
    .{ .len = 12, .bits = 83, .run = 51 },
    .{ .len = 12, .bits = 84, .run = 44 },
    .{ .len = 12, .bits = 85, .run = 45 },
    .{ .len = 12, .bits = 86, .run = 46 },
    .{ .len = 12, .bits = 87, .run = 47 },
    .{ .len = 12, .bits = 88, .run = 57 },
    .{ .len = 12, .bits = 89, .run = 58 },
    .{ .len = 12, .bits = 90, .run = 61 },
    .{ .len = 12, .bits = 91, .run = 256 },
    .{ .len = 12, .bits = 100, .run = 48 },
    .{ .len = 12, .bits = 101, .run = 49 },
    .{ .len = 12, .bits = 102, .run = 62 },
    .{ .len = 12, .bits = 103, .run = 63 },
    .{ .len = 12, .bits = 104, .run = 30 },
    .{ .len = 12, .bits = 105, .run = 31 },
    .{ .len = 12, .bits = 106, .run = 32 },
    .{ .len = 12, .bits = 107, .run = 33 },
    .{ .len = 12, .bits = 108, .run = 40 },
    .{ .len = 12, .bits = 109, .run = 41 },
    .{ .len = 12, .bits = 200, .run = 128 },
    .{ .len = 12, .bits = 201, .run = 192 },
    .{ .len = 12, .bits = 202, .run = 26 },
    .{ .len = 12, .bits = 203, .run = 27 },
    .{ .len = 12, .bits = 204, .run = 28 },
    .{ .len = 12, .bits = 205, .run = 29 },
    .{ .len = 12, .bits = 210, .run = 34 },
    .{ .len = 12, .bits = 211, .run = 35 },
    .{ .len = 12, .bits = 212, .run = 36 },
    .{ .len = 12, .bits = 213, .run = 37 },
    .{ .len = 12, .bits = 214, .run = 38 },
    .{ .len = 12, .bits = 215, .run = 39 },
    .{ .len = 12, .bits = 218, .run = 42 },
    .{ .len = 12, .bits = 219, .run = 43 },
    .{ .len = 13, .bits = 74, .run = 640 },
    .{ .len = 13, .bits = 75, .run = 704 },
    .{ .len = 13, .bits = 76, .run = 768 },
    .{ .len = 13, .bits = 77, .run = 832 },
    .{ .len = 13, .bits = 82, .run = 1280 },
    .{ .len = 13, .bits = 83, .run = 1344 },
    .{ .len = 13, .bits = 84, .run = 1408 },
    .{ .len = 13, .bits = 85, .run = 1472 },
    .{ .len = 13, .bits = 90, .run = 1536 },
    .{ .len = 13, .bits = 91, .run = 1600 },
    .{ .len = 13, .bits = 100, .run = 1664 },
    .{ .len = 13, .bits = 101, .run = 1728 },
    .{ .len = 13, .bits = 108, .run = 512 },
    .{ .len = 13, .bits = 109, .run = 576 },
    .{ .len = 13, .bits = 114, .run = 896 },
    .{ .len = 13, .bits = 115, .run = 960 },
    .{ .len = 13, .bits = 116, .run = 1024 },
    .{ .len = 13, .bits = 117, .run = 1088 },
    .{ .len = 13, .bits = 118, .run = 1152 },
    .{ .len = 13, .bits = 119, .run = 1216 },
};

/// 비트를 하나씩 읽는다.
pub const Bits = struct {
    data: []const u8,
    pos: usize = 0, // 비트 위치

    pub fn peek(self: *const Bits, n: u5) u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const p = self.pos + i;
            const byte = if (p / 8 < self.data.len) self.data[p / 8] else 0;
            const bit: u32 = (byte >> @intCast(7 - (p % 8))) & 1;
            v = (v << 1) | bit;
        }
        return v;
    }
    pub fn skip(self: *Bits, n: usize) void {
        self.pos += n;
    }
    pub fn done(self: *const Bits) bool {
        return self.pos >= self.data.len * 8;
    }
    pub fn alignByte(self: *Bits) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }
};

/// 한 번의 달림 길이를 읽는다. 마무리 부호가 나올 때까지 이어 붙인다.
fn oneRun(bs: *Bits, tab: []const Code) ?u16 {
    var total: u32 = 0;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        var hit: ?Code = null;
        for (tab) |c| {
            if (bs.peek(@intCast(c.len)) == c.bits) { hit = c; break; }
        }
        const c = hit orelse return null;
        bs.skip(c.len);
        total += c.run;
        if (c.run < 64) return @intCast(@min(total, 65535)); // 마무리 부호
        if (total > 65535) return null;
    }
    return null;
}

/// G4(2차원)와 G3 1차원을 푼다. 흰=0, 검=1 로 한 비트씩 dst 에 적는다.
/// 성공하면 true.
pub fn decode(src: []const u8, w: u32, h: u32, k: i32, byte_align: bool, dst: []u8) bool {
    var at: usize = 0;
    return decodeFrom(src, w, h, k, byte_align, dst, &at);
}

/// 같은 흐름에서 여러 판을 이어 푸는 판. JBIG2 하프톤이 비트평면을 한
/// 흐름에 이어 담고 판마다 EOFB 로 끊어 놓는다.
pub fn decodeFrom(src: []const u8, w: u32, h: u32, k: i32, byte_align: bool, dst: []u8, bitpos: *usize) bool {
    if (w == 0 or w > 20000 or h == 0) return false;
    const row_bytes = (w + 7) / 8;
    if (dst.len < row_bytes * h) return false;
    @memset(dst[0 .. row_bytes * h], 0);

    var bs = Bits{ .data = src, .pos = bitpos.* };
    var ref: [20002]u32 = undefined;
    var cur: [20002]u32 = undefined;
    var ref_n: u32 = 0;
    // 첫 참조 줄은 모두 흰색
    ref[0] = w;
    ref[1] = w;
    ref_n = 2;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var cur_n: u32 = 0;
        var a0: i64 = -1;
        var color: u1 = 0;
        var two_d = k < 0;
        if (k > 0) {
            // 섞인 방식 — EOL 뒤 한 비트가 방식을 알린다
            if (bs.peek(12) == 1) {
                bs.skip(12);
                two_d = bs.peek(1) == 0;
                bs.skip(1);
            }
        } else if (k == 0) {
            two_d = false;
            if (bs.peek(12) == 1) bs.skip(12);
        }

        var guard: u32 = 0;
        while (a0 < w and guard < 40000) : (guard += 1) {
            if (bs.done()) break;
            if (two_d) {
                // b1 = 참조 줄에서 a0 보다 큰, 지금 색과 다른 첫 변화점
                var b1: u32 = w;
                var i: u32 = 0;
                while (i < ref_n) : (i += 1) {
                    if (@as(i64, ref[i]) > a0 and (i % 2) == @as(u32, color)) { b1 = ref[i]; break; }
                }
                var b2: u32 = w;
                if (i + 1 < ref_n) b2 = ref[i + 1];

                if (bs.peek(4) == 0b0001) { // 지나가기
                    bs.skip(4);
                    a0 = b2;
                    continue;
                }
                if (bs.peek(3) == 0b001) { // 가로
                    bs.skip(3);
                    const start: u32 = if (a0 < 0) 0 else @intCast(a0);
                    const r1 = oneRun(&bs, if (color == 0) &WHITE else &BLACK) orelse break;
                    const r2 = oneRun(&bs, if (color == 0) &BLACK else &WHITE) orelse break;
                    const a1 = @min(start + r1, w);
                    const a2 = @min(a1 + r2, w);
                    if (cur_n + 2 <= cur.len) { cur[cur_n] = a1; cur[cur_n + 1] = a2; cur_n += 2; }
                    a0 = a2;
                    continue;
                }
                // 세로 방식
                var dv: i32 = 100;
                if (bs.peek(1) == 1) { bs.skip(1); dv = 0; }
                else if (bs.peek(3) == 0b011) { bs.skip(3); dv = 1; }
                else if (bs.peek(3) == 0b010) { bs.skip(3); dv = -1; }
                else if (bs.peek(6) == 0b000011) { bs.skip(6); dv = 2; }
                else if (bs.peek(6) == 0b000010) { bs.skip(6); dv = -2; }
                else if (bs.peek(7) == 0b0000011) { bs.skip(7); dv = 3; }
                else if (bs.peek(7) == 0b0000010) { bs.skip(7); dv = -3; }
                else break;
                const a1i: i64 = @as(i64, b1) + dv;
                const a1: u32 = if (a1i < 0) 0 else @intCast(@min(a1i, @as(i64, w)));
                if (cur_n < cur.len) { cur[cur_n] = a1; cur_n += 1; }
                a0 = a1;
                color = ~color;
            } else {
                // 1차원 — 흰/검 달림이 번갈아 나온다
                const start: u32 = if (a0 < 0) 0 else @intCast(a0);
                const r = oneRun(&bs, if (color == 0) &WHITE else &BLACK) orelse break;
                const a1 = @min(start + r, w);
                if (cur_n < cur.len) { cur[cur_n] = a1; cur_n += 1; }
                a0 = a1;
                color = ~color;
            }
        }

        // 변화점으로 줄을 칠한다
        {
            var x: u32 = 0;
            var c: u1 = 0;
            var i: u32 = 0;
            while (i < cur_n and x < w) : (i += 1) {
                const to = @min(cur[i], w);
                if (c == 1) {
                    var p = x;
                    while (p < to) : (p += 1)
                        dst[y * row_bytes + p / 8] |= @as(u8, 0x80) >> @intCast(p % 8);
                }
                x = to;
                c = ~c;
            }
            if (c == 1) {
                var p = x;
                while (p < w) : (p += 1)
                    dst[y * row_bytes + p / 8] |= @as(u8, 0x80) >> @intCast(p % 8);
            }
        }

        // 다음 줄의 참조로 쓴다
        var ci: u32 = 0;
        while (ci < cur_n) : (ci += 1) ref[ci] = cur[ci];
        ref_n = cur_n;
        if (ref_n + 2 < ref.len) { ref[ref_n] = w; ref[ref_n + 1] = w; ref_n += 2; }
        if (byte_align) bs.alignByte();
        if (bs.done()) { y += 1; break; }
    }
    // 판 끝을 알리는 EOFB(EOL 두 번)를 넘기고 바이트 경계에 맞춘다 —
    // 다음 판이 그 자리에서 이어 온다.
    if (bs.peek(24) == 0x001001) { bs.skip(24); bs.alignByte(); }
    bitpos.* = bs.pos;
    return true;
}
