const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Chain(comptime A: type, comptime B: type) type {
    if (A.Output != B.Input) {
        @compileError("Chain: A.Output (" ++ @typeName(A.Output) ++ ") != B.Input (" ++ @typeName(B.Input) ++ ")");
    }

    return struct {
        const Self = @This();

        pub const Input = A.Input;
        pub const Output = B.Output;

        a: A,
        b: B,
        mid_buf: []A.Output,

        pub fn init(alloc: Allocator, chunk_size: usize, a: A, b: B) !Self {
            return .{
                .a = a,
                .b = b,
                .mid_buf = try alloc.alloc(A.Output, chunk_size),
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.mid_buf);
        }

        pub fn process(self: *Self, input: []const Input, output: []Output) usize {
            const mid_n = self.a.process(input, self.mid_buf);
            return self.b.process(self.mid_buf[0..mid_n], output);
        }

        pub fn reset(self: *Self) void {
            self.a.reset();
            self.b.reset();
        }
    };
}

const testing = std.testing;

const Doubler = struct {
    pub const Input = f32;
    pub const Output = f32;

    pub fn process(_: *Doubler, input: []const f32, output: []f32) usize {
        for (input, output) |v, *o| o.* = v * 2.0;
        return input.len;
    }

    pub fn reset(_: *Doubler) void {}
};

const Adder = struct {
    pub const Input = f32;
    pub const Output = f32;
    offset: f32,

    pub fn process(self: *Adder, input: []const f32, output: []f32) usize {
        for (input, output) |v, *o| o.* = v + self.offset;
        return input.len;
    }

    pub fn reset(_: *Adder) void {}
};

test "chain two processors" {
    var chain = try Chain(Doubler, Adder).init(testing.allocator, 4, .{}, .{ .offset = 10.0 });
    defer chain.deinit(testing.allocator);

    const input = [_]f32{ 1.0, 2.0, 3.0 };
    var output: [3]f32 = undefined;

    const n = chain.process(&input, &output);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectApproxEqAbs(@as(f32, 12.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 14.0), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 16.0), output[2], 0.001);
}

test "triple chain" {
    const Inner = Chain(Doubler, Doubler);
    var chain = try Chain(Inner, Adder).init(
        testing.allocator,
        4,
        try Inner.init(testing.allocator, 4, .{}, .{}),
        .{ .offset = 1.0 },
    );
    defer {
        chain.a.deinit(testing.allocator);
        chain.deinit(testing.allocator);
    }

    const input = [_]f32{3.0};
    var output: [1]f32 = undefined;

    _ = chain.process(&input, &output);
    try testing.expectApproxEqAbs(@as(f32, 13.0), output[0], 0.001);
}
