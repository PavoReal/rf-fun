const std = @import("std");
const hackrf = @import("rf_fun");

pub const Nco = struct {
    phase: f64 = 0.0,
    phase_inc: f64 = 0.0,
    cos_inc: f32 = 1.0,
    sin_inc: f32 = 0.0,
    osc_i: f32 = 1.0,
    osc_q: f32 = 0.0,
    renorm_counter: u32 = 0,

    pub fn init(offset_hz: f64, sample_rate_hz: f64) Nco {
        const pi = -2.0 * std.math.pi * offset_hz / sample_rate_hz;
        return .{
            .phase_inc = pi,
            .cos_inc = @floatCast(@cos(pi)),
            .sin_inc = @floatCast(@sin(pi)),
            .osc_i = 1.0,
            .osc_q = 0.0,
        };
    }

    pub fn setFrequency(self: *Nco, offset_hz: f64, sample_rate_hz: f64) void {
        const new_inc = -2.0 * std.math.pi * offset_hz / sample_rate_hz;
        if (new_inc == self.phase_inc) return;
        self.phase_inc = new_inc;
        self.cos_inc = @floatCast(@cos(new_inc));
        self.sin_inc = @floatCast(@sin(new_inc));
    }

    inline fn advance(self: *Nco) void {
        const new_i = self.osc_i * self.cos_inc - self.osc_q * self.sin_inc;
        const new_q = self.osc_i * self.sin_inc + self.osc_q * self.cos_inc;
        self.osc_i = new_i;
        self.osc_q = new_q;
        self.renorm_counter += 1;
        if (self.renorm_counter >= 512) {
            self.renormalize();
        }
    }

    inline fn renormalize(self: *Nco) void {
        const r = self.osc_i * self.osc_i + self.osc_q * self.osc_q;
        const scale = (3.0 - r) * 0.5;
        self.osc_i *= scale;
        self.osc_q *= scale;
        self.renorm_counter = 0;
    }

    pub fn process(self: *Nco, input: []const [2]f32, output: [][2]f32) usize {
        for (input, output) |sample, *out| {
            out.*[0] = sample[0] * self.osc_i - sample[1] * self.osc_q;
            out.*[1] = sample[0] * self.osc_q + sample[1] * self.osc_i;
            self.advance();
        }
        return input.len;
    }

    pub fn processIQ(self: *Nco, input: []const hackrf.IQSample, output: [][2]f32) usize {
        const len = input.len;
        const vec_len = 8;
        const chunks = len / vec_len;
        const remainder = len % vec_len;
        const inv128: @Vector(vec_len, f32) = @splat(1.0 / 128.0);

        for (0..chunks) |chunk| {
            const base = chunk * vec_len;

            var osc_i_arr: [vec_len]f32 = undefined;
            var osc_q_arr: [vec_len]f32 = undefined;
            for (0..vec_len) |j| {
                osc_i_arr[j] = self.osc_i;
                osc_q_arr[j] = self.osc_q;
                self.advance();
            }

            var in_i_arr: [vec_len]f32 = undefined;
            var in_q_arr: [vec_len]f32 = undefined;
            for (0..vec_len) |j| {
                in_i_arr[j] = @floatFromInt(input[base + j].i);
                in_q_arr[j] = @floatFromInt(input[base + j].q);
            }

            const in_i: @Vector(vec_len, f32) = in_i_arr;
            const in_q: @Vector(vec_len, f32) = in_q_arr;
            const osc_i_v: @Vector(vec_len, f32) = osc_i_arr;
            const osc_q_v: @Vector(vec_len, f32) = osc_q_arr;

            const scaled_i = in_i * inv128;
            const scaled_q = in_q * inv128;

            const out_i = scaled_i * osc_i_v - scaled_q * osc_q_v;
            const out_q = scaled_i * osc_q_v + scaled_q * osc_i_v;

            const out_i_arr: [vec_len]f32 = out_i;
            const out_q_arr: [vec_len]f32 = out_q;

            for (0..vec_len) |j| {
                output[base + j] = .{ out_i_arr[j], out_q_arr[j] };
            }
        }

        const tail_start = chunks * vec_len;
        for (tail_start..len) |i| {
            const sample = input[i];
            const si: f32 = @as(f32, @floatFromInt(sample.i)) / 128.0;
            const sq: f32 = @as(f32, @floatFromInt(sample.q)) / 128.0;
            output[i] = .{
                si * self.osc_i - sq * self.osc_q,
                si * self.osc_q + sq * self.osc_i,
            };
            self.advance();
        }

        _ = remainder;
        return len;
    }

    pub fn reset(self: *Nco) void {
        self.phase = 0.0;
        self.osc_i = 1.0;
        self.osc_q = 0.0;
        self.renorm_counter = 0;
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
    try testing.expectApproxEqAbs(@as(f32, 1.0), nco.osc_i, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), nco.osc_q, 1e-6);
}

test "NCO processIQ matches toFloat + process" {
    const fs = 2_000_000.0;
    const f_offset = 100_000.0;

    var iq_input: [256]hackrf.IQSample = undefined;
    for (&iq_input, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / fs;
        const phase = 2.0 * std.math.pi * 50_000.0 * t;
        s.*.i = @intFromFloat(std.math.clamp(@as(f32, @floatCast(@cos(phase))) * 127.0, -128.0, 127.0));
        s.*.q = @intFromFloat(std.math.clamp(@as(f32, @floatCast(@sin(phase))) * 127.0, -128.0, 127.0));
    }

    var nco_ref = Nco.init(f_offset, fs);
    var float_input: [256][2]f32 = undefined;
    for (iq_input[0..], float_input[0..]) |iq, *f| {
        f.* = iq.toFloat();
    }
    var ref_output: [256][2]f32 = undefined;
    _ = nco_ref.process(&float_input, &ref_output);

    var nco_test = Nco.init(f_offset, fs);
    var test_output: [256][2]f32 = undefined;
    _ = nco_test.processIQ(&iq_input, &test_output);

    for (ref_output, test_output) |ref, tst| {
        try testing.expectApproxEqAbs(ref[0], tst[0], 1e-5);
        try testing.expectApproxEqAbs(ref[1], tst[1], 1e-5);
    }
}
