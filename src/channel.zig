const std = @import("std");
const hackrf = @import("rf_fun");
const radio = @import("radio_decoder.zig");
const DecoderWorker = radio.DecoderWorker;
const ModulationType = radio.ModulationType;
const c = radio.c;

pub const ChannelConfig = struct {
    freq_mhz: f64 = 462.5625,
    modulation: ModulationType = .nfm,
    squelch_db: f32 = -80.0,
    volume: f32 = 1.0,
    muted: bool = false,
    label: [16]u8 = [_]u8{0} ** 16,
    label_len: u8 = 0,
    nfm_dev: f32 = 5_000.0,
    tau: f32 = 75e-6,

    pub fn labelSlice(self: *const ChannelConfig) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn setLabel(self: *ChannelConfig, text: []const u8) void {
        const len = @min(text.len, self.label.len);
        @memcpy(self.label[0..len], text[0..len]);
        self.label_len = @intCast(len);
    }
};

pub const Channel = struct {
    config: ChannelConfig,
    worker: DecoderWorker,
    enabled: bool = true,
    solo: bool = false,
    smooth_gain: f32 = 0.0,
    audio_out_count: usize = 0,
    resample_stream: ?*c.SDL_AudioStream = null,
    alloc: std.mem.Allocator,
    pending_modulation: std.atomic.Value(i8) = .init(-1),

    pub fn init(alloc: std.mem.Allocator, config: ChannelConfig, sample_rate: f64, center_freq_mhz: f32) !Channel {
        const cf: f64 = @floatCast(center_freq_mhz);
        const offset = (config.freq_mhz - cf) * 1e6;

        var worker = try DecoderWorker.init(
            alloc,
            sample_rate,
            offset,
            config.tau,
            config.modulation,
            config.nfm_dev,
        );
        worker.audio_stream = null;
        worker.squelch_threshold = config.squelch_db;

        const src_rate: c_int = @intFromFloat(config.modulation.audioRate());
        const src_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = src_rate,
        };
        const dst_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = 48000,
        };
        const resample_stream = c.SDL_CreateAudioStream(&src_spec, &dst_spec);

        return .{
            .config = config,
            .worker = worker,
            .alloc = alloc,
            .resample_stream = resample_stream,
        };
    }

    pub fn deinit(self: *Channel) void {
        if (self.resample_stream) |stream| {
            c.SDL_DestroyAudioStream(stream);
            self.resample_stream = null;
        }
        self.worker.deinit();
    }

    pub fn process(self: *Channel, input: []const hackrf.IQSample) usize {
        const s2_count = self.worker.workCore(input);
        self.audio_out_count = s2_count;
        return s2_count;
    }

    pub fn audioSlice(self: *const Channel) []const f32 {
        if (self.audio_out_count == 0) return &.{};
        return self.worker.delayed_audio_buf[0..self.audio_out_count];
    }

    pub fn reconfigure(self: *Channel, sample_rate: f64, center_freq_mhz: f32) !void {
        const cf: f64 = @floatCast(center_freq_mhz);
        const offset = (self.config.freq_mhz - cf) * 1e6;
        self.worker.nco.setFrequency(offset, sample_rate);

        try self.worker.reconfigure(
            sample_rate,
            self.config.tau,
            self.config.modulation,
            self.config.nfm_dev,
        );
        self.worker.squelch_threshold = self.config.squelch_db;

        if (self.resample_stream) |stream| {
            c.SDL_DestroyAudioStream(stream);
        }
        const src_rate: c_int = @intFromFloat(self.config.modulation.audioRate());
        const src_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = src_rate,
        };
        const dst_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = 48000,
        };
        self.resample_stream = c.SDL_CreateAudioStream(&src_spec, &dst_spec);
    }

    pub fn updateTuning(self: *Channel, sample_rate: f64, center_freq_mhz: f32) void {
        const cf: f64 = @floatCast(center_freq_mhz);
        const offset = (self.config.freq_mhz - cf) * 1e6;
        self.worker.nco.setFrequency(offset, sample_rate);
    }

    pub fn signalLevelDb(self: *const Channel) f32 {
        return @bitCast(self.worker.signal_level_atomic.load(.acquire));
    }

    pub fn isSquelchOpen(self: *const Channel) bool {
        return self.worker.squelch_open_atomic.load(.acquire) != 0;
    }

    pub fn requestModulationChange(self: *Channel, mod: ModulationType) void {
        self.pending_modulation.store(@intCast(@intFromEnum(mod)), .release);
    }

    pub fn applyPendingReconfigure(self: *Channel, sample_rate: f64, center_freq_mhz: f32) void {
        const raw = self.pending_modulation.swap(-1, .acquire);
        if (raw < 0) return;
        const mod: ModulationType = @enumFromInt(@as(u8, @intCast(raw)));
        self.config.modulation = mod;
        self.reconfigure(sample_rate, center_freq_mhz) catch {};
    }
};
