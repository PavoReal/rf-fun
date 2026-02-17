const std = @import("std");

pub const DcFilter = struct {
    pub const Input = [2]f32;
    pub const Output = [2]f32;

    alpha: f32,
    prev_in: [2]f32 = .{ 0, 0 },
    prev_out: [2]f32 = .{ 0, 0 },

    pub fn init(alpha: f32) DcFilter {
        return .{ .alpha = alpha };
    }

    pub fn process(self: *DcFilter, input: []const Input, output: []Output) usize {
        for (input, output) |sample, *out| {
            out.*[0] = sample[0] - self.prev_in[0] + self.alpha * self.prev_out[0];
            out.*[1] = sample[1] - self.prev_in[1] + self.alpha * self.prev_out[1];
            self.prev_in = sample;
            self.prev_out = out.*;
        }
        return input.len;
    }

    pub fn reset(self: *DcFilter) void {
        self.prev_in = .{ 0, 0 };
        self.prev_out = .{ 0, 0 };
    }
};

const testing = std.testing;

test "removes DC offset" {
    var filter = DcFilter.init(0.995);

    var input: [1024][2]f32 = undefined;
    var output: [1024][2]f32 = undefined;

    for (&input) |*s| {
        s.* = .{ 0.5, -0.3 };
    }

    _ = filter.process(&input, &output);

    const last = output[1023];
    try testing.expect(@abs(last[0]) < 0.05);
    try testing.expect(@abs(last[1]) < 0.05);
}

test "passes AC signal" {
    var filter = DcFilter.init(0.995);

    var input: [4096][2]f32 = undefined;
    var output: [4096][2]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        const sig = @sin(2.0 * std.math.pi * t / 64.0);
        s.* = .{ sig, sig };
    }

    _ = filter.process(&input, &output);

    var max_amplitude: f32 = 0;
    for (output[512..]) |s| {
        max_amplitude = @max(max_amplitude, @abs(s[0]));
    }
    try testing.expect(max_amplitude > 0.8);
}

test "reset clears state" {
    var filter = DcFilter.init(0.995);

    var input = [_][2]f32{.{ 1.0, 1.0 }} ** 100;
    var output: [100][2]f32 = undefined;
    _ = filter.process(&input, &output);

    filter.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_in[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_out[0], 0.001);
}
