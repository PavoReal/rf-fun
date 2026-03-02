const std = @import("std");
const Biquad = @import("biquad.zig").Biquad;

pub const SquelchState = enum(u8) {
    closed = 0,
    opening = 1,
    open = 2,
    closing = 3,
};

pub const NoiseSquelch = struct {
    noise_hpf: Biquad,
    noise_ema: f32 = 1.0,
    state: SquelchState = .closed,
    transition_count: u32 = 0,
    attack_samples: u32,
    release_samples: u32,
    ramp_samples: u32,
    ramp_pos: u32 = 0,
    open_threshold: f32 = 0.0,
    close_threshold: f32 = 0.0,
    ema_tc_samples: f32,

    auto_mode: bool = false,
    noise_floor_ema: f32 = 0.0,
    floor_tc_samples: f32,
    floor_rise_tc_samples: f32,
    floor_initialized: bool = false,
    auto_margin: f32 = 0.7,

    pub fn init(sample_rate: f32) NoiseSquelch {
        return .{
            .noise_hpf = Biquad.initHighPass(sample_rate, 4000.0, 0.707),
            .attack_samples = @intFromFloat(0.050 * sample_rate),
            .release_samples = @intFromFloat(0.300 * sample_rate),
            .ramp_samples = @intFromFloat(0.005 * sample_rate),
            .ema_tc_samples = 0.200 * sample_rate,
            .floor_tc_samples = 2.0 * sample_rate,
            .floor_rise_tc_samples = 8.0 * sample_rate,
        };
    }

    pub fn setAutoMode(self: *NoiseSquelch, enabled: bool) void {
        if (self.auto_mode == enabled) return;
        self.auto_mode = enabled;
        self.noise_floor_ema = 0.0;
        self.floor_initialized = false;
    }

    pub fn setThreshold(self: *NoiseSquelch, threshold: f32) void {
        if (self.auto_mode) return;
        if (threshold <= 0.0) {
            self.open_threshold = 0.0;
            self.close_threshold = 0.0;
        } else {
            self.close_threshold = threshold;
            self.open_threshold = threshold * 2.0;
        }
    }

    pub fn measureAndGate(self: *NoiseSquelch, noise_input: []const f32, audio: []f32) void {
        if (noise_input.len == 0) return;

        if (!self.auto_mode and self.open_threshold <= 0.0) {
            self.state = .open;
            self.noise_ema = 0.0;
            return;
        }

        var sum_sq: f64 = 0.0;
        for (noise_input) |x| {
            const filtered = self.noise_hpf.processSample(x);
            sum_sq += @as(f64, filtered) * @as(f64, filtered);
        }
        const rms: f32 = @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(noise_input.len))));

        const block_alpha = 1.0 - @exp(-@as(f32, @floatFromInt(noise_input.len)) / self.ema_tc_samples);
        self.noise_ema += block_alpha * (rms - self.noise_ema);

        if (self.auto_mode) {
            if (!self.floor_initialized) {
                self.noise_floor_ema = rms;
                self.floor_initialized = true;
            } else if (self.state == .closed or self.state == .closing) {
                const floor_alpha = 1.0 - @exp(-@as(f32, @floatFromInt(noise_input.len)) / self.floor_tc_samples);
                self.noise_floor_ema += floor_alpha * (rms - self.noise_floor_ema);
            } else if (rms > self.noise_floor_ema) {
                const rise_alpha = 1.0 - @exp(-@as(f32, @floatFromInt(noise_input.len)) / self.floor_rise_tc_samples);
                self.noise_floor_ema += rise_alpha * (rms - self.noise_floor_ema);
            }

            self.close_threshold = self.noise_floor_ema * self.auto_margin;
            self.open_threshold = self.close_threshold * 2.0;
        }

        const prev_state = self.state;
        switch (self.state) {
            .closed => {
                if (self.noise_ema < self.close_threshold) {
                    self.state = .opening;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                }
            },
            .opening => {
                if (self.noise_ema >= self.open_threshold) {
                    self.state = .closed;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                } else {
                    self.transition_count += @intCast(noise_input.len);
                    if (self.transition_count >= self.attack_samples) {
                        self.state = .open;
                    }
                }
            },
            .open => {
                if (self.noise_ema > self.open_threshold) {
                    self.state = .closing;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                }
            },
            .closing => {
                if (self.noise_ema <= self.close_threshold) {
                    self.state = .open;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                } else {
                    self.transition_count += @intCast(noise_input.len);
                    if (self.transition_count >= self.release_samples) {
                        self.state = .closed;
                    }
                }
            },
        }

        _ = prev_state;
        self.applyGate(audio);
    }

    fn applyGate(self: *NoiseSquelch, audio: []f32) void {
        switch (self.state) {
            .closed => @memset(audio, 0.0),
            .open => {},
            .opening => {
                for (audio) |*s| {
                    const gain = if (self.ramp_samples > 0)
                        @as(f32, @floatFromInt(@min(self.ramp_pos, self.ramp_samples))) / @as(f32, @floatFromInt(self.ramp_samples))
                    else
                        1.0;
                    s.* *= gain;
                    if (self.ramp_pos < self.ramp_samples) self.ramp_pos += 1;
                }
            },
            .closing => {
                for (audio) |*s| {
                    const gain = if (self.ramp_samples > 0)
                        1.0 - @as(f32, @floatFromInt(@min(self.ramp_pos, self.ramp_samples))) / @as(f32, @floatFromInt(self.ramp_samples))
                    else
                        0.0;
                    s.* *= gain;
                    if (self.ramp_pos < self.ramp_samples) self.ramp_pos += 1;
                }
            },
        }
    }

    pub fn noiseLevel(self: *const NoiseSquelch) f32 {
        return self.noise_ema;
    }

    pub fn noiseFloor(self: *const NoiseSquelch) f32 {
        return self.noise_floor_ema;
    }

    pub fn isOpen(self: *const NoiseSquelch) bool {
        return self.state == .open or self.state == .opening;
    }

    pub fn reset(self: *NoiseSquelch) void {
        self.noise_hpf.reset();
        self.noise_ema = 1.0;
        self.state = .closed;
        self.transition_count = 0;
        self.ramp_pos = 0;
        self.noise_floor_ema = 0.0;
        self.floor_initialized = false;
    }
};

const testing = std.testing;

test "squelch opens on clean signal (low noise)" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setThreshold(0.3);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.1 * @sin(2.0 * std.math.pi * 1000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    for (0..20) |_| {
        sq.measureAndGate(&noise_input, &audio);
    }

    try testing.expect(sq.isOpen());
}

test "squelch closes on noisy signal (high noise)" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setThreshold(0.01);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.8 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    for (0..20) |_| {
        sq.measureAndGate(&noise_input, &audio);
    }

    try testing.expect(!sq.isOpen());
}

test "threshold zero means always open" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setThreshold(0.0);

    var noise_input: [1000]f32 = undefined;
    var audio: [1000]f32 = undefined;
    @memset(&noise_input, 1.0);
    @memset(&audio, 0.5);

    sq.measureAndGate(&noise_input, &audio);

    try testing.expect(sq.isOpen());
    try testing.expectApproxEqAbs(@as(f32, 0.5), audio[500], 0.001);
}

test "hysteresis prevents chatter" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setThreshold(0.3);

    var low_noise: [2000]f32 = undefined;
    var mid_noise: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&low_noise, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.01 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }

    for (&mid_noise, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.4 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }

    for (0..30) |_| {
        @memset(&audio, 0.5);
        sq.measureAndGate(&low_noise, &audio);
    }
    try testing.expect(sq.isOpen());

    @memset(&audio, 0.5);
    sq.measureAndGate(&mid_noise, &audio);
    try testing.expect(sq.isOpen());
}

test "closed gate zeroes audio" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setThreshold(0.001);
    sq.state = .closed;

    var noise_input: [1000]f32 = undefined;
    var audio: [1000]f32 = undefined;
    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.9 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 1.0);

    sq.measureAndGate(&noise_input, &audio);

    for (audio) |s| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), s, 0.001);
    }
}

test "reset returns to initial state" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setThreshold(0.3);
    sq.state = .open;
    sq.noise_ema = 0.1;
    sq.transition_count = 500;

    sq.reset();

    try testing.expect(sq.state == .closed);
    try testing.expectApproxEqAbs(@as(f32, 1.0), sq.noise_ema, 0.001);
    try testing.expect(sq.transition_count == 0);
    try testing.expect(!sq.floor_initialized);
    try testing.expectApproxEqAbs(@as(f32, 0.0), sq.noise_floor_ema, 0.001);
}

test "auto mode initializes floor from first block" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.5 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    sq.measureAndGate(&noise_input, &audio);

    try testing.expect(sq.floor_initialized);
    try testing.expect(sq.noise_floor_ema > 0.0);
    try testing.expect(sq.close_threshold > 0.0);
    try testing.expect(sq.open_threshold > sq.close_threshold);
}

test "auto mode derives threshold from floor" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.5 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    for (0..10) |_| {
        sq.measureAndGate(&noise_input, &audio);
    }

    const expected_close = sq.noise_floor_ema * sq.auto_margin;
    try testing.expectApproxEqAbs(expected_close, sq.close_threshold, 0.001);
    try testing.expectApproxEqAbs(expected_close * 2.0, sq.open_threshold, 0.001);
}

test "auto mode ignores manual setThreshold" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;
    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.5 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);
    sq.measureAndGate(&noise_input, &audio);

    const auto_close = sq.close_threshold;
    sq.setThreshold(0.999);
    try testing.expectApproxEqAbs(auto_close, sq.close_threshold, 0.001);
}

test "auto mode closes squelch on noise-only signal" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.5 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    for (0..50) |_| {
        sq.measureAndGate(&noise_input, &audio);
    }

    try testing.expect(!sq.isOpen());
}

test "auto mode floor does not fall when open" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.5 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    for (0..50) |_| {
        sq.measureAndGate(&noise_input, &audio);
    }
    const floor_before = sq.noise_floor_ema;

    sq.state = .open;
    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.01 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    for (0..10) |_| {
        sq.measureAndGate(&noise_input, &audio);
        sq.state = .open;
    }

    try testing.expectApproxEqAbs(floor_before, sq.noise_floor_ema, 0.001);
}

test "auto mode floor tracks rising noise when open" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);

    var noise_input: [2000]f32 = undefined;
    var audio: [2000]f32 = undefined;

    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.3 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    @memset(&audio, 0.5);

    for (0..50) |_| {
        sq.measureAndGate(&noise_input, &audio);
    }
    const floor_before = sq.noise_floor_ema;

    sq.state = .open;
    for (&noise_input, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = 0.9 * @sin(2.0 * std.math.pi * 8000.0 * t / 25000.0);
    }
    for (0..100) |_| {
        sq.measureAndGate(&noise_input, &audio);
        sq.state = .open;
    }

    try testing.expect(sq.noise_floor_ema > floor_before);
}

test "setAutoMode resets floor tracker" {
    var sq = NoiseSquelch.init(25000.0);
    sq.setAutoMode(true);
    sq.noise_floor_ema = 0.5;
    sq.floor_initialized = true;

    sq.setAutoMode(false);
    sq.setAutoMode(true);

    try testing.expectApproxEqAbs(@as(f32, 0.0), sq.noise_floor_ema, 0.001);
    try testing.expect(!sq.floor_initialized);
}
