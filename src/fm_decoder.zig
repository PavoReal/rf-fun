const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const DecimatingFir = @import("dsp/decimating_fir.zig").DecimatingFir;
const Nco = @import("dsp/nco.zig").Nco;
const DeEmphasis = @import("dsp/deemphasis.zig").DeEmphasis;
const zgui = @import("zgui");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const INTERMEDIATE_RATE: f32 = 400_000.0;
const AUDIO_RATE: f32 = 50_000.0;
const STAGE2_DECIMATION: usize = 8;

pub const FmDecoderWorker = struct {
    const Self = @This();

    alloc: std.mem.Allocator,

    nco: Nco,
    stage1_fir: DecimatingFir([2]f32),
    stage2_fir: DecimatingFir(f32),
    deemphasis: DeEmphasis,

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

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, freq_offset: f64, tau: f32) !Self {
        const sr: f32 = @floatCast(sample_rate);

        const stage1_r = computeStage1Decimation(sr);
        const input_cap: usize = 262144;
        const stage1_cap = input_cap / stage1_r + 1;
        const stage2_cap = stage1_cap / STAGE2_DECIMATION + 1;

        var stage1_fir = try DecimatingFir([2]f32).init(alloc, computeTapCount(stage1_r), INTERMEDIATE_RATE * 0.45, sr, stage1_r);
        errdefer stage1_fir.deinit(alloc);

        var stage2_fir = try DecimatingFir(f32).init(alloc, computeTapCount(STAGE2_DECIMATION), AUDIO_RATE * 0.45, INTERMEDIATE_RATE, STAGE2_DECIMATION);
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
            .nco = Nco.init(freq_offset, sample_rate),
            .stage1_fir = stage1_fir,
            .stage2_fir = stage2_fir,
            .deemphasis = DeEmphasis.init(AUDIO_RATE, tau),
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

        for (input[0..len], self.nco_buf[0..len]) |sample, *out| {
            out.* = sample.toFloat();
        }

        _ = self.nco.process(self.nco_buf[0..len], self.nco_buf[0..len]);

        const s1_count = self.stage1_fir.process(self.nco_buf[0..len], self.stage1_buf);
        if (s1_count == 0) return;

        self.discriminate(self.stage1_buf[0..s1_count], self.discrim_buf[0..s1_count]);

        const s2_count = self.stage2_fir.process(self.discrim_buf[0..s1_count], self.stage2_buf);
        if (s2_count == 0) return;

        _ = self.deemphasis.process(self.stage2_buf[0..s2_count], self.audio_buf[0..s2_count]);

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

    pub fn reconfigure(self: *Self, sample_rate: f64, tau: f32) !void {
        const sr: f32 = @floatCast(sample_rate);
        const stage1_r = computeStage1Decimation(sr);

        const new_stage1_cap = self.input_capacity / stage1_r + 1;
        const new_stage2_cap = new_stage1_cap / STAGE2_DECIMATION + 1;

        self.stage1_fir.deinit(self.alloc);
        self.stage1_fir = try DecimatingFir([2]f32).init(self.alloc, computeTapCount(stage1_r), INTERMEDIATE_RATE * 0.45, sr, stage1_r);

        self.stage2_fir.deinit(self.alloc);
        self.stage2_fir = try DecimatingFir(f32).init(self.alloc, computeTapCount(STAGE2_DECIMATION), AUDIO_RATE * 0.45, INTERMEDIATE_RATE, STAGE2_DECIMATION);

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

        self.deemphasis = DeEmphasis.init(AUDIO_RATE, tau);
        self.prev_sample = .{ 0.0, 0.0 };
    }

    pub fn reset(self: *Self) void {
        self.nco.reset();
        self.stage1_fir.reset();
        self.stage2_fir.reset();
        self.deemphasis.reset();
        self.prev_sample = .{ 0.0, 0.0 };
    }

    fn computeStage1Decimation(sample_rate: f32) usize {
        const r = @as(usize, @intFromFloat(sample_rate / INTERMEDIATE_RATE));
        return @max(r, 1);
    }

    fn computeTapCount(decimation: usize) usize {
        return @max(decimation * 4 + 1, 15);
    }
};

pub const FmDecoder = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    worker: FmDecoderWorker,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    enabled: std.atomic.Value(bool) = .init(false),
    freq_mhz: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 98.1))),
    volume: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.5))),
    tau: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 75e-6))),

    reconfigure_flag: std.atomic.Value(bool) = .init(false),

    sample_rate: f64,
    center_freq_mhz: f32,

    read_cursor: usize = 0,
    input_buf: []hackrf.IQSample,

    audio_stream: ?*c.SDL_AudioStream = null,

    ui_enabled: bool = false,
    ui_volume: f32 = 0.5,
    ui_deemphasis_index: i32 = 0,
    ui_freq_mhz: f64 = 98.1,
    ui_freq_text: [16]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, center_freq_mhz: f32) !Self {
        const default_freq: f64 = 98.1;
        const offset = (default_freq - @as(f64, @floatCast(center_freq_mhz))) * 1e6;

        var worker = try FmDecoderWorker.init(alloc, sample_rate, offset, 75e-6);
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
        self.reconfigure_flag.store(true, .release);
    }

    fn createAudioStream(self: *Self) void {
        if (self.audio_stream != null) return;

        var spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = @intFromFloat(AUDIO_RATE),
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
        while (self.running.load(.acquire)) {
            if (!self.enabled.load(.acquire)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            if (self.reconfigure_flag.swap(false, .acquire)) {
                const tau: f32 = @bitCast(self.tau.load(.acquire));
                self.worker.reconfigure(self.sample_rate, tau) catch {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                };

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

            self.worker.work(self.input_buf[0..copied]);
        }
    }

    pub fn setFreqMhz(self: *Self, freq_mhz: f64) void {
        self.freq_mhz.store(@bitCast(freq_mhz), .release);
        self.ui_freq_mhz = freq_mhz;
        _ = std.fmt.bufPrint(&self.ui_freq_text, "{d:.3}\x00", .{freq_mhz}) catch {};
    }

    pub fn renderUi(self: *Self) void {
        if (!zgui.begin("FM Radio###FM Decoder", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        var toggled = self.ui_enabled;
        if (zgui.checkbox("Enable FM Decoder", .{ .v = &toggled })) {
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

        zgui.separatorText("Status");

        if (self.ui_enabled) {
            zgui.textColored(.{ 0.2, 1.0, 0.2, 1.0 }, "Decoding", .{});
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
