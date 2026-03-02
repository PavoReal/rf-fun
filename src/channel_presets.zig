const std = @import("std");
const CtcssDetector = @import("dsp/ctcss_detector.zig").CtcssDetector;
const Golay23_12 = @import("dsp/golay.zig").Golay23_12;
const ModulationType = @import("radio_decoder.zig").ModulationType;

pub const PresetChannel = struct {
    number: u8,
    freq_mhz: f64,
    label: ?[:0]const u8 = null,
    modulation: ?ModulationType = null,
};

pub const PresetTable = struct {
    name: [:0]const u8,
    modulation: ModulationType = .nfm,
    channels: []const PresetChannel,
};

pub const ChannelCode = union(enum) {
    none,
    ctcss: u8,
    dcs_normal: u16,
    dcs_inverted: u16,
};

pub fn parseChannelCode(label: ?[:0]const u8) ChannelCode {
    const lbl = label orelse return .none;
    if (lbl.len == 0) return .none;

    if (lbl[0] == 'D' and lbl.len >= 4) {
        const suffix = lbl[lbl.len - 1];
        if (suffix == 'N' or suffix == 'I') {
            var code: u16 = 0;
            for (lbl[1 .. lbl.len - 1]) |ch| {
                if (ch < '0' or ch > '7') return .none;
                code = code * 8 + @as(u16, ch - '0');
            }
            if (Golay23_12.isStandardDcsCode(code)) {
                return if (suffix == 'I') .{ .dcs_inverted = code } else .{ .dcs_normal = code };
            }
            return .none;
        }
    }

    var freq: f32 = 0.0;
    var decimal_places: u8 = 0;
    var saw_dot = false;
    for (lbl) |ch| {
        if (ch == '.') {
            saw_dot = true;
        } else if (ch >= '0' and ch <= '9') {
            freq = freq * 10.0 + @as(f32, @floatFromInt(ch - '0'));
            if (saw_dot) decimal_places += 1;
        } else {
            return .none;
        }
    }
    var div: f32 = 1.0;
    for (0..decimal_places) |_| div *= 10.0;
    freq /= div;

    for (CtcssDetector.tone_freqs, 0..) |tone, i| {
        if (@abs(tone - freq) < 0.15) {
            return .{ .ctcss = @intCast(i) };
        }
    }
    return .none;
}

pub const frs_channels = [_]PresetChannel{
    .{ .number = 1, .freq_mhz = 462.5625 },
    .{ .number = 2, .freq_mhz = 462.5875 },
    .{ .number = 3, .freq_mhz = 462.6125 },
    .{ .number = 4, .freq_mhz = 462.6375 },
    .{ .number = 5, .freq_mhz = 462.6625 },
    .{ .number = 6, .freq_mhz = 462.6875 },
    .{ .number = 7, .freq_mhz = 462.7125 },
    .{ .number = 8, .freq_mhz = 467.5625 },
    .{ .number = 9, .freq_mhz = 467.5875 },
    .{ .number = 10, .freq_mhz = 467.6125 },
    .{ .number = 11, .freq_mhz = 467.6375 },
    .{ .number = 12, .freq_mhz = 467.6625 },
    .{ .number = 13, .freq_mhz = 467.6875 },
    .{ .number = 14, .freq_mhz = 467.7125 },
    .{ .number = 15, .freq_mhz = 462.5500 },
    .{ .number = 16, .freq_mhz = 462.5750 },
    .{ .number = 17, .freq_mhz = 462.6000 },
    .{ .number = 18, .freq_mhz = 462.6250 },
    .{ .number = 19, .freq_mhz = 462.6500 },
    .{ .number = 20, .freq_mhz = 462.6750 },
    .{ .number = 21, .freq_mhz = 462.7000 },
    .{ .number = 22, .freq_mhz = 462.7250 },
};

pub const h777_channels = [_]PresetChannel{
    .{ .number = 1, .freq_mhz = 462.5625, .label = "67.0" },
    .{ .number = 2, .freq_mhz = 462.5875, .label = "118.8" },
    .{ .number = 3, .freq_mhz = 462.6125, .label = "127.3" },
    .{ .number = 4, .freq_mhz = 462.6375, .label = "131.8" },
    .{ .number = 5, .freq_mhz = 462.6625, .label = "136.5" },
    .{ .number = 6, .freq_mhz = 462.6250, .label = "127.3" },
    .{ .number = 7, .freq_mhz = 462.7250, .label = "136.5" },
    .{ .number = 8, .freq_mhz = 462.6875, .label = "161.3" },
    .{ .number = 9, .freq_mhz = 462.7125, .label = "166.2" },
    .{ .number = 10, .freq_mhz = 462.5500, .label = "123.0" },
    .{ .number = 11, .freq_mhz = 462.5750, .label = "D743I" },
    .{ .number = 12, .freq_mhz = 462.6000, .label = "D332I" },
    .{ .number = 13, .freq_mhz = 462.6500, .label = "D245I" },
    .{ .number = 14, .freq_mhz = 462.6750, .label = "D606N" },
    .{ .number = 15, .freq_mhz = 462.7000, .label = "D731I" },
    .{ .number = 16, .freq_mhz = 462.7250, .label = "D462I" },
};

pub const preset_tables = [_]PresetTable{
    .{ .name = "FRS (Standard)", .channels = &frs_channels },
    .{ .name = "Retevis H777", .channels = &h777_channels },
};

pub const preset_labels: [:0]const u8 = "FRS (Standard)\x00Retevis H777\x00";
