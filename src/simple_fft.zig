const std = @import("std");

const fftw = @cImport({
    @cDefine("__float128", "double");
    @cInclude("fftw3.h");
});

pub const SimpleFFT = struct {
    const Self = @This();

    fft_size: u32 = 0,
    fft_in: *[]fftw.fftw_complex = undefined,
    fft_out: *[]fftw.fftw_complex = undefined,
    fft_plan: fftw.fftw_plan = undefined,
    fft_mag: []f32 = undefined,
    fft_freqs: []f32 = undefined,

    pub fn init(alloc: std.mem.Allocator, fft_size: u32, center_freq: f32, fs: f32) !Self {
        var self: Self = .{};

        self.fft_size = fft_size;

        if (self.fft_size == 0) {
            return self;
        }

        self.fft_in = @ptrCast(@alignCast(fftw.fftw_malloc(@sizeOf(fftw.fftw_complex) * self.fft_size)));
        self.fft_out = @ptrCast(@alignCast(fftw.fftw_malloc(@sizeOf(fftw.fftw_complex) * self.fft_size)));
        self.fft_plan = fftw.fftw_plan_dft_1d(@intCast(self.fft_size), self.fft_in.ptr, self.fft_out.ptr, fftw.FFTW_FORWARD, fftw.FFTW_ESTIMATE);
        self.fft_mag = try alloc.alloc(f32, self.fft_size);
        self.fft_freqs = try alloc.alloc(f32, self.fft_size);

        const center_freq_mhz = center_freq / 1e6;
        const sample_rate_mhz = fs / 1e6;

        for (0..self.fft_size) |i| {
            const fft_size_f32 = @as(f32, @floatFromInt(self.fft_size));

            const bin: f32 = @as(f32, @floatFromInt(i)) - fft_size_f32 / 2.0;
            self.fft_freqs[i] = center_freq_mhz + bin * sample_rate_mhz / fft_size_f32;
        }

        return self;
    }

    pub fn calc(self: *Self, dat_i: []f32, dat_q: []f32) void {
        std.debug.assert(dat_i.len >= self.fft_size);
        std.debug.assert(dat_q.len >= self.fft_size);

        for (0..self.fft_size) |i| {
            self.fft_in[i][0] = dat_i;
            self.fft_in[i][1] = dat_q;
        }

        fftw.fftw_execute(self.fft_plan);

        const half = self.fft_size / 2;
        const n_sq: f64 = self.fft_size * self.fft_size;

        for (0..self.fft_size) |i| {
            const src = (i + half) % self.fft_size;
            const re = self.fft_out[src][0];
            const im = self.fft_out[src][1];

            const power = (re * re + im * im) / n_sq;
            self.fft_mag[i] = @floatCast(10.0 * @log10(@max(power, 1e-12)));
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        fftw.fftw_free(self.fft_in.ptr);
        fftw.fftw_free(self.fft_out.ptr);
        fftw.fftw_destroy_plan(self.fft_plan);
        alloc.free(self.fft_mag);
        alloc.free(self.fft_freqs);
    }
};
