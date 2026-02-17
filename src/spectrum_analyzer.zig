const std = @import("std");
const hackrf = @import("rf_fun");
const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const WindowType = @import("simple_fft.zig").WindowType;
const window_labels = @import("simple_fft.zig").window_labels;
const Waterfall = @import("waterfall.zig").Waterfall;
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const zgui = @import("zgui");
const zsdl = @import("zsdl3");

pub const fft_size_values = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096, 8192 };
pub const fft_size_labels: [:0]const u8 = "64\x00128\x00256\x00512\x001024\x002048\x004096\x008192\x00";

pub const UiResult = struct {
    resized: bool = false,
    new_fft_size: u32 = 0,
};

pub const SpectrumAnalyzer = struct {
    const Self = @This();

    alloc: std.mem.Allocator,

    fft: SimpleFFT,
    fft_buf: [][2]f32,
    iq_scratch: []hackrf.IQSample,

    fft_size_index: i32,
    window_index: i32,

    avg_count: i32,
    ema_data: []f32,
    ema_initialized: bool,

    peak_hold_enabled: bool,
    peak_hold_data: []f32,
    peak_decay_rate: f32,
    last_peak_time_ms: u64,

    fft_frame_interval_us: u64,
    last_fft_time_us: u64,

    refit_x: bool,

    waterfall: Waterfall,
    wf_history_len: u32,

    pub fn init(
        alloc: std.mem.Allocator,
        fft_size_index: i32,
        window_index: i32,
        cf_mhz: f32,
        fs_hz: f64,
        wf_history: u32,
    ) !Self {
        const fft_size = fft_size_values[@intCast(fft_size_index)];

        var fft = try SimpleFFT.init(alloc, fft_size, cf_mhz * 1e6, @floatCast(fs_hz), @enumFromInt(window_index));
        errdefer fft.deinit(alloc);

        const fft_buf = try alloc.alloc([2]f32, fft_size);
        errdefer alloc.free(fft_buf);

        const iq_scratch = try alloc.alloc(hackrf.IQSample, fft_size);
        errdefer alloc.free(iq_scratch);

        const ema_data = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(ema_data);
        @memset(ema_data, -200.0);

        const peak_hold_data = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(peak_hold_data);
        @memset(peak_hold_data, -200.0);

        var waterfall = try Waterfall.init(alloc, fft_size, wf_history);
        errdefer waterfall.deinit(alloc);

        const fft_target_fps: i32 = 30;

        return Self{
            .alloc = alloc,
            .fft = fft,
            .fft_buf = fft_buf,
            .iq_scratch = iq_scratch,
            .fft_size_index = fft_size_index,
            .window_index = window_index,
            .avg_count = 2,
            .ema_data = ema_data,
            .ema_initialized = false,
            .peak_hold_enabled = false,
            .peak_hold_data = peak_hold_data,
            .peak_decay_rate = 1.6,
            .last_peak_time_ms = 0,
            .fft_frame_interval_us = 1_000_000 / @as(u64, @intCast(fft_target_fps)),
            .last_fft_time_us = zsdl.getTicks() * 1000,
            .refit_x = true,
            .waterfall = waterfall,
            .wf_history_len = wf_history,
        };
    }

    pub fn deinit(self: *Self) void {
        self.fft.deinit(self.alloc);
        self.alloc.free(self.fft_buf);
        self.alloc.free(self.iq_scratch);
        self.alloc.free(self.ema_data);
        self.alloc.free(self.peak_hold_data);
        self.waterfall.deinit(self.alloc);
    }

    pub fn resize(self: *Self, new_index: i32, cf_mhz: f32, fs_hz: f64) !u32 {
        const new_size = fft_size_values[@intCast(new_index)];
        self.fft_size_index = new_index;

        self.fft.deinit(self.alloc);
        self.fft = try SimpleFFT.init(self.alloc, new_size, cf_mhz * 1e6, @floatCast(fs_hz), @enumFromInt(self.window_index));

        self.fft_buf = try self.alloc.realloc(self.fft_buf, new_size);
        self.iq_scratch = try self.alloc.realloc(self.iq_scratch, new_size);

        self.waterfall.deinit(self.alloc);
        self.waterfall = try Waterfall.init(self.alloc, new_size, self.wf_history_len);

        self.peak_hold_data = try self.alloc.realloc(self.peak_hold_data, new_size);
        @memset(self.peak_hold_data, -200.0);

        self.ema_data = try self.alloc.realloc(self.ema_data, new_size);
        @memset(self.ema_data, -200.0);
        self.ema_initialized = false;

        return new_size;
    }

    pub fn updateFreqs(self: *Self, cf_mhz: f32, fs_hz: f64) void {
        self.fft.updateFreqs(cf_mhz * 1e6, @floatCast(fs_hz));
        self.refit_x = true;
    }

    pub fn resetSmoothing(self: *Self) void {
        self.ema_initialized = false;
    }

    pub fn resetAll(self: *Self) void {
        @memset(self.fft.fft_mag, 0);
        @memset(self.ema_data, -200.0);
        self.ema_initialized = false;
        @memset(self.peak_hold_data, -200.0);
        self.last_peak_time_ms = 0;
        self.waterfall.clear();
    }

    pub fn processFrame(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) bool {
        const current_time_us = zsdl.getTicks() * 1000;
        if (current_time_us - self.last_fft_time_us < self.fft_frame_interval_us) return false;
        if (!mutex.tryLock()) return false;

        self.last_fft_time_us = current_time_us;
        const copied = rx_buffer.copyNewest(self.iq_scratch[0..self.fft.fft_size]);
        mutex.unlock();

        if (copied != self.fft.fft_size) return false;

        const fft_slice = self.fft_buf[0..self.fft.fft_size];
        for (self.iq_scratch[0..copied], fft_slice) |sample, *out| {
            out.* = sample.toFloat();
        }

        self.fft.calc(fft_slice);

        const alpha: f32 = 1.0 / @as(f32, @floatFromInt(self.avg_count));
        if (alpha < 1.0) {
            if (!self.ema_initialized) {
                @memcpy(self.ema_data[0..self.fft.fft_size], self.fft.fft_mag[0..self.fft.fft_size]);
                self.ema_initialized = true;
            } else {
                for (0..self.fft.fft_size) |i| {
                    self.ema_data[i] = alpha * self.fft.fft_mag[i] + (1.0 - alpha) * self.ema_data[i];
                }
            }
        }

        if (self.peak_hold_enabled) {
            const src = if (alpha < 1.0) self.ema_data[0..self.fft.fft_size] else self.fft.fft_mag[0..self.fft.fft_size];
            const now_ms = zsdl.getTicks();
            if (self.last_peak_time_ms > 0 and self.peak_decay_rate > 0) {
                const dt: f32 = @floatFromInt(now_ms - self.last_peak_time_ms);
                const decay = self.peak_decay_rate * dt / 1000.0;
                for (0..self.fft.fft_size) |i| {
                    self.peak_hold_data[i] -= decay;
                }
            }
            self.last_peak_time_ms = now_ms;
            for (0..self.fft.fft_size) |i| {
                self.peak_hold_data[i] = @max(self.peak_hold_data[i], src[i]);
            }
        }

        const wf_src = if (alpha < 1.0) self.ema_data[0..self.fft.fft_size] else self.fft.fft_mag[0..self.fft.fft_size];
        self.waterfall.pushRow(wf_src);

        return true;
    }

    pub fn displayData(self: *const Self) []const f32 {
        const alpha: f32 = 1.0 / @as(f32, @floatFromInt(self.avg_count));
        if (alpha < 1.0 and self.ema_initialized) {
            return self.ema_data[0..self.fft.fft_size];
        }
        return self.fft.fft_mag[0..self.fft.fft_size];
    }

    pub fn freqData(self: *const Self) []const f32 {
        return self.fft.fft_freqs[0..self.fft.fft_size];
    }

    pub fn fftSize(self: *const Self) u32 {
        return self.fft.fft_size;
    }

    pub fn xRange(self: *const Self) ?[2]f64 {
        if (self.fft.fft_freqs.len > 0) {
            return .{
                @floatCast(self.fft.fft_freqs[0]),
                @floatCast(self.fft.fft_freqs[self.fft.fft_size - 1]),
            };
        }
        return null;
    }

    pub fn renderUi(self: *Self, fps: f32, cf_mhz: f32, fs_hz: f64) !UiResult {
        var result = UiResult{};

        zgui.setNextWindowPos(.{ .x = 360, .y = 10, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 340, .h = 400, .cond = .first_use_ever });

        if (zgui.begin(zgui.formatZ("Analysis ({d:.0} fps)###Analysis", .{fps}), .{})) {
            if (zgui.combo("FFT Size", .{
                .current_item = &self.fft_size_index,
                .items_separated_by_zeros = fft_size_labels,
            })) {
                const new_size = try self.resize(self.fft_size_index, cf_mhz, fs_hz);
                result.resized = true;
                result.new_fft_size = new_size;
            }

            if (zgui.combo("Window", .{
                .current_item = &self.window_index,
                .items_separated_by_zeros = window_labels,
            })) {
                self.fft.setWindow(@enumFromInt(self.window_index));
            }

            if (zgui.sliderInt("Averages", .{ .min = 1, .max = 100, .v = &self.avg_count })) {
                if (self.avg_count <= 1) {
                    self.ema_initialized = false;
                }
            }

            _ = zgui.checkbox("Peak Hold", .{ .v = &self.peak_hold_enabled });
            zgui.sameLine(.{});
            if (zgui.button("Reset Peak", .{})) {
                @memset(self.peak_hold_data, -200.0);
                self.last_peak_time_ms = 0;
            }
            _ = zgui.sliderFloat("Peak Decay (dB/s)", .{ .min = 0, .max = 100, .v = &self.peak_decay_rate });

            zgui.separatorText("Waterfall");
            if (zgui.sliderFloat("dB Min", .{ .min = -160, .max = 0, .v = &self.waterfall.db_min })) {
                self.waterfall.rebuildLut();
                self.waterfall.dirty = true;
            }
            if (zgui.sliderFloat("dB Max", .{ .min = -160, .max = 0, .v = &self.waterfall.db_max })) {
                self.waterfall.rebuildLut();
                self.waterfall.dirty = true;
            }
        }
        zgui.end();

        return result;
    }
};
