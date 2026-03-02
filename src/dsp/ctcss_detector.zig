const std = @import("std");

pub const CtcssDetector = struct {
    pub const num_tones = 50;

    pub const tone_freqs = [num_tones]f32{
        67.0,  69.3,  71.9,  74.4,  77.0,  79.7,  82.5,  85.4,  88.5,  91.5,
        94.8,  97.4,  100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
        171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 192.8, 196.6, 199.5, 203.5,
        206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1, 259.5,
    };

    coeffs: [num_tones]f32,
    state_s1: [num_tones]f32,
    state_s2: [num_tones]f32,
    block_count: usize,
    block_size: usize,
    signal_power_acc: f64,
    detected_tone_index: i8,
    detected_power: f32,
    sample_rate: f32,
    confirm_count: u8 = 0,
    confirm_threshold: u8 = 3,
    confirmed_tone_index: i8 = -1,
    no_tone_count: u8 = 0,
    drop_threshold: u8 = 5,
    prev_raw_index: i8 = -1,

    pub fn init(sample_rate: f32) CtcssDetector {
        const min_cycles = 15;
        const min_samples = @as(f32, min_cycles) * sample_rate / 67.0;
        var block_size: usize = 1;
        while (@as(f32, @floatFromInt(block_size)) < min_samples) {
            block_size <<= 1;
        }

        const n_f: f32 = @floatFromInt(block_size);
        var coeffs: [num_tones]f32 = undefined;
        for (&coeffs, &tone_freqs) |*c, freq| {
            const k = freq * n_f / sample_rate;
            c.* = 2.0 * @cos(2.0 * std.math.pi * k / n_f);
        }

        return .{
            .coeffs = coeffs,
            .state_s1 = .{0.0} ** num_tones,
            .state_s2 = .{0.0} ** num_tones,
            .block_count = 0,
            .block_size = block_size,
            .signal_power_acc = 0.0,
            .detected_tone_index = -1,
            .detected_power = 0.0,
            .sample_rate = sample_rate,
        };
    }

    pub fn reset(self: *CtcssDetector) void {
        self.state_s1 = .{0.0} ** num_tones;
        self.state_s2 = .{0.0} ** num_tones;
        self.block_count = 0;
        self.signal_power_acc = 0.0;
        self.detected_tone_index = -1;
        self.detected_power = 0.0;
        self.confirm_count = 0;
        self.confirmed_tone_index = -1;
        self.no_tone_count = 0;
        self.prev_raw_index = -1;
    }

    pub fn process(self: *CtcssDetector, input: []const f32) bool {
        for (input) |sample| {
            self.signal_power_acc += @as(f64, sample) * @as(f64, sample);

            for (0..num_tones) |i| {
                const s0 = self.coeffs[i] * self.state_s1[i] - self.state_s2[i] + sample;
                self.state_s2[i] = self.state_s1[i];
                self.state_s1[i] = s0;
            }

            self.block_count += 1;
            if (self.block_count >= self.block_size) {
                self.finalizeBlock();
                return true;
            }
        }
        return false;
    }

    fn finalizeBlock(self: *CtcssDetector) void {
        const n_sq: f32 = @floatFromInt(self.block_size * self.block_size);

        var max_power: f32 = 0.0;
        var max_index: i8 = -1;

        for (0..num_tones) |i| {
            const s1 = self.state_s1[i];
            const s2 = self.state_s2[i];
            const coeff = self.coeffs[i];
            const power = (s1 * s1 + s2 * s2 - coeff * s1 * s2) / n_sq;
            if (power > max_power) {
                max_power = power;
                max_index = @intCast(i);
            }
        }

        const avg_signal_power: f32 = @floatCast(self.signal_power_acc / @as(f64, @floatFromInt(self.block_size)));
        const threshold = avg_signal_power * 0.001;

        if (max_power > threshold and max_index >= 0) {
            self.detected_tone_index = max_index;
            self.detected_power = max_power;
        } else {
            self.detected_tone_index = -1;
            self.detected_power = 0.0;
        }

        if (self.detected_tone_index >= 0) {
            self.no_tone_count = 0;
            if (self.detected_tone_index == self.prev_raw_index) {
                self.confirm_count +|= 1;
                if (self.confirm_count >= self.confirm_threshold) {
                    self.confirmed_tone_index = self.detected_tone_index;
                }
            } else {
                self.confirm_count = 1;
            }
            self.prev_raw_index = self.detected_tone_index;
        } else {
            self.confirm_count = 0;
            self.prev_raw_index = -1;
            self.no_tone_count +|= 1;
            if (self.no_tone_count >= self.drop_threshold) {
                self.confirmed_tone_index = -1;
            }
        }

        self.state_s1 = .{0.0} ** num_tones;
        self.state_s2 = .{0.0} ** num_tones;
        self.block_count = 0;
        self.signal_power_acc = 0.0;
    }

    pub fn detectedToneHz(self: *const CtcssDetector) ?f32 {
        if (self.detected_tone_index < 0) return null;
        return tone_freqs[@intCast(self.detected_tone_index)];
    }

    pub fn detectedToneIndex(self: *const CtcssDetector) ?usize {
        if (self.detected_tone_index < 0) return null;
        return @intCast(self.detected_tone_index);
    }

    pub fn confirmedToneHz(self: *const CtcssDetector) ?f32 {
        if (self.confirmed_tone_index < 0) return null;
        return tone_freqs[@intCast(self.confirmed_tone_index)];
    }

    pub fn confirmedToneIndex(self: *const CtcssDetector) ?usize {
        if (self.confirmed_tone_index < 0) return null;
        return @intCast(self.confirmed_tone_index);
    }
};

const testing = std.testing;

test "detect 100 Hz CTCSS tone" {
    const sample_rate = 25000.0;
    var detector = CtcssDetector.init(sample_rate);

    const num_samples = detector.block_size * 3;
    var detected = false;
    for (0..num_samples) |i| {
        const t: f32 = @floatFromInt(i);
        const sample = @sin(2.0 * std.math.pi * 100.0 * t / sample_rate);
        const buf = [_]f32{sample};
        if (detector.process(&buf)) {
            detected = true;
        }
    }

    try testing.expect(detected);
    const idx = detector.detectedToneIndex();
    try testing.expect(idx != null);
    try testing.expectEqual(@as(usize, 12), idx.?);
    const hz = detector.detectedToneHz();
    try testing.expect(hz != null);
    try testing.expectApproxEqAbs(@as(f32, 100.0), hz.?, 0.01);
}

test "silence yields no detection" {
    var detector = CtcssDetector.init(25000.0);

    const num_samples = detector.block_size * 2;
    for (0..num_samples) |_| {
        const buf = [_]f32{0.0};
        _ = detector.process(&buf);
    }

    try testing.expect(detector.detectedToneIndex() == null);
    try testing.expect(detector.detectedToneHz() == null);
}

test "out-of-range 500 Hz tone not detected" {
    const sample_rate = 25000.0;
    var detector = CtcssDetector.init(sample_rate);

    const num_samples = detector.block_size * 3;
    for (0..num_samples) |i| {
        const t: f32 = @floatFromInt(i);
        const sample = @sin(2.0 * std.math.pi * 500.0 * t / sample_rate);
        const buf = [_]f32{sample};
        _ = detector.process(&buf);
    }

    const idx = detector.detectedToneIndex();
    if (idx) |tone_idx| {
        const detected_freq = CtcssDetector.tone_freqs[tone_idx];
        try testing.expect(@abs(detected_freq - 500.0) > 10.0);
    }
}

test "reset clears state" {
    const sample_rate = 25000.0;
    var detector = CtcssDetector.init(sample_rate);

    const num_samples = detector.block_size * 3;
    for (0..num_samples) |i| {
        const t: f32 = @floatFromInt(i);
        const sample = @sin(2.0 * std.math.pi * 100.0 * t / sample_rate);
        const buf = [_]f32{sample};
        _ = detector.process(&buf);
    }

    try testing.expect(detector.detectedToneIndex() != null);

    detector.reset();

    try testing.expectEqual(@as(i8, -1), detector.detected_tone_index);
    try testing.expectEqual(@as(f32, 0.0), detector.detected_power);
    try testing.expectEqual(@as(usize, 0), detector.block_count);
    try testing.expectEqual(@as(f64, 0.0), detector.signal_power_acc);
    try testing.expectEqual(@as(u8, 0), detector.confirm_count);
    try testing.expectEqual(@as(i8, -1), detector.confirmed_tone_index);
    try testing.expectEqual(@as(u8, 0), detector.no_tone_count);
    try testing.expectEqual(@as(i8, -1), detector.prev_raw_index);
    for (detector.state_s1) |s| {
        try testing.expectEqual(@as(f32, 0.0), s);
    }
    for (detector.state_s2) |s| {
        try testing.expectEqual(@as(f32, 0.0), s);
    }
}

test "hysteresis confirms stable tone" {
    const sample_rate = 25000.0;
    var detector = CtcssDetector.init(sample_rate);

    const blocks_needed = detector.confirm_threshold + 1;
    const num_samples = detector.block_size * blocks_needed;
    for (0..num_samples) |i| {
        const t: f32 = @floatFromInt(i);
        const sample = @sin(2.0 * std.math.pi * 100.0 * t / sample_rate);
        const buf = [_]f32{sample};
        _ = detector.process(&buf);
    }

    try testing.expect(detector.detectedToneIndex() != null);
    try testing.expect(detector.confirmedToneIndex() != null);
    try testing.expectEqual(@as(usize, 12), detector.confirmedToneIndex().?);
    const hz = detector.confirmedToneHz();
    try testing.expect(hz != null);
    try testing.expectApproxEqAbs(@as(f32, 100.0), hz.?, 0.01);
}

test "hysteresis drops after silence" {
    const sample_rate = 25000.0;
    var detector = CtcssDetector.init(sample_rate);

    const confirm_blocks = detector.confirm_threshold + 1;
    const confirm_samples = detector.block_size * confirm_blocks;
    for (0..confirm_samples) |i| {
        const t: f32 = @floatFromInt(i);
        const sample = @sin(2.0 * std.math.pi * 100.0 * t / sample_rate);
        const buf = [_]f32{sample};
        _ = detector.process(&buf);
    }

    try testing.expect(detector.confirmedToneIndex() != null);

    const silence_blocks = detector.drop_threshold + 1;
    const silence_samples = detector.block_size * silence_blocks;
    for (0..silence_samples) |_| {
        const buf = [_]f32{0.0};
        _ = detector.process(&buf);
    }

    try testing.expect(detector.confirmedToneIndex() == null);
    try testing.expect(detector.confirmedToneHz() == null);
}
