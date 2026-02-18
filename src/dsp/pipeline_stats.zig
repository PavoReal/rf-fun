const std = @import("std");

pub fn PipelineStats(comptime StageEnum: type) type {
    const count = std.enums.values(StageEnum).len;
    return struct {
        stage_ns: [count]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** count,
        total_ns: std.atomic.Value(u64) = .init(0),

        pub fn view(self: *const @This(), labels: *const [count][:0]const u8) PipelineView {
            return .{
                .stage_count = count,
                .labels = labels,
                .stage_ns = &self.stage_ns,
                .total_ns = &self.total_ns,
            };
        }
    };
}

pub fn EmaAccumulator(comptime StageEnum: type) type {
    const count = std.enums.values(StageEnum).len;
    return struct {
        values: [count]f64,
        total: f64,
        alpha: f64,
        initialized: bool,

        pub fn init(alpha: f64) @This() {
            return .{
                .values = .{0.0} ** count,
                .total = 0.0,
                .alpha = alpha,
                .initialized = false,
            };
        }

        pub fn update(self: *@This(), stage: StageEnum, raw_ns: u64) void {
            const idx = @intFromEnum(stage);
            const v: f64 = @floatFromInt(raw_ns);
            if (!self.initialized) {
                self.values[idx] = v;
            } else {
                self.values[idx] = self.alpha * v + (1.0 - self.alpha) * self.values[idx];
            }
        }

        pub fn updateTotal(self: *@This(), raw_ns: u64) void {
            const v: f64 = @floatFromInt(raw_ns);
            if (!self.initialized) {
                self.total = v;
            } else {
                self.total = self.alpha * v + (1.0 - self.alpha) * self.total;
            }
        }

        pub fn finalize(self: *@This()) void {
            self.initialized = true;
        }

        pub fn publish(self: *const @This(), stats: *PipelineStats(StageEnum)) void {
            for (0..count) |i| {
                stats.stage_ns[i].store(@intFromFloat(self.values[i]), .release);
            }
            stats.total_ns.store(@intFromFloat(self.total), .release);
        }
    };
}

pub const PipelineView = struct {
    stage_count: usize,
    labels: []const [:0]const u8,
    stage_ns: []const std.atomic.Value(u64),
    total_ns: *const std.atomic.Value(u64),
};

pub const ThreadStats = struct {
    busy_pct: std.atomic.Value(u32) = .init(0),
    iteration_count: std.atomic.Value(u64) = .init(0),
};
