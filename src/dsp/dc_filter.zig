const std = @import("std");

pub fn DcFilter(comptime T: type) type {
    const is_complex = T == [2]f32;
    const zero: T = if (is_complex) .{ 0, 0 } else 0;

    return struct {
        const Self = @This();

        pub const Input = T;
        pub const Output = T;

        alpha: f32,
        prev_in: T = zero,
        prev_out: T = zero,

        pub fn init(alpha: f32) Self {
            return .{ .alpha = alpha };
        }

        pub fn process(self: *Self, input: []const Input, output: []Output) usize {
            for (input, output) |sample, *out| {
                if (is_complex) {
                    out.*[0] = sample[0] - self.prev_in[0] + self.alpha * self.prev_out[0];
                    out.*[1] = sample[1] - self.prev_in[1] + self.alpha * self.prev_out[1];
                } else {
                    out.* = sample - self.prev_in + self.alpha * self.prev_out;
                }
                self.prev_in = sample;
                self.prev_out = out.*;
            }
            return input.len;
        }

        pub fn reset(self: *Self) void {
            self.prev_in = zero;
            self.prev_out = zero;
        }
    };
}

const testing = std.testing;

test "complex: removes DC offset" {
    var filter = DcFilter([2]f32).init(0.995);

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

test "complex: passes AC signal" {
    var filter = DcFilter([2]f32).init(0.995);

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

test "complex: reset clears state" {
    var filter = DcFilter([2]f32).init(0.995);

    var input = [_][2]f32{.{ 1.0, 1.0 }} ** 100;
    var output: [100][2]f32 = undefined;
    _ = filter.process(&input, &output);

    filter.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_in[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_out[0], 0.001);
}

test "scalar: removes DC offset" {
    var filter = DcFilter(f32).init(0.995);

    var input: [1024]f32 = undefined;
    var output: [1024]f32 = undefined;

    for (&input) |*s| {
        s.* = 0.5;
    }

    _ = filter.process(&input, &output);

    try testing.expect(@abs(output[1023]) < 0.05);
}

test "scalar: passes AC signal" {
    var filter = DcFilter(f32).init(0.995);

    var input: [4096]f32 = undefined;
    var output: [4096]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * t / 64.0);
    }

    _ = filter.process(&input, &output);

    var max_amplitude: f32 = 0;
    for (output[512..]) |s| {
        max_amplitude = @max(max_amplitude, @abs(s));
    }
    try testing.expect(max_amplitude > 0.8);
}

test "scalar: reset clears state" {
    var filter = DcFilter(f32).init(0.995);

    var input = [_]f32{1.0} ** 100;
    var output: [100]f32 = undefined;
    _ = filter.process(&input, &output);

    filter.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_in, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.prev_out, 0.001);
}
