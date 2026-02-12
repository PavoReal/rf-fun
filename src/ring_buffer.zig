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

        pub fn appendOne(self: *Self, item: T) void {
            self.buf[self.head] = item;
            self.head = (self.head + 1) % self.buf.len;
            if (self.count < self.buf.len) self.count += 1;
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

        /// Return up to `n` of the oldest elements as split slices.
        pub fn oldest(self: Self, n: usize) Slices {
            const want = @min(n, self.count);
            if (want == 0) return .{ .first = &.{}, .second = &.{} };
            const s = self.slices();
            if (want <= s.first.len) {
                return .{ .first = s.first[0..want], .second = &.{} };
            }
            return .{ .first = s.first, .second = s.second[0 .. want - s.first.len] };
        }

        /// Return up to `n` of the newest elements as split slices.
        pub fn newest(self: Self, n: usize) Slices {
            const want = @min(n, self.count);
            if (want == 0) return .{ .first = &.{}, .second = &.{} };
            const s = self.slices();
            if (want <= s.second.len) {
                return .{ .first = &.{}, .second = s.second[s.second.len - want ..] };
            }
            const from_first = want - s.second.len;
            return .{ .first = s.first[s.first.len - from_first ..], .second = s.second };
        }

        /// Copy up to `dest.len` of the newest elements into `dest` contiguously.
        /// Returns the number of elements actually copied.
        pub fn copyNewest(self: Self, dest: []T) usize {
            const want = @min(dest.len, self.count);
            if (want == 0) return 0;
            const s = self.newest(want);
            @memcpy(dest[0..s.first.len], s.first);
            @memcpy(dest[s.first.len..][0..s.second.len], s.second);
            return want;
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

// === oldest/newest tests ===

fn collectSlices(s: RingBuf.Slices, out: []u8) []u8 {
    @memcpy(out[0..s.first.len], s.first);
    @memcpy(out[s.first.len..][0..s.second.len], s.second);
    return out[0 .. s.first.len + s.second.len];
}

test "oldest on empty buffer" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    const s = rb.oldest(3);
    try testing.expectEqual(@as(usize, 0), s.first.len + s.second.len);
}

test "newest on empty buffer" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    const s = rb.newest(3);
    try testing.expectEqual(@as(usize, 0), s.first.len + s.second.len);
}

test "oldest n=0" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3 });
    const s = rb.oldest(0);
    try testing.expectEqual(@as(usize, 0), s.first.len + s.second.len);
}

test "newest n=0" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3 });
    const s = rb.newest(0);
    try testing.expectEqual(@as(usize, 0), s.first.len + s.second.len);
}

test "oldest partial, no wrap" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 10, 20, 30, 40, 50 });
    var buf: [8]u8 = undefined;
    const result = collectSlices(rb.oldest(3), &buf);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, result);
}

test "newest partial, no wrap" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 10, 20, 30, 40, 50 });
    var buf: [8]u8 = undefined;
    const result = collectSlices(rb.newest(3), &buf);
    try testing.expectEqualSlices(u8, &.{ 30, 40, 50 }, result);
}

test "oldest clamps to count" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2 });
    var buf: [8]u8 = undefined;
    const result = collectSlices(rb.oldest(100), &buf);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, result);
}

test "newest clamps to count" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2 });
    var buf: [8]u8 = undefined;
    const result = collectSlices(rb.newest(100), &buf);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, result);
}

test "oldest with wrap, spans both segments" {
    // buf capacity 4, write 6 items -> oldest is [3,4,5,6]
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3, 4, 5, 6 });
    // full contents: [3, 4, 5, 6]
    var buf: [4]u8 = undefined;

    // oldest 2 should be [3, 4]
    const o2 = collectSlices(rb.oldest(2), &buf);
    try testing.expectEqualSlices(u8, &.{ 3, 4 }, o2);

    // oldest 3 should span both slices: [3, 4, 5]
    const o3 = collectSlices(rb.oldest(3), &buf);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5 }, o3);

    // oldest 4 = all
    const o4 = collectSlices(rb.oldest(4), &buf);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, o4);
}

test "newest with wrap, spans both segments" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3, 4, 5, 6 });
    // full contents oldest->newest: [3, 4, 5, 6]
    var buf: [4]u8 = undefined;

    // newest 1 = [6]
    const n1 = collectSlices(rb.newest(1), &buf);
    try testing.expectEqualSlices(u8, &.{ 6 }, n1);

    // newest 2 = [5, 6]
    const n2 = collectSlices(rb.newest(2), &buf);
    try testing.expectEqualSlices(u8, &.{ 5, 6 }, n2);

    // newest 3 spans both segments: [4, 5, 6]
    const n3 = collectSlices(rb.newest(3), &buf);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, n3);

    // newest 4 = all
    const n4 = collectSlices(rb.newest(4), &buf);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5, 6 }, n4);
}

test "oldest and newest agree on full buffer" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 10, 20, 30, 40 });
    var buf_o: [4]u8 = undefined;
    var buf_n: [4]u8 = undefined;
    const all_oldest = collectSlices(rb.oldest(4), &buf_o);
    const all_newest = collectSlices(rb.newest(4), &buf_n);
    try testing.expectEqualSlices(u8, all_oldest, all_newest);
}

// === copyNewest tests ===

test "copyNewest basic, no wrap" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 10, 20, 30, 40, 50 });
    var dest: [3]u8 = undefined;
    const n = rb.copyNewest(&dest);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &.{ 30, 40, 50 }, &dest);
}

test "copyNewest with wrap-around" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2, 3, 4, 5, 6 });
    // contents oldest→newest: [3, 4, 5, 6]
    var dest: [3]u8 = undefined;
    const n = rb.copyNewest(&dest);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, &dest);
}

test "copyNewest under-filled buffer" {
    var rb = try RingBuf.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append(&.{ 1, 2 });
    var dest: [5]u8 = undefined;
    const n = rb.copyNewest(&dest);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, dest[0..2], &.{ 1, 2 });
}

test "copyNewest empty buffer" {
    var rb = try RingBuf.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    var dest: [4]u8 = undefined;
    const n = rb.copyNewest(&dest);
    try testing.expectEqual(@as(usize, 0), n);
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
