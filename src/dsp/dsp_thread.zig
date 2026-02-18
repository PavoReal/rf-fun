const std = @import("std");
const Allocator = std.mem.Allocator;
const DoubleBuffer = @import("double_buffer.zig").DoubleBuffer;
const FixedSizeRingBuffer = @import("../ring_buffer.zig").FixedSizeRingBuffer;
const pipeline_stats = @import("pipeline_stats.zig");
pub const ThreadStats = pipeline_stats.ThreadStats;

pub fn ProcessorWorker(comptime P: type) type {
    return struct {
        const Self = @This();

        pub const Input = P.Input;

        processor: P,
        output: DoubleBuffer(P.Output),
        work_buf: []P.Output,
        process_time_ns: u64 = 0,
        output_time_ns: u64 = 0,

        pub fn init(alloc: Allocator, capacity: usize, processor: P) !Self {
            var output = try DoubleBuffer(P.Output).init(alloc, capacity);
            errdefer output.deinit(alloc);
            const work_buf = try alloc.alloc(P.Output, capacity);
            return .{
                .processor = processor,
                .output = output,
                .work_buf = work_buf,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.output.deinit(alloc);
            alloc.free(self.work_buf);
        }

        pub fn work(self: *Self, input: []const Input) void {
            const t0: u64 = @intCast(std.time.nanoTimestamp());
            const n = self.processor.process(input, self.work_buf);
            const t1: u64 = @intCast(std.time.nanoTimestamp());
            const out = self.output.writeSlice();
            @memcpy(out[0..n], self.work_buf[0..n]);
            self.output.publish(n);
            const t2: u64 = @intCast(std.time.nanoTimestamp());
            self.process_time_ns = t1 - t0;
            self.output_time_ns = t2 - t1;
        }

        pub fn reset(self: *Self) void {
            self.processor.reset();
        }

        pub fn getOutput(self: *Self) ?[]const P.Output {
            return self.output.read();
        }
    };
}

pub fn DspThread(comptime Worker: type) type {
    return struct {
        const Self = @This();

        worker: Worker,
        thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = .init(false),
        target_interval_ns: std.atomic.Value(u64) = .init(0),
        chunk_size: usize,
        input_buf: []Worker.Input,
        alloc: Allocator,
        thread_stats: ThreadStats = .{},

        pub fn init(alloc: Allocator, chunk_size: usize, worker: Worker) !Self {
            return .{
                .worker = worker,
                .chunk_size = chunk_size,
                .input_buf = try alloc.alloc(Worker.Input, chunk_size),
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.alloc.free(self.input_buf);
        }

        pub fn start(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(Worker.Input)) !void {
            if (self.running.load(.acquire)) return;
            self.running.store(true, .release);
            self.thread = try std.Thread.spawn(.{}, runLoop, .{ self, mutex, rx_buffer });
        }

        pub fn setTargetRate(self: *Self, hz: u32) void {
            if (hz == 0) {
                self.target_interval_ns.store(0, .release);
            } else {
                self.target_interval_ns.store(1_000_000_000 / @as(u64, hz), .release);
            }
        }

        pub fn stop(self: *Self) void {
            if (!self.running.load(.acquire)) return;
            self.running.store(false, .release);
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }

        fn runLoop(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(Worker.Input)) void {
            var last_work_ns: i128 = std.time.nanoTimestamp();
            var busy_ema: f64 = 0.0;
            var busy_initialized = false;
            const busy_alpha = 0.05;

            while (self.running.load(.acquire)) {
                const loop_start: u64 = @intCast(std.time.nanoTimestamp());

                mutex.lock();
                const copied = rx_buffer.copyNewest(self.input_buf);
                mutex.unlock();

                if (copied < self.chunk_size) {
                    std.Thread.sleep(1_000_000);
                    continue;
                }

                const work_start: u64 = @intCast(std.time.nanoTimestamp());
                self.worker.work(self.input_buf[0..copied]);
                const work_end: u64 = @intCast(std.time.nanoTimestamp());

                _ = self.thread_stats.iteration_count.fetchAdd(1, .monotonic);

                const target_ns = self.target_interval_ns.load(.acquire);
                if (target_ns > 0) {
                    const now = std.time.nanoTimestamp();
                    const elapsed = now - last_work_ns;
                    if (elapsed >= 0 and elapsed < target_ns) {
                        std.Thread.sleep(@intCast(target_ns - @as(u64, @intCast(elapsed))));
                    }
                    last_work_ns = std.time.nanoTimestamp();
                }

                const loop_end: u64 = @intCast(std.time.nanoTimestamp());
                const work_dur = work_end - work_start;
                const loop_dur = loop_end - loop_start;
                if (loop_dur > 0) {
                    const ratio = @as(f64, @floatFromInt(work_dur)) / @as(f64, @floatFromInt(loop_dur));
                    if (!busy_initialized) {
                        busy_ema = ratio;
                        busy_initialized = true;
                    } else {
                        busy_ema = busy_alpha * ratio + (1.0 - busy_alpha) * busy_ema;
                    }
                    self.thread_stats.busy_pct.store(@intFromFloat(busy_ema * 10000.0), .release);
                }
            }
        }
    };
}

const testing = std.testing;

const CounterWorker = struct {
    pub const Input = f32;
    call_count: std.atomic.Value(u32) = .init(0),

    pub fn work(self: *CounterWorker, _: []const f32) void {
        _ = self.call_count.fetchAdd(1, .monotonic);
    }

    pub fn reset(self: *CounterWorker) void {
        self.call_count.store(0, .monotonic);
    }
};

test "DspThread start and stop" {
    var rb = try FixedSizeRingBuffer(f32).init(testing.allocator, 1024);
    defer rb.deinit(testing.allocator);

    var mutex = std.Thread.Mutex{};

    var thread = try DspThread(CounterWorker).init(testing.allocator, 64, .{});
    defer thread.deinit();

    var data: [256]f32 = undefined;
    @memset(&data, 1.0);

    {
        mutex.lock();
        rb.append(&data);
        mutex.unlock();
    }

    try thread.start(&mutex, &rb);
    std.Thread.sleep(50_000_000);
    thread.stop();

    try testing.expect(thread.worker.call_count.load(.monotonic) > 0);
}
