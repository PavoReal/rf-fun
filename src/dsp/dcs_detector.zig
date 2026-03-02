const std = @import("std");
const Golay23_12 = @import("golay.zig").Golay23_12;
const Biquad = @import("biquad.zig").Biquad;

pub const DcsDetector = struct {
    lpf: Biquad,
    integrator: f32,
    integrator_count: u32,
    samples_per_bit: f32,
    clock_phase: f32,
    prev_filtered: f32,
    shift_reg: u32,
    bits_received: u32,
    detected_code: i16,
    detected_inverted: u8,
    consecutive_match: u8,
    required_consecutive: u8,
    last_candidate_code: i16,
    last_candidate_inv: u8,

    pub fn init(sample_rate: f32) DcsDetector {
        return .{
            .lpf = Biquad.initLowPass(sample_rate, 300.0, 0.707),
            .integrator = 0.0,
            .integrator_count = 0,
            .samples_per_bit = sample_rate / 134.4,
            .clock_phase = 0.0,
            .prev_filtered = 0.0,
            .shift_reg = 0,
            .bits_received = 0,
            .detected_code = -1,
            .detected_inverted = 0,
            .consecutive_match = 0,
            .required_consecutive = 3,
            .last_candidate_code = -2,
            .last_candidate_inv = 0,
        };
    }

    pub fn process(self: *DcsDetector, input: []const f32) void {
        for (input) |sample| {
            const filtered = self.lpf.processSample(sample);
            self.integrator += filtered;
            self.integrator_count += 1;

            const count_f: f32 = @floatFromInt(self.integrator_count);
            if (count_f >= self.samples_per_bit + self.clock_phase) {
                const bit: u1 = if (self.integrator > 0.0) 1 else 0;

                const transition = @abs(filtered - self.prev_filtered);
                const ideal_boundary = self.samples_per_bit;
                const phase_error = (count_f - ideal_boundary) / ideal_boundary;
                self.clock_phase += phase_error * 0.02 * transition;
                self.clock_phase = std.math.clamp(self.clock_phase, -self.samples_per_bit * 0.3, self.samples_per_bit * 0.3);

                self.shift_reg = ((self.shift_reg << 1) | @as(u32, bit)) & 0x7FFFFF;
                self.bits_received +|= 1;

                self.integrator = 0.0;
                self.integrator_count = 0;

                if (self.bits_received >= 23) {
                    self.tryDecode();
                }
            }

            self.prev_filtered = filtered;
        }
    }

    fn tryDecode(self: *DcsDetector) void {
        const raw: u23 = @intCast(self.shift_reg & 0x7FFFFF);
        const window = bitReverse23(raw);

        if (Golay23_12.isDcsCodeValid(window)) |dcs| {
            self.updateCandidate(@intCast(dcs.code), 0);
            return;
        }

        const inverted: u23 = ~window;
        if (Golay23_12.isDcsCodeValid(inverted)) |dcs| {
            self.updateCandidate(@intCast(dcs.code), 1);
            return;
        }
    }

    fn bitReverse23(val: u23) u23 {
        var result: u23 = 0;
        var v: u23 = val;
        for (0..23) |_| {
            result = (result << 1) | @as(u23, @intCast(v & 1));
            v >>= 1;
        }
        return result;
    }

    fn updateCandidate(self: *DcsDetector, code: i16, inverted: u8) void {
        if (code == self.last_candidate_code and inverted == self.last_candidate_inv) {
            self.consecutive_match +|= 1;
            if (self.consecutive_match >= self.required_consecutive) {
                self.detected_code = code;
                self.detected_inverted = inverted;
            }
        } else {
            self.last_candidate_code = code;
            self.last_candidate_inv = inverted;
            self.consecutive_match = 1;
        }
    }

    pub fn detectedCode(self: *const DcsDetector) ?u16 {
        if (self.detected_code < 0) return null;
        return @intCast(self.detected_code);
    }

    pub fn isInverted(self: *const DcsDetector) bool {
        return self.detected_inverted != 0;
    }

    pub fn detectedCodeString(self: *const DcsDetector) ?[5]u8 {
        const code = self.detectedCode() orelse return null;
        const octal = Golay23_12.dcsCodeToOctalString(code);
        var result: [5]u8 = undefined;
        result[0] = 'D';
        result[1] = octal[0];
        result[2] = octal[1];
        result[3] = octal[2];
        result[4] = if (self.detected_inverted != 0) 'I' else 'N';
        return result;
    }

    pub fn reset(self: *DcsDetector) void {
        self.lpf.reset();
        self.integrator = 0.0;
        self.integrator_count = 0;
        self.clock_phase = 0.0;
        self.prev_filtered = 0.0;
        self.shift_reg = 0;
        self.bits_received = 0;
        self.detected_code = -1;
        self.detected_inverted = 0;
        self.consecutive_match = 0;
        self.last_candidate_code = -2;
        self.last_candidate_inv = 0;
    }
};

const testing = std.testing;

fn generateNrzSignal(codeword: u23, samples_per_bit: f32, amplitude: f32, invert_polarity: bool, repetitions: u32, buf: []f32) usize {
    var idx: usize = 0;
    for (0..repetitions) |_| {
        for (0..23) |bit_i| {
            const bit_val = (codeword >> @intCast(bit_i)) & 1;
            var level: f32 = if (bit_val == 1) amplitude else -amplitude;
            if (invert_polarity) level = -level;

            const count: usize = @intFromFloat(samples_per_bit);
            for (0..count) |_| {
                if (idx >= buf.len) return idx;
                buf[idx] = level;
                idx += 1;
            }
        }
    }
    return idx;
}

test "detect DCS code from synthetic NRZ waveform" {
    const sample_rate: f32 = 25000.0;
    const samples_per_bit: f32 = sample_rate / 134.4;
    const code: u16 = 0o023;
    const data: u12 = (0b100 << 9) | @as(u12, @intCast(code));
    const codeword = Golay23_12.encode(data);

    const total_samples = @as(usize, @intFromFloat(samples_per_bit)) * 23 * 6 + 1000;
    var signal: [total_samples]f32 = undefined;
    const written = generateNrzSignal(codeword, samples_per_bit, 0.3, false, 6, &signal);

    var det = DcsDetector.init(sample_rate);
    det.process(signal[0..written]);

    const detected = det.detectedCode();
    try testing.expect(detected != null);
    try testing.expectEqual(@as(u16, 0o023), detected.?);
    try testing.expect(!det.isInverted());
}

test "detect inverted DCS code" {
    const sample_rate: f32 = 25000.0;
    const samples_per_bit: f32 = sample_rate / 134.4;
    const code: u16 = 0o023;
    const data: u12 = (0b100 << 9) | @as(u12, @intCast(code));
    const codeword = Golay23_12.encode(data);

    const total_samples = @as(usize, @intFromFloat(samples_per_bit)) * 23 * 6 + 1000;
    var signal: [total_samples]f32 = undefined;
    const written = generateNrzSignal(codeword, samples_per_bit, 0.3, true, 6, &signal);

    var det = DcsDetector.init(sample_rate);
    det.process(signal[0..written]);

    const detected = det.detectedCode();
    try testing.expect(detected != null);
    try testing.expectEqual(@as(u16, 0o023), detected.?);
    try testing.expect(det.isInverted());
}

test "no detection on silence" {
    const sample_rate: f32 = 25000.0;
    var det = DcsDetector.init(sample_rate);

    const silence = [_]f32{0.0} ** 10000;
    det.process(&silence);

    try testing.expect(det.detectedCode() == null);
}

test "reset clears detection" {
    const sample_rate: f32 = 25000.0;
    const samples_per_bit: f32 = sample_rate / 134.4;
    const code: u16 = 0o023;
    const data: u12 = (0b100 << 9) | @as(u12, @intCast(code));
    const codeword = Golay23_12.encode(data);

    const total_samples = @as(usize, @intFromFloat(samples_per_bit)) * 23 * 6 + 1000;
    var signal: [total_samples]f32 = undefined;
    const written = generateNrzSignal(codeword, samples_per_bit, 0.3, false, 6, &signal);

    var det = DcsDetector.init(sample_rate);
    det.process(signal[0..written]);
    try testing.expect(det.detectedCode() != null);

    det.reset();
    try testing.expectEqual(@as(i16, -1), det.detected_code);
    try testing.expect(det.detectedCode() == null);
}

test "detectedCodeString formats correctly" {
    var det = DcsDetector.init(25000.0);

    try testing.expect(det.detectedCodeString() == null);

    det.detected_code = 0o023;
    det.detected_inverted = 0;
    const normal = det.detectedCodeString().?;
    try testing.expectEqualStrings("D023N", &normal);

    det.detected_code = 0o743;
    det.detected_inverted = 1;
    const inv = det.detectedCodeString().?;
    try testing.expectEqualStrings("D743I", &inv);
}
