const std = @import("std");
const hackrf = @import("rf_fun");
const WavReader = @import("wav_reader.zig").WavReader;
const SampleBuffer = @import("sample_buffer.zig").SampleBuffer;

pub const FileSource = struct {
    reader: ?WavReader = null,

    playing: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    looping: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    position: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    thread: ?std.Thread = null,

    file_size_bytes: u64 = 0,
    sample_rate: u32 = 0,
    bits_per_sample: u16 = 0,
    total_samples: u64 = 0,
    duration_secs: f64 = 0,
    file_path: [1024]u8 = std.mem.zeroes([1024]u8),
    file_path_len: usize = 0,

    waveform_min_i: [512]f32 = std.mem.zeroes([512]f32),
    waveform_max_i: [512]f32 = std.mem.zeroes([512]f32),
    waveform_min_q: [512]f32 = std.mem.zeroes([512]f32),
    waveform_max_q: [512]f32 = std.mem.zeroes([512]f32),
    spectrum_mag: [512]f32 = std.mem.zeroes([512]f32),
    preview_ready: bool = false,

    sample_buf: *SampleBuffer,

    center_freq_mhz: f32 = 100.0,

    load_error: ?[]const u8 = null,

    pub fn loadFile(self: *FileSource, path: []const u8) void {
        if (self.reader) |*r| {
            r.close();
            self.reader = null;
        }

        self.reader = WavReader.open(path) catch |err| {
            self.load_error = @errorName(err);
            return;
        };

        var r = &self.reader.?;

        self.sample_rate = r.sample_rate;
        self.bits_per_sample = r.bits_per_sample;
        self.total_samples = r.total_samples;
        self.duration_secs = @as(f64, @floatFromInt(r.total_samples)) / @as(f64, @floatFromInt(r.sample_rate));

        if (std.fs.cwd().statFile(path)) |stat| {
            self.file_size_bytes = stat.size;
        } else |_| {}

        const copy_len = @min(path.len, self.file_path.len);
        @memcpy(self.file_path[0..copy_len], path[0..copy_len]);
        self.file_path_len = copy_len;

        const samples_per_bucket = if (self.total_samples / 512 > 0) self.total_samples / 512 else 1;
        var chunk: [4096]hackrf.IQSample = undefined;
        var bucket_idx: usize = 0;
        var bucket_count: u64 = 0;
        var min_i: f32 = 1.0;
        var max_i: f32 = -1.0;
        var min_q: f32 = 1.0;
        var max_q: f32 = -1.0;

        while (bucket_idx < 512) {
            const read = r.readSamples(&chunk) catch 0;
            if (read == 0) break;

            for (0..read) |j| {
                const fi: f32 = @as(f32, @floatFromInt(chunk[j].i)) / 128.0;
                const fq: f32 = @as(f32, @floatFromInt(chunk[j].q)) / 128.0;

                if (fi < min_i) min_i = fi;
                if (fi > max_i) max_i = fi;
                if (fq < min_q) min_q = fq;
                if (fq > max_q) max_q = fq;

                bucket_count += 1;
                if (bucket_count >= samples_per_bucket) {
                    if (bucket_idx < 512) {
                        self.waveform_min_i[bucket_idx] = min_i;
                        self.waveform_max_i[bucket_idx] = max_i;
                        self.waveform_min_q[bucket_idx] = min_q;
                        self.waveform_max_q[bucket_idx] = max_q;
                        bucket_idx += 1;
                    }
                    min_i = 1.0;
                    max_i = -1.0;
                    min_q = 1.0;
                    max_q = -1.0;
                    bucket_count = 0;
                }
            }
        }

        if (bucket_count > 0 and bucket_idx < 512) {
            self.waveform_min_i[bucket_idx] = min_i;
            self.waveform_max_i[bucket_idx] = max_i;
            self.waveform_min_q[bucket_idx] = min_q;
            self.waveform_max_q[bucket_idx] = max_q;
        }

        r.seekToSample(self.total_samples / 2) catch {};

        var spectrum_samples: [1024]hackrf.IQSample = undefined;
        const spec_read = r.readSamples(&spectrum_samples) catch 0;

        for (0..512) |k| {
            var sum_re: f64 = 0;
            var sum_im: f64 = 0;
            const kf: f64 = @floatFromInt(k);

            for (0..spec_read) |n| {
                const nf: f64 = @floatFromInt(n);
                const angle = -2.0 * std.math.pi * kf * nf / 1024.0;
                const sample_val: f64 = @floatFromInt(spectrum_samples[n].i);
                sum_re += sample_val * @cos(angle);
                sum_im += sample_val * @sin(angle);
            }

            self.spectrum_mag[k] = @floatCast(10.0 * @log10(sum_re * sum_re + sum_im * sum_im + 1e-20));
        }

        r.seekToSample(0) catch {};

        self.preview_ready = true;
        self.load_error = null;
    }

    pub fn play(self: *FileSource) !void {
        if (self.reader == null) return;

        self.position.store(0, .release);
        self.reader.?.seekToSample(0) catch {};
        self.playing.store(1, .release);
        self.thread = try std.Thread.spawn(.{}, playbackLoop, .{self});
    }

    fn playbackLoop(self: *FileSource) void {
        const start_raw = std.time.nanoTimestamp();
        var start_time: u64 = @intCast(start_raw);
        var samples_pushed: u64 = 0;
        var staging: [8192]hackrf.IQSample = undefined;
        const sr: f64 = @floatFromInt(self.sample_rate);

        while (self.playing.load(.acquire) != 0) {
            const now_raw = std.time.nanoTimestamp();
            const now: u64 = @intCast(now_raw);
            const elapsed_ns = now - start_time;
            const elapsed_secs: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const expected: u64 = @intFromFloat(elapsed_secs * sr);
            const to_push = expected -| samples_pushed;

            if (to_push > 0) {
                const chunk = @min(to_push, staging.len);
                const read = self.reader.?.readSamples(staging[0..chunk]) catch 0;

                if (read > 0) {
                    self.sample_buf.mutex.lock();
                    self.sample_buf.rx_buffer.append(staging[0..read]);
                    self.sample_buf.bytes_received += read * 2;
                    self.sample_buf.mutex.unlock();

                    samples_pushed += read;
                    self.position.store(samples_pushed, .release);
                }

                if (read < chunk) {
                    if (self.looping.load(.acquire) != 0) {
                        self.reader.?.seekToSample(0) catch {};
                        samples_pushed = 0;
                        self.position.store(0, .release);
                        const reset_raw = std.time.nanoTimestamp();
                        start_time = @intCast(reset_raw);
                    } else {
                        self.playing.store(0, .release);
                        break;
                    }
                }
            } else {
                std.Thread.sleep(1_000_000);
            }
        }
    }

    pub fn stop(self: *FileSource) void {
        self.playing.store(0, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.reader) |*r| {
            r.seekToSample(0) catch {};
        }
        self.position.store(0, .release);
    }

    pub fn unload(self: *FileSource) void {
        if (self.playing.load(.acquire) != 0) {
            self.stop();
        }
        if (self.reader) |*r| {
            r.close();
            self.reader = null;
        }
        self.file_path_len = 0;
        self.total_samples = 0;
        self.sample_rate = 0;
        self.bits_per_sample = 0;
        self.file_size_bytes = 0;
        self.duration_secs = 0;
        self.preview_ready = false;
    }

    pub fn isPlaying(self: *const FileSource) bool {
        return self.playing.load(.acquire) != 0;
    }

    pub fn progress(self: *const FileSource) f32 {
        if (self.total_samples == 0) return 0;
        return @floatCast(@as(f64, @floatFromInt(self.position.load(.acquire))) / @as(f64, @floatFromInt(self.total_samples)));
    }

    pub fn elapsedSecs(self: *const FileSource) f64 {
        if (self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.position.load(.acquire))) / @as(f64, @floatFromInt(self.sample_rate));
    }
};
