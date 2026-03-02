const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn DecimatingFir(comptime T: type) type {
    const is_complex = T == [2]f32;
    const zero: T = if (is_complex) .{ 0.0, 0.0 } else 0.0;

    return struct {
        const Self = @This();

        coeffs: []f32,
        delay_line: []T,
        delay_pos: usize,
        decimation: usize,
        num_taps: usize,
        phase: usize,

        pub fn init(alloc: Allocator, num_taps: usize, cutoff_hz: f32, sample_rate_hz: f32, decimation: usize) !Self {
            const coeffs = try alloc.alloc(f32, num_taps);
            errdefer alloc.free(coeffs);

            designFilter(coeffs, cutoff_hz, sample_rate_hz);

            const delay_line = try alloc.alloc(T, num_taps * 2);
            errdefer alloc.free(delay_line);
            @memset(delay_line, zero);

            return .{
                .coeffs = coeffs,
                .delay_line = delay_line,
                .delay_pos = 0,
                .decimation = decimation,
                .num_taps = num_taps,
                .phase = 0,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.coeffs);
            alloc.free(self.delay_line);
        }

        pub fn process(self: *Self, input: []const T, output: []T) usize {
            var out_idx: usize = 0;
            for (input) |sample| {
                self.delay_line[self.delay_pos] = sample;
                self.delay_line[self.delay_pos + self.num_taps] = sample;
                self.delay_pos += 1;
                if (self.delay_pos >= self.num_taps) self.delay_pos = 0;

                self.phase += 1;
                if (self.phase >= self.decimation) {
                    self.phase = 0;
                    output[out_idx] = self.computeOutput();
                    out_idx += 1;
                }
            }
            return out_idx;
        }

        fn computeOutput(self: *Self) T {
            const delay = self.delay_line[self.delay_pos..][0..self.num_taps];
            const coeffs = self.coeffs;
            const vec_len = 8;

            if (is_complex) {
                var acc_i_v: @Vector(vec_len, f32) = @splat(0.0);
                var acc_q_v: @Vector(vec_len, f32) = @splat(0.0);
                var k: usize = 0;
                const simd_end = self.num_taps - (self.num_taps % vec_len);

                while (k < simd_end) : (k += vec_len) {
                    var di: [vec_len]f32 = undefined;
                    var dq: [vec_len]f32 = undefined;
                    var cv: [vec_len]f32 = undefined;
                    for (0..vec_len) |j| {
                        di[j] = delay[k + j][0];
                        dq[j] = delay[k + j][1];
                        cv[j] = coeffs[k + j];
                    }
                    const coeff_v: @Vector(vec_len, f32) = cv;
                    acc_i_v += @as(@Vector(vec_len, f32), di) * coeff_v;
                    acc_q_v += @as(@Vector(vec_len, f32), dq) * coeff_v;
                }

                var acc_i = @reduce(.Add, acc_i_v);
                var acc_q = @reduce(.Add, acc_q_v);
                while (k < self.num_taps) : (k += 1) {
                    acc_i += delay[k][0] * coeffs[k];
                    acc_q += delay[k][1] * coeffs[k];
                }
                return .{ acc_i, acc_q };
            } else {
                var acc_v: @Vector(vec_len, f32) = @splat(0.0);
                var k: usize = 0;
                const simd_end = self.num_taps - (self.num_taps % vec_len);

                while (k < simd_end) : (k += vec_len) {
                    const d: @Vector(vec_len, f32) = delay[k..][0..vec_len].*;
                    const cv: @Vector(vec_len, f32) = coeffs[k..][0..vec_len].*;
                    acc_v += d * cv;
                }

                var acc = @reduce(.Add, acc_v);
                while (k < self.num_taps) : (k += 1) {
                    acc += delay[k] * coeffs[k];
                }
                return acc;
            }
        }

        pub fn reset(self: *Self) void {
            @memset(self.delay_line, zero);
            self.delay_pos = 0;
            self.phase = 0;
        }

        fn designFilter(coeffs: []f32, cutoff_hz: f32, sample_rate_hz: f32) void {
            const n = coeffs.len;
            const fc = cutoff_hz / sample_rate_hz;
            const mid: f32 = @as(f32, @floatFromInt(n - 1)) / 2.0;

            var sum: f32 = 0.0;
            for (coeffs, 0..) |*c, i| {
                const x: f32 = @as(f32, @floatFromInt(i)) - mid;
                const sinc = if (@abs(x) < 1e-6)
                    2.0 * std.math.pi * fc
                else
                    @sin(2.0 * std.math.pi * fc * x) / x;

                const fi = @as(f32, @floatFromInt(i));
                const fn_minus_1 = @as(f32, @floatFromInt(n - 1));
                const blackman = 0.42 - 0.5 * @cos(2.0 * std.math.pi * fi / fn_minus_1) + 0.08 * @cos(4.0 * std.math.pi * fi / fn_minus_1);
                c.* = sinc * blackman;
                sum += c.*;
            }

            for (coeffs) |*c| {
                c.* /= sum;
            }
        }
    };
}

const testing = std.testing;

test "DecimatingFir real decimation by 2" {
    var fir = try DecimatingFir(f32).init(testing.allocator, 31, 100.0, 1000.0, 2);
    defer fir.deinit(testing.allocator);

    var input: [100]f32 = undefined;
    for (&input, 0..) |*s, i| {
        s.* = if (i == 0) 1.0 else 0.0;
    }

    var output: [50]f32 = undefined;
    const n = fir.process(&input, &output);
    try testing.expectEqual(@as(usize, 50), n);
}

test "DecimatingFir complex decimation by 5" {
    var fir = try DecimatingFir([2]f32).init(testing.allocator, 51, 80000.0, 2000000.0, 5);
    defer fir.deinit(testing.allocator);

    var input: [100][2]f32 = undefined;
    for (&input) |*s| {
        s.* = .{ 1.0, 0.0 };
    }

    var output: [20][2]f32 = undefined;
    const n = fir.process(&input, &output);
    try testing.expectEqual(@as(usize, 20), n);

    // DC input should produce DC output (after settling)
    try testing.expect(@abs(output[19][0]) > 0.5);
}

test "DecimatingFir reset clears state" {
    var fir = try DecimatingFir(f32).init(testing.allocator, 15, 100.0, 1000.0, 2);
    defer fir.deinit(testing.allocator);

    var input = [_]f32{1.0} ** 30;
    var output: [15]f32 = undefined;
    _ = fir.process(&input, &output);

    fir.reset();
    try testing.expectEqual(@as(usize, 0), fir.delay_pos);
    try testing.expectEqual(@as(usize, 0), fir.phase);
}

test "DecimatingFir attenuates above cutoff" {
    var fir = try DecimatingFir(f32).init(testing.allocator, 63, 100.0, 1000.0, 2);
    defer fir.deinit(testing.allocator);

    // Generate 400 Hz signal (above 100 Hz cutoff, below 500 Hz Nyquist)
    var input: [2000]f32 = undefined;
    for (&input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = @sin(2.0 * std.math.pi * 400.0 * t / 1000.0);
    }

    var output: [1000]f32 = undefined;
    _ = fir.process(&input, &output);

    var max_out: f32 = 0;
    for (output[200..]) |s| {
        max_out = @max(max_out, @abs(s));
    }
    try testing.expect(max_out < 0.3);
}

test "DecimatingFir 63 taps SIMD + scalar tail" {
    var fir = try DecimatingFir(f32).init(testing.allocator, 63, 100.0, 1000.0, 1);
    defer fir.deinit(testing.allocator);

    var input: [200]f32 = undefined;
    for (&input) |*s| s.* = 1.0;

    var output: [200]f32 = undefined;
    const n = fir.process(&input, &output);
    try testing.expectEqual(@as(usize, 200), n);

    try testing.expectApproxEqAbs(@as(f32, 1.0), output[199], 0.01);
}
