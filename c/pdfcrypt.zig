// PDF 암호 풀기에 필요한 알고리즘들.
//
// 표준 보안 처리기는 MD5·RC4 (판 2~4) 와 SHA-2·AES (판 5~6) 를 쓴다.
// 여기서는 그 다섯 가지를 직접 적는다 — 링크할 라이브러리가 없고,
// 필요한 부분만 쓰면 얼마 되지 않는다.

// ===== MD5 =====
pub const Md5 = struct {
    a: u32 = 0x67452301,
    b: u32 = 0xefcdab89,
    c: u32 = 0x98badcfe,
    d: u32 = 0x10325476,
    buf: [64]u8 = undefined,
    n: usize = 0,
    total: u64 = 0,

    const S = [64]u5{
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };
    const K = blk: {
        var k: [64]u32 = undefined;
        for (&k, 0..) |*v, i| {
            // floor(abs(sin(i+1)) * 2^32) 를 미리 적어 둔다
            v.* = KTAB[i];
        }
        break :blk k;
    };
    const KTAB = [64]u32{
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    };

    fn block(self: *Md5, m: []const u8) void {
        var w: [16]u32 = undefined;
        for (&w, 0..) |*v, i| {
            v.* = @as(u32, m[i * 4]) | (@as(u32, m[i * 4 + 1]) << 8) |
                (@as(u32, m[i * 4 + 2]) << 16) | (@as(u32, m[i * 4 + 3]) << 24);
        }
        var a = self.a;
        var b = self.b;
        var c = self.c;
        var d = self.d;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            var f: u32 = undefined;
            var g: usize = undefined;
            if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) % 16;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            } else {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
            }
            const tmp = d;
            d = c;
            c = b;
            const x = a +% f +% KTAB[i] +% w[g];
            b = b +% ((x << S[i]) | (x >> @intCast(32 - @as(u32, S[i]))));
            a = tmp;
        }
        self.a +%= a;
        self.b +%= b;
        self.c +%= c;
        self.d +%= d;
    }

    pub fn update(self: *Md5, data: []const u8) void {
        self.total +%= data.len;
        var i: usize = 0;
        while (i < data.len) {
            const take = @min(64 - self.n, data.len - i);
            @memcpy(self.buf[self.n..][0..take], data[i..][0..take]);
            self.n += take;
            i += take;
            if (self.n == 64) {
                self.block(&self.buf);
                self.n = 0;
            }
        }
    }

    pub fn final(self: *Md5, out: *[16]u8) void {
        const bits = self.total *% 8;
        var pad: [72]u8 = undefined;
        @memset(&pad, 0);
        pad[0] = 0x80;
        const rem = self.n % 64;
        const padlen: usize = if (rem < 56) 56 - rem else 120 - rem;
        self.update(pad[0..padlen]);
        var lenb: [8]u8 = undefined;
        var k: usize = 0;
        while (k < 8) : (k += 1) lenb[k] = @truncate(bits >> @intCast(8 * k));
        self.update(&lenb);
        const st = [4]u32{ self.a, self.b, self.c, self.d };
        for (st, 0..) |v, i| {
            out[i * 4] = @truncate(v);
            out[i * 4 + 1] = @truncate(v >> 8);
            out[i * 4 + 2] = @truncate(v >> 16);
            out[i * 4 + 3] = @truncate(v >> 24);
        }
    }
};

pub fn md5(parts: []const []const u8, out: *[16]u8) void {
    var h = Md5{};
    for (parts) |p| h.update(p);
    h.final(out);
}

// ===== RC4 =====
pub fn rc4(key: []const u8, data: []u8) void {
    var s: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) s[i] = @intCast(i);
    var j: u8 = 0;
    i = 0;
    while (i < 256) : (i += 1) {
        j = j +% s[i] +% key[i % key.len];
        const t = s[i];
        s[i] = s[j];
        s[j] = t;
    }
    var x: u8 = 0;
    var y: u8 = 0;
    for (data) |*b| {
        x +%= 1;
        y +%= s[x];
        const t = s[x];
        s[x] = s[y];
        s[y] = t;
        b.* ^= s[@as(u8, s[x] +% s[y])];
    }
}

// ===== SHA-256 =====
const K256 = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

fn ror32(x: u32, n: u5) u32 {
    return (x >> n) | (x << @intCast(32 - @as(u32, n)));
}

pub fn sha256(parts: []const []const u8, out: *[32]u8) void {
    var h = [8]u32{
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    var total: u64 = 0;
    for (parts) |p| total += p.len;
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    const doBlock = struct {
        fn go(hh: *[8]u32, m: []const u8) void {
            var w: [64]u32 = undefined;
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                w[i] = (@as(u32, m[i * 4]) << 24) | (@as(u32, m[i * 4 + 1]) << 16) |
                    (@as(u32, m[i * 4 + 2]) << 8) | m[i * 4 + 3];
            }
            while (i < 64) : (i += 1) {
                const s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
                const s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
            }
            var a = hh[0];
            var b = hh[1];
            var c = hh[2];
            var d = hh[3];
            var e = hh[4];
            var f = hh[5];
            var g = hh[6];
            var hx = hh[7];
            i = 0;
            while (i < 64) : (i += 1) {
                const S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
                const ch = (e & f) ^ (~e & g);
                const t1 = hx +% S1 +% ch +% K256[i] +% w[i];
                const S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
                const mj = (a & b) ^ (a & c) ^ (b & c);
                const t2 = S0 +% mj;
                hx = g;
                g = f;
                f = e;
                e = d +% t1;
                d = c;
                c = b;
                b = a;
                a = t1 +% t2;
            }
            hh[0] +%= a;
            hh[1] +%= b;
            hh[2] +%= c;
            hh[3] +%= d;
            hh[4] +%= e;
            hh[5] +%= f;
            hh[6] +%= g;
            hh[7] +%= hx;
        }
    }.go;
    for (parts) |p| {
        var i: usize = 0;
        while (i < p.len) {
            const take = @min(64 - n, p.len - i);
            @memcpy(buf[n..][0..take], p[i..][0..take]);
            n += take;
            i += take;
            if (n == 64) {
                doBlock(&h, &buf);
                n = 0;
            }
        }
    }
    // 채우기
    var tail: [128]u8 = undefined;
    @memset(&tail, 0);
    @memcpy(tail[0..n], buf[0..n]);
    tail[n] = 0x80;
    const bits = total * 8;
    const total_len: usize = if (n < 56) 64 else 128;
    var k: usize = 0;
    while (k < 8) : (k += 1) tail[total_len - 1 - k] = @truncate(bits >> @intCast(8 * k));
    doBlock(&h, tail[0..64]);
    if (total_len == 128) doBlock(&h, tail[64..128]);
    for (h, 0..) |v, i| {
        out[i * 4] = @truncate(v >> 24);
        out[i * 4 + 1] = @truncate(v >> 16);
        out[i * 4 + 2] = @truncate(v >> 8);
        out[i * 4 + 3] = @truncate(v);
    }
}

// ===== SHA-512 / SHA-384 =====
const K512 = [80]u64{
    0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
    0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
    0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
    0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
    0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
    0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
    0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
    0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
    0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
    0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
    0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
    0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
    0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
    0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
    0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
};

fn ror64(x: u64, n: u6) u64 {
    return (x >> n) | (x << @intCast(64 - @as(u64, n)));
}

fn sha512core(parts: []const []const u8, h0: [8]u64, out: []u8) void {
    var h = h0;
    var total: u64 = 0;
    for (parts) |p| total += p.len;
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const doBlock = struct {
        fn go(hh: *[8]u64, m: []const u8) void {
            var w: [80]u64 = undefined;
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                var v: u64 = 0;
                var k: usize = 0;
                while (k < 8) : (k += 1) v = (v << 8) | m[i * 8 + k];
                w[i] = v;
            }
            while (i < 80) : (i += 1) {
                const s0 = ror64(w[i - 15], 1) ^ ror64(w[i - 15], 8) ^ (w[i - 15] >> 7);
                const s1 = ror64(w[i - 2], 19) ^ ror64(w[i - 2], 61) ^ (w[i - 2] >> 6);
                w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
            }
            var a = hh[0];
            var b = hh[1];
            var c = hh[2];
            var d = hh[3];
            var e = hh[4];
            var f = hh[5];
            var g = hh[6];
            var hx = hh[7];
            i = 0;
            while (i < 80) : (i += 1) {
                const S1 = ror64(e, 14) ^ ror64(e, 18) ^ ror64(e, 41);
                const ch = (e & f) ^ (~e & g);
                const t1 = hx +% S1 +% ch +% K512[i] +% w[i];
                const S0 = ror64(a, 28) ^ ror64(a, 34) ^ ror64(a, 39);
                const mj = (a & b) ^ (a & c) ^ (b & c);
                const t2 = S0 +% mj;
                hx = g;
                g = f;
                f = e;
                e = d +% t1;
                d = c;
                c = b;
                b = a;
                a = t1 +% t2;
            }
            hh[0] +%= a;
            hh[1] +%= b;
            hh[2] +%= c;
            hh[3] +%= d;
            hh[4] +%= e;
            hh[5] +%= f;
            hh[6] +%= g;
            hh[7] +%= hx;
        }
    }.go;
    for (parts) |p| {
        var i: usize = 0;
        while (i < p.len) {
            const take = @min(128 - n, p.len - i);
            @memcpy(buf[n..][0..take], p[i..][0..take]);
            n += take;
            i += take;
            if (n == 128) {
                doBlock(&h, &buf);
                n = 0;
            }
        }
    }
    var tail: [256]u8 = undefined;
    @memset(&tail, 0);
    @memcpy(tail[0..n], buf[0..n]);
    tail[n] = 0x80;
    const bits = total * 8;
    const total_len: usize = if (n < 112) 128 else 256;
    var k: usize = 0;
    while (k < 8) : (k += 1) tail[total_len - 1 - k] = @truncate(bits >> @intCast(8 * k));
    doBlock(&h, tail[0..128]);
    if (total_len == 256) doBlock(&h, tail[128..256]);
    var i: usize = 0;
    while (i * 8 < out.len) : (i += 1) {
        var k2: usize = 0;
        while (k2 < 8 and i * 8 + k2 < out.len) : (k2 += 1)
            out[i * 8 + k2] = @truncate(h[i] >> @intCast(56 - 8 * k2));
    }
}

pub fn sha512(parts: []const []const u8, out: *[64]u8) void {
    sha512core(parts, .{
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    }, out);
}

pub fn sha384(parts: []const []const u8, out: *[48]u8) void {
    sha512core(parts, .{
        0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
        0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4,
    }, out);
}

// ===== AES =====
const SBOX = [256]u8{
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
};
const RSBOX = blk: {
    var r: [256]u8 = undefined;
    for (SBOX, 0..) |v, i| r[v] = @intCast(i);
    break :blk r;
};

fn xtime(x: u8) u8 {
    return (x << 1) ^ (if (x & 0x80 != 0) @as(u8, 0x1b) else 0);
}
fn mul(a: u8, b: u8) u8 {
    var r: u8 = 0;
    var x = a;
    var y = b;
    while (y != 0) : (y >>= 1) {
        if (y & 1 != 0) r ^= x;
        x = xtime(x);
    }
    return r;
}

pub const Aes = struct {
    rk: [60]u32 = undefined,
    nr: u32 = 10,

    pub fn init(key: []const u8) Aes {
        var a = Aes{};
        const nk: u32 = @intCast(key.len / 4);
        a.nr = nk + 6;
        var i: u32 = 0;
        while (i < nk) : (i += 1) {
            a.rk[i] = (@as(u32, key[i * 4]) << 24) | (@as(u32, key[i * 4 + 1]) << 16) |
                (@as(u32, key[i * 4 + 2]) << 8) | key[i * 4 + 3];
        }
        var rcon: u8 = 1;
        while (i < 4 * (a.nr + 1)) : (i += 1) {
            var t = a.rk[i - 1];
            if (i % nk == 0) {
                t = (t << 8) | (t >> 24);
                t = (@as(u32, SBOX[@as(u8, @truncate(t >> 24))]) << 24) |
                    (@as(u32, SBOX[@as(u8, @truncate(t >> 16))]) << 16) |
                    (@as(u32, SBOX[@as(u8, @truncate(t >> 8))]) << 8) |
                    SBOX[@as(u8, @truncate(t))];
                t ^= @as(u32, rcon) << 24;
                rcon = xtime(rcon);
            } else if (nk > 6 and i % nk == 4) {
                t = (@as(u32, SBOX[@as(u8, @truncate(t >> 24))]) << 24) |
                    (@as(u32, SBOX[@as(u8, @truncate(t >> 16))]) << 16) |
                    (@as(u32, SBOX[@as(u8, @truncate(t >> 8))]) << 8) |
                    SBOX[@as(u8, @truncate(t))];
            }
            a.rk[i] = a.rk[i - nk] ^ t;
        }
        return a;
    }

    fn addRound(self: *const Aes, st: *[16]u8, r: u32) void {
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const w = self.rk[r * 4 + i];
            st[i * 4] ^= @truncate(w >> 24);
            st[i * 4 + 1] ^= @truncate(w >> 16);
            st[i * 4 + 2] ^= @truncate(w >> 8);
            st[i * 4 + 3] ^= @truncate(w);
        }
    }

    pub fn encryptBlock(self: *const Aes, blk2: *[16]u8) void {
        self.addRound(blk2, 0);
        var r: u32 = 1;
        while (r <= self.nr) : (r += 1) {
            for (blk2) |*v| v.* = SBOX[v.*];
            // ShiftRows
            var t: [16]u8 = blk2.*;
            var c: usize = 0;
            while (c < 4) : (c += 1) {
                blk2[c * 4 + 1] = t[((c + 1) % 4) * 4 + 1];
                blk2[c * 4 + 2] = t[((c + 2) % 4) * 4 + 2];
                blk2[c * 4 + 3] = t[((c + 3) % 4) * 4 + 3];
            }
            if (r != self.nr) {
                t = blk2.*;
                c = 0;
                while (c < 4) : (c += 1) {
                    const a0 = t[c * 4];
                    const a1 = t[c * 4 + 1];
                    const a2 = t[c * 4 + 2];
                    const a3 = t[c * 4 + 3];
                    blk2[c * 4] = mul(a0, 2) ^ mul(a1, 3) ^ a2 ^ a3;
                    blk2[c * 4 + 1] = a0 ^ mul(a1, 2) ^ mul(a2, 3) ^ a3;
                    blk2[c * 4 + 2] = a0 ^ a1 ^ mul(a2, 2) ^ mul(a3, 3);
                    blk2[c * 4 + 3] = mul(a0, 3) ^ a1 ^ a2 ^ mul(a3, 2);
                }
            }
            self.addRound(blk2, r);
        }
    }

    pub fn decryptBlock(self: *const Aes, blk2: *[16]u8) void {
        self.addRound(blk2, self.nr);
        var r: u32 = self.nr;
        while (r > 0) : (r -= 1) {
            // InvShiftRows
            var t: [16]u8 = blk2.*;
            var c: usize = 0;
            while (c < 4) : (c += 1) {
                blk2[((c + 1) % 4) * 4 + 1] = t[c * 4 + 1];
                blk2[((c + 2) % 4) * 4 + 2] = t[c * 4 + 2];
                blk2[((c + 3) % 4) * 4 + 3] = t[c * 4 + 3];
            }
            for (blk2) |*v| v.* = RSBOX[v.*];
            self.addRound(blk2, r - 1);
            if (r != 1) {
                t = blk2.*;
                c = 0;
                while (c < 4) : (c += 1) {
                    const a0 = t[c * 4];
                    const a1 = t[c * 4 + 1];
                    const a2 = t[c * 4 + 2];
                    const a3 = t[c * 4 + 3];
                    blk2[c * 4] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9);
                    blk2[c * 4 + 1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13);
                    blk2[c * 4 + 2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11);
                    blk2[c * 4 + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14);
                }
            }
        }
    }
};

/// CBC 로 푼다. 앞 16바이트가 IV 다. 채움을 뗀 길이를 준다.
pub fn aesCbcDecrypt(key: []const u8, data: []u8) u32 {
    if (data.len < 32 or data.len % 16 != 0) return 0;
    const a = Aes.init(key);
    var iv: [16]u8 = undefined;
    @memcpy(&iv, data[0..16]);
    var out: u32 = 0;
    var i: usize = 16;
    while (i + 16 <= data.len) : (i += 16) {
        var blk2: [16]u8 = undefined;
        @memcpy(&blk2, data[i..][0..16]);
        const cipher = blk2;
        a.decryptBlock(&blk2);
        var k: usize = 0;
        while (k < 16) : (k += 1) data[out + k] = blk2[k] ^ iv[k];
        iv = cipher;
        out += 16;
    }
    if (out == 0) return 0;
    const pad = data[out - 1];
    if (pad >= 1 and pad <= 16 and pad <= out) out -= pad;
    return out;
}

/// IV 없이 CBC 로 푼다 (판 5·6 의 UE·OE 에 쓴다)
pub fn aesCbcNoIvDecrypt(key: []const u8, data: []u8) void {
    const a = Aes.init(key);
    var iv = [_]u8{0} ** 16;
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        var blk2: [16]u8 = undefined;
        @memcpy(&blk2, data[i..][0..16]);
        const cipher = blk2;
        a.decryptBlock(&blk2);
        var k: usize = 0;
        while (k < 16) : (k += 1) data[i + k] = blk2[k] ^ iv[k];
        iv = cipher;
    }
}

/// CBC 로 잠근다 (판 6 의 해시 2.B 에 쓴다)
pub fn aesCbcEncrypt(key: []const u8, iv0: []const u8, data: []u8) void {
    const a = Aes.init(key);
    var iv: [16]u8 = undefined;
    @memcpy(&iv, iv0[0..16]);
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        var blk2: [16]u8 = undefined;
        var k: usize = 0;
        while (k < 16) : (k += 1) blk2[k] = data[i + k] ^ iv[k];
        a.encryptBlock(&blk2);
        @memcpy(data[i..][0..16], &blk2);
        iv = blk2;
    }
}
