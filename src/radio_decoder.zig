const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const DecimatingFir = @import("dsp/decimating_fir.zig").DecimatingFir;
const Nco = @import("dsp/nco.zig").Nco;
const DeEmphasis = @import("dsp/deemphasis.zig").DeEmphasis;
const DcFilter = @import("dsp/dc_filter.zig").DcFilter;
const ps = @import("dsp/pipeline_stats.zig");
const zgui = @import("zgui");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const ModulationType = enum(u8) {
    fm = 0,
    am = 1,

    pub fn intermediateRate(self: ModulationType) f32 {
        return switch (self) {
            .fm => 400_000.0,
            .am => 32_000.0,
        };
    }

    pub fn audioRate(self: ModulationType) f32 {
        return switch (self) {
            .fm => 50_000.0,
            .am => 16_000.0,
        };
    }

    pub fn stage2Decimation(self: ModulationType) usize {
        return switch (self) {
            .fm => 8,
            .am => 2,
        };
    }

    pub fn bandwidthMhz(self: ModulationType) f64 {
        return self.intermediateRate() / 1e6;
    }
};

pub const RadioStageId = enum(u3) {
    nco_mix = 0,
    stage1_decimate = 1,
    demodulate = 2,
    stage2_decimate = 3,
    deemphasis = 4,
    audio_output = 5,
};

pub const radio_stage_labels: [std.enums.values(RadioStageId).len][:0]const u8 = .{
    "NCO Mix",
    "Stage 1 Decimate",
    "Demodulate",
    "Stage 2 Decimate",
    "De-emphasis",
    "Audio Output",
};

pub const DecoderWorker = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    modulation: ModulationType,

    nco: Nco,
    stage1_fir: DecimatingFir([2]f32),
    stage2_fir: DecimatingFir(f32),
    deemphasis: DeEmphasis,
    dc_block: DcFilter(f32),

    prev_sample: [2]f32,

    nco_buf: [][2]f32,
    stage1_buf: [][2]f32,
    discrim_buf: []f32,
    stage2_buf: []f32,
    audio_buf: []f32,

    input_capacity: usize,
    stage1_capacity: usize,
    stage2_capacity: usize,

    volume: f32,
    audio_stream: ?*c.SDL_AudioStream,

    peak_level: std.atomic.Value(u32) = .init(0),

    timing_ema: ps.EmaAccumulator(RadioStageId) = ps.EmaAccumulator(RadioStageId).init(0.1),
    pipeline_stats: ps.PipelineStats(RadioStageId) = .{},

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, freq_offset: f64, tau: f32, modulation: ModulationType) !Self {
        const sr: f32 = @floatCast(sample_rate);
        const intermediate_rate = modulation.intermediateRate();
        const audio_rate = modulation.audioRate();
        const s2_dec = modulation.stage2Decimation();

        const stage1_r = computeStage1Decimation(sr, intermediate_rate);
        const input_cap: usize = 262144;
        const stage1_cap = input_cap / stage1_r + 1;
        const stage2_cap = stage1_cap / s2_dec + 1;

        const stage1_cutoff: f32 = switch (modulation) {
            .fm => intermediate_rate * 0.45,
            .am => 5000.0,
        };

        var stage1_fir = try DecimatingFir([2]f32).init(alloc, computeTapCount(stage1_r), stage1_cutoff, sr, stage1_r);
        errdefer stage1_fir.deinit(alloc);

        var stage2_fir = try DecimatingFir(f32).init(alloc, computeTapCount(s2_dec), audio_rate * 0.45, intermediate_rate, s2_dec);
        errdefer stage2_fir.deinit(alloc);

        const nco_buf = try alloc.alloc([2]f32, input_cap);
        errdefer alloc.free(nco_buf);

        const stage1_buf = try alloc.alloc([2]f32, stage1_cap);
        errdefer alloc.free(stage1_buf);

        const discrim_buf = try alloc.alloc(f32, stage1_cap);
        errdefer alloc.free(discrim_buf);

        const stage2_buf = try alloc.alloc(f32, stage2_cap);
        errdefer alloc.free(stage2_buf);

        const audio_buf = try alloc.alloc(f32, stage2_cap);
        errdefer alloc.free(audio_buf);

        return .{
            .alloc = alloc,
            .modulation = modulation,
            .nco = Nco.init(freq_offset, sample_rate),
            .stage1_fir = stage1_fir,
            .stage2_fir = stage2_fir,
            .deemphasis = DeEmphasis.init(audio_rate, tau),
            .dc_block = DcFilter(f32).init(0.995),
            .prev_sample = .{ 0.0, 0.0 },
            .nco_buf = nco_buf,
            .stage1_buf = stage1_buf,
            .discrim_buf = discrim_buf,
            .stage2_buf = stage2_buf,
            .audio_buf = audio_buf,
            .input_capacity = input_cap,
            .stage1_capacity = stage1_cap,
            .stage2_capacity = stage2_cap,
            .volume = 0.5,
            .audio_stream = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.nco_buf);
        self.alloc.free(self.stage1_buf);
        self.alloc.free(self.discrim_buf);
        self.alloc.free(self.stage2_buf);
        self.alloc.free(self.audio_buf);
        self.stage1_fir.deinit(self.alloc);
        self.stage2_fir.deinit(self.alloc);
    }

    pub fn work(self: *Self, input: []const hackrf.IQSample) void {
        if (input.len == 0) return;

        const len = @min(input.len, self.input_capacity);

        const t0: u64 = @intCast(std.time.nanoTimestamp());
        for (input[0..len], self.nco_buf[0..len]) |sample, *out| {
            out.* = sample.toFloat();
        }
        _ = self.nco.process(self.nco_buf[0..len], self.nco_buf[0..len]);
        const t1: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.nco_mix, t1 - t0);

        const s1_count = self.stage1_fir.process(self.nco_buf[0..len], self.stage1_buf);
        if (s1_count == 0) return;
        const t2: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.stage1_decimate, t2 - t1);

        switch (self.modulation) {
            .fm => self.discriminate(self.stage1_buf[0..s1_count], self.discrim_buf[0..s1_count]),
            .am => {
                self.envelopeDetect(self.stage1_buf[0..s1_count], self.discrim_buf[0..s1_count]);
                _ = self.dc_block.process(self.discrim_buf[0..s1_count], self.discrim_buf[0..s1_count]);
            },
        }
        const t3: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.demodulate, t3 - t2);

        const s2_count = self.stage2_fir.process(self.discrim_buf[0..s1_count], self.stage2_buf);
        if (s2_count == 0) return;
        const t4: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.stage2_decimate, t4 - t3);

        switch (self.modulation) {
            .fm => _ = self.deemphasis.process(self.stage2_buf[0..s2_count], self.audio_buf[0..s2_count]),
            .am => @memcpy(self.audio_buf[0..s2_count], self.stage2_buf[0..s2_count]),
        }
        const t5: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.deemphasis, t5 - t4);

        var peak: f32 = 0.0;
        for (self.audio_buf[0..s2_count]) |*s| {
            s.* *= self.volume;
            peak = @max(peak, @abs(s.*));
        }
        self.peak_level.store(@bitCast(peak), .release);

        if (self.audio_stream) |stream| {
            _ = c.SDL_PutAudioStreamData(
                stream,
                self.audio_buf[0..s2_count].ptr,
                @intCast(s2_count * @sizeOf(f32)),
            );
        }
        const t6: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.audio_output, t6 - t5);

        self.timing_ema.updateTotal(t6 - t0);
        self.timing_ema.finalize();
        self.timing_ema.publish(&self.pipeline_stats);
    }

    fn discriminate(self: *Self, input: []const [2]f32, output: []f32) void {
        for (input, output) |sample, *out| {
            const conj_prev = [2]f32{ self.prev_sample[0], -self.prev_sample[1] };
            const prod_i = sample[0] * conj_prev[0] - sample[1] * conj_prev[1];
            const prod_q = sample[0] * conj_prev[1] + sample[1] * conj_prev[0];
            out.* = std.math.atan2(prod_q, prod_i);
            self.prev_sample = sample;
        }
    }

    fn envelopeDetect(_: *Self, input: []const [2]f32, output: []f32) void {
        for (input, output) |sample, *out| {
            out.* = @sqrt(sample[0] * sample[0] + sample[1] * sample[1]);
        }
    }

    pub fn reconfigure(self: *Self, sample_rate: f64, tau: f32, modulation: ModulationType) !void {
        const sr: f32 = @floatCast(sample_rate);
        const intermediate_rate = modulation.intermediateRate();
        const audio_rate = modulation.audioRate();
        const s2_dec = modulation.stage2Decimation();
        const stage1_r = computeStage1Decimation(sr, intermediate_rate);

        const new_stage1_cap = self.input_capacity / stage1_r + 1;
        const new_stage2_cap = new_stage1_cap / s2_dec + 1;

        const stage1_cutoff: f32 = switch (modulation) {
            .fm => intermediate_rate * 0.45,
            .am => 5000.0,
        };

        self.stage1_fir.deinit(self.alloc);
        self.stage1_fir = try DecimatingFir([2]f32).init(self.alloc, computeTapCount(stage1_r), stage1_cutoff, sr, stage1_r);

        self.stage2_fir.deinit(self.alloc);
        self.stage2_fir = try DecimatingFir(f32).init(self.alloc, computeTapCount(s2_dec), audio_rate * 0.45, intermediate_rate, s2_dec);

        if (new_stage1_cap > self.stage1_capacity) {
            self.alloc.free(self.stage1_buf);
            self.stage1_buf = try self.alloc.alloc([2]f32, new_stage1_cap);
            self.alloc.free(self.discrim_buf);
            self.discrim_buf = try self.alloc.alloc(f32, new_stage1_cap);
        }
        self.stage1_capacity = new_stage1_cap;

        if (new_stage2_cap > self.stage2_capacity) {
            self.alloc.free(self.stage2_buf);
            self.stage2_buf = try self.alloc.alloc(f32, new_stage2_cap);
            self.alloc.free(self.audio_buf);
            self.audio_buf = try self.alloc.alloc(f32, new_stage2_cap);
        }
        self.stage2_capacity = new_stage2_cap;

        self.modulation = modulation;
        self.deemphasis = DeEmphasis.init(audio_rate, tau);
        self.prev_sample = .{ 0.0, 0.0 };
        self.dc_block.reset();
    }

    pub fn reset(self: *Self) void {
        self.nco.reset();
        self.stage1_fir.reset();
        self.stage2_fir.reset();
        self.deemphasis.reset();
        self.dc_block.reset();
        self.prev_sample = .{ 0.0, 0.0 };
    }

    fn computeStage1Decimation(sample_rate: f32, intermediate_rate: f32) usize {
        const r = @as(usize, @intFromFloat(sample_rate / intermediate_rate));
        return @max(r, 1);
    }

    fn computeTapCount(decimation: usize) usize {
        return @max(decimation * 4 + 1, 15);
    }
};

pub const RadioDecoder = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    worker: DecoderWorker,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    enabled: std.atomic.Value(bool) = .init(false),
    freq_mhz: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 98.1))),
    volume: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.5))),
    tau: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 75e-6))),
    modulation: std.atomic.Value(u8) = .init(0),

    reconfigure_flag: std.atomic.Value(bool) = .init(false),

    thread_stats: ps.ThreadStats = .{},
    measured_dsp_rate: std.atomic.Value(u32) = .init(0),

    sample_rate: f64,
    center_freq_mhz: f32,

    read_cursor: usize = 0,
    input_buf: []hackrf.IQSample,

    audio_stream: ?*c.SDL_AudioStream = null,

    ui_enabled: bool = false,
    ui_volume: f32 = 0.5,
    ui_deemphasis_index: i32 = 0,
    ui_modulation_index: i32 = 0,
    ui_freq_mhz: f64 = 98.1,
    ui_freq_text: [16]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, center_freq_mhz: f32) !Self {
        const cf: f64 = @floatCast(center_freq_mhz);
        const half_bw = sample_rate / 2e6;
        const default_freq: f64 = std.math.clamp(98.1, cf - half_bw, cf + half_bw);
        const offset = (default_freq - cf) * 1e6;

        var worker = try DecoderWorker.init(alloc, sample_rate, offset, 75e-6, .fm);
        errdefer worker.deinit();

        const buf_size: usize = 262144;
        const input_buf = try alloc.alloc(hackrf.IQSample, buf_size);
        errdefer alloc.free(input_buf);

        var self = Self{
            .alloc = alloc,
            .worker = worker,
            .sample_rate = sample_rate,
            .center_freq_mhz = center_freq_mhz,
            .input_buf = input_buf,
        };

        _ = std.fmt.bufPrint(&self.ui_freq_text, "{d:.3}\x00", .{default_freq}) catch {};

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.destroyAudioStream();
        self.worker.deinit();
        self.alloc.free(self.input_buf);
    }

    pub fn start(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) !void {
        if (self.running.load(.acquire)) return;
        self.createAudioStream();
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{ self, mutex, rx_buffer });
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn updateFreqs(self: *Self, center_freq_mhz: f32, sample_rate: f64) void {
        self.center_freq_mhz = center_freq_mhz;
        self.sample_rate = sample_rate;
        self.clampFreq();
        self.reconfigure_flag.store(true, .release);
    }

    fn clampFreq(self: *Self) void {
        const half_bw = self.sample_rate / 2e6;
        const cf: f64 = @floatCast(self.center_freq_mhz);
        const lo = cf - half_bw;
        const hi = cf + half_bw;
        const freq = self.ui_freq_mhz;
        if (freq < lo or freq > hi) {
            const clamped = std.math.clamp(freq, lo, hi);
            self.setFreqMhz(clamped);
        }
    }

    fn currentModulation(self: *Self) ModulationType {
        return @enumFromInt(self.modulation.load(.acquire));
    }

    fn createAudioStream(self: *Self) void {
        if (self.audio_stream != null) return;

        const mod = self.currentModulation();
        var spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = @intFromFloat(mod.audioRate()),
        };

        self.audio_stream = c.SDL_OpenAudioDeviceStream(
            c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &spec,
            null,
            null,
        );

        if (self.audio_stream) |stream| {
            self.worker.audio_stream = stream;
            const vol: f32 = @bitCast(self.volume.load(.acquire));
            _ = c.SDL_SetAudioStreamGain(stream, vol);
        }
    }

    fn destroyAudioStream(self: *Self) void {
        if (self.audio_stream) |stream| {
            c.SDL_DestroyAudioStream(stream);
            self.audio_stream = null;
            self.worker.audio_stream = null;
        }
    }

    fn runLoop(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) void {
        var busy_ema: f64 = 0.0;
        var busy_initialized = false;
        const busy_alpha = 0.05;
        var frame_count: u32 = 0;
        var last_rate_ns: i128 = std.time.nanoTimestamp();

        while (self.running.load(.acquire)) {
            if (!self.enabled.load(.acquire)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            const loop_start: u64 = @intCast(std.time.nanoTimestamp());

            const new_mod: ModulationType = @enumFromInt(self.modulation.load(.acquire));
            const mod_changed = new_mod != self.worker.modulation;

            if (self.reconfigure_flag.swap(false, .acquire) or mod_changed) {
                const tau: f32 = @bitCast(self.tau.load(.acquire));
                self.worker.reconfigure(self.sample_rate, tau, new_mod) catch {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                };

                if (mod_changed) {
                    self.destroyAudioStream();
                    self.createAudioStream();
                    if (self.audio_stream) |stream| {
                        _ = c.SDL_ResumeAudioStreamDevice(stream);
                    }
                }

                mutex.lock();
                self.read_cursor = rx_buffer.total_written;
                mutex.unlock();

                if (self.audio_stream) |stream| {
                    _ = c.SDL_ClearAudioStream(stream);
                }
            }

            const freq_mhz: f64 = @bitCast(self.freq_mhz.load(.acquire));
            const offset = (freq_mhz - @as(f64, @floatCast(self.center_freq_mhz))) * 1e6;
            self.worker.nco.setFrequency(offset, self.sample_rate);

            const vol: f32 = @bitCast(self.volume.load(.acquire));
            self.worker.volume = vol;

            mutex.lock();
            const copied = rx_buffer.copySequential(&self.read_cursor, self.input_buf);
            mutex.unlock();

            if (copied < 1024) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

            const work_start: u64 = @intCast(std.time.nanoTimestamp());
            self.worker.work(self.input_buf[0..copied]);
            const work_end: u64 = @intCast(std.time.nanoTimestamp());

            _ = self.thread_stats.iteration_count.fetchAdd(1, .monotonic);
            frame_count += 1;

            const now_ns = std.time.nanoTimestamp();
            const rate_elapsed = now_ns - last_rate_ns;
            if (rate_elapsed >= 500_000_000) {
                const elapsed_s: f64 = @as(f64, @floatFromInt(rate_elapsed)) / 1_000_000_000.0;
                const rate: f32 = @floatCast(@as(f64, @floatFromInt(frame_count)) / elapsed_s);
                self.measured_dsp_rate.store(@bitCast(rate), .release);
                frame_count = 0;
                last_rate_ns = now_ns;
            }

            const loop_end: u64 = @intCast(std.time.nanoTimestamp());
            const work_dur = work_end - work_start;
            const loop_dur = loop_end - loop_start;
            if (loop_dur > 0) {
                const ratio = @as(f64, @floatFromInt(work_dur)) / @as(f64, @floatFromInt(loop_dur));
                if (!busy_initialized) {
                    busy_ema = ratio;
                    busy_initialized = true;
                } else {
                    busy_ema = busy_alpha * ratio + (1.0 - busy_alpha) * busy_ema;
                }
                self.thread_stats.busy_pct.store(@intFromFloat(busy_ema * 10000.0), .release);
            }
        }
    }

    pub fn setFreqMhz(self: *Self, freq_mhz: f64) void {
        const half_bw = self.sample_rate / 2e6;
        const cf: f64 = @floatCast(self.center_freq_mhz);
        const clamped = std.math.clamp(freq_mhz, cf - half_bw, cf + half_bw);
        self.freq_mhz.store(@bitCast(clamped), .release);
        self.ui_freq_mhz = clamped;
        _ = std.fmt.bufPrint(&self.ui_freq_text, "{d:.3}\x00", .{clamped}) catch {};
    }

    pub fn pipelineView(self: *const Self) ps.PipelineView {
        return self.worker.pipeline_stats.view(&radio_stage_labels);
    }

    pub fn threadStats(self: *const Self) *const ps.ThreadStats {
        return &self.thread_stats;
    }

    pub fn dspRate(self: *const Self) ?f32 {
        const raw = self.measured_dsp_rate.load(.acquire);
        if (raw == 0) return null;
        return @bitCast(raw);
    }

    pub fn renderUi(self: *Self) void {
        if (!zgui.begin("Radio###Radio Decoder", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        var toggled = self.ui_enabled;
        if (zgui.checkbox("Enable Decoder", .{ .v = &toggled })) {
            self.ui_enabled = toggled;
            self.enabled.store(toggled, .release);
            if (toggled) {
                if (self.audio_stream) |stream| {
                    _ = c.SDL_ResumeAudioStreamDevice(stream);
                }
            } else {
                if (self.audio_stream) |stream| {
                    _ = c.SDL_PauseAudioStreamDevice(stream);
                }
            }
        }

        zgui.separatorText("Modulation");

        const mod_labels: [:0]const u8 = "FM\x00AM\x00";
        if (zgui.combo("Mode", .{
            .current_item = &self.ui_modulation_index,
            .items_separated_by_zeros = mod_labels,
        })) {
            self.modulation.store(@intCast(self.ui_modulation_index), .release);
        }

        zgui.separatorText("Tuning");

        zgui.text("Frequency: {d:.3} MHz", .{self.ui_freq_mhz});

        zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Drag the line on the FFT plot to tune", .{});

        zgui.separatorText("Audio");

        if (zgui.sliderFloat("Volume", .{ .v = &self.ui_volume, .min = 0.0, .max = 1.0 })) {
            self.volume.store(@bitCast(self.ui_volume), .release);
            if (self.audio_stream) |stream| {
                _ = c.SDL_SetAudioStreamGain(stream, self.ui_volume);
            }
        }

        if (self.ui_modulation_index == 0) {
            const tau_values = [_]f32{ 75e-6, 50e-6 };
            const tau_labels: [:0]const u8 = "75 us (US/KR)\x0050 us (EU/AU)\x00";

            if (zgui.combo("De-emphasis", .{
                .current_item = &self.ui_deemphasis_index,
                .items_separated_by_zeros = tau_labels,
            })) {
                const new_tau = tau_values[@intCast(self.ui_deemphasis_index)];
                self.tau.store(@bitCast(new_tau), .release);
                self.reconfigure_flag.store(true, .release);
            }
        }

        zgui.separatorText("Status");

        if (self.ui_enabled) {
            const mod: ModulationType = @enumFromInt(@as(u8, @intCast(self.ui_modulation_index)));
            const label = switch (mod) {
                .fm => "Decoding FM",
                .am => "Decoding AM",
            };
            zgui.textColored(.{ 0.2, 1.0, 0.2, 1.0 }, "{s}", .{label});
        } else {
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Stopped", .{});
        }

        const peak_raw = self.worker.peak_level.load(.acquire);
        const peak: f32 = @bitCast(peak_raw);
        const bar_frac = @min(peak * 2.0, 1.0);

        zgui.text("Audio Level:", .{});
        zgui.sameLine(.{});
        zgui.progressBar(.{ .fraction = bar_frac, .overlay = "", .w = -1.0 });
    }
};
