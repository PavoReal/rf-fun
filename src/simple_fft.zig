const std = @import("std");

const fftw = @cImport({
    @cDefine("__float128", "double");
    @cInclude("fftw3.h");
});

pub const WindowType = enum(i32) {
    NONE = 0,
    HANNING = 1,
    HAMMING = 2,
    BLACKMAN_HARRIS = 3,
    FLAT_TOP = 4,
};

pub const window_labels: [:0]const u8 = "None\x00Hanning\x00Hamming\x00Blackman-Harris\x00Flat-Top\x00";

pub const SimpleFFT = struct {
    const Self = @This();

    fft_size: u32 = 0,
    fft_in: [*]fftw.fftwf_complex = undefined,
    fft_out: [*]fftw.fftwf_complex = undefined,
    fft_plan: fftw.fftwf_plan = undefined,
    fft_mag: []f32 = undefined,
    fft_freqs: []f32 = undefined,
    window_func_type: WindowType = .NONE,
    window_coefs: []f32 = undefined,
    coherent_gain_sq: f32 = 1.0,

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
        self.window_coefs = try alloc.alloc(f32, self.fft_size);

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

    pub fn setWindow(self: *Self, window: WindowType) void {
        self.window_func_type = window;
        self.calcWindowCoef();
    }

    pub fn calcWindowCoef(self: *Self) void {
        const n: f32 = @floatFromInt(self.fft_size);
        var sum: f32 = 0.0;

        switch (self.window_func_type) {
            .NONE => {
                for (0..self.fft_size) |i| {
                    self.window_coefs[i] = 1.0;
                }
                self.coherent_gain_sq = 1.0;
                return;
            },
            .HANNING => {
                for (0..self.fft_size) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const w = 0.5 * (1.0 - @cos(2.0 * std.math.pi * fi / n));
                    self.window_coefs[i] = @floatCast(w);
                    sum += self.window_coefs[i];
                }
            },
            .HAMMING => {
                for (0..self.fft_size) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const w = 0.54 - 0.46 * @cos(2.0 * std.math.pi * fi / n);
                    self.window_coefs[i] = @floatCast(w);
                    sum += self.window_coefs[i];
                }
            },
            .BLACKMAN_HARRIS => {
                const a0: f64 = 0.35875;
                const a1: f64 = 0.48829;
                const a2: f64 = 0.14128;
                const a3: f64 = 0.01168;
                for (0..self.fft_size) |i| {
                    const fi: f64 = @floatFromInt(i);
                    const nf: f64 = @floatFromInt(self.fft_size);
                    const w = a0 - a1 * @cos(2.0 * std.math.pi * fi / nf) + a2 * @cos(4.0 * std.math.pi * fi / nf) - a3 * @cos(6.0 * std.math.pi * fi / nf);
                    self.window_coefs[i] = @floatCast(w);
                    sum += self.window_coefs[i];
                }
            },
            .FLAT_TOP => {
                const a0: f64 = 0.21557895;
                const a1: f64 = 0.41663158;
                const a2: f64 = 0.277263158;
                const a3: f64 = 0.083578947;
                const a4: f64 = 0.006947368;
                for (0..self.fft_size) |i| {
                    const fi: f64 = @floatFromInt(i);
                    const nf: f64 = @floatFromInt(self.fft_size);
                    const w = a0 - a1 * @cos(2.0 * std.math.pi * fi / nf) + a2 * @cos(4.0 * std.math.pi * fi / nf) - a3 * @cos(6.0 * std.math.pi * fi / nf) + a4 * @cos(8.0 * std.math.pi * fi / nf);
                    self.window_coefs[i] = @floatCast(w);
                    sum += self.window_coefs[i];
                }
            },
        }

        // Coherent gain = (sum of window coefs) / N
        // We store the square for power correction
        const cg = sum / n;
        self.coherent_gain_sq = cg * cg;
        if (self.coherent_gain_sq < 1e-12) self.coherent_gain_sq = 1.0;
    }

    pub fn calc(self: *Self, data: []const [2]f32) void {
        std.debug.assert(data.len >= self.fft_size);

        for (0..self.fft_size) |i| {
            self.fft_in[i] = .{ data[i][0] * self.window_coefs[i], data[i][1] * self.window_coefs[i] };
        }

        fftw.fftwf_execute(self.fft_plan);

        const half = self.fft_size / 2;
        const n_f: f32 = @floatFromInt(self.fft_size);
        const n_sq: f32 = n_f * n_f;

        for (0..self.fft_size) |i| {
            const src = (i + half) % self.fft_size;
            const re = self.fft_out[src][0];
            const im = self.fft_out[src][1];

            const power = (re * re + im * im) / (n_sq * self.coherent_gain_sq);
            self.fft_mag[i] = 10.0 * @log10(@max(power, 1e-12));
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        fftw.fftwf_destroy_plan(self.fft_plan);
        fftw.fftwf_free(@ptrCast(self.fft_in));
        fftw.fftwf_free(@ptrCast(self.fft_out));
        alloc.free(self.fft_mag);
        alloc.free(self.fft_freqs);
        alloc.free(self.window_coefs);
    }
};
