const std = @import("std");

pub const Golay23_12 = struct {
    // Generator polynomial for Golay(23,12):
    //   g(x) = x^11 + x^9 + x^7 + x^6 + x^5 + x + 1
    //   Binary: 1010_1110_0011 = 0xAE3 (12 bits including leading 1)
    const generator_poly: u12 = 0xAE3;

    const syndrome_table: [2048]u23 = buildSyndromeTable();

    fn buildSyndromeTable() [2048]u23 {
        @setEvalBranchQuota(100_000);
        var table: [2048]u23 = .{0} ** 2048;

        // Weight 1: single-bit errors
        for (0..23) |i| {
            const pattern: u23 = @as(u23, 1) << @intCast(i);
            const syn = computeSyndrome(pattern);
            table[syn] = pattern;
        }

        // Weight 2: double-bit errors
        for (0..23) |i| {
            for ((i + 1)..23) |j| {
                const pattern: u23 = (@as(u23, 1) << @intCast(i)) | (@as(u23, 1) << @intCast(j));
                const syn = computeSyndrome(pattern);
                table[syn] = pattern;
            }
        }

        // Weight 3: triple-bit errors
        for (0..23) |i| {
            for ((i + 1)..23) |j| {
                for ((j + 1)..23) |k| {
                    const pattern: u23 = (@as(u23, 1) << @intCast(i)) | (@as(u23, 1) << @intCast(j)) | (@as(u23, 1) << @intCast(k));
                    const syn = computeSyndrome(pattern);
                    table[syn] = pattern;
                }
            }
        }

        return table;
    }

    fn computeSyndrome(word: u23) u11 {
        var rem: u23 = word;
        for (0..12) |i| {
            const bit_pos: u5 = @intCast(22 - i);
            if (rem & (@as(u23, 1) << bit_pos) != 0) {
                const shift: u5 = @intCast(11 - i);
                rem ^= @as(u23, generator_poly) << shift;
            }
        }
        return @intCast(rem & 0x7FF);
    }

    pub fn encode(data: u12) u23 {
        const shifted: u23 = @as(u23, data) << 11;
        const parity = computeSyndrome(shifted);
        return shifted | @as(u23, parity);
    }

    pub fn decode(received: u23) ?u12 {
        const syn = computeSyndrome(received);
        if (syn == 0) return @intCast(received >> 11);
        const error_pattern = syndrome_table[syn];
        if (error_pattern == 0) return null;
        const corrected = received ^ error_pattern;
        return @intCast(corrected >> 11);
    }

    pub const DcsCode = struct {
        code: u16,
    };

    const standard_dcs_codes = [104]u16{
        0o023, 0o025, 0o026, 0o031, 0o032, 0o036, 0o043, 0o047,
        0o051, 0o053, 0o054, 0o065, 0o071, 0o072, 0o073, 0o074,
        0o114, 0o115, 0o116, 0o122, 0o125, 0o131, 0o132, 0o134,
        0o143, 0o145, 0o152, 0o155, 0o156, 0o162, 0o165, 0o172,
        0o174, 0o205, 0o212, 0o223, 0o225, 0o226, 0o243, 0o244,
        0o245, 0o246, 0o251, 0o252, 0o255, 0o261, 0o263, 0o265,
        0o266, 0o271, 0o274, 0o306, 0o311, 0o315, 0o325, 0o331,
        0o332, 0o343, 0o346, 0o351, 0o356, 0o364, 0o365, 0o371,
        0o411, 0o412, 0o413, 0o423, 0o431, 0o432, 0o445, 0o446,
        0o452, 0o454, 0o455, 0o462, 0o464, 0o465, 0o466, 0o503,
        0o506, 0o516, 0o523, 0o526, 0o532, 0o546, 0o565, 0o606,
        0o612, 0o624, 0o627, 0o631, 0o632, 0o654, 0o662, 0o664,
        0o703, 0o712, 0o723, 0o731, 0o732, 0o734, 0o743, 0o754,
    };

    const dcs_bitset: [8]u64 = buildDcsBitset();

    fn buildDcsBitset() [8]u64 {
        var bits: [8]u64 = .{0} ** 8;
        for (standard_dcs_codes) |code| {
            const word_idx = code >> 6;
            const bit_idx: u6 = @intCast(code & 0x3F);
            bits[word_idx] |= @as(u64, 1) << bit_idx;
        }
        return bits;
    }

    pub fn isStandardDcsCode(code: u16) bool {
        if (code >= 512) return false;
        const word_idx = code >> 6;
        const bit_idx: u6 = @intCast(code & 0x3F);
        return (dcs_bitset[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    pub fn isDcsCodeValid(codeword: u23) ?DcsCode {
        const data = decode(codeword) orelse return null;
        if ((data >> 9) & 0x7 != 0b100) return null;
        const octal_code: u16 = @intCast(data & 0x1FF);
        if (!isStandardDcsCode(octal_code)) return null;
        return .{ .code = octal_code };
    }

    pub fn dcsCodeToOctalString(code: u16) [3]u8 {
        var buf: [3]u8 = undefined;
        buf[0] = '0' + @as(u8, @intCast((code >> 6) & 0x7));
        buf[1] = '0' + @as(u8, @intCast((code >> 3) & 0x7));
        buf[2] = '0' + @as(u8, @intCast(code & 0x7));
        return buf;
    }
};

const testing = std.testing;

test "encode produces valid codewords" {
    for (0..4096) |i| {
        const data: u12 = @intCast(i);
        const codeword = Golay23_12.encode(data);
        const syn = Golay23_12.computeSyndrome(codeword);
        try testing.expectEqual(@as(u11, 0), syn);
    }
}

test "decode roundtrip" {
    const test_values = [_]u12{ 0, 1, 0x7FF, 0xFFF, 0x123, 0xABC, 0x555, 0xAAA };
    for (test_values) |data| {
        const codeword = Golay23_12.encode(data);
        const decoded = Golay23_12.decode(codeword);
        try testing.expect(decoded != null);
        try testing.expectEqual(data, decoded.?);
    }
}

test "correct single-bit errors" {
    const data: u12 = 0x3E7;
    const codeword = Golay23_12.encode(data);

    for (0..23) |i| {
        const error_pattern: u23 = @as(u23, 1) << @intCast(i);
        const corrupted = codeword ^ error_pattern;
        const decoded = Golay23_12.decode(corrupted);
        try testing.expect(decoded != null);
        try testing.expectEqual(data, decoded.?);
    }
}

test "correct double-bit errors" {
    const data: u12 = 0x1A5;
    const codeword = Golay23_12.encode(data);

    for (0..23) |i| {
        for ((i + 1)..23) |j| {
            const error_pattern: u23 = (@as(u23, 1) << @intCast(i)) | (@as(u23, 1) << @intCast(j));
            const corrupted = codeword ^ error_pattern;
            const decoded = Golay23_12.decode(corrupted);
            try testing.expect(decoded != null);
            try testing.expectEqual(data, decoded.?);
        }
    }
}

test "correct triple-bit errors" {
    const data: u12 = 0xC0D;
    const codeword = Golay23_12.encode(data);
    var tested: usize = 0;

    for (0..23) |i| {
        for ((i + 1)..23) |j| {
            for ((j + 1)..23) |k| {
                const error_pattern: u23 = (@as(u23, 1) << @intCast(i)) | (@as(u23, 1) << @intCast(j)) | (@as(u23, 1) << @intCast(k));
                const corrupted = codeword ^ error_pattern;
                const decoded = Golay23_12.decode(corrupted);
                try testing.expect(decoded != null);
                try testing.expectEqual(data, decoded.?);
                tested += 1;
            }
        }
    }

    try testing.expectEqual(@as(usize, 1771), tested);
}

test "reject 4-bit errors" {
    const data: u12 = 0x492;
    const codeword = Golay23_12.encode(data);
    var null_count: usize = 0;
    var total: usize = 0;

    for (0..23) |i| {
        for ((i + 1)..23) |j| {
            for ((j + 1)..23) |k| {
                for ((k + 1)..23) |l| {
                    const error_pattern: u23 = (@as(u23, 1) << @intCast(i)) |
                        (@as(u23, 1) << @intCast(j)) |
                        (@as(u23, 1) << @intCast(k)) |
                        (@as(u23, 1) << @intCast(l));
                    const corrupted = codeword ^ error_pattern;
                    const decoded = Golay23_12.decode(corrupted);
                    if (decoded == null or decoded.? != data) {
                        null_count += 1;
                    }
                    total += 1;
                }
            }
        }
    }

    try testing.expect(total == 8855);
    try testing.expect(null_count > total / 2);
}

test "syndrome table covers all 2048 entries" {
    var populated: usize = 0;
    if (Golay23_12.syndrome_table[0] == 0) populated += 1;
    for (1..2048) |i| {
        if (Golay23_12.syndrome_table[i] != 0) populated += 1;
    }
    try testing.expectEqual(@as(usize, 2048), populated);
}

test "syndrome table entries have correct weight" {
    try testing.expectEqual(@as(u23, 0), Golay23_12.syndrome_table[0]);
    for (1..2048) |i| {
        const pattern = Golay23_12.syndrome_table[i];
        try testing.expect(pattern != 0);
        const weight = @popCount(pattern);
        try testing.expect(weight >= 1 and weight <= 3);
        const verify_syn = Golay23_12.computeSyndrome(pattern);
        try testing.expectEqual(@as(u11, @intCast(i)), verify_syn);
    }
}

test "minimum distance is 7" {
    var min_weight: u32 = 24;
    for (1..4096) |i| {
        const data: u12 = @intCast(i);
        const codeword = Golay23_12.encode(data);
        const weight: u32 = @popCount(codeword);
        if (weight < min_weight) min_weight = weight;
    }
    try testing.expectEqual(@as(u32, 7), min_weight);
}

test "DCS code validation with standard codes" {
    for (Golay23_12.standard_dcs_codes) |code| {
        try testing.expect(Golay23_12.isStandardDcsCode(code));
    }
    try testing.expect(!Golay23_12.isStandardDcsCode(0));
    try testing.expect(!Golay23_12.isStandardDcsCode(1));
    try testing.expect(!Golay23_12.isStandardDcsCode(511));
}

test "DCS encode/decode roundtrip" {
    const signature: u12 = 0b100_000000000;
    for (Golay23_12.standard_dcs_codes) |code| {
        const data: u12 = signature | @as(u12, @intCast(code));
        const codeword = Golay23_12.encode(data);
        const result = Golay23_12.isDcsCodeValid(codeword);
        try testing.expect(result != null);
        try testing.expectEqual(code, result.?.code);
    }
}

test "DCS rejects wrong signature bits" {
    const bad_signature: u12 = 0b010_000000000;
    const code: u12 = 0o023;
    const data: u12 = bad_signature | code;
    const codeword = Golay23_12.encode(data);
    const result = Golay23_12.isDcsCodeValid(codeword);
    try testing.expect(result == null);
}

test "DCS octal string formatting" {
    const s1 = Golay23_12.dcsCodeToOctalString(0o023);
    try testing.expectEqualStrings("023", &s1);
    const s2 = Golay23_12.dcsCodeToOctalString(0o754);
    try testing.expectEqualStrings("754", &s2);
    const s3 = Golay23_12.dcsCodeToOctalString(0o365);
    try testing.expectEqualStrings("365", &s3);
}
