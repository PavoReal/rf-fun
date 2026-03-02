const std = @import("std");
const hackrf = @import("rf_fun");

pub const WavInfo = struct {
    sample_rate: u32,
    bits_per_sample: u16,
    num_samples: usize,
};

pub const WavReadError = error{
    InvalidRiff,
    InvalidWave,
    FormatNotFound,
    DataNotFound,
    UnsupportedFormat,
    UnsupportedChannels,
    UnsupportedBitDepth,
};

pub fn readWav(path: []const u8, alloc: std.mem.Allocator) (WavReadError || std.fs.File.OpenError || std.mem.Allocator.Error || error{EndOfStream})!struct { samples: []hackrf.IQSample, info: WavInfo } {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var read_buf: [8192]u8 = undefined;
    var fr = file.reader(&read_buf);
    const reader = &fr.interface;

    var riff_id: [4]u8 = undefined;
    _ = try reader.readAll(&riff_id);
    if (!std.mem.eql(u8, &riff_id, "RIFF")) return WavReadError.InvalidRiff;
    _ = try reader.readInt(u32, .little);
    var wave_id: [4]u8 = undefined;
    _ = try reader.readAll(&wave_id);
    if (!std.mem.eql(u8, &wave_id, "WAVE")) return WavReadError.InvalidWave;

    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var num_channels: u16 = 0;
    var found_fmt = false;

    var data_size: u32 = 0;
    var found_data = false;

    while (true) {
        var chunk_id: [4]u8 = undefined;
        reader.readAll(&chunk_id) catch break;
        const chunk_size = reader.readInt(u32, .little) catch break;

        if (std.mem.eql(u8, &chunk_id, "fmt ")) {
            const audio_format = try reader.readInt(u16, .little);
            if (audio_format != 1) return WavReadError.UnsupportedFormat;
            num_channels = try reader.readInt(u16, .little);
            if (num_channels != 2) return WavReadError.UnsupportedChannels;
            sample_rate = try reader.readInt(u32, .little);
            _ = try reader.readInt(u32, .little);
            _ = try reader.readInt(u16, .little);
            bits_per_sample = try reader.readInt(u16, .little);
            if (bits_per_sample != 8 and bits_per_sample != 16) return WavReadError.UnsupportedBitDepth;
            if (chunk_size > 16) {
                try reader.skipBytes(chunk_size - 16, .{});
            }
            found_fmt = true;
        } else if (std.mem.eql(u8, &chunk_id, "data")) {
            data_size = chunk_size;
            found_data = true;
            break;
        } else {
            try reader.skipBytes(chunk_size, .{});
        }
    }

    if (!found_fmt) return WavReadError.FormatNotFound;
    if (!found_data) return WavReadError.DataNotFound;

    const bytes_per_sample: u32 = @as(u32, bits_per_sample) / 8;
    const block_align: u32 = @as(u32, num_channels) * bytes_per_sample;
    const num_samples: usize = @intCast(data_size / block_align);

    const samples = try alloc.alloc(hackrf.IQSample, num_samples);
    errdefer alloc.free(samples);

    for (samples) |*s| {
        if (bits_per_sample == 8) {
            const i_byte = try reader.readByte();
            const q_byte = try reader.readByte();
            s.i = @bitCast(i_byte ^ 0x80);
            s.q = @bitCast(q_byte ^ 0x80);
        } else {
            const i_val = try reader.readInt(i16, .little);
            const q_val = try reader.readInt(i16, .little);
            s.i = @intCast(i_val >> 8);
            s.q = @intCast(q_val >> 8);
        }
    }

    return .{
        .samples = samples,
        .info = .{
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .num_samples = num_samples,
        },
    };
}
