const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn FixedSizeRingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        head: usize,
        count: usize,

        pub fn init(allocator: Allocator, cap: usize) Allocator.Error!Self {
            return .{
                .buf = try allocator.alloc(T, cap),
                .head = 0,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn append(self: *Self, items: []const T) void {
            const cap = self.buf.len;
            if (items.len == 0) return;

            if (items.len >= cap) {
                // Input larger than buffer — keep only the last `cap` items
                @memcpy(self.buf[0..cap], items[items.len - cap ..]);
                self.head = 0;
                self.count = cap;
                return;
            }

            // Two-part copy: [head..end] then [0..wrap]
            const first_len = @min(items.len, cap - self.head);
            @memcpy(self.buf[self.head..][0..first_len], items[0..first_len]);
            const remaining = items.len - first_len;
            if (remaining > 0) {
                @memcpy(self.buf[0..remaining], items[first_len..][0..remaining]);
            }
            self.head = (self.head + items.len) % cap;
            self.count = @min(self.count + items.len, cap);
        }

        pub fn capacity(self: Self) usize {
            return self.buf.len;
        }

        pub fn len(self: Self) usize {
            return self.count;
        }

        pub fn isFull(self: Self) bool {
            return self.count == self.buf.len;
        }

        pub const Slices = struct {
            first: []const T,
            second: []const T,
        };

        pub fn slices(self: Self) Slices {
            if (self.count < self.buf.len) {
                // Haven't wrapped yet — data is [0..count]
                return .{ .first = self.buf[0..self.count], .second = &.{} };
            }
            // Wrapped — oldest starts at head, newest ends at head
            return .{
                .first = self.buf[self.head..self.buf.len],
                .second = self.buf[0..self.head],
            };
        }
    };
}

// === Tests ===

const testing = std.testing;
const RingBuf = FixedSizeRingBuffer(u8);

test "empty buffer" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), rb.len());
    try testing.expectEqual(@as(usize, 8), rb.capacity());
    try testing.expect(!rb.isFull());

    const s = rb.slices();
    try testing.expectEqual(@as(usize, 0), s.first.len);
    try testing.expectEqual(@as(usize, 0), s.second.len);
}

test "basic append and read back" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3 });
    try testing.expectEqual(@as(usize, 3), rb.len());
    try testing.expect(!rb.isFull());

    const s = rb.slices();
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, s.first);
    try testing.expectEqual(@as(usize, 0), s.second.len);
}

test "fill exactly to capacity" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 10, 20, 30, 40 });
    try testing.expectEqual(@as(usize, 4), rb.len());
    try testing.expect(rb.isFull());

    const s = rb.slices();
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, s.first);
    try testing.expectEqual(@as(usize, 0), s.second.len);
}

test "overwrite oldest data" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3, 4 }); // fill buffer
    rb.append(&.{ 5, 6 }); // overwrite 1, 2

    try testing.expectEqual(@as(usize, 4), rb.len());
    try testing.expect(rb.isFull());

    // Oldest data starts at head (which is 2), so: [3, 4, 5, 6]
    const s = rb.slices();

    // Verify full contents oldest→newest
    var result: [4]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, &result);
}

test "wrap-around correctness" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    // Append 3 items, then 3 more — should wrap
    rb.append(&.{ 1, 2, 3 });
    try testing.expectEqual(@as(usize, 3), rb.len());

    rb.append(&.{ 4, 5, 6 });
    try testing.expectEqual(@as(usize, 4), rb.len());
    try testing.expect(rb.isFull());

    // Buffer contents: buf = [5, 6, 3, 4], head = 2
    // Oldest→newest: [3, 4, 5, 6]
    const s = rb.slices();
    var result: [4]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, &result);
}

test "append larger than capacity keeps tail" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    try testing.expectEqual(@as(usize, 4), rb.len());
    try testing.expect(rb.isFull());

    // Should keep last 4 items: [7, 8, 9, 10]
    const s = rb.slices();
    try testing.expectEqualSlices(u8, &.{ 7, 8, 9, 10 }, s.first);
    try testing.expectEqual(@as(usize, 0), s.second.len);
}

test "append empty slice is no-op" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{});
    try testing.expectEqual(@as(usize, 0), rb.len());
}

test "multiple small appends then overwrite" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{1});
    rb.append(&.{2});
    rb.append(&.{3});
    rb.append(&.{4});
    try testing.expect(rb.isFull());

    rb.append(&.{5});
    try testing.expectEqual(@as(usize, 4), rb.len());

    const s = rb.slices();
    var result: [4]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, &result);
}

test "works with extern struct type" {
    const Sample = extern struct { i: i8, q: i8 };
    const SampleRing = FixedSizeRingBuffer(Sample);

    var rb = try SampleRing.init(testing.allocator, 3);
    defer rb.deinit(testing.allocator);

    rb.append(&.{
        .{ .i = 1, .q = 2 },
        .{ .i = 3, .q = 4 },
    });

    try testing.expectEqual(@as(usize, 2), rb.len());

    const s = rb.slices();
    try testing.expectEqual(@as(i8, 1), s.first[0].i);
    try testing.expectEqual(@as(i8, 4), s.first[1].q);
}
