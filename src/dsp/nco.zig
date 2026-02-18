const std = @import("std");

pub const Nco = struct {
    phase: f64 = 0.0,
    phase_inc: f64 = 0.0,

    pub fn init(offset_hz: f64, sample_rate_hz: f64) Nco {
        return .{
            .phase_inc = -2.0 * std.math.pi * offset_hz / sample_rate_hz,
        };
    }

    pub fn setFrequency(self: *Nco, offset_hz: f64, sample_rate_hz: f64) void {
        self.phase_inc = -2.0 * std.math.pi * offset_hz / sample_rate_hz;
    }

    pub fn process(self: *Nco, input: []const [2]f32, output: [][2]f32) usize {
        for (input, output) |sample, *out| {
            const cos_p: f32 = @floatCast(@cos(self.phase));
            const sin_p: f32 = @floatCast(@sin(self.phase));

            out.*[0] = sample[0] * cos_p - sample[1] * sin_p;
            out.*[1] = sample[0] * sin_p + sample[1] * cos_p;

            self.phase += self.phase_inc;
            if (self.phase > std.math.pi) {
                self.phase -= 2.0 * std.math.pi;
            } else if (self.phase < -std.math.pi) {
                self.phase += 2.0 * std.math.pi;
            }
        }
        return input.len;
    }

    pub fn reset(self: *Nco) void {
        self.phase = 0.0;
    }
};

const testing = std.testing;

test "NCO zero offset is passthrough" {
    var nco = Nco.init(0.0, 1000.0);

    var input = [_][2]f32{
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ -1.0, 0.0 },
    };
    var output: [3][2]f32 = undefined;

    const n = nco.process(&input, &output);
    try testing.expectEqual(@as(usize, 3), n);

    for (input, output) |inp, out| {
        try testing.expectApproxEqAbs(inp[0], out[0], 1e-6);
        try testing.expectApproxEqAbs(inp[1], out[1], 1e-6);
    }
}

test "NCO shifts frequency" {
    const fs = 1000.0;
    const f_offset = 100.0;
    var nco = Nco.init(f_offset, fs);

    var input: [1000][2]f32 = undefined;
    var output: [1000][2]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / fs;
        const phase = 2.0 * std.math.pi * f_offset * t;
        s.*[0] = @floatCast(@cos(phase));
        s.*[1] = @floatCast(@sin(phase));
    }

    _ = nco.process(&input, &output);

    for (output[100..]) |s| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), s[0], 0.01);
        try testing.expectApproxEqAbs(@as(f32, 0.0), s[1], 0.01);
    }
}

test "NCO reset clears phase" {
    var nco = Nco.init(100.0, 1000.0);

    var input = [_][2]f32{.{ 1.0, 0.0 }} ** 37;
    var output: [37][2]f32 = undefined;
    _ = nco.process(&input, &output);

    nco.reset();
    try testing.expectApproxEqAbs(@as(f64, 0.0), nco.phase, 1e-10);
}
