const std = @import("std");

pub const Agc = struct {
    gain: f32,
    reference: f32,
    attack_rate: f32,
    decay_rate: f32,
    max_gain: f32,
    min_gain: f32,

    pub fn init(reference: f32, attack: f32, decay: f32) Agc {
        return .{
            .gain = 1.0,
            .reference = reference,
            .attack_rate = attack,
            .decay_rate = decay,
            .max_gain = 1000.0,
            .min_gain = 0.001,
        };
    }

    pub fn process(self: *Agc, input: []const f32, output: []f32) usize {
        for (input, output) |x, *out| {
            const y = x * self.gain;
            out.* = y;

            const err = self.reference - @abs(y);
            if (err < 0) {
                self.gain += self.attack_rate * err;
            } else {
                self.gain += self.decay_rate * err;
            }
            self.gain = std.math.clamp(self.gain, self.min_gain, self.max_gain);
        }
        return input.len;
    }

    pub fn reset(self: *Agc) void {
        self.gain = 1.0;
    }
};

const testing = std.testing;

test "AGC constant input converges to reference" {
    var agc = Agc.init(0.5, 0.1, 0.01);

    var buf: [2000]f32 = undefined;
    for (&buf) |*s| s.* = 0.1;

    _ = agc.process(&buf, &buf);

    var avg: f32 = 0;
    for (buf[1800..]) |s| avg += @abs(s);
    avg /= 200.0;

    try testing.expectApproxEqAbs(@as(f32, 0.5), avg, 0.1);
}

test "AGC loud signal reduces gain quickly" {
    var agc = Agc.init(0.5, 0.1, 0.01);
    agc.gain = 10.0;

    var buf: [100]f32 = undefined;
    for (&buf) |*s| s.* = 5.0;

    _ = agc.process(&buf, &buf);

    try testing.expect(agc.gain < 1.0);
}

test "AGC quiet signal increases gain slowly" {
    var agc = Agc.init(0.5, 0.1, 0.01);
    agc.gain = 0.1;

    var buf: [500]f32 = undefined;
    for (&buf) |*s| s.* = 0.01;

    const initial_gain = agc.gain;
    _ = agc.process(&buf, &buf);

    try testing.expect(agc.gain > initial_gain);
}

test "AGC gain stays within bounds" {
    var agc = Agc.init(0.5, 0.1, 0.01);

    var buf: [5000]f32 = undefined;
    for (&buf) |*s| s.* = 0.0;
    _ = agc.process(&buf, &buf);
    try testing.expect(agc.gain >= agc.min_gain);
    try testing.expect(agc.gain <= agc.max_gain);

    agc.reset();
    for (&buf) |*s| s.* = 100.0;
    _ = agc.process(&buf, &buf);
    try testing.expect(agc.gain >= agc.min_gain);
    try testing.expect(agc.gain <= agc.max_gain);
}

test "AGC reset restores initial gain" {
    var agc = Agc.init(0.5, 0.1, 0.01);

    var buf: [100]f32 = undefined;
    for (&buf) |*s| s.* = 5.0;
    _ = agc.process(&buf, &buf);

    try testing.expect(agc.gain != 1.0);
    agc.reset();
    try testing.expectApproxEqAbs(@as(f32, 1.0), agc.gain, 1e-6);
}
