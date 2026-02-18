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

            const delay_line = try alloc.alloc(T, num_taps);
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
                self.delay_pos = (self.delay_pos + 1) % self.num_taps;

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
            if (is_complex) {
                var acc_i: f32 = 0.0;
                var acc_q: f32 = 0.0;
                var idx = self.delay_pos;
                for (self.coeffs) |coeff| {
                    if (idx == 0) idx = self.num_taps;
                    idx -= 1;
                    acc_i += self.delay_line[idx][0] * coeff;
                    acc_q += self.delay_line[idx][1] * coeff;
                }
                return .{ acc_i, acc_q };
            } else {
                var acc: f32 = 0.0;
                var idx = self.delay_pos;
                for (self.coeffs) |coeff| {
                    if (idx == 0) idx = self.num_taps;
                    idx -= 1;
                    acc += self.delay_line[idx] * coeff;
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

                const hamming = 0.54 - 0.46 * @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1)));
                c.* = sinc * hamming;
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
