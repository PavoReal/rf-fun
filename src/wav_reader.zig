const std = @import("std");
const hackrf = @import("rf_fun");

pub const IQSample = hackrf.IQSample;

pub const WavReaderError = error{
    InvalidWav,
    UnsupportedFormat,
};

pub const WavReader = struct {
    file: std.fs.File,
    data_offset: u64,
    data_size: u64,
    sample_rate: u32,
    bits_per_sample: u16,
    num_channels: u16,
    bytes_per_frame: u64,
    total_samples: u64,
    bytes_read_pos: u64 = 0,

    pub fn open(path: []const u8) !WavReader {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        var header: [12]u8 = undefined;
        var n = try file.readAll(&header);
        if (n < 12) return error.InvalidWav;

        if (!std.mem.eql(u8, header[0..4], "RIFF")) return error.InvalidWav;
        if (!std.mem.eql(u8, header[8..12], "WAVE")) return error.InvalidWav;

        var sample_rate: u32 = 0;
        var bits_per_sample: u16 = 0;
        var num_channels: u16 = 0;
        var found_fmt = false;

        var data_offset: u64 = 0;
        var data_size: u64 = 0;

        while (true) {
            var chunk_header: [8]u8 = undefined;
            n = try file.readAll(&chunk_header);
            if (n < 8) break;

            const chunk_id = chunk_header[0..4];
            const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

            if (std.mem.eql(u8, chunk_id, "fmt ")) {
                if (chunk_size < 16) return error.InvalidWav;

                var fmt_data: [16]u8 = undefined;
                n = try file.readAll(&fmt_data);
                if (n < 16) return error.InvalidWav;

                const audio_format = std.mem.readInt(u16, fmt_data[0..2], .little);
                if (audio_format != 1) return error.UnsupportedFormat;

                num_channels = std.mem.readInt(u16, fmt_data[2..4], .little);
                if (num_channels != 2) return error.UnsupportedFormat;

                sample_rate = std.mem.readInt(u32, fmt_data[4..8], .little);
                bits_per_sample = std.mem.readInt(u16, fmt_data[14..16], .little);

                if (bits_per_sample != 8 and bits_per_sample != 16) return error.UnsupportedFormat;

                if (chunk_size > 16) {
                    try file.seekBy(@intCast(chunk_size - 16));
                }

                found_fmt = true;
            } else if (std.mem.eql(u8, chunk_id, "data")) {
                if (!found_fmt) return error.InvalidWav;

                data_size = chunk_size;
                data_offset = try file.getPos();
                break;
            } else {
                try file.seekBy(@intCast(chunk_size));
            }
        }

        if (data_offset == 0) return error.InvalidWav;

        const bytes_per_frame: u64 = @as(u64, num_channels) * @as(u64, bits_per_sample) / 8;
        const total_samples = if (bytes_per_frame > 0) data_size / bytes_per_frame else 0;

        return WavReader{
            .file = file,
            .data_offset = data_offset,
            .data_size = data_size,
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .num_channels = num_channels,
            .bytes_per_frame = bytes_per_frame,
            .total_samples = total_samples,
            .bytes_read_pos = 0,
        };
    }

    pub fn readSamples(self: *WavReader, dest: []IQSample) !usize {
        if (self.bytes_read_pos >= self.data_size) return 0;

        const remaining_bytes = self.data_size - self.bytes_read_pos;
        const max_frames = remaining_bytes / self.bytes_per_frame;
        const frames_to_read = @min(dest.len, max_frames);

        if (frames_to_read == 0) return 0;

        if (self.bits_per_sample == 8) {
            const bytes_needed = frames_to_read * 2;
            var buf: [8192]u8 = undefined;
            var total_read: usize = 0;

            while (total_read < bytes_needed) {
                const chunk = @min(buf.len, bytes_needed - total_read);
                const n = try self.file.readAll(buf[0..chunk]);
                if (n == 0) break;

                const pairs = n / 2;
                for (0..pairs) |j| {
                    const idx = total_read / 2 + j;
                    dest[idx] = .{
                        .i = @bitCast(buf[j * 2] ^ 0x80),
                        .q = @bitCast(buf[j * 2 + 1] ^ 0x80),
                    };
                }
                total_read += pairs * 2;
            }

            const samples_read = total_read / 2;
            self.bytes_read_pos += total_read;
            return samples_read;
        } else {
            const bytes_needed = frames_to_read * 4;
            var buf: [8192]u8 = undefined;
            var total_read: usize = 0;

            while (total_read < bytes_needed) {
                const chunk = @min(buf.len, bytes_needed - total_read);
                const n = try self.file.readAll(buf[0..chunk]);
                if (n == 0) break;

                const aligned = (n / 4) * 4;
                const frames = aligned / 4;
                for (0..frames) |j| {
                    const idx = total_read / 4 + j;
                    const offset = j * 4;
                    const i_val = std.mem.readInt(i16, buf[offset..][0..2], .little);
                    const q_val = std.mem.readInt(i16, buf[offset + 2 ..][0..2], .little);
                    dest[idx] = .{
                        .i = @intCast(i_val >> 8),
                        .q = @intCast(q_val >> 8),
                    };
                }
                total_read += frames * 4;
            }

            const samples_read = total_read / 4;
            self.bytes_read_pos += total_read;
            return samples_read;
        }
    }

    pub fn seekToSample(self: *WavReader, index: u64) !void {
        const byte_offset = index * self.bytes_per_frame;
        try self.file.seekTo(self.data_offset + byte_offset);
        self.bytes_read_pos = byte_offset;
    }

    pub fn close(self: *WavReader) void {
        self.file.close();
    }
};
