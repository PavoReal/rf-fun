const std = @import("std");
const zgui = @import("zgui");
const hackrf = @import("rf_fun");
const HackRFConfig = @import("hackrf_config.zig").HackRFConfig;

pub const FreqWidget = struct {
    freq_hz: u64 = 100_000_000,
    hovered_digit: i32 = -1,
    widget_hovered: bool = false,
    pending_scroll: f32 = 0,
    prev_freq_hz: u64 = 0,
    large_font: zgui.Font,

    const MIN_FREQ_HZ: u64 = 1_000_000;
    const MAX_FREQ_HZ: u64 = 6_000_000_000;
    const NUM_DIGITS: usize = 10;

    const FONT_SCALE: f32 = 4.0;

    const pow10 = [NUM_DIGITS]u64{
        1, 10, 100, 1_000, 10_000,
        100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
    };

    pub fn init(cf_mhz: f32, large_font: zgui.Font) FreqWidget {
        return .{
            .freq_hz = mhzToHz(cf_mhz),
            .prev_freq_hz = mhzToHz(cf_mhz),
            .large_font = large_font,
        };
    }

    pub fn feedScrollDelta(self: *FreqWidget, delta_y: f32) void {
        self.pending_scroll += delta_y;
    }

    pub fn getBarHeight() f32 {
        const base = zgui.getStyle().font_size_base;
        const label_h = base + 2.0;
        const digit_h = base * FONT_SCALE;
        const arrow_h = digit_h * 0.3;
        const cell_h = arrow_h + digit_h + arrow_h;
        return label_h + cell_h + 16.0;
    }

    pub fn render(self: *FreqWidget, config: *HackRFConfig, device: ?hackrf.Device) void {
        self.syncFromConfig(config);

        const base_size = zgui.getStyle().font_size_base;
        const font_size = base_size * FONT_SCALE;

        zgui.pushFont(self.large_font, font_size);
        const digit_metrics = zgui.calcTextSize("0", .{});
        zgui.popFont();

        const digit_w = digit_metrics[0];
        const digit_h = digit_metrics[1];
        const arrow_h = digit_h * 0.3;
        const pad_x: f32 = 3.0;
        const cell_w = digit_w + pad_x * 2.0;
        const cell_h = arrow_h + digit_h + arrow_h;
        const dot_w = digit_w * 0.5;

        const avail_h = zgui.getContentRegionAvail()[1];
        const y_offset = @max(0.0, (avail_h - cell_h) / 2.0);

        const draw_list = zgui.getWindowDrawList();
        const cursor_start = zgui.getCursorScreenPos();
        const origin_x = cursor_start[0];
        const origin_y = cursor_start[1] + y_offset;

        const digits = getDigits(self.freq_hz);
        const leading = findLeadingDigit(digits);

        const text_color: u32 = 0xFF_FF_FF_FF;
        const dimmed_color: u32 = 0x4D_FF_FF_FF;
        const accent_bg: u32 = zgui.colorConvertFloat4ToU32(.{ 0.2, 0.5, 1.0, 0.25 });
        const arrow_color: u32 = 0xCC_FF_FF_FF;

        var x = origin_x;
        var new_hovered: i32 = -1;
        var any_hovered = false;

        var i_signed: i32 = NUM_DIGITS - 1;
        while (i_signed >= 0) : (i_signed -= 1) {
            const i: usize = @intCast(i_signed);

            if (i == 8 or i == 5 or i == 2) {
                const dot_y = origin_y + arrow_h;
                zgui.pushFont(self.large_font, font_size);
                draw_list.addTextUnformatted(
                    .{ x + dot_w * 0.15, dot_y },
                    dimmed_color,
                    ".",
                );
                zgui.popFont();
                x += dot_w;
            }

            const cell_x = x;
            const cell_y = origin_y;

            zgui.setCursorScreenPos(.{ cell_x, cell_y });
            zgui.pushIntId(@intCast(i_signed));
            _ = zgui.invisibleButton("##digit", .{ .w = cell_w, .h = cell_h });

            const hovered = zgui.isItemHovered(.{});
            if (hovered) {
                new_hovered = i_signed;
                any_hovered = true;

                draw_list.addRectFilled(.{
                    .pmin = .{ cell_x, cell_y },
                    .pmax = .{ cell_x + cell_w, cell_y + cell_h },
                    .col = accent_bg,
                    .rounding = 3.0,
                });

                const arrow_cx = cell_x + cell_w / 2.0;
                const arrow_half_w = cell_w * 0.25;

                draw_list.addTriangleFilled(.{
                    .p1 = .{ arrow_cx, cell_y + 2.0 },
                    .p2 = .{ arrow_cx - arrow_half_w, cell_y + arrow_h - 2.0 },
                    .p3 = .{ arrow_cx + arrow_half_w, cell_y + arrow_h - 2.0 },
                    .col = arrow_color,
                });

                const bot_arrow_top = cell_y + arrow_h + digit_h + 2.0;
                draw_list.addTriangleFilled(.{
                    .p1 = .{ arrow_cx, cell_y + cell_h - 2.0 },
                    .p2 = .{ arrow_cx - arrow_half_w, bot_arrow_top },
                    .p3 = .{ arrow_cx + arrow_half_w, bot_arrow_top },
                    .col = arrow_color,
                });

                if (zgui.isItemClicked(.left)) {
                    const mouse_y = zgui.getMousePos()[1];
                    const mid_y = cell_y + cell_h / 2.0;
                    if (mouse_y < mid_y) {
                        self.incrementDigit(i);
                    } else {
                        self.decrementDigit(i);
                    }
                }
            }

            zgui.popId();

            const digit_char: [1]u8 = .{'0' + digits[i]};
            const col = if (i > leading) dimmed_color else text_color;
            const text_x = cell_x + pad_x;
            const text_y = cell_y + arrow_h;

            zgui.pushFont(self.large_font, font_size);
            draw_list.addTextUnformatted(
                .{ text_x, text_y },
                col,
                &digit_char,
            );
            zgui.popFont();

            x += cell_w;
        }

        self.hovered_digit = new_hovered;
        self.widget_hovered = any_hovered;

        if (any_hovered and self.hovered_digit >= 0) {
            if (self.pending_scroll >= 1.0) {
                self.incrementDigit(@intCast(self.hovered_digit));
                self.pending_scroll -= 1.0;
            } else if (self.pending_scroll <= -1.0) {
                self.decrementDigit(@intCast(self.hovered_digit));
                self.pending_scroll += 1.0;
            }
        } else {
            self.pending_scroll = 0;
        }

        const total_w = x - origin_x;
        zgui.setCursorScreenPos(.{ cursor_start[0] + total_w, cursor_start[1] });

        self.syncToConfig(config, device);
    }

    fn getDigits(freq_hz: u64) [NUM_DIGITS]u8 {
        var digits: [NUM_DIGITS]u8 = undefined;
        var val = freq_hz;
        for (0..NUM_DIGITS) |i| {
            digits[i] = @intCast(val % 10);
            val /= 10;
        }
        return digits;
    }

    fn findLeadingDigit(digits: [NUM_DIGITS]u8) usize {
        var i: usize = NUM_DIGITS - 1;
        while (i > 0) : (i -= 1) {
            if (digits[i] != 0) return i;
        }
        return 0;
    }

    fn incrementDigit(self: *FreqWidget, idx: usize) void {
        self.freq_hz = @min(self.freq_hz +| pow10[idx], MAX_FREQ_HZ);
    }

    fn decrementDigit(self: *FreqWidget, idx: usize) void {
        self.freq_hz = @max(self.freq_hz -| pow10[idx], MIN_FREQ_HZ);
    }

    fn syncFromConfig(self: *FreqWidget, config: *const HackRFConfig) void {
        const config_hz = mhzToHz(config.cf_mhz);
        if (config_hz != self.prev_freq_hz) {
            self.freq_hz = config_hz;
            self.prev_freq_hz = config_hz;
        }
    }

    fn syncToConfig(self: *FreqWidget, config: *HackRFConfig, device: ?hackrf.Device) void {
        if (self.freq_hz != self.prev_freq_hz) {
            self.prev_freq_hz = self.freq_hz;
            config.cf_mhz = hzToMhz(self.freq_hz);
            config.freq_changed = true;
            if (device) |dev| {
                dev.setFreq(self.freq_hz) catch {};
            }
        }
    }

    fn mhzToHz(mhz: f32) u64 {
        const val: f64 = @floatCast(mhz);
        return @intFromFloat(@round(val * 1_000_000.0));
    }

    fn hzToMhz(hz: u64) f32 {
        const val: f64 = @floatFromInt(hz);
        return @floatCast(val / 1_000_000.0);
    }
};
