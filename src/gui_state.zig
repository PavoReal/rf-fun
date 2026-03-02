const std = @import("std");
const SpectrumAnalyzer = @import("spectrum_analyzer.zig").SpectrumAnalyzer;
const RadioDecoder = @import("radio_decoder.zig").RadioDecoder;
const StatsWindow = @import("stats_window.zig").StatsWindow;

pub const GuiState = struct {
    spec_fft_size_index: i32 = 6,
    spec_window_index: i32 = 3,
    spec_avg_count: i32 = 2,
    spec_peak_hold_enabled: bool = false,
    spec_peak_decay_rate: f32 = 1.6,
    spec_dc_filter_enabled: bool = false,
    spec_wf_db_min: f32 = -120.0,
    spec_wf_db_max: f32 = 0.0,

    radio_volume: f32 = 0.5,
    radio_modulation_index: i32 = 0,
    radio_deemphasis_index: i32 = 0,
    radio_squelch_threshold: f32 = 0.0,
    radio_squelch_auto: bool = true,
    radio_squelch_mode_index: i32 = 0,
    radio_dsp_rate: i32 = 30,
    radio_scan_hold: f32 = 2.0,
    radio_scan_speed: f32 = 0.250,
    radio_scan_require_tone: bool = false,
    radio_show_activity_log: bool = false,

    theme_index: i32 = 0,
    font_size: f32 = 13.0,
    stats_num_peaks: i32 = 0,

    pub fn save(self: *const GuiState) void {
        const file = std.fs.cwd().createFile("gui.ini", .{}) catch return;
        defer file.close();
        var write_buf: [4096]u8 = undefined;
        var w = file.writer(&write_buf);
        const iw = &w.interface;
        inline for (@typeInfo(GuiState).@"struct".fields) |field| {
            const val = @field(self, field.name);
            if (field.type == f32) {
                iw.print("{s}={d:.6}\n", .{ field.name, val }) catch return;
            } else if (field.type == i32) {
                iw.print("{s}={d}\n", .{ field.name, val }) catch return;
            } else if (field.type == bool) {
                iw.print("{s}={}\n", .{ field.name, val }) catch return;
            }
        }
        iw.flush() catch {};
    }

    pub fn load(self: *GuiState) void {
        const file = std.fs.cwd().openFile("gui.ini", .{}) catch return;
        defer file.close();
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);
        const ir = &reader.interface;
        while (ir.takeDelimiter('\n') catch null) |line_raw| {
            const trimmed = std.mem.trimRight(u8, line_raw, "\r");
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = trimmed[0..eq];
            const val = trimmed[eq + 1 ..];

            inline for (@typeInfo(GuiState).@"struct".fields) |field| {
                if (std.mem.eql(u8, key, field.name)) {
                    if (field.type == f32) {
                        @field(self, field.name) = std.fmt.parseFloat(f32, val) catch @field(self, field.name);
                    } else if (field.type == i32) {
                        @field(self, field.name) = std.fmt.parseInt(i32, val, 10) catch @field(self, field.name);
                    } else if (field.type == bool) {
                        @field(self, field.name) = std.mem.eql(u8, val, "true");
                    }
                }
            }
        }
    }

    pub fn collect(self: *GuiState, analyzer: *SpectrumAnalyzer, decoder: *RadioDecoder, stats: *StatsWindow) void {
        self.spec_fft_size_index = analyzer.fft_size_index;
        self.spec_window_index = analyzer.window_index;
        self.spec_avg_count = analyzer.avg_count;
        self.spec_peak_hold_enabled = analyzer.peak_hold_enabled;
        self.spec_peak_decay_rate = analyzer.peak_decay_rate;
        self.spec_dc_filter_enabled = analyzer.dc_filter_enabled;
        self.spec_wf_db_min = analyzer.waterfall.db_min;
        self.spec_wf_db_max = analyzer.waterfall.db_max;

        self.radio_volume = decoder.ui_volume;
        self.radio_modulation_index = decoder.ui_modulation_index;
        self.radio_deemphasis_index = decoder.ui_deemphasis_index;
        self.radio_squelch_threshold = decoder.ui_squelch_threshold;
        self.radio_squelch_auto = decoder.ui_squelch_auto;
        self.radio_squelch_mode_index = decoder.ui_squelch_mode_index;
        self.radio_dsp_rate = decoder.ui_dsp_rate;
        self.radio_scan_hold = decoder.ui_scan_hold;
        self.radio_scan_speed = decoder.ui_scan_speed;
        self.radio_scan_require_tone = decoder.ui_scan_require_tone;
        self.radio_show_activity_log = decoder.ui_show_activity_log;

        self.stats_num_peaks = @intCast(stats.num_display_peaks);
    }
};
