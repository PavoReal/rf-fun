const std = @import("std");

pub const Agc = struct {
    gain: f32 = 1.0,
    target: f32 = 0.3,
    attack: f32,
    decay: f32,
    max_gain: f32 = 1000.0,

    pub const Input = f32;
    pub const Output = f32;

    pub fn init(sample_rate: f32) Agc {
        return .{
            .attack = 1.0 - @exp(-1.0 / (0.002 * sample_rate)),
            .decay = 1.0 - @exp(-1.0 / (0.300 * sample_rate)),
        };
    }

    pub fn process(self: *Agc, input: []const f32, output: []f32) usize {
        for (input, output) |sample, *out| {
            out.* = sample * self.gain;
            const mag = @abs(out.*);
            if (mag > self.target) {
                self.gain *= (1.0 - self.attack);
            } else {
                self.gain = @min(self.gain * (1.0 + self.decay), self.max_gain);
            }
        }
        return input.len;
    }

    pub fn reset(self: *Agc) void {
        self.gain = 1.0;
    }
};
