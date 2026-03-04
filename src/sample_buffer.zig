const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;

pub const SampleBuffer = struct {
    mutex: std.Thread.Mutex = .{},
    rx_buffer: FixedSizeRingBuffer(hackrf.IQSample),
    bytes_received: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !SampleBuffer {
        return .{ .rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, capacity) };
    }

    pub fn reset(self: *SampleBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.rx_buffer.reset();
        self.bytes_received = 0;
    }

    pub fn resizeBuffer(self: *SampleBuffer, alloc: std.mem.Allocator, new_count: usize) !void {
        const new_buf = try alloc.alloc(hackrf.IQSample, new_count);
        self.mutex.lock();
        defer self.mutex.unlock();
        alloc.free(self.rx_buffer.buf);
        self.rx_buffer.buf = new_buf;
        self.rx_buffer.reset();
        self.bytes_received = 0;
    }

    pub fn deinit(self: *SampleBuffer, alloc: std.mem.Allocator) void {
        self.rx_buffer.deinit(alloc);
    }
};
