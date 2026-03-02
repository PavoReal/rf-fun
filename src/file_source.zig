const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;

pub const FileSource = struct {
    const Self = @This();

    mutex: std.Thread.Mutex = .{},
    rx_buffer: FixedSizeRingBuffer(hackrf.IQSample) = undefined,
    samples: []hackrf.IQSample,
    sample_rate: u32,
    position: usize = 0,
    playing: std.atomic.Value(bool) = .init(false),
    looping: bool = true,
    thread: ?std.Thread = null,
    total_written: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, samples: []hackrf.IQSample, sample_rate: u32, buf_size: usize) !Self {
        return .{
            .rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, buf_size),
            .samples = samples,
            .sample_rate = sample_rate,
        };
    }

    pub fn start(self: *Self) !void {
        if (self.playing.load(.acquire)) return;
        self.position = 0;
        self.total_written = 0;
        self.playing.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, playbackLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.playing.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.stop();
        self.rx_buffer.deinit(alloc);
    }

    fn playbackLoop(self: *Self) void {
        const chunk_size: usize = 32768;
        const ns_per_chunk: u64 = @intFromFloat(@as(f64, @floatFromInt(chunk_size)) / @as(f64, @floatFromInt(self.sample_rate)) * 1e9);

        while (self.playing.load(.acquire)) {
            const remaining = self.samples.len - self.position;
            if (remaining == 0) {
                if (self.looping) {
                    self.position = 0;
                    continue;
                } else {
                    break;
                }
            }

            const to_write = @min(chunk_size, remaining);
            const chunk = self.samples[self.position..self.position + to_write];

            self.mutex.lock();
            self.rx_buffer.append(chunk);
            self.total_written += to_write;
            self.mutex.unlock();

            self.position += to_write;
            std.Thread.sleep(ns_per_chunk);
        }
    }
};
