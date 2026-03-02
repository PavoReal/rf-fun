const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const DecimatingFir = @import("dsp/decimating_fir.zig").DecimatingFir;
const Nco = @import("dsp/nco.zig").Nco;
const DeEmphasis = @import("dsp/deemphasis.zig").DeEmphasis;
const DcFilter = @import("dsp/dc_filter.zig").DcFilter;
const CtcssDetector = @import("dsp/ctcss_detector.zig").CtcssDetector;
const Biquad = @import("dsp/biquad.zig").Biquad;
const Agc = @import("dsp/agc.zig").Agc;
const Squelch = @import("dsp/squelch.zig").Squelch;
const DelayLine = @import("dsp/delay_line.zig").DelayLine;
const DcsDetector = @import("dsp/dcs_detector.zig").DcsDetector;
const ToneSquelch = @import("dsp/tone_squelch.zig").ToneSquelch;
const Golay23_12 = @import("dsp/golay.zig").Golay23_12;
const Scanner = @import("scanner.zig").Scanner;
const presets = @import("channel_presets.zig");
const demod = @import("demod_profile.zig");
const ps = @import("dsp/pipeline_stats.zig");
const zgui = @import("zgui");
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const ModulationType = enum(u8) {
    fm = 0,
    am = 1,
    nfm = 2,

    pub fn profile(self: ModulationType) demod.DemodProfile {
        return switch (self) {
            .fm => demod.fm_profile,
            .am => demod.am_profile,
            .nfm => demod.nfm_profile,
        };
    }

    pub fn intermediateRate(self: ModulationType) f32 {
        return self.profile().intermediate_rate;
    }

    pub fn audioRate(self: ModulationType) f32 {
        return self.profile().audio_rate;
    }

    pub fn stage2Decimation(self: ModulationType) usize {
        return self.profile().stage2_decimation;
    }

    pub fn bandwidthMhz(self: ModulationType) f64 {
        return self.profile().intermediate_rate / 1e6;
    }

    pub fn defaultTau(self: ModulationType) f32 {
        return self.profile().default_tau;
    }

    pub fn deviationGain(self: ModulationType, nfm_dev: f32) f32 {
        const p = self.profile();
        const max_dev: f32 = if (self == .nfm) nfm_dev else p.max_deviation;
        return p.intermediate_rate / (2.0 * std.math.pi * max_dev);
    }
};

pub const RadioStageId = enum(u4) {
    nco_mix = 0,
    stage1_decimate = 1,
    demodulate = 2,
    stage2_decimate = 3,
    deemphasis = 4,
    ctcss_detect = 5,
    dcs_detect = 6,
    ctcss_hpf = 7,
    noise_squelch = 8,
    tone_squelch = 9,
    audio_output = 10,
};

pub const radio_stage_labels: [std.enums.values(RadioStageId).len][:0]const u8 = .{
    "NCO Mix",
    "Stage 1 Decimate",
    "Demodulate",
    "Stage 2 Decimate",
    "De-emphasis",
    "CTCSS Detect",
    "DCS Detect",
    "CTCSS HPF",
    "Noise Squelch",
    "Tone Squelch",
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
    deviation_gain: f32,

    nco_buf: [][2]f32,
    stage1_buf: [][2]f32,
    discrim_buf: []f32,
    stage2_buf: []f32,
    audio_buf: []f32,

    input_capacity: usize,
    stage1_capacity: usize,
    stage2_capacity: usize,

    agc: ?Agc,
    pilot_notch: ?Biquad,

    ctcss: ?CtcssDetector,
    dcs: ?DcsDetector,
    squelch: Squelch,
    tone_squelch_state: ?ToneSquelch,
    ctcss_hpf: ?Biquad,
    audio_delay: DelayLine,
    delayed_audio_buf: []f32,
    squelch_threshold: f32,

    audio_stream: ?*c.SDL_AudioStream,

    peak_level: std.atomic.Value(u32) = .init(0),
    ctcss_tone_index: std.atomic.Value(i8) = .init(-1),
    ctcss_confirmed_index: std.atomic.Value(i8) = .init(-1),
    dcs_code_atomic: std.atomic.Value(i16) = .init(-1),
    dcs_inverted_atomic: std.atomic.Value(u8) = .init(0),
    squelch_open_atomic: std.atomic.Value(u8) = .init(0),
    tone_squelch_open_atomic: std.atomic.Value(u8) = .init(0),
    signal_level_atomic: std.atomic.Value(u32) = .init(@bitCast(@as(f32, -120.0))),

    squelch_mode_atomic: std.atomic.Value(u8) = .init(0),
    expected_ctcss_idx_atomic: std.atomic.Value(i8) = .init(-1),
    expected_dcs_code_atomic: std.atomic.Value(i16) = .init(-1),
    expected_dcs_inv_atomic: std.atomic.Value(u8) = .init(0),

    audio_underrun_count: std.atomic.Value(u64) = .init(0),

    timing_ema: ps.EmaAccumulator(RadioStageId) = ps.EmaAccumulator(RadioStageId).init(0.1),
    pipeline_stats: ps.PipelineStats(RadioStageId) = .{},

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, freq_offset: f64, tau: f32, modulation: ModulationType, nfm_dev: f32) !Self {
        const sr: f32 = @floatCast(sample_rate);
        const intermediate_rate = modulation.intermediateRate();
        const audio_rate = modulation.audioRate();
        const s2_dec = modulation.stage2Decimation();

        const stage1_r = computeStage1Decimation(sr, intermediate_rate);
        const input_cap: usize = 262144;
        const stage1_cap = input_cap / stage1_r + 1;
        const stage2_cap = stage1_cap / s2_dec + 1;

        const p = modulation.profile();
        const stage1_cutoff: f32 = switch (p.stage1_cutoff_mode) {
            .proportional => intermediate_rate * p.stage1_cutoff_value,
            .fixed => p.stage1_cutoff_value,
            .nfm_adaptive => (nfm_dev + 3000.0) * 1.1,
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

        const delayed_audio_buf = try alloc.alloc(f32, stage2_cap);
        errdefer alloc.free(delayed_audio_buf);

        const delay_samples: usize = @intFromFloat(0.020 * audio_rate);
        var audio_delay = try DelayLine.init(alloc, delay_samples);
        errdefer audio_delay.deinit(alloc);

        return .{
            .alloc = alloc,
            .modulation = modulation,
            .nco = Nco.init(freq_offset, sample_rate),
            .stage1_fir = stage1_fir,
            .stage2_fir = stage2_fir,
            .deemphasis = DeEmphasis.init(audio_rate, tau),
            .dc_block = DcFilter(f32).init(0.995),
            .prev_sample = .{ 0.0, 0.0 },
            .deviation_gain = modulation.deviationGain(nfm_dev),
            .nco_buf = nco_buf,
            .stage1_buf = stage1_buf,
            .discrim_buf = discrim_buf,
            .stage2_buf = stage2_buf,
            .audio_buf = audio_buf,
            .input_capacity = input_cap,
            .stage1_capacity = stage1_cap,
            .stage2_capacity = stage2_cap,
            .agc = if (p.has_agc) Agc.init(0.5, 0.1, 0.01) else null,
            .pilot_notch = if (p.has_pilot_notch) Biquad.initNotch(audio_rate, p.pilot_notch_freq, 10.0) else null,
            .ctcss = if (p.has_tone_detection) CtcssDetector.init(audio_rate) else null,
            .dcs = if (p.has_tone_detection) DcsDetector.init(audio_rate) else null,
            .squelch = Squelch.init(intermediate_rate, audio_rate),
            .tone_squelch_state = if (p.has_tone_detection) ToneSquelch.init(audio_rate) else null,
            .ctcss_hpf = if (p.has_tone_detection) Biquad.initHighPass(audio_rate, 300.0, 0.707) else null,
            .audio_delay = audio_delay,
            .delayed_audio_buf = delayed_audio_buf,
            .squelch_threshold = 0.0,
            .audio_stream = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.nco_buf);
        self.alloc.free(self.stage1_buf);
        self.alloc.free(self.discrim_buf);
        self.alloc.free(self.stage2_buf);
        self.alloc.free(self.audio_buf);
        self.alloc.free(self.delayed_audio_buf);
        self.audio_delay.deinit(self.alloc);
        self.stage1_fir.deinit(self.alloc);
        self.stage2_fir.deinit(self.alloc);
    }

    pub fn workCore(self: *Self, input: []const hackrf.IQSample) usize {
        const len = @min(input.len, self.input_capacity);

        const t0: u64 = @intCast(std.time.nanoTimestamp());
        _ = self.nco.processIQ(input[0..len], self.nco_buf[0..len]);
        const t1: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.nco_mix, t1 - t0);

        const s1_count = self.stage1_fir.process(self.nco_buf[0..len], self.stage1_buf);
        if (s1_count == 0) return 0;
        const t2: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.stage1_decimate, t2 - t1);

        const prof = self.modulation.profile();
        switch (prof.demod_method) {
            .discriminator => {
                self.discriminate(self.stage1_buf[0..s1_count], self.discrim_buf[0..s1_count]);
                for (self.discrim_buf[0..s1_count]) |*s| {
                    s.* *= self.deviation_gain;
                }
            },
            .envelope => {
                self.envelopeDetect(self.stage1_buf[0..s1_count], self.discrim_buf[0..s1_count]);
                if (prof.uses_dc_block) {
                    _ = self.dc_block.process(self.discrim_buf[0..s1_count], self.discrim_buf[0..s1_count]);
                }
            },
        }
        const t3: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.demodulate, t3 - t2);

        const s2_count = self.stage2_fir.process(self.discrim_buf[0..s1_count], self.stage2_buf);
        if (s2_count == 0) return 0;
        const t4: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.stage2_decimate, t4 - t3);

        if (prof.has_deemphasis) {
            _ = self.deemphasis.process(self.stage2_buf[0..s2_count], self.audio_buf[0..s2_count]);
        } else {
            @memcpy(self.audio_buf[0..s2_count], self.stage2_buf[0..s2_count]);
        }

        if (self.agc) |*agc| {
            _ = agc.process(self.audio_buf[0..s2_count], self.audio_buf[0..s2_count]);
        }

        if (self.pilot_notch) |*notch| {
            _ = notch.process(self.audio_buf[0..s2_count], self.audio_buf[0..s2_count]);
        }

        const t5: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.deemphasis, t5 - t4);

        if (self.ctcss) |*ctcss| {
            if (ctcss.process(self.stage2_buf[0..s2_count])) {
                self.ctcss_tone_index.store(ctcss.detected_tone_index, .release);
                self.ctcss_confirmed_index.store(ctcss.confirmed_tone_index, .release);
            }
        }
        const t5b: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.ctcss_detect, t5b - t5);

        if (self.dcs) |*dcs| {
            dcs.process(self.stage2_buf[0..s2_count]);
            if (dcs.detectedCode()) |code| {
                self.dcs_code_atomic.store(@intCast(code), .release);
                self.dcs_inverted_atomic.store(if (dcs.isInverted()) 1 else 0, .release);
            } else {
                self.dcs_code_atomic.store(-1, .release);
            }
        }
        const t5c: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.dcs_detect, t5c - t5b);

        if (self.ctcss_hpf) |*hpf| {
            _ = hpf.process(self.audio_buf[0..s2_count], self.audio_buf[0..s2_count]);
        }
        const t5d: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.ctcss_hpf, t5d - t5c);

        _ = self.audio_delay.process(self.audio_buf[0..s2_count], self.delayed_audio_buf[0..s2_count]);

        self.squelch.setThreshold(self.squelch_threshold);
        self.squelch.updateLevel(self.stage1_buf[0..s1_count]);
        self.squelch.gate(self.delayed_audio_buf[0..s2_count]);
        self.signal_level_atomic.store(@bitCast(self.squelch.levelDb()), .release);
        self.squelch_open_atomic.store(if (self.squelch.isOpen()) 1 else 0, .release);
        const t5e: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.noise_squelch, t5e - t5d);

        if (self.tone_squelch_state) |*tsq| {
            tsq.mode = @enumFromInt(self.squelch_mode_atomic.load(.acquire));
            tsq.expected_ctcss_index = self.expected_ctcss_idx_atomic.load(.acquire);
            tsq.expected_dcs_code = self.expected_dcs_code_atomic.load(.acquire);
            tsq.expected_dcs_inverted = self.expected_dcs_inv_atomic.load(.acquire);

            const confirmed_ctcss = self.ctcss_confirmed_index.load(.acquire);
            const dcs_code = self.dcs_code_atomic.load(.acquire);
            const dcs_inv = self.dcs_inverted_atomic.load(.acquire);

            _ = tsq.evaluate(confirmed_ctcss, dcs_code, dcs_inv);
            tsq.gate(self.delayed_audio_buf[0..s2_count]);
            self.tone_squelch_open_atomic.store(if (tsq.is_open) 1 else 0, .release);
        } else {
            self.tone_squelch_open_atomic.store(1, .release);
        }
        const t5f: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.tone_squelch, t5f - t5e);

        var peak: f32 = 0.0;
        for (self.delayed_audio_buf[0..s2_count]) |s| {
            peak = @max(peak, @abs(s));
        }
        self.peak_level.store(@bitCast(peak), .release);

        return s2_count;
    }

    pub fn work(self: *Self, input: []const hackrf.IQSample) void {
        if (input.len == 0) return;

        const t_start: u64 = @intCast(std.time.nanoTimestamp());
        const s2_count = self.workCore(input);
        if (s2_count == 0) return;

        const t_audio_start: u64 = @intCast(std.time.nanoTimestamp());
        if (self.audio_stream) |stream| {
            const queued_before = c.SDL_GetAudioStreamQueued(stream);
            if (queued_before == 0 and s2_count > 0) {
                _ = self.audio_underrun_count.fetchAdd(1, .monotonic);
            }
            _ = c.SDL_PutAudioStreamData(
                stream,
                self.delayed_audio_buf[0..s2_count].ptr,
                @intCast(s2_count * @sizeOf(f32)),
            );
        }
        const t_end: u64 = @intCast(std.time.nanoTimestamp());
        self.timing_ema.update(.audio_output, t_end - t_audio_start);

        self.timing_ema.updateTotal(t_end - t_start);
        self.timing_ema.finalize();
        self.timing_ema.publish(&self.pipeline_stats);
    }

    fn fastAtan2(y: f32, x: f32) f32 {
        const abs_x = @abs(x);
        const abs_y = @abs(y);
        const max_val = @max(abs_x, abs_y);
        const min_val = @min(abs_x, abs_y);
        const z = min_val / (max_val + 1e-10);
        const z2 = z * z;
        var result = (0.97239411 + (-0.19194795) * z2) * z;
        if (abs_y > abs_x) result = std.math.pi / 2.0 - result;
        if (x < 0.0) result = std.math.pi - result;
        if (y < 0.0) result = -result;
        return result;
    }

    fn fastAtan2Simd(y: @Vector(8, f32), x: @Vector(8, f32)) @Vector(8, f32) {
        const abs_x = @abs(x);
        const abs_y = @abs(y);
        const max_val = @max(abs_x, abs_y);
        const min_val = @min(abs_x, abs_y);
        const epsilon: @Vector(8, f32) = @splat(1e-10);
        const z = min_val / (max_val + epsilon);
        const z2 = z * z;
        const c1: @Vector(8, f32) = @splat(0.97239411);
        const c2: @Vector(8, f32) = @splat(-0.19194795);
        const half_pi: @Vector(8, f32) = @splat(std.math.pi / 2.0);
        const pi: @Vector(8, f32) = @splat(std.math.pi);
        const zero: @Vector(8, f32) = @splat(0.0);
        var result = (c1 + c2 * z2) * z;
        const swap_mask = abs_y > abs_x;
        result = @select(f32, swap_mask, half_pi - result, result);
        const x_neg = x < zero;
        result = @select(f32, x_neg, pi - result, result);
        const y_neg = y < zero;
        result = @select(f32, y_neg, -result, result);
        return result;
    }

    fn discriminate(self: *Self, input: []const [2]f32, output: []f32) void {
        if (input.len == 0) return;

        {
            const sample = input[0];
            const prod_i = sample[0] * self.prev_sample[0] + sample[1] * self.prev_sample[1];
            const prod_q = sample[1] * self.prev_sample[0] - sample[0] * self.prev_sample[1];
            output[0] = fastAtan2(prod_q, prod_i);
        }

        const vec_len = 8;
        var i: usize = 1;
        const simd_end = if (input.len > vec_len) input.len - (input.len - 1) % vec_len else 1;

        while (i < simd_end) : (i += vec_len) {
            var cur_i_arr: [vec_len]f32 = undefined;
            var cur_q_arr: [vec_len]f32 = undefined;
            var prev_i_arr: [vec_len]f32 = undefined;
            var prev_q_arr: [vec_len]f32 = undefined;

            for (0..vec_len) |j| {
                cur_i_arr[j] = input[i + j][0];
                cur_q_arr[j] = input[i + j][1];
                prev_i_arr[j] = input[i + j - 1][0];
                prev_q_arr[j] = input[i + j - 1][1];
            }

            const cur_i: @Vector(vec_len, f32) = cur_i_arr;
            const cur_q: @Vector(vec_len, f32) = cur_q_arr;
            const prev_i: @Vector(vec_len, f32) = prev_i_arr;
            const prev_q: @Vector(vec_len, f32) = prev_q_arr;

            const prod_i = cur_i * prev_i + cur_q * prev_q;
            const prod_q = cur_q * prev_i - cur_i * prev_q;

            const result = fastAtan2Simd(prod_q, prod_i);
            const result_arr: [vec_len]f32 = result;

            for (0..vec_len) |j| {
                output[i + j] = result_arr[j];
            }
        }

        while (i < input.len) : (i += 1) {
            const sample = input[i];
            const prev = input[i - 1];
            const prod_i = sample[0] * prev[0] + sample[1] * prev[1];
            const prod_q = sample[1] * prev[0] - sample[0] * prev[1];
            output[i] = fastAtan2(prod_q, prod_i);
        }

        self.prev_sample = input[input.len - 1];
    }

    fn envelopeDetect(_: *Self, input: []const [2]f32, output: []f32) void {
        for (input, output) |sample, *out| {
            out.* = @sqrt(sample[0] * sample[0] + sample[1] * sample[1]);
        }
    }

    pub fn reconfigure(self: *Self, sample_rate: f64, tau: f32, modulation: ModulationType, nfm_dev: f32) !void {
        const sr: f32 = @floatCast(sample_rate);
        const intermediate_rate = modulation.intermediateRate();
        const audio_rate = modulation.audioRate();
        const s2_dec = modulation.stage2Decimation();
        const stage1_r = computeStage1Decimation(sr, intermediate_rate);

        const new_stage1_cap = self.input_capacity / stage1_r + 1;
        const new_stage2_cap = new_stage1_cap / s2_dec + 1;

        const p = modulation.profile();
        const stage1_cutoff: f32 = switch (p.stage1_cutoff_mode) {
            .proportional => intermediate_rate * p.stage1_cutoff_value,
            .fixed => p.stage1_cutoff_value,
            .nfm_adaptive => (nfm_dev + 3000.0) * 1.1,
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
            self.alloc.free(self.delayed_audio_buf);
            self.delayed_audio_buf = try self.alloc.alloc(f32, new_stage2_cap);
        }
        self.stage2_capacity = new_stage2_cap;

        self.audio_delay.deinit(self.alloc);
        const delay_samples: usize = @intFromFloat(0.020 * audio_rate);
        self.audio_delay = try DelayLine.init(self.alloc, delay_samples);

        self.modulation = modulation;
        self.deviation_gain = modulation.deviationGain(nfm_dev);
        self.deemphasis = DeEmphasis.init(audio_rate, tau);
        self.prev_sample = .{ 0.0, 0.0 };
        self.dc_block.reset();
        self.agc = if (p.has_agc) Agc.init(0.5, 0.1, 0.01) else null;
        self.pilot_notch = if (p.has_pilot_notch) Biquad.initNotch(audio_rate, p.pilot_notch_freq, 10.0) else null;
        self.ctcss = if (p.has_tone_detection) CtcssDetector.init(audio_rate) else null;
        self.dcs = if (p.has_tone_detection) DcsDetector.init(audio_rate) else null;
        self.squelch = Squelch.init(intermediate_rate, audio_rate);
        self.tone_squelch_state = if (p.has_tone_detection) ToneSquelch.init(audio_rate) else null;
        self.ctcss_hpf = if (p.has_tone_detection) Biquad.initHighPass(audio_rate, 300.0, 0.707) else null;
    }

    pub fn reset(self: *Self) void {
        self.nco.reset();
        self.stage1_fir.reset();
        self.stage2_fir.reset();
        self.deemphasis.reset();
        self.dc_block.reset();
        self.prev_sample = .{ 0.0, 0.0 };
        if (self.agc) |*agc| agc.reset();
        if (self.pilot_notch) |*notch| notch.reset();
        if (self.ctcss) |*ctcss| ctcss.reset();
        if (self.dcs) |*dcs| dcs.reset();
        self.squelch.reset();
        if (self.tone_squelch_state) |*tsq| tsq.reset();
        if (self.ctcss_hpf) |*hpf| hpf.reset();
        self.audio_delay.reset();
    }

    fn computeStage1Decimation(sample_rate: f32, intermediate_rate: f32) usize {
        const r = @as(usize, @intFromFloat(sample_rate / intermediate_rate));
        return @max(r, 1);
    }

    fn computeTapCount(decimation: usize) usize {
        return @max(decimation * 4 + 1, 31);
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
    squelch_threshold: std.atomic.Value(u32) = .init(@bitCast(@as(f32, -100.0))),
    nfm_deviation: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 5_000.0))),

    reconfigure_flag: std.atomic.Value(bool) = .init(false),
    retune_center_requested: std.atomic.Value(u64) = .init(0),
    target_interval_ns: std.atomic.Value(u64) = .init(1_000_000_000 / 30),

    thread_stats: ps.ThreadStats = .{},
    measured_dsp_rate: std.atomic.Value(u32) = .init(0),

    sample_rate: f64,
    center_freq_mhz: f32,

    input_buf: []hackrf.IQSample,

    audio_stream: ?*c.SDL_AudioStream = null,

    scanner: Scanner = .{},

    ui_enabled: bool = false,
    ui_volume: f32 = 0.5,
    ui_deemphasis_index: i32 = 0,
    ui_modulation_index: i32 = 0,
    ui_freq_mhz: f64 = 98.1,
    ui_freq_text: [16]u8 = undefined,
    ui_squelch_threshold: f32 = -100.0,
    ui_dsp_rate: i32 = 30,
    ui_preset_index: i32 = 0,
    ui_squelch_mode_index: i32 = 0,
    ui_scan_hold: f32 = 2.0,
    ui_scan_speed: f32 = 0.250,
    ui_scan_require_tone: bool = false,
    ui_show_activity_log: bool = false,
    ui_deviation_index: i32 = 1,

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, center_freq_mhz: f32) !Self {
        const cf: f64 = @floatCast(center_freq_mhz);
        const half_bw = sample_rate / 2e6;
        const default_freq: f64 = std.math.clamp(98.1, cf - half_bw, cf + half_bw);
        const offset = (default_freq - cf) * 1e6;

        var worker = try DecoderWorker.init(alloc, sample_rate, offset, 75e-6, .fm, 5_000.0);
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

    const GuiState = @import("gui_state.zig").GuiState;

    pub fn applyGuiState(self: *Self, gs: *const GuiState) void {
        self.ui_volume = gs.radio_volume;
        self.ui_modulation_index = gs.radio_modulation_index;
        self.ui_deemphasis_index = gs.radio_deemphasis_index;
        self.ui_squelch_threshold = gs.radio_squelch_threshold;
        self.ui_squelch_mode_index = gs.radio_squelch_mode_index;
        self.ui_dsp_rate = gs.radio_dsp_rate;
        self.ui_scan_hold = gs.radio_scan_hold;
        self.ui_scan_speed = gs.radio_scan_speed;
        self.ui_scan_require_tone = gs.radio_scan_require_tone;
        self.ui_show_activity_log = gs.radio_show_activity_log;
        self.ui_deviation_index = gs.radio_deviation_index;

        self.volume.store(@bitCast(self.ui_volume), .release);
        self.modulation.store(@intCast(self.ui_modulation_index), .release);
        self.squelch_threshold.store(@bitCast(self.ui_squelch_threshold), .release);
        self.target_interval_ns.store(1_000_000_000 / @as(u64, @intCast(@max(1, self.ui_dsp_rate))), .release);

        const dev_values = [_]f32{ 2_500.0, 5_000.0 };
        const dev_idx: usize = @intCast(std.math.clamp(self.ui_deviation_index, 0, 1));
        self.nfm_deviation.store(@bitCast(dev_values[dev_idx]), .release);
        self.reconfigure_flag.store(true, .release);
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

    pub fn setTargetRate(self: *Self, hz: u32) void {
        if (hz == 0) {
            self.target_interval_ns.store(0, .release);
        } else {
            self.target_interval_ns.store(1_000_000_000 / @as(u64, hz), .release);
        }
    }

    fn runLoop(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) void {
        var busy_ema: f64 = 0.0;
        var busy_initialized = false;
        const busy_alpha = 0.05;
        var frame_count: u32 = 0;
        var last_rate_ns: i128 = std.time.nanoTimestamp();
        var last_work_ns: i128 = std.time.nanoTimestamp();

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
                const nfm_dev: f32 = @bitCast(self.nfm_deviation.load(.acquire));
                self.worker.reconfigure(self.sample_rate, tau, new_mod, nfm_dev) catch {
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

                if (self.audio_stream) |stream| {
                    _ = c.SDL_ClearAudioStream(stream);
                }
            }

            const freq_mhz: f64 = @bitCast(self.freq_mhz.load(.acquire));
            const offset = (freq_mhz - @as(f64, @floatCast(self.center_freq_mhz))) * 1e6;
            self.worker.nco.setFrequency(offset, self.sample_rate);

            const squelch_thresh: f32 = @bitCast(self.squelch_threshold.load(.acquire));
            self.worker.squelch_threshold = squelch_thresh;

            mutex.lock();
            const copied = rx_buffer.copyNewest(self.input_buf);
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

            const target_ns = self.target_interval_ns.load(.acquire);
            if (target_ns > 0) {
                const since_last = std.time.nanoTimestamp() - last_work_ns;
                if (since_last >= 0 and since_last < target_ns) {
                    std.Thread.sleep(@intCast(target_ns - @as(u64, @intCast(since_last))));
                }
                last_work_ns = std.time.nanoTimestamp();
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
        const lo = cf - half_bw;
        const hi = cf + half_bw;

        if (freq_mhz >= lo and freq_mhz <= hi) {
            self.freq_mhz.store(@bitCast(freq_mhz), .release);
            self.ui_freq_mhz = freq_mhz;
            _ = std.fmt.bufPrint(&self.ui_freq_text, "{d:.3}\x00", .{freq_mhz}) catch {};
        } else {
            self.ui_freq_mhz = freq_mhz;
            _ = std.fmt.bufPrint(&self.ui_freq_text, "{d:.3}\x00", .{freq_mhz}) catch {};
            self.retune_center_requested.store(@bitCast(freq_mhz), .release);
        }
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

    pub fn audioUnderruns(self: *const Self) u64 {
        return self.worker.audio_underrun_count.load(.acquire);
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

        if (zgui.combo("Mode", .{
            .current_item = &self.ui_modulation_index,
            .items_separated_by_zeros = demod.combo_labels,
        })) {
            self.modulation.store(@intCast(self.ui_modulation_index), .release);
            if (self.ui_modulation_index == 2) {
                const nfm_tau: f32 = 75e-6;
                self.tau.store(@bitCast(nfm_tau), .release);
                self.reconfigure_flag.store(true, .release);
            }
        }

        zgui.separatorText("Tuning");

        zgui.text("Frequency: {d:.3} MHz", .{self.ui_freq_mhz});

        zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Drag the line on the FFT plot to tune", .{});

        zgui.separatorText("Audio");

        if (zgui.sliderFloat("Volume", .{ .v = &self.ui_volume, .min = 0.0, .max = 3.0 })) {
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

        if (self.ui_modulation_index == 2) {
            zgui.text("De-emphasis: 75 us", .{});

            const dev_values = [_]f32{ 2_500.0, 5_000.0 };
            const dev_labels: [:0]const u8 = "Narrow (2.5 kHz)\x00Standard (5.0 kHz)\x00";
            if (zgui.combo("Deviation", .{
                .current_item = &self.ui_deviation_index,
                .items_separated_by_zeros = dev_labels,
            })) {
                const new_dev = dev_values[@intCast(self.ui_deviation_index)];
                self.nfm_deviation.store(@bitCast(new_dev), .release);
                self.reconfigure_flag.store(true, .release);
            }
        }

        zgui.separatorText("Squelch");

        if (zgui.sliderFloat("Threshold", .{
            .v = &self.ui_squelch_threshold,
            .min = -100.0,
            .max = 0.0,
            .cfmt = "%.0f dB",
        })) {
            self.squelch_threshold.store(@bitCast(self.ui_squelch_threshold), .release);
        }

        const level_raw = self.worker.signal_level_atomic.load(.acquire);
        const level_db: f32 = @bitCast(level_raw);
        const level_frac = std.math.clamp((level_db + 100.0) / 100.0, 0.0, 1.0);

        zgui.text("Signal: {d:.0} dB", .{level_db});
        zgui.sameLine(.{});
        zgui.progressBar(.{ .fraction = level_frac, .overlay = "", .w = -1.0 });

        {
            const draw_list = zgui.getWindowDrawList();
            const bar_min = zgui.getItemRectMin();
            const bar_max = zgui.getItemRectMax();
            const bar_width = bar_max[0] - bar_min[0];
            const thresh_frac = std.math.clamp((self.ui_squelch_threshold + 100.0) / 100.0, 0.0, 1.0);
            const thresh_x = bar_min[0] + thresh_frac * bar_width;
            draw_list.addLine(.{
                .p1 = .{ thresh_x, bar_min[1] },
                .p2 = .{ thresh_x, bar_max[1] },
                .col = 0xE0_00_FFFF,
                .thickness = 2.0,
            });
        }

        const sq_open = self.worker.squelch_open_atomic.load(.acquire) != 0;
        if (sq_open) {
            zgui.textColored(.{ 0.2, 1.0, 0.2, 1.0 }, "Squelch: OPEN", .{});
        } else {
            zgui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "Squelch: CLOSED", .{});
        }

        if (self.ui_modulation_index == 2) {
            zgui.separatorText("Tone Squelch");

            const squelch_mode_labels: [:0]const u8 = "Carrier Only\x00CTCSS Any\x00CTCSS Match\x00DCS Any\x00DCS Match\x00Any Tone\x00";
            if (zgui.combo("Mode###tsq_mode", .{
                .current_item = &self.ui_squelch_mode_index,
                .items_separated_by_zeros = squelch_mode_labels,
            })) {
                self.worker.squelch_mode_atomic.store(@intCast(self.ui_squelch_mode_index), .release);
            }

            const confirmed_ctcss = self.worker.ctcss_confirmed_index.load(.acquire);
            const dcs_code_raw = self.worker.dcs_code_atomic.load(.acquire);
            const dcs_inv = self.worker.dcs_inverted_atomic.load(.acquire);

            zgui.text("Detected:", .{});
            zgui.sameLine(.{});
            if (confirmed_ctcss >= 0) {
                const tone_hz = CtcssDetector.tone_freqs[@intCast(confirmed_ctcss)];
                zgui.textColored(.{ 0.2, 1.0, 0.8, 1.0 }, "CTCSS {d:.1} Hz", .{tone_hz});
            } else if (dcs_code_raw >= 0) {
                const dcs_code_u16: u16 = @intCast(dcs_code_raw);
                const octal = Golay23_12.dcsCodeToOctalString(dcs_code_u16);
                const suffix: u8 = if (dcs_inv != 0) 'I' else 'N';
                zgui.textColored(.{ 0.2, 0.8, 1.0, 1.0 }, "DCS D{s}{c}", .{ &octal, suffix });
            } else {
                zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "None", .{});
            }

            const tsq_open = self.worker.tone_squelch_open_atomic.load(.acquire) != 0;
            if (tsq_open) {
                zgui.textColored(.{ 0.2, 1.0, 0.2, 1.0 }, "Tone Gate: OPEN", .{});
            } else {
                zgui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "Tone Gate: CLOSED", .{});
            }

            zgui.separatorText("Scan");
            self.renderScanControls();

            zgui.separatorText("Channel Presets");
            _ = zgui.combo("Radio", .{
                .current_item = &self.ui_preset_index,
                .items_separated_by_zeros = preset_labels,
            });
            self.renderChannelTable();

            if (zgui.collapsingHeader("Activity Log", .{})) {
                self.renderActivityLog();
            }
        }

        zgui.separatorText("Status");

        if (self.ui_enabled) {
            const mod: ModulationType = @enumFromInt(@as(u8, @intCast(self.ui_modulation_index)));
            const label = switch (mod) {
                .fm => "Decoding FM",
                .am => "Decoding AM",
                .nfm => "Decoding NFM",
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

    const ChannelCode = presets.ChannelCode;

    fn parseChannelCode(label: ?[:0]const u8) ChannelCode {
        return presets.parseChannelCode(label);
    }

    fn findMatchingChannel(self: *const Self) ?usize {
        const idx: usize = @intCast(std.math.clamp(self.ui_preset_index, 0, @as(i32, @intCast(presets.preset_tables.len - 1))));
        const preset = presets.preset_tables[idx];

        const confirmed_ctcss = self.worker.ctcss_confirmed_index.load(.acquire);
        const dcs_code = self.worker.dcs_code_atomic.load(.acquire);
        const dcs_inv = self.worker.dcs_inverted_atomic.load(.acquire);
        const current_freq = self.ui_freq_mhz;

        for (preset.channels, 0..) |ch, i| {
            if (@abs(ch.freq_mhz - current_freq) > 0.0025) continue;

            const code = parseChannelCode(ch.label);
            const matched = switch (code) {
                .none => true,
                .ctcss => |tone_idx| confirmed_ctcss >= 0 and confirmed_ctcss == @as(i8, @intCast(tone_idx)),
                .dcs_normal => |dcs_val| dcs_code >= 0 and @as(u16, @intCast(dcs_code)) == dcs_val and dcs_inv == 0,
                .dcs_inverted => |dcs_val| dcs_code >= 0 and @as(u16, @intCast(dcs_code)) == dcs_val and dcs_inv == 1,
            };
            if (matched) return i;
        }
        return null;
    }

    const preset_tables = presets.preset_tables;
    const preset_labels = presets.preset_labels;

    fn renderScanControls(self: *Self) void {
        const is_scanning = self.scanner.state != .idle;

        if (!is_scanning) {
            if (zgui.smallButton("Start Scan")) {
                const pidx: usize = @intCast(std.math.clamp(self.ui_preset_index, 0, @as(i32, @intCast(preset_tables.len - 1))));
                const num_ch: u8 = @intCast(preset_tables[pidx].channels.len);
                const now_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
                self.scanner.dwell_ms = @intFromFloat(self.ui_scan_speed * 1000.0);
                self.scanner.hold_ms = @intFromFloat(self.ui_scan_hold * 1000.0);
                self.scanner.require_tone_match = self.ui_scan_require_tone;
                self.scanner.start(num_ch, now_ms);
            }
        } else {
            if (zgui.smallButton("Stop Scan")) {
                self.scanner.stop();
            }
        }

        if (zgui.sliderFloat("Hold (s)", .{ .v = &self.ui_scan_hold, .min = 0.5, .max = 10.0, .cfmt = "%.1f" })) {
            self.scanner.hold_ms = @intFromFloat(self.ui_scan_hold * 1000.0);
        }
        if (zgui.sliderFloat("Speed (s)", .{ .v = &self.ui_scan_speed, .min = 0.05, .max = 2.0, .cfmt = "%.3f" })) {
            self.scanner.dwell_ms = @intFromFloat(self.ui_scan_speed * 1000.0);
        }
        if (zgui.checkbox("Require tone match", .{ .v = &self.ui_scan_require_tone })) {
            self.scanner.require_tone_match = self.ui_scan_require_tone;
        }

        if (is_scanning) {
            const sq_open = self.worker.squelch_open_atomic.load(.acquire) != 0;
            const tsq_open = self.worker.tone_squelch_open_atomic.load(.acquire) != 0;
            const now_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
            const action = self.scanner.tick(now_ms, sq_open, tsq_open);

            switch (action) {
                .tune_to_channel => |ch_idx| {
                    const pidx: usize = @intCast(std.math.clamp(self.ui_preset_index, 0, @as(i32, @intCast(preset_tables.len - 1))));
                    const channels = preset_tables[pidx].channels;
                    if (ch_idx < channels.len) {
                        self.setFreqMhz(channels[ch_idx].freq_mhz);
                        self.reconfigure_flag.store(true, .release);
                    }
                },
                .stop_on_channel => |ch_idx| {
                    const pidx: usize = @intCast(std.math.clamp(self.ui_preset_index, 0, @as(i32, @intCast(preset_tables.len - 1))));
                    const channels = preset_tables[pidx].channels;
                    if (ch_idx < channels.len) {
                        self.scanner.setActiveFreq(channels[ch_idx].freq_mhz);
                        const confirmed_ctcss = self.worker.ctcss_confirmed_index.load(.acquire);
                        const dcs_code_raw = self.worker.dcs_code_atomic.load(.acquire);
                        const dcs_inv = self.worker.dcs_inverted_atomic.load(.acquire);
                        if (confirmed_ctcss >= 0) {
                            self.scanner.setActiveTone(.ctcss, @as(i16, confirmed_ctcss));
                        } else if (dcs_code_raw >= 0) {
                            self.scanner.setActiveTone(
                                if (dcs_inv != 0) .dcs_inverted else .dcs_normal,
                                dcs_code_raw,
                            );
                        }
                    }
                },
                .none => {},
            }

            switch (self.scanner.state) {
                .scanning => zgui.textColored(.{ 1.0, 1.0, 0.2, 1.0 }, "Scanning Ch {d}...", .{self.scanner.current_channel + 1}),
                .active => zgui.textColored(.{ 0.2, 1.0, 0.2, 1.0 }, "Active on Ch {d}", .{self.scanner.current_channel + 1}),
                .holding => zgui.textColored(.{ 1.0, 0.8, 0.2, 1.0 }, "Holding Ch {d}...", .{self.scanner.current_channel + 1}),
                .idle => zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Idle", .{}),
            }
        }
    }

    fn renderChannelTable(self: *Self) void {
        const idx: usize = @intCast(std.math.clamp(self.ui_preset_index, 0, @as(i32, @intCast(preset_tables.len - 1))));
        const preset = preset_tables[idx];
        const matched_ch = self.findMatchingChannel();

        var has_labels = false;
        for (preset.channels) |ch| {
            if (ch.label != null) {
                has_labels = true;
                break;
            }
        }

        const col_count: i32 = if (has_labels) 5 else 4;

        if (zgui.beginTable("channel_presets", .{
            .column = col_count,
            .flags = .{ .borders = .{ .inner_h = true, .outer_h = true }, .row_bg = true, .sizing = .stretch_prop, .scroll_y = true },
            .outer_size = .{ 0.0, 300.0 },
        })) {
            defer zgui.endTable();

            zgui.tableSetupColumn("", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 20 });
            zgui.tableSetupColumn("Ch", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 30 });
            zgui.tableSetupColumn("Freq (MHz)", .{});
            if (has_labels) {
                zgui.tableSetupColumn("Code", .{});
            }
            zgui.tableSetupColumn("", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 40 });
            zgui.tableHeadersRow();

            for (preset.channels, 0..) |ch, i| {
                zgui.tableNextRow(.{});

                const is_matched = matched_ch != null and matched_ch.? == i;
                if (is_matched) {
                    zgui.tableSetBgColor(.{ .target = .row_bg0, .color = zgui.colorConvertFloat4ToU32(.{ 0.1, 0.4, 0.1, 0.5 }) });
                }

                _ = zgui.tableNextColumn();
                if (is_matched) {
                    zgui.textColored(.{ 0.2, 1.0, 0.2, 1.0 }, ">>", .{});
                }

                _ = zgui.tableNextColumn();
                zgui.text("{d}", .{ch.number});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.4}", .{ch.freq_mhz});
                if (has_labels) {
                    _ = zgui.tableNextColumn();
                    if (ch.label) |lbl| {
                        zgui.text("{s}", .{lbl});
                    }
                }
                _ = zgui.tableNextColumn();

                zgui.pushIntId(@intCast(ch.number));
                if (zgui.smallButton("Tune")) {
                    self.ui_modulation_index = 2;
                    self.modulation.store(2, .release);
                    self.setFreqMhz(ch.freq_mhz);
                    const nfm_tau: f32 = 750e-6;
                    self.tau.store(@bitCast(nfm_tau), .release);
                    self.reconfigure_flag.store(true, .release);
                }
                zgui.popId();
            }
        }
    }

    fn renderActivityLog(self: *const Self) void {
        if (self.scanner.log_count == 0) {
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "No activity recorded", .{});
            return;
        }

        const max_display: u8 = @min(self.scanner.log_count, 20);
        for (0..max_display) |ri| {
            const entry = self.scanner.getLogEntry(@intCast(ri)) orelse continue;
            const dur_s = @as(f32, @floatFromInt(entry.durationMs())) / 1000.0;

            switch (entry.tone_type) {
                .ctcss => {
                    if (entry.tone_value >= 0 and entry.tone_value < CtcssDetector.num_tones) {
                        const hz = CtcssDetector.tone_freqs[@intCast(entry.tone_value)];
                        zgui.text("Ch {d} CTCSS {d:.1} Hz  {d:.1}s", .{ entry.channel_index + 1, hz, dur_s });
                    } else {
                        zgui.text("Ch {d} CTCSS  {d:.1}s", .{ entry.channel_index + 1, dur_s });
                    }
                },
                .dcs_normal, .dcs_inverted => {
                    if (entry.tone_value >= 0) {
                        const code_u16: u16 = @intCast(entry.tone_value);
                        const octal = Golay23_12.dcsCodeToOctalString(code_u16);
                        const suffix: u8 = if (entry.tone_type == .dcs_inverted) 'I' else 'N';
                        zgui.text("Ch {d} DCS D{s}{c}  {d:.1}s", .{ entry.channel_index + 1, &octal, suffix, dur_s });
                    } else {
                        zgui.text("Ch {d} DCS  {d:.1}s", .{ entry.channel_index + 1, dur_s });
                    }
                },
                .none => {
                    zgui.text("Ch {d}  {d:.1}s", .{ entry.channel_index + 1, dur_s });
                },
            }
        }
    }
};
