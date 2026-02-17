const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn DoubleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        bufs: [2][]T,
        lens: [2]usize = .{ 0, 0 },
        write_idx: u8 = 0,
        read_idx: std.atomic.Value(u8) = .init(0),
        new_data: std.atomic.Value(u8) = .init(0),

        pub fn init(alloc: Allocator, cap: usize) !Self {
            const buf0 = try alloc.alloc(T, cap);
            errdefer alloc.free(buf0);
            const buf1 = try alloc.alloc(T, cap);
            return Self{
                .bufs = .{ buf0, buf1 },
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.bufs[0]);
            alloc.free(self.bufs[1]);
        }

        pub fn capacity(self: *const Self) usize {
            return self.bufs[0].len;
        }

        pub fn writeSlice(self: *Self) []T {
            return self.bufs[self.write_idx & 1];
        }

        pub fn publish(self: *Self, len: usize) void {
            const idx = self.write_idx & 1;
            self.lens[idx] = len;
            self.read_idx.store(idx, .release);
            self.write_idx +%= 1;
            self.new_data.store(1, .release);
        }

        pub fn read(self: *Self) ?[]const T {
            if (self.new_data.swap(0, .acquire) == 0) return null;
            const idx = self.read_idx.load(.acquire);
            return self.bufs[idx][0..self.lens[idx]];
        }
    };
}

const testing = std.testing;

test "basic write and read" {
    var db = try DoubleBuffer(f32).init(testing.allocator, 4);
    defer db.deinit(testing.allocator);

    try testing.expect(db.read() == null);

    const ws = db.writeSlice();
    ws[0] = 1.0;
    ws[1] = 2.0;
    db.publish(2);

    const data = db.read().?;
    try testing.expectEqual(@as(usize, 2), data.len);
    try testing.expectApproxEqAbs(@as(f32, 1.0), data[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), data[1], 0.001);
}

test "no new data returns null" {
    var db = try DoubleBuffer(u8).init(testing.allocator, 8);
    defer db.deinit(testing.allocator);

    try testing.expect(db.read() == null);

    const ws = db.writeSlice();
    ws[0] = 42;
    db.publish(1);

    _ = db.read();
    try testing.expect(db.read() == null);
}

test "double write overwrites" {
    var db = try DoubleBuffer(u8).init(testing.allocator, 4);
    defer db.deinit(testing.allocator);

    var ws = db.writeSlice();
    ws[0] = 1;
    db.publish(1);

    ws = db.writeSlice();
    ws[0] = 2;
    ws[1] = 3;
    db.publish(2);

    const data = db.read().?;
    try testing.expectEqual(@as(usize, 2), data.len);
    try testing.expectEqual(@as(u8, 2), data[0]);
    try testing.expectEqual(@as(u8, 3), data[1]);
}

test "capacity" {
    var db = try DoubleBuffer(f32).init(testing.allocator, 16);
    defer db.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 16), db.capacity());
}
