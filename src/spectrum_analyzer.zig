const std = @import("std");
const hackrf = @import("rf_fun");
const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const WindowType = @import("simple_fft.zig").WindowType;
const window_labels = @import("simple_fft.zig").window_labels;
const Waterfall = @import("waterfall.zig").Waterfall;
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const DspThread = @import("dsp/dsp_thread.zig").DspThread;
const DcFilter = @import("dsp/dc_filter.zig").DcFilter;
const DoubleBuffer = @import("dsp/double_buffer.zig").DoubleBuffer;
const ps = @import("dsp/pipeline_stats.zig");
const PipelineStats = ps.PipelineStats;
const EmaAccumulator = ps.EmaAccumulator;
const StageId = ps.StageId;
const ThreadStats = ps.ThreadStats;
const SignalStats = @import("signal_stats.zig").SignalStats;
const PeakInfo = @import("signal_stats.zig").PeakInfo;
const MAX_PEAKS = @import("signal_stats.zig").MAX_PEAKS;
const zgui = @import("zgui");

pub const fft_size_values = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096, 8192 };
pub const fft_size_labels: [:0]const u8 = "64\x00128\x00256\x00512\x001024\x002048\x004096\x008192\x00";

pub const UiResult = struct {
    resized: bool = false,
    new_fft_size: u32 = 0,
};

pub const SpectrumFrame = struct {
    display_data: []const f32,
    peak_hold: []const f32,
    fft_mag_row: []const f32,
    fft_size: u32,
};

pub const SpectrumWorker = struct {
    const Self = @This();

    pub const Input = hackrf.IQSample;

    alloc: std.mem.Allocator,

    fft: SimpleFFT,
    fft_buf: [][2]f32,

    avg_count: std.atomic.Value(i32),
    ema_data: []f32,
    ema_initialized: bool,

    peak_hold_enabled: std.atomic.Value(u8),
    peak_hold_data: []f32,
    peak_decay_rate: std.atomic.Value(u32),
    last_work_time_ns: i128,

    dc_filter_enabled: std.atomic.Value(u8),
    dc_filter: DcFilter,
    dc_buf: [][2]f32,

    output: DoubleBuffer(SpectrumFrame),
    frame_display: []f32,
    frame_peak: []f32,
    frame_mag: []f32,

    center_freq_hz: std.atomic.Value(u32),
    sample_rate_hz: std.atomic.Value(u32),
    window_type: std.atomic.Value(i32),
    freq_dirty: std.atomic.Value(u8),
    window_dirty: std.atomic.Value(u8),
    reset_requested: std.atomic.Value(u8),

    timing_ema: EmaAccumulator = EmaAccumulator.init(0.1),
    pipeline_stats: PipelineStats = .{},

    pub fn init(alloc: std.mem.Allocator, fft_size: u32, cf_hz: f32, fs_hz: f32, window: WindowType) !Self {
        var fft = try SimpleFFT.init(alloc, fft_size, cf_hz, fs_hz, window);
        errdefer fft.deinit(alloc);

        const fft_buf = try alloc.alloc([2]f32, fft_size);
        errdefer alloc.free(fft_buf);

        const ema_data = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(ema_data);
        @memset(ema_data, -200.0);

        const peak_hold_data = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(peak_hold_data);
        @memset(peak_hold_data, -200.0);

        const dc_buf = try alloc.alloc([2]f32, fft_size);
        errdefer alloc.free(dc_buf);

        var output = try DoubleBuffer(SpectrumFrame).init(alloc, 2);
        errdefer output.deinit(alloc);

        const frame_display = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(frame_display);
        const frame_peak = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(frame_peak);
        const frame_mag = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(frame_mag);

        return Self{
            .alloc = alloc,
            .fft = fft,
            .fft_buf = fft_buf,
            .avg_count = .init(2),
            .ema_data = ema_data,
            .ema_initialized = false,
            .peak_hold_enabled = .init(0),
            .peak_hold_data = peak_hold_data,
            .peak_decay_rate = .init(@bitCast(@as(f32, 1.6))),
            .last_work_time_ns = std.time.nanoTimestamp(),
            .dc_filter_enabled = .init(0),
            .dc_filter = DcFilter.init(0.995),
            .dc_buf = dc_buf,
            .output = output,
            .frame_display = frame_display,
            .frame_peak = frame_peak,
            .frame_mag = frame_mag,
            .center_freq_hz = .init(@bitCast(cf_hz)),
            .sample_rate_hz = .init(@bitCast(fs_hz)),
            .window_type = .init(@intFromEnum(window)),
            .freq_dirty = .init(0),
            .window_dirty = .init(0),
            .reset_requested = .init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.fft.deinit(self.alloc);
        self.alloc.free(self.fft_buf);
        self.alloc.free(self.ema_data);
        self.alloc.free(self.peak_hold_data);
        self.alloc.free(self.dc_buf);
        self.output.deinit(self.alloc);
        self.alloc.free(self.frame_display);
        self.alloc.free(self.frame_peak);
        self.alloc.free(self.frame_mag);
    }

    pub fn work(self: *Self, input: []const hackrf.IQSample) void {
        if (self.reset_requested.swap(0, .acquire) != 0) {
            @memset(self.ema_data[0..self.fft.fft_size], -200.0);
            self.ema_initialized = false;
            @memset(self.peak_hold_data[0..self.fft.fft_size], -200.0);
            self.last_work_time_ns = std.time.nanoTimestamp();
            self.dc_filter.reset();
            self.timing_ema = EmaAccumulator.init(0.1);
        }

        if (self.freq_dirty.swap(0, .acquire) != 0) {
            const cf: f32 = @bitCast(self.center_freq_hz.load(.acquire));
            const fs: f32 = @bitCast(self.sample_rate_hz.load(.acquire));
            self.fft.updateFreqs(cf, fs);
        }

        if (self.window_dirty.swap(0, .acquire) != 0) {
            const wt: WindowType = @enumFromInt(self.window_type.load(.acquire));
            self.fft.setWindow(wt);
        }

        const fft_size = self.fft.fft_size;
        const samples_needed = @min(input.len, fft_size);
        const fft_slice = self.fft_buf[0..fft_size];

        for (input[0..samples_needed], fft_slice[0..samples_needed]) |sample, *out| {
            out.* = sample.toFloat();
        }

        // Stage 1: DC Filter
        const t0: u64 = @intCast(std.time.nanoTimestamp());
        if (self.dc_filter_enabled.load(.acquire) != 0) {
            _ = self.dc_filter.process(fft_slice[0..samples_needed], self.dc_buf[0..samples_needed]);
            @memcpy(fft_slice[0..samples_needed], self.dc_buf[0..samples_needed]);
        }
        const t1: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.dc_filter, t1 - t0);

        // Stage 2: FFT Compute
        self.fft.calc(fft_slice);
        const t2: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.fft_compute, t2 - t1);

        // Stage 3: EMA Averaging
        const avg_count = self.avg_count.load(.acquire);
        const alpha: f32 = 1.0 / @as(f32, @floatFromInt(avg_count));
        if (alpha < 1.0) {
            if (!self.ema_initialized) {
                @memcpy(self.ema_data[0..fft_size], self.fft.fft_mag[0..fft_size]);
                self.ema_initialized = true;
            } else {
                for (0..fft_size) |i| {
                    self.ema_data[i] = alpha * self.fft.fft_mag[i] + (1.0 - alpha) * self.ema_data[i];
                }
            }
        }
        const t3: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.ema_avg, t3 - t2);

        // Stage 4: Peak Hold
        const peak_enabled = self.peak_hold_enabled.load(.acquire) != 0;
        if (peak_enabled) {
            const src = if (alpha < 1.0) self.ema_data[0..fft_size] else self.fft.fft_mag[0..fft_size];
            const now_ns = std.time.nanoTimestamp();
            const decay_rate: f32 = @bitCast(self.peak_decay_rate.load(.acquire));

            if (decay_rate > 0) {
                const dt_ns = now_ns - self.last_work_time_ns;
                const dt_s: f32 = @floatFromInt(@divFloor(dt_ns, 1_000_000));
                const decay = decay_rate * dt_s / 1000.0;
                for (0..fft_size) |i| {
                    self.peak_hold_data[i] -= decay;
                }
            }
            self.last_work_time_ns = now_ns;

            for (0..fft_size) |i| {
                self.peak_hold_data[i] = @max(self.peak_hold_data[i], src[i]);
            }
        } else {
            self.last_work_time_ns = std.time.nanoTimestamp();
        }
        const t4: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.peak_hold, t4 - t3);

        // Stage 5: Output
        const display_src = if (alpha < 1.0 and self.ema_initialized) self.ema_data[0..fft_size] else self.fft.fft_mag[0..fft_size];
        @memcpy(self.frame_display[0..fft_size], display_src);
        @memcpy(self.frame_peak[0..fft_size], self.peak_hold_data[0..fft_size]);
        @memcpy(self.frame_mag[0..fft_size], display_src);

        const out_slice = self.output.writeSlice();
        out_slice[0] = SpectrumFrame{
            .display_data = self.frame_display[0..fft_size],
            .peak_hold = self.frame_peak[0..fft_size],
            .fft_mag_row = self.frame_mag[0..fft_size],
            .fft_size = fft_size,
        };
        self.output.publish(1);
        const t5: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.output, t5 - t4);

        self.timing_ema.updateTotal(t5 - t0);
        self.timing_ema.finalize();
        self.timing_ema.publish(&self.pipeline_stats);
    }

    pub fn reset(self: *Self) void {
        self.reset_requested.store(1, .release);
    }
};

pub const SpectrumAnalyzer = struct {
    const Self = @This();

    alloc: std.mem.Allocator,

    dsp_thread: DspThread(SpectrumWorker),

    fft_size_index: i32,
    window_index: i32,
    avg_count: i32,

    peak_hold_enabled: bool,
    peak_decay_rate: f32,
    dc_filter_enabled: bool,
    dsp_rate: i32,

    dsp_frame_count: u32,
    last_rate_time_ns: i128,
    measured_dsp_rate: ?f32,

    cached_display: []f32,
    cached_peak: []f32,
    has_frame: bool,

    refit_x: bool,

    waterfall: Waterfall,
    wf_history_len: u32,

    fft_freqs: []f32,

    stats: SignalStats,
    stats_scratch: []f32,

    pub fn init(
        alloc: std.mem.Allocator,
        fft_size_index: i32,
        window_index: i32,
        cf_mhz: f32,
        fs_hz: f64,
        wf_history: u32,
    ) !Self {
        const fft_size = fft_size_values[@intCast(fft_size_index)];
        const cf_hz = cf_mhz * 1e6;
        const fs: f32 = @floatCast(fs_hz);

        var worker = try SpectrumWorker.init(alloc, fft_size, cf_hz, fs, @enumFromInt(window_index));
        errdefer worker.deinit();

        var dsp_thread = try DspThread(SpectrumWorker).init(alloc, fft_size, worker);
        errdefer dsp_thread.deinit();

        var waterfall = try Waterfall.init(alloc, fft_size, wf_history);
        errdefer waterfall.deinit(alloc);

        const cached_display = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(cached_display);
        @memset(cached_display, -200.0);

        const cached_peak = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(cached_peak);
        @memset(cached_peak, -200.0);

        const fft_freqs = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(fft_freqs);
        computeFreqs(fft_freqs, fft_size, cf_mhz, fs_hz);

        const stats_scratch = try alloc.alloc(f32, fft_size);
        errdefer alloc.free(stats_scratch);

        dsp_thread.setTargetRate(30);

        return Self{
            .alloc = alloc,
            .dsp_thread = dsp_thread,
            .fft_size_index = fft_size_index,
            .window_index = window_index,
            .avg_count = 2,
            .peak_hold_enabled = false,
            .peak_decay_rate = 1.6,
            .dc_filter_enabled = false,
            .dsp_rate = 30,
            .dsp_frame_count = 0,
            .last_rate_time_ns = std.time.nanoTimestamp(),
            .measured_dsp_rate = null,
            .cached_display = cached_display,
            .cached_peak = cached_peak,
            .has_frame = false,
            .refit_x = true,
            .waterfall = waterfall,
            .wf_history_len = wf_history,
            .fft_freqs = fft_freqs,
            .stats = .{},
            .stats_scratch = stats_scratch,
        };
    }

    pub fn deinit(self: *Self) void {
        self.dsp_thread.stop();
        self.dsp_thread.worker.deinit();
        self.dsp_thread.deinit();
        self.waterfall.deinit(self.alloc);
        self.alloc.free(self.cached_display);
        self.alloc.free(self.cached_peak);
        self.alloc.free(self.fft_freqs);
        self.alloc.free(self.stats_scratch);
    }

    pub fn startThread(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) !void {
        try self.dsp_thread.start(mutex, rx_buffer);
    }

    pub fn stopThread(self: *Self) void {
        self.dsp_thread.stop();
    }

    pub fn pollFrame(self: *Self) bool {
        if (self.dsp_thread.worker.output.read()) |frames| {
            if (frames.len > 0) {
                const frame = frames[0];
                const fft_size = frame.fft_size;
                @memcpy(self.cached_display[0..fft_size], frame.display_data);
                @memcpy(self.cached_peak[0..fft_size], frame.peak_hold);
                self.waterfall.pushRow(frame.fft_mag_row);
                self.has_frame = true;

                self.dsp_frame_count += 1;
                const now_ns = std.time.nanoTimestamp();
                const elapsed_ns = now_ns - self.last_rate_time_ns;
                if (elapsed_ns >= 500_000_000) {
                    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
                    self.measured_dsp_rate = @floatCast(@as(f64, @floatFromInt(self.dsp_frame_count)) / elapsed_s);
                    self.dsp_frame_count = 0;
                    self.last_rate_time_ns = now_ns;
                }

                const min_dist = SignalStats.minDistanceForWindow(self.window_index);
                self.stats = SignalStats.compute(
                    self.cached_display[0..fft_size],
                    self.fft_freqs[0..fft_size],
                    min_dist,
                    self.stats_scratch[0..fft_size],
                );

                return true;
            }
        }
        return false;
    }

    pub fn resize(self: *Self, new_index: i32, cf_mhz: f32, fs_hz: f64) !u32 {
        const was_running = self.dsp_thread.running.load(.acquire);
        _ = was_running;
        self.dsp_thread.stop();

        const new_size = fft_size_values[@intCast(new_index)];
        self.fft_size_index = new_index;

        self.dsp_thread.worker.deinit();
        self.dsp_thread.alloc.free(self.dsp_thread.input_buf);

        const cf_hz = cf_mhz * 1e6;
        const fs: f32 = @floatCast(fs_hz);
        self.dsp_thread.worker = try SpectrumWorker.init(self.alloc, new_size, cf_hz, fs, @enumFromInt(self.window_index));
        self.dsp_thread.input_buf = try self.alloc.alloc(hackrf.IQSample, new_size);
        self.dsp_thread.chunk_size = new_size;

        self.dsp_thread.worker.avg_count.store(self.avg_count, .release);
        self.dsp_thread.worker.peak_hold_enabled.store(@intFromBool(self.peak_hold_enabled), .release);
        self.dsp_thread.worker.peak_decay_rate.store(@bitCast(self.peak_decay_rate), .release);
        self.dsp_thread.worker.dc_filter_enabled.store(@intFromBool(self.dc_filter_enabled), .release);
        self.dsp_thread.setTargetRate(@intCast(self.dsp_rate));

        self.waterfall.deinit(self.alloc);
        self.waterfall = try Waterfall.init(self.alloc, new_size, self.wf_history_len);

        self.cached_display = try self.alloc.realloc(self.cached_display, new_size);
        @memset(self.cached_display, -200.0);

        self.cached_peak = try self.alloc.realloc(self.cached_peak, new_size);
        @memset(self.cached_peak, -200.0);

        self.fft_freqs = try self.alloc.realloc(self.fft_freqs, new_size);
        computeFreqs(self.fft_freqs, new_size, cf_mhz, fs_hz);

        self.stats_scratch = try self.alloc.realloc(self.stats_scratch, new_size);
        self.stats = .{};

        self.has_frame = false;

        return new_size;
    }

    pub fn updateFreqs(self: *Self, cf_mhz: f32, fs_hz: f64) void {
        const cf_hz = cf_mhz * 1e6;
        const fs: f32 = @floatCast(fs_hz);
        self.dsp_thread.worker.center_freq_hz.store(@bitCast(cf_hz), .release);
        self.dsp_thread.worker.sample_rate_hz.store(@bitCast(fs), .release);
        self.dsp_thread.worker.freq_dirty.store(1, .release);

        computeFreqs(self.fft_freqs, fft_size_values[@intCast(self.fft_size_index)], cf_mhz, fs_hz);
        self.refit_x = true;
    }

    pub fn resetSmoothing(self: *Self) void {
        self.dsp_thread.worker.reset_requested.store(1, .release);
    }

    pub fn resetAll(self: *Self) void {
        self.dsp_thread.worker.reset_requested.store(1, .release);
        @memset(self.cached_display, -200.0);
        @memset(self.cached_peak, -200.0);
        self.has_frame = false;
        self.waterfall.clear();
        self.measured_dsp_rate = null;
        self.dsp_frame_count = 0;
        self.last_rate_time_ns = std.time.nanoTimestamp();
    }

    pub fn dspRate(self: *const Self) ?f32 {
        return self.measured_dsp_rate;
    }

    pub fn displayData(self: *const Self) []const f32 {
        return self.cached_display[0..fft_size_values[@intCast(self.fft_size_index)]];
    }

    pub fn freqData(self: *const Self) []const f32 {
        return self.fft_freqs[0..fft_size_values[@intCast(self.fft_size_index)]];
    }

    pub fn fftSize(self: *const Self) u32 {
        return fft_size_values[@intCast(self.fft_size_index)];
    }

    pub fn xRange(self: *const Self) ?[2]f64 {
        const size = fft_size_values[@intCast(self.fft_size_index)];
        if (size > 0) {
            return .{
                @floatCast(self.fft_freqs[0]),
                @floatCast(self.fft_freqs[size - 1]),
            };
        }
        return null;
    }

    pub fn renderUi(self: *Self, fps: f32, cf_mhz: f32, fs_hz: f64) !UiResult {
        var result = UiResult{};

        zgui.setNextWindowPos(.{ .x = 360, .y = 10, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 340, .h = 400, .cond = .first_use_ever });

        const title = if (self.measured_dsp_rate) |rate|
            zgui.formatZ("Analysis ({d:.0} fps | {d:.0} Hz DSP)###Analysis", .{ fps, rate })
        else
            zgui.formatZ("Analysis ({d:.0} fps | -- Hz DSP)###Analysis", .{fps});
        if (zgui.begin(title, .{})) {
            if (zgui.beginTabBar("analysis_tabs", .{})) {
                defer zgui.endTabBar();

                if (zgui.beginTabItem("Controls", .{})) {
                    defer zgui.endTabItem();

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
                        self.dsp_thread.worker.window_type.store(self.window_index, .release);
                        self.dsp_thread.worker.window_dirty.store(1, .release);
                    }

                    if (zgui.sliderInt("Averages", .{ .min = 1, .max = 100, .v = &self.avg_count })) {
                        self.dsp_thread.worker.avg_count.store(self.avg_count, .release);
                        if (self.avg_count <= 1) {
                            self.dsp_thread.worker.reset_requested.store(1, .release);
                        }
                    }

                    if (zgui.checkbox("DC Filter", .{ .v = &self.dc_filter_enabled })) {
                        self.dsp_thread.worker.dc_filter_enabled.store(@intFromBool(self.dc_filter_enabled), .release);
                    }

                    if (zgui.sliderInt("DSP Rate (Hz)", .{ .min = 1, .max = 500, .v = &self.dsp_rate })) {
                        self.dsp_thread.setTargetRate(@intCast(self.dsp_rate));
                    }

                    _ = zgui.checkbox("Peak Hold", .{ .v = &self.peak_hold_enabled });
                    self.dsp_thread.worker.peak_hold_enabled.store(@intFromBool(self.peak_hold_enabled), .release);

                    zgui.sameLine(.{});
                    if (zgui.button("Reset Peak", .{})) {
                        self.dsp_thread.worker.reset_requested.store(1, .release);
                    }
                    if (zgui.sliderFloat("Peak Decay (dB/s)", .{ .min = 0, .max = 100, .v = &self.peak_decay_rate })) {
                        self.dsp_thread.worker.peak_decay_rate.store(@bitCast(self.peak_decay_rate), .release);
                    }

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

                if (zgui.beginTabItem("Signal Info", .{})) {
                    defer zgui.endTabItem();
                    self.renderSignalInfo();
                }

                if (zgui.beginTabItem("Pipeline", .{})) {
                    defer zgui.endTabItem();
                    self.renderPipelineStats();
                }
            }
        }
        zgui.end();

        return result;
    }

    fn renderSignalInfo(self: *const Self) void {
        if (!self.has_frame) {
            zgui.text("No data", .{});
            return;
        }

        const s = self.stats;

        zgui.separatorText("Overview");
        zgui.text("Peak:        {d:.3} MHz  @ {d:.1} dB", .{ s.peak_freq_mhz, s.peak_power_db });
        zgui.text("Noise Floor: {d:.1} dB", .{s.noise_floor_db});
        zgui.text("SFDR:        {d:.1} dB", .{s.sfdr_db});
        zgui.text("SNR:         {d:.1} dB", .{s.snr_db});

        zgui.separatorText("Top Peaks");
        if (s.num_peaks == 0) {
            zgui.text("No peaks detected", .{});
            return;
        }

        if (zgui.beginTable("peaks_table", .{
            .column = 3,
            .flags = .{ .borders = .{ .inner_h = true, .outer_h = true }, .row_bg = true, .sizing = .stretch_prop },
        })) {
            defer zgui.endTable();

            zgui.tableSetupColumn("#", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 24 });
            zgui.tableSetupColumn("Freq (MHz)", .{});
            zgui.tableSetupColumn("Power (dB)", .{});
            zgui.tableHeadersRow();

            for (0..s.num_peaks) |i| {
                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                zgui.text("{d}", .{i + 1});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.3}", .{s.peaks[i].freq_mhz});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.1}", .{s.peaks[i].power_db});
            }
        }
    }

    fn renderPipelineStats(self: *const Self) void {
        if (!self.has_frame) {
            zgui.text("No data", .{});
            return;
        }

        const stats = &self.dsp_thread.worker.pipeline_stats;
        const tstats = &self.dsp_thread.thread_stats;

        zgui.separatorText("Stage Timing");
        if (zgui.beginTable("pipeline_stages", .{
            .column = 2,
            .flags = .{ .borders = .{ .inner_h = true, .outer_h = true }, .row_bg = true, .sizing = .stretch_prop },
        })) {
            defer zgui.endTable();

            zgui.tableSetupColumn("Stage", .{});
            zgui.tableSetupColumn("Time", .{});
            zgui.tableHeadersRow();

            for (0..ps.stage_count) |i| {
                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                zgui.text("{s}", .{ps.stage_labels[i]});
                _ = zgui.tableNextColumn();
                const ns = stats.stage_ns[i].load(.acquire);
                const us: f64 = @as(f64, @floatFromInt(ns)) / 1000.0;
                zgui.text("{d:.1} us", .{us});
            }

            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            zgui.textColored(.{ 1.0, 1.0, 0.4, 1.0 }, "Total", .{});
            _ = zgui.tableNextColumn();
            const total_ns = stats.total_ns.load(.acquire);
            const total_us: f64 = @as(f64, @floatFromInt(total_ns)) / 1000.0;
            zgui.textColored(.{ 1.0, 1.0, 0.4, 1.0 }, "{d:.1} us", .{total_us});
        }

        zgui.separatorText("Thread");
        const busy_raw = tstats.busy_pct.load(.acquire);
        const busy: f64 = @as(f64, @floatFromInt(busy_raw)) / 100.0;
        zgui.text("Utilization: {d:.2}%%", .{busy});

        const iterations = tstats.iteration_count.load(.acquire);
        zgui.text("Iterations:  {d}", .{iterations});

        if (self.measured_dsp_rate) |rate| {
            zgui.text("DSP Rate:    {d:.1} Hz", .{rate});
        } else {
            zgui.text("DSP Rate:    --", .{});
        }
    }

    fn computeFreqs(freqs: []f32, fft_size: u32, cf_mhz: f32, fs_hz: f64) void {
        const sr_mhz: f32 = @floatCast(fs_hz / 1e6);
        const n: f32 = @floatFromInt(fft_size);
        for (0..fft_size) |i| {
            const bin: f32 = @as(f32, @floatFromInt(i)) - n / 2.0;
            freqs[i] = cf_mhz + bin * sr_mhz / n;
        }
    }
};
