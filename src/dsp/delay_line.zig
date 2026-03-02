const std = @import("std");

pub const DelayLine = struct {
    const Self = @This();

    pub const Input = f32;
    pub const Output = f32;

    buf: []f32,
    write_pos: usize,
    len: usize,

    pub fn init(alloc: std.mem.Allocator, delay_samples: usize) !Self {
        const buf = try alloc.alloc(f32, delay_samples);
        @memset(buf, 0);
        return .{
            .buf = buf,
            .write_pos = 0,
            .len = delay_samples,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        self.buf = &.{};
        self.len = 0;
        self.write_pos = 0;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) usize {
        const count = @min(input.len, output.len);
        for (0..count) |i| {
            output[i] = self.buf[self.write_pos];
            self.buf[self.write_pos] = input[i];
            self.write_pos = (self.write_pos + 1) % self.len;
        }
        return count;
    }

    pub fn reset(self: *Self) void {
        @memset(self.buf, 0);
        self.write_pos = 0;
    }
};

const testing = std.testing;

test "delay offset" {
    var dl = try DelayLine.init(testing.allocator, 3);
    defer dl.deinit(testing.allocator);

    const input = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var output: [8]f32 = undefined;

    const n = dl.process(&input, &output);
    try testing.expectEqual(@as(usize, 8), n);

    try testing.expectApproxEqAbs(@as(f32, 0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), output[2], 0.001);

    try testing.expectApproxEqAbs(@as(f32, 1), output[3], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2), output[4], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3), output[5], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4), output[6], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), output[7], 0.001);
}

test "initial silence" {
    var dl = try DelayLine.init(testing.allocator, 5);
    defer dl.deinit(testing.allocator);

    const input = [_]f32{ 10, 20, 30, 40, 50 };
    var output: [5]f32 = undefined;

    _ = dl.process(&input, &output);

    for (output) |sample| {
        try testing.expectApproxEqAbs(@as(f32, 0), sample, 0.001);
    }
}

test "passthrough after fill" {
    var dl = try DelayLine.init(testing.allocator, 4);
    defer dl.deinit(testing.allocator);

    const fill = [_]f32{ 1, 2, 3, 4 };
    var discard: [4]f32 = undefined;
    _ = dl.process(&fill, &discard);

    const input2 = [_]f32{ 5, 6, 7, 8 };
    var output2: [4]f32 = undefined;
    _ = dl.process(&input2, &output2);

    try testing.expectApproxEqAbs(@as(f32, 1), output2[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2), output2[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3), output2[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4), output2[3], 0.001);
}

test "reset clears buffer" {
    var dl = try DelayLine.init(testing.allocator, 3);
    defer dl.deinit(testing.allocator);

    const input = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var output: [6]f32 = undefined;
    _ = dl.process(&input, &output);

    dl.reset();

    const input2 = [_]f32{ 10, 20, 30 };
    var output2: [3]f32 = undefined;
    _ = dl.process(&input2, &output2);

    try testing.expectApproxEqAbs(@as(f32, 0), output2[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), output2[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), output2[2], 0.001);
}
