const std = @import("std");
const hackrf = @import("rf_fun");

pub const IQSample = hackrf.IQSample;

pub fn writeWav(path: []const u8, sample_rate: u32, bits_per_sample: u16, samples: []const IQSample) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var write_buf: [8192]u8 = undefined;
    var fw = file.writer(&write_buf);
    const writer = &fw.interface;

    const num_channels: u16 = 2;
    const bytes_per_sample: u16 = bits_per_sample / 8;
    const block_align: u16 = num_channels * bytes_per_sample;
    const byte_rate: u32 = sample_rate * @as(u32, block_align);
    const data_size: u32 = @intCast(samples.len * @as(usize, block_align));

    try writer.writeAll("RIFF");
    try writer.writeInt(u32, 36 + data_size, .little);
    try writer.writeAll("WAVE");

    try writer.writeAll("fmt ");
    try writer.writeInt(u32, 16, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, num_channels, .little);
    try writer.writeInt(u32, sample_rate, .little);
    try writer.writeInt(u32, byte_rate, .little);
    try writer.writeInt(u16, block_align, .little);
    try writer.writeInt(u16, bits_per_sample, .little);

    try writer.writeAll("data");
    try writer.writeInt(u32, data_size, .little);

    for (samples) |s| {
        if (bits_per_sample == 8) {
            try writer.writeByte(@as(u8, @bitCast(s.i)) ^ 0x80);
            try writer.writeByte(@as(u8, @bitCast(s.q)) ^ 0x80);
        } else {
            try writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(i16, @as(i16, s.i) << 8)));
            try writer.writeAll(&std.mem.toBytes(std.mem.nativeToLittle(i16, @as(i16, s.q) << 8)));
        }
    }

    try writer.flush();
}
