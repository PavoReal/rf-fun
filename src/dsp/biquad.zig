const std = @import("std");

pub const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32 = 0.0,
    z2: f32 = 0.0,

    pub fn initHighPass(sample_rate: f32, cutoff_hz: f32, q: f32) Biquad {
        const w0 = 2.0 * std.math.pi * cutoff_hz / sample_rate;
        const sin_w0 = @sin(w0);
        const cos_w0 = @cos(w0);
        const alpha = sin_w0 / (2.0 * q);

        const a0 = 1.0 + alpha;
        const inv_a0 = 1.0 / a0;

        return .{
            .b0 = ((1.0 + cos_w0) / 2.0) * inv_a0,
            .b1 = (-(1.0 + cos_w0)) * inv_a0,
            .b2 = ((1.0 + cos_w0) / 2.0) * inv_a0,
            .a1 = (-2.0 * cos_w0) * inv_a0,
            .a2 = (1.0 - alpha) * inv_a0,
        };
    }

    pub fn initLowPass(sample_rate: f32, cutoff_hz: f32, q: f32) Biquad {
        const w0 = 2.0 * std.math.pi * cutoff_hz / sample_rate;
        const sin_w0 = @sin(w0);
        const cos_w0 = @cos(w0);
        const alpha = sin_w0 / (2.0 * q);

        const a0 = 1.0 + alpha;
        const inv_a0 = 1.0 / a0;

        return .{
            .b0 = ((1.0 - cos_w0) / 2.0) * inv_a0,
            .b1 = (1.0 - cos_w0) * inv_a0,
            .b2 = ((1.0 - cos_w0) / 2.0) * inv_a0,
            .a1 = (-2.0 * cos_w0) * inv_a0,
            .a2 = (1.0 - alpha) * inv_a0,
        };
    }

    pub fn processSample(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }

    pub fn process(self: *Biquad, input: []const f32, output: []f32) usize {
        for (input, output) |x, *out| {
            out.* = self.processSample(x);
        }
        return input.len;
    }

    pub fn reset(self: *Biquad) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
};

const testing = std.testing;

test "HPF attenuates low frequencies" {
    var hpf = Biquad.initHighPass(25000.0, 4000.0, 0.707);

    var input: [4000]f32 = undefined;
    var output: [4000]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 100.0 * t / 25000.0);
    }

    _ = hpf.process(&input, &output);

    var max_out: f32 = 0;
    for (output[2000..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out < 0.05);
}

test "HPF passes high frequencies" {
    var hpf = Biquad.initHighPass(25000.0, 4000.0, 0.707);

    var input: [4000]f32 = undefined;
    var output: [4000]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }

    _ = hpf.process(&input, &output);

    var max_out: f32 = 0;
    for (output[2000..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out > 0.7);
}

test "HPF supports in-place processing" {
    var hpf = Biquad.initHighPass(25000.0, 4000.0, 0.707);

    var buf: [2000]f32 = undefined;
    for (&buf, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }

    _ = hpf.process(&buf, &buf);

    var max_out: f32 = 0;
    for (buf[1000..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out > 0.7);
}

test "HPF reset clears state" {
    var hpf = Biquad.initHighPass(25000.0, 4000.0, 0.707);

    var input = [_]f32{1.0} ** 100;
    var output: [100]f32 = undefined;
    _ = hpf.process(&input, &output);

    try testing.expect(hpf.z1 != 0.0 or hpf.z2 != 0.0);
    hpf.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), hpf.z1, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), hpf.z2, 1e-6);
}

test "LPF passes low frequencies" {
    var lpf = Biquad.initLowPass(25000.0, 4000.0, 0.707);

    var input: [4000]f32 = undefined;
    var output: [4000]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 100.0 * t / 25000.0);
    }

    _ = lpf.process(&input, &output);

    var max_out: f32 = 0;
    for (output[2000..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out > 0.7);
}

test "LPF attenuates high frequencies" {
    var lpf = Biquad.initLowPass(25000.0, 4000.0, 0.707);

    var input: [4000]f32 = undefined;
    var output: [4000]f32 = undefined;

    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }

    _ = lpf.process(&input, &output);

    var max_out: f32 = 0;
    for (output[2000..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out < 0.15);
}
