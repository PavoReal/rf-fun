const std = @import("std");

pub const DeEmphasis = struct {
    alpha: f32,
    prev_out: f32 = 0.0,

    pub fn init(sample_rate: f32, tau: f32) DeEmphasis {
        return .{
            .alpha = 1.0 - @exp(-1.0 / (sample_rate * tau)),
        };
    }

    pub fn process(self: *DeEmphasis, input: []const f32, output: []f32) usize {
        var y = self.prev_out;
        for (input, output) |x, *out| {
            y = y + self.alpha * (x - y);
            out.* = y;
        }
        self.prev_out = y;
        return input.len;
    }

    pub fn reset(self: *DeEmphasis) void {
        self.prev_out = 0.0;
    }
};

const testing = std.testing;

test "DeEmphasis is low-pass filter" {
    var filter = DeEmphasis.init(50000.0, 75e-6);

    var input: [2000]f32 = undefined;
    var output: [2000]f32 = undefined;

    // High frequency signal (well above cutoff ~2122 Hz)
    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 10000.0 * t / 50000.0);
    }

    _ = filter.process(&input, &output);

    // High freq should be attenuated
    var max_out: f32 = 0;
    for (output[500..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out < 0.5);
}

test "DeEmphasis passes low frequencies" {
    var filter = DeEmphasis.init(50000.0, 75e-6);

    var input: [4000]f32 = undefined;
    var output: [4000]f32 = undefined;

    // Low frequency signal (well below cutoff)
    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 100.0 * t / 50000.0);
    }

    _ = filter.process(&input, &output);

    var max_out: f32 = 0;
    for (output[1000..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out > 0.8);
}

test "DeEmphasis reset clears state" {
    var filter = DeEmphasis.init(50000.0, 75e-6);

    var input = [_]f32{1.0} ** 100;
    var output: [100]f32 = undefined;
    _ = filter.process(&input, &output);

    try testing.expect(filter.prev_out != 0.0);
    filter.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_out, 1e-6);
}
