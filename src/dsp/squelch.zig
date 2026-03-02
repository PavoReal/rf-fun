const std = @import("std");

pub const SquelchState = enum(u8) {
    closed = 0,
    opening = 1,
    open = 2,
    closing = 3,
};

pub const Squelch = struct {
    level_db: f32 = -120.0,
    state: SquelchState = .closed,
    transition_count: u32 = 0,
    attack_samples: u32,
    release_samples: u32,
    ramp_samples: u32,
    ramp_pos: u32 = 0,
    threshold_db: f32 = -100.0,
    ema_tc_samples: f32,
    ema_fast_tc_samples: f32,
    intermediate_rate: f32,

    pub fn init(intermediate_rate: f32, audio_rate: f32) Squelch {
        return .{
            .attack_samples = @intFromFloat(0.050 * intermediate_rate),
            .release_samples = @intFromFloat(0.150 * intermediate_rate),
            .ramp_samples = @intFromFloat(0.010 * audio_rate),
            .ema_tc_samples = 0.200 * intermediate_rate,
            .ema_fast_tc_samples = 0.030 * intermediate_rate,
            .intermediate_rate = intermediate_rate,
        };
    }

    pub fn setThreshold(self: *Squelch, threshold_db: f32) void {
        self.threshold_db = threshold_db;
    }

    pub fn updateLevel(self: *Squelch, iq_samples: []const [2]f32) void {
        if (iq_samples.len == 0) return;

        if (self.threshold_db <= -100.0) {
            self.state = .open;
            return;
        }

        var sum: f64 = 0.0;
        for (iq_samples) |s| {
            const i: f64 = @floatCast(s[0]);
            const q: f64 = @floatCast(s[1]);
            sum += @sqrt(i * i + q * q);
        }
        const mean_mag: f32 = @floatCast(sum / @as(f64, @floatFromInt(iq_samples.len)));

        const raw_db = if (mean_mag > 0.0) 20.0 * @log10(mean_mag) else -120.0;
        const new_db = @max(raw_db, -120.0);

        const tc = if (new_db < self.level_db) self.ema_fast_tc_samples else self.ema_tc_samples;
        const block_alpha = 1.0 - @exp(-@as(f32, @floatFromInt(iq_samples.len)) / tc);
        self.level_db += block_alpha * (new_db - self.level_db);

        const open_threshold = self.threshold_db;
        const close_threshold = self.threshold_db - 3.0;

        switch (self.state) {
            .closed => {
                if (self.level_db >= open_threshold) {
                    self.state = .opening;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                }
            },
            .opening => {
                if (self.level_db < close_threshold) {
                    self.state = .closed;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                } else {
                    self.transition_count += @intCast(iq_samples.len);
                    if (self.transition_count >= self.attack_samples) {
                        self.state = .open;
                    }
                }
            },
            .open => {
                if (self.level_db < close_threshold) {
                    self.state = .closing;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                }
            },
            .closing => {
                if (self.level_db >= open_threshold) {
                    self.state = .open;
                    self.transition_count = 0;
                    self.ramp_pos = 0;
                } else {
                    self.transition_count += @intCast(iq_samples.len);
                    if (self.transition_count >= self.release_samples) {
                        self.state = .closed;
                    }
                }
            },
        }
    }

    pub fn gate(self: *Squelch, audio: []f32) void {
        switch (self.state) {
            .closed => @memset(audio, 0.0),
            .open => {},
            .opening => {
                for (audio) |*s| {
                    const frac = @as(f32, @floatFromInt(@min(self.ramp_pos, self.ramp_samples))) / @as(f32, @floatFromInt(self.ramp_samples));
                    const gain = 0.5 * (1.0 - @cos(std.math.pi * frac));
                    s.* *= gain;
                    if (self.ramp_pos < self.ramp_samples) self.ramp_pos += 1;
                }
            },
            .closing => {
                for (audio) |*s| {
                    const frac = @as(f32, @floatFromInt(@min(self.ramp_pos, self.ramp_samples))) / @as(f32, @floatFromInt(self.ramp_samples));
                    const gain = 0.5 * (1.0 + @cos(std.math.pi * frac));
                    s.* *= gain;
                    if (self.ramp_pos < self.ramp_samples) self.ramp_pos += 1;
                }
            },
        }
    }

    pub fn levelDb(self: *const Squelch) f32 {
        return self.level_db;
    }

    pub fn isOpen(self: *const Squelch) bool {
        return self.state == .open or self.state == .opening;
    }

    pub fn reset(self: *Squelch) void {
        self.level_db = -120.0;
        self.state = .closed;
        self.transition_count = 0;
        self.ramp_pos = 0;
    }
};

const testing = std.testing;

test "opens on strong IQ signal above threshold" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.setThreshold(-40.0);

    var iq: [4000][2]f32 = undefined;
    for (&iq) |*s| {
        s.* = .{ 0.1, 0.1 };
    }

    for (0..30) |_| {
        sq.updateLevel(&iq);
    }

    try testing.expect(sq.isOpen());
}

test "stays closed on weak IQ signal below threshold" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.setThreshold(-20.0);

    var iq: [4000][2]f32 = undefined;
    for (&iq) |*s| {
        s.* = .{ 0.0001, 0.0001 };
    }

    for (0..30) |_| {
        sq.updateLevel(&iq);
    }

    try testing.expect(!sq.isOpen());
}

test "threshold at -100 dB means always open (disabled)" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.setThreshold(-100.0);

    var iq: [1000][2]f32 = undefined;
    for (&iq) |*s| {
        s.* = .{ 0.0001, 0.0001 };
    }

    sq.updateLevel(&iq);
    try testing.expect(sq.isOpen());
}

test "hysteresis prevents chatter" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.setThreshold(-30.0);

    var strong: [4000][2]f32 = undefined;
    for (&strong) |*s| {
        s.* = .{ 0.1, 0.1 };
    }

    for (0..80) |_| {
        sq.updateLevel(&strong);
    }
    try testing.expect(sq.isOpen());

    var mid: [4000][2]f32 = undefined;
    for (&mid) |*s| {
        s.* = .{ 0.025, 0.025 };
    }
    sq.updateLevel(&mid);
    try testing.expect(sq.isOpen());
}

test "closed gate zeroes audio" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.state = .closed;

    var audio: [1000]f32 = undefined;
    @memset(&audio, 1.0);

    sq.gate(&audio);

    for (audio) |s| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), s, 0.001);
    }
}

test "reset returns to initial state" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.state = .open;
    sq.level_db = -30.0;
    sq.transition_count = 500;

    sq.reset();

    try testing.expect(sq.state == .closed);
    try testing.expectApproxEqAbs(@as(f32, -120.0), sq.level_db, 0.001);
    try testing.expect(sq.transition_count == 0);
}

test "asymmetric EMA: fast fall, slow rise" {
    var sq = Squelch.init(400_000.0, 50_000.0);
    sq.setThreshold(-50.0);
    sq.level_db = -30.0;

    var weak: [4000][2]f32 = undefined;
    for (&weak) |*s| {
        s.* = .{ 0.0001, 0.0001 };
    }
    sq.updateLevel(&weak);
    const after_fall = sq.level_db;

    sq.level_db = -80.0;
    var strong: [4000][2]f32 = undefined;
    for (&strong) |*s| {
        s.* = .{ 0.1, 0.1 };
    }
    sq.updateLevel(&strong);
    const after_rise = sq.level_db;

    const fall_delta = @abs(after_fall - (-30.0));
    const rise_delta = @abs(after_rise - (-80.0));
    try testing.expect(fall_delta > rise_delta);
}
