const std = @import("std");

const fftw = @cImport({
    @cDefine("__float128", "double");
    @cInclude("fftw3.h");
});

const WindowType = enum { NONE, BLACKMANHARRIS };

pub const SimpleFFT = struct {
    const Self = @This();

    fft_size: u32 = 0,
    fft_in: [*]fftw.fftwf_complex = undefined,
    fft_out: [*]fftw.fftwf_complex = undefined,
    fft_plan: fftw.fftwf_plan = undefined,
    fft_mag: []f32 = undefined,
    fft_freqs: []f32 = undefined,
    window_func_type: WindowType = WindowType.NONE,

    pub fn init(alloc: std.mem.Allocator, fft_size: u32, center_freq: f32, fs: f32, window: WindowType) !Self {
        var self: Self = .{};

        self.fft_size = fft_size;
        self.window_func_type = window;

        if (self.fft_size == 0) {
            return self;
        }

        self.fft_in = @ptrCast(@alignCast(fftw.fftwf_malloc(@sizeOf(fftw.fftwf_complex) * self.fft_size)));
        self.fft_out = @ptrCast(@alignCast(fftw.fftwf_malloc(@sizeOf(fftw.fftwf_complex) * self.fft_size)));
        self.fft_plan = fftw.fftwf_plan_dft_1d(@intCast(self.fft_size), self.fft_in, self.fft_out, fftw.FFTW_FORWARD, fftw.FFTW_ESTIMATE);
        self.fft_mag = try alloc.alloc(f32, self.fft_size);
        self.fft_freqs = try alloc.alloc(f32, self.fft_size);

        self.updateFreqs(center_freq, fs);
        self.calcWindowCoef();

        return self;
    }

    pub fn updateFreqs(self: *Self, center_freq: f32, fs: f32) void {
        const center_freq_mhz = center_freq / 1e6;
        const sample_rate_mhz = fs / 1e6;
        const fft_size_f32: f32 = @floatFromInt(self.fft_size);
        for (0..self.fft_size) |i| {
            const bin: f32 = @as(f32, @floatFromInt(i)) - fft_size_f32 / 2.0;
            self.fft_freqs[i] = center_freq_mhz + bin * sample_rate_mhz / fft_size_f32;
        }
    }

    fn calcBlackmanHarris(_: *Self) void {}

    pub fn calcWindowCoef(self: *Self) void {
        switch (self.window_func_type) {
            .NONE => return,
            .BLACKMANHARRIS => self.calcBlackmanHarris(),
        }
    }

    pub fn calc(self: *Self, data: []const [2]f32) void {
        std.debug.assert(data.len >= self.fft_size);

        for (0..self.fft_size) |i| {
            self.fft_in[i] = data[i];
        }

        fftw.fftwf_execute(self.fft_plan);

        const half = self.fft_size / 2;
        const n_f: f32 = @floatFromInt(self.fft_size);
        const n_sq: f32 = n_f * n_f;

        for (0..self.fft_size) |i| {
            const src = (i + half) % self.fft_size;
            const re = self.fft_out[src][0];
            const im = self.fft_out[src][1];

            const power = (re * re + im * im) / n_sq;
            self.fft_mag[i] = 10.0 * @log10(@max(power, 1e-12));
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        fftw.fftwf_destroy_plan(self.fft_plan);
        fftw.fftwf_free(@ptrCast(self.fft_in));
        fftw.fftwf_free(@ptrCast(self.fft_out));
        alloc.free(self.fft_mag);
        alloc.free(self.fft_freqs);
    }
};
