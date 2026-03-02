const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const Channel = @import("channel.zig").Channel;
const ChannelConfig = @import("channel.zig").ChannelConfig;
const ModulationType = @import("radio_decoder.zig").ModulationType;
const presets = @import("channel_presets.zig");
pub const c = @import("radio_decoder.zig").c;

pub const MAX_CHANNELS: u8 = 32;
const MIX_BUF_SIZE: usize = 32768;

const ATTACK_COEFF: f32 = 1.0 - @exp(-1.0 / (0.005 * 48000.0));
const RELEASE_COEFF: f32 = 1.0 - @exp(-1.0 / (0.015 * 48000.0));
const GATE_THRESHOLD: f32 = 1e-4;

pub const ChannelManager = struct {
    const Self = @This();

    channels: [MAX_CHANNELS]?Channel = [_]?Channel{null} ** MAX_CHANNELS,
    active_count: u8 = 0,
    alloc: std.mem.Allocator,

    output_stream: ?*c.SDL_AudioStream = null,
    mix_buffer: []f32,
    resample_buffer: []f32,

    master_volume: f32 = 1.0,
    master_muted: bool = false,
    click_filter: bool = true,
    global_squelch_db: f32 = -80.0,

    thread: ?std.Thread = null,
    running: std.atomic.Value(u8) = .init(0),
    enabled: std.atomic.Value(u8) = .init(0),

    sample_rate: f64,
    center_freq_mhz: f32,

    input_buf: []hackrf.IQSample,

    target_interval_ns: u64 = 1_000_000_000 / 30,

    pub fn init(alloc: std.mem.Allocator, sample_rate: f64, center_freq_mhz: f32) !Self {
        const input_buf = try alloc.alloc(hackrf.IQSample, 262144);
        errdefer alloc.free(input_buf);

        const mix_buffer = try alloc.alloc(f32, MIX_BUF_SIZE);
        errdefer alloc.free(mix_buffer);

        const resample_buffer = try alloc.alloc(f32, MIX_BUF_SIZE);
        errdefer alloc.free(resample_buffer);

        return .{
            .alloc = alloc,
            .sample_rate = sample_rate,
            .center_freq_mhz = center_freq_mhz,
            .input_buf = input_buf,
            .mix_buffer = mix_buffer,
            .resample_buffer = resample_buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.removeAllChannels();
        self.alloc.free(self.input_buf);
        self.alloc.free(self.mix_buffer);
        self.alloc.free(self.resample_buffer);
    }

    pub fn addChannel(self: *Self, config: ChannelConfig) !u8 {
        for (&self.channels, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = try Channel.init(self.alloc, config, self.sample_rate, self.center_freq_mhz);
                self.active_count += 1;
                return @intCast(i);
            }
        }
        return error.NoFreeSlot;
    }

    pub fn removeChannel(self: *Self, index: u8) void {
        if (index >= MAX_CHANNELS) return;
        if (self.channels[index]) |*ch| {
            ch.deinit();
            self.channels[index] = null;
            if (self.active_count > 0) self.active_count -= 1;
        }
    }

    pub fn setGlobalSquelch(self: *Self, db: f32) void {
        self.global_squelch_db = db;
        for (&self.channels) |*slot| {
            if (slot.*) |*ch| {
                ch.config.squelch_db = db;
                ch.worker.squelch_threshold = db;
            }
        }
    }

    pub fn removeAllChannels(self: *Self) void {
        for (&self.channels) |*slot| {
            if (slot.*) |*ch| {
                ch.deinit();
                slot.* = null;
            }
        }
        self.active_count = 0;
    }

    pub fn loadPreset(self: *Self, preset_index: usize) !void {
        self.removeAllChannels();
        if (preset_index >= presets.preset_tables.len) return;
        const table = presets.preset_tables[preset_index];

        for (table.channels) |pch| {
            var config = ChannelConfig{
                .freq_mhz = pch.freq_mhz,
                .modulation = pch.modulation orelse table.modulation,
                .squelch_db = self.global_squelch_db,
            };
            var label_buf: [16]u8 = undefined;
            const label_text = std.fmt.bufPrint(&label_buf, "Ch {d}", .{pch.number}) catch "Ch";
            config.setLabel(label_text);
            _ = try self.addChannel(config);
        }
    }

    pub fn start(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) !void {
        if (self.running.load(.acquire) != 0) return;
        self.createOutputStream();
        self.running.store(1, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{ self, mutex, rx_buffer });
    }

    pub fn stop(self: *Self) void {
        if (self.running.load(.acquire) == 0) return;
        self.running.store(0, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.destroyOutputStream();
    }

    pub fn updateFreqs(self: *Self, center_freq_mhz: f32, sample_rate: f64) void {
        self.center_freq_mhz = center_freq_mhz;
        self.sample_rate = sample_rate;
        for (&self.channels) |*slot| {
            if (slot.*) |*ch| {
                ch.updateTuning(sample_rate, center_freq_mhz);
            }
        }
    }

    pub fn setEnabled(self: *Self, on: bool) void {
        self.enabled.store(if (on) 1 else 0, .release);
        if (on) {
            if (self.output_stream) |stream| {
                _ = c.SDL_ResumeAudioStreamDevice(stream);
            }
        } else {
            if (self.output_stream) |stream| {
                _ = c.SDL_PauseAudioStreamDevice(stream);
            }
        }
    }

    pub fn isEnabled(self: *const Self) bool {
        return self.enabled.load(.acquire) != 0;
    }

    fn createOutputStream(self: *Self) void {
        if (self.output_stream != null) return;
        var spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 1,
            .freq = 48000,
        };
        self.output_stream = c.SDL_OpenAudioDeviceStream(
            c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &spec,
            null,
            null,
        );
    }

    fn destroyOutputStream(self: *Self) void {
        if (self.output_stream) |stream| {
            c.SDL_DestroyAudioStream(stream);
            self.output_stream = null;
        }
    }

    fn runLoop(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample)) void {
        var last_work_ns: i128 = std.time.nanoTimestamp();

        while (self.running.load(.acquire) != 0) {
            if (self.enabled.load(.acquire) == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            if (self.active_count == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            mutex.lock();
            const copied = rx_buffer.copyNewest(self.input_buf);
            mutex.unlock();

            if (copied < 1024) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

            const iq_slice = self.input_buf[0..copied];

            var any_solo = false;
            for (&self.channels) |*slot| {
                if (slot.*) |*ch| {
                    if (ch.solo) {
                        any_solo = true;
                        break;
                    }
                }
            }

            for (&self.channels) |*slot| {
                if (slot.*) |*ch| {
                    ch.applyPendingReconfigure(self.sample_rate, self.center_freq_mhz);
                }
            }

            for (&self.channels) |*slot| {
                if (slot.*) |*ch| {
                    if (!ch.enabled) continue;
                    _ = ch.process(iq_slice);
                }
            }

            self.mixChannels(any_solo);

            const target_ns = self.target_interval_ns;
            if (target_ns > 0) {
                const since_last = std.time.nanoTimestamp() - last_work_ns;
                if (since_last >= 0 and since_last < target_ns) {
                    std.Thread.sleep(@intCast(target_ns - @as(u64, @intCast(since_last))));
                }
                last_work_ns = std.time.nanoTimestamp();
            }
        }
    }

    fn mixChannels(self: *Self, any_solo: bool) void {
        const output_stream = self.output_stream orelse return;
        if (self.master_muted) return;

        @memset(self.mix_buffer, 0.0);
        var mix_len: usize = 0;

        for (&self.channels) |*slot| {
            const ch = &(slot.* orelse continue);
            const resample_stream = ch.resample_stream orelse continue;

            const is_active = ch.enabled and !ch.config.muted and !(any_solo and !ch.solo);
            const target_gain: f32 = if (is_active) ch.config.volume else 0.0;

            if (ch.smooth_gain < GATE_THRESHOLD and target_gain == 0.0) {
                ch.smooth_gain = 0.0;
                continue;
            }

            if (ch.audio_out_count > 0) {
                const audio = ch.audioSlice();
                _ = c.SDL_PutAudioStreamData(
                    resample_stream,
                    audio.ptr,
                    @intCast(audio.len * @sizeOf(f32)),
                );
            }

            const avail = c.SDL_GetAudioStreamAvailable(resample_stream);
            if (avail <= 0) continue;
            const avail_samples: usize = @intCast(@divTrunc(avail, @sizeOf(f32)));
            const read_count = @min(avail_samples, MIX_BUF_SIZE);

            const got = c.SDL_GetAudioStreamData(
                resample_stream,
                self.resample_buffer[0..read_count].ptr,
                @intCast(read_count * @sizeOf(f32)),
            );
            if (got <= 0) continue;

            const got_samples: usize = @intCast(@divTrunc(got, @sizeOf(f32)));

            if (self.click_filter) {
                for (0..got_samples) |i| {
                    if (i >= MIX_BUF_SIZE) break;
                    const coeff = if (target_gain > ch.smooth_gain) ATTACK_COEFF else RELEASE_COEFF;
                    ch.smooth_gain += coeff * (target_gain - ch.smooth_gain);
                    if (ch.smooth_gain < GATE_THRESHOLD and target_gain == 0.0) ch.smooth_gain = 0.0;
                    self.mix_buffer[i] += self.resample_buffer[i] * ch.smooth_gain;
                }
            } else {
                const vol = ch.config.volume;
                for (0..got_samples) |i| {
                    if (i >= MIX_BUF_SIZE) break;
                    self.mix_buffer[i] += self.resample_buffer[i] * vol;
                }
                ch.smooth_gain = target_gain;
            }
            mix_len = @max(mix_len, got_samples);
        }

        if (mix_len == 0) return;

        for (self.mix_buffer[0..mix_len]) |*s| {
            s.* *= self.master_volume;
            s.* = std.math.clamp(s.*, -1.0, 1.0);
        }

        _ = c.SDL_PutAudioStreamData(
            output_stream,
            self.mix_buffer[0..mix_len].ptr,
            @intCast(mix_len * @sizeOf(f32)),
        );
    }
};
