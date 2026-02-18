const std = @import("std");

pub const StageId = enum(u3) {
    dc_filter = 0,
    fft_compute = 1,
    ema_avg = 2,
    peak_hold = 3,
    output = 4,
};

pub const stage_count = std.enums.values(StageId).len;

pub const stage_labels: [stage_count][:0]const u8 = .{
    "DC Filter",
    "FFT Compute",
    "EMA Averaging",
    "Peak Hold",
    "Output",
};

pub const PipelineStats = struct {
    stage_ns: [stage_count]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** stage_count,
    total_ns: std.atomic.Value(u64) = .init(0),
};

pub const EmaAccumulator = struct {
    values: [stage_count]f64,
    total: f64,
    alpha: f64,
    initialized: bool,

    pub fn init(alpha: f64) EmaAccumulator {
        return .{
            .values = .{0.0} ** stage_count,
            .total = 0.0,
            .alpha = alpha,
            .initialized = false,
        };
    }

    pub fn update(self: *EmaAccumulator, stage: StageId, raw_ns: u64) void {
        const idx = @intFromEnum(stage);
        const v: f64 = @floatFromInt(raw_ns);
        if (!self.initialized) {
            self.values[idx] = v;
        } else {
            self.values[idx] = self.alpha * v + (1.0 - self.alpha) * self.values[idx];
        }
    }

    pub fn updateTotal(self: *EmaAccumulator, raw_ns: u64) void {
        const v: f64 = @floatFromInt(raw_ns);
        if (!self.initialized) {
            self.total = v;
        } else {
            self.total = self.alpha * v + (1.0 - self.alpha) * self.total;
        }
    }

    pub fn finalize(self: *EmaAccumulator) void {
        self.initialized = true;
    }

    pub fn publish(self: *const EmaAccumulator, stats: *PipelineStats) void {
        for (0..stage_count) |i| {
            stats.stage_ns[i].store(@intFromFloat(self.values[i]), .release);
        }
        stats.total_ns.store(@intFromFloat(self.total), .release);
    }
};

pub const ThreadStats = struct {
    busy_pct: std.atomic.Value(u32) = .init(0),
    iteration_count: std.atomic.Value(u64) = .init(0),
};
