const std = @import("std");

pub const SquelchMode = enum(u8) {
    carrier_only = 0,
    ctcss_any = 1,
    ctcss_match = 2,
    dcs_any = 3,
    dcs_match = 4,
    tone_any = 5,
};

pub const ToneSquelch = struct {
    mode: SquelchMode = .carrier_only,
    expected_ctcss_index: i8 = -1,
    expected_dcs_code: i16 = -1,
    expected_dcs_inverted: u8 = 0,

    is_open: bool = false,
    ramp_pos: u32 = 0,
    ramp_samples: u32,
    sample_rate: f32,

    pub fn init(sample_rate: f32) ToneSquelch {
        return .{
            .ramp_samples = @intFromFloat(0.010 * sample_rate),
            .sample_rate = sample_rate,
        };
    }

    pub fn evaluate(
        self: *ToneSquelch,
        ctcss_confirmed_index: i8,
        dcs_code: i16,
        dcs_inverted: u8,
    ) bool {
        const result = switch (self.mode) {
            .carrier_only => true,
            .ctcss_any => ctcss_confirmed_index >= 0,
            .ctcss_match => ctcss_confirmed_index >= 0 and ctcss_confirmed_index == self.expected_ctcss_index,
            .dcs_any => dcs_code >= 0,
            .dcs_match => dcs_code >= 0 and
                dcs_code == self.expected_dcs_code and
                dcs_inverted == self.expected_dcs_inverted,
            .tone_any => ctcss_confirmed_index >= 0 or dcs_code >= 0,
        };

        if (result != self.is_open) {
            self.ramp_pos = 0;
        }
        self.is_open = result;

        return result;
    }

    pub fn gate(self: *ToneSquelch, audio: []f32) void {
        if (self.mode == .carrier_only) return;

        if (self.is_open) {
            if (self.ramp_pos < self.ramp_samples) {
                for (audio) |*s| {
                    const gain = if (self.ramp_samples > 0) blk: {
                        const frac = @as(f32, @floatFromInt(@min(self.ramp_pos, self.ramp_samples))) /
                            @as(f32, @floatFromInt(self.ramp_samples));
                        break :blk 0.5 * (1.0 - @cos(std.math.pi * frac));
                    } else 1.0;
                    s.* *= gain;
                    if (self.ramp_pos < self.ramp_samples) self.ramp_pos += 1;
                }
            }
        } else {
            if (self.ramp_pos < self.ramp_samples) {
                for (audio) |*s| {
                    const gain = if (self.ramp_samples > 0) blk: {
                        const frac = @as(f32, @floatFromInt(@min(self.ramp_pos, self.ramp_samples))) /
                            @as(f32, @floatFromInt(self.ramp_samples));
                        break :blk 0.5 * (1.0 + @cos(std.math.pi * frac));
                    } else 0.0;
                    s.* *= gain;
                    if (self.ramp_pos < self.ramp_samples) self.ramp_pos += 1;
                }
            } else {
                @memset(audio, 0.0);
            }
        }
    }

    pub fn reset(self: *ToneSquelch) void {
        self.is_open = false;
        self.ramp_pos = 0;
    }
};

const testing = std.testing;

test "carrier_only always passes" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .carrier_only;

    _ = sq.evaluate(-1, -1, 0);
    try testing.expect(sq.is_open);

    var audio = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    sq.gate(&audio);
    try testing.expectApproxEqAbs(@as(f32, 0.5), audio[0], 0.001);
}

test "ctcss_any opens on any confirmed tone" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .ctcss_any;

    _ = sq.evaluate(-1, -1, 0);
    try testing.expect(!sq.is_open);

    _ = sq.evaluate(5, -1, 0);
    try testing.expect(sq.is_open);
}

test "ctcss_match requires specific tone" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .ctcss_match;
    sq.expected_ctcss_index = 12;

    _ = sq.evaluate(5, -1, 0);
    try testing.expect(!sq.is_open);

    _ = sq.evaluate(12, -1, 0);
    try testing.expect(sq.is_open);
}

test "dcs_any opens on any DCS code" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .dcs_any;

    _ = sq.evaluate(-1, -1, 0);
    try testing.expect(!sq.is_open);

    _ = sq.evaluate(-1, 23, 0);
    try testing.expect(sq.is_open);
}

test "dcs_match requires specific code and polarity" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .dcs_match;
    sq.expected_dcs_code = 0o743;
    sq.expected_dcs_inverted = 1;

    _ = sq.evaluate(-1, 0o743, 0);
    try testing.expect(!sq.is_open);

    _ = sq.evaluate(-1, 0o023, 1);
    try testing.expect(!sq.is_open);

    _ = sq.evaluate(-1, 0o743, 1);
    try testing.expect(sq.is_open);
}

test "tone_any opens on CTCSS or DCS" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .tone_any;

    _ = sq.evaluate(-1, -1, 0);
    try testing.expect(!sq.is_open);

    _ = sq.evaluate(3, -1, 0);
    try testing.expect(sq.is_open);

    sq.reset();
    _ = sq.evaluate(-1, 0o023, 0);
    try testing.expect(sq.is_open);
}

test "gate mutes audio when closed" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .ctcss_any;

    _ = sq.evaluate(-1, -1, 0);
    sq.ramp_pos = sq.ramp_samples;

    var audio = [_]f32{1.0} ** 100;
    sq.gate(&audio);

    for (audio) |s| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), s, 0.001);
    }
}

test "gate ramps on open transition" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .ctcss_any;

    _ = sq.evaluate(5, -1, 0);

    var audio = [_]f32{1.0} ** 100;
    sq.gate(&audio);

    try testing.expect(audio[0] < 0.1);
    try testing.expect(audio[99] > audio[0]);
}

test "reset clears state" {
    var sq = ToneSquelch.init(25000.0);
    sq.mode = .ctcss_any;
    _ = sq.evaluate(5, -1, 0);
    try testing.expect(sq.is_open);

    sq.reset();
    try testing.expect(!sq.is_open);
    try testing.expectEqual(@as(u32, 0), sq.ramp_pos);
}
