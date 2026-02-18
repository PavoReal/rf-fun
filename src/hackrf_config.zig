const std = @import("std");
const hackrf = @import("rf_fun");
const zgui = @import("zgui");

pub const sample_rate_values = [_]f64{ 2e6, 4e6, 8e6, 10e6, 16e6, 20e6 };
pub const sample_rate_labels: [:0]const u8 = "2 MHz\x004 MHz\x008 MHz\x0010 MHz\x0016 MHz\x0020 MHz\x00";

const bb_filter_values = [_]u32{
    1750000,  2500000,  3500000,  5000000,
    5500000,  6000000,  7000000,  8000000,
    9000000,  10000000, 12000000, 14000000,
    15000000, 20000000, 24000000, 28000000,
};
const bb_filter_labels: [:0]const u8 =
    "Auto\x001.75 MHz\x002.5 MHz\x003.5 MHz\x005 MHz\x005.5 MHz\x006 MHz\x00" ++
    "7 MHz\x008 MHz\x009 MHz\x0010 MHz\x0012 MHz\x0014 MHz\x00" ++
    "15 MHz\x0020 MHz\x0024 MHz\x0028 MHz\x00";

pub const HackRFConfig = struct {
    cf_mhz: f32 = 2400.0,
    sample_rate_index: i32 = 5,
    bb_filter_index: i32 = 0,

    lna_gain: i32 = 0,
    vga_gain: i32 = 0,
    amp_enable: bool = false,

    clkout_enable: bool = false,
    hw_sync: bool = false,
    ui_enable: bool = true,
    rx_overrun_limit: i32 = 0,

    board_name: ?[:0]const u8 = null,
    board_rev_name: ?[:0]const u8 = null,
    usb_api_version: ?u16 = null,
    part_id_serial: ?hackrf.PartIdSerialNo = null,
    clkin_status: ?u8 = null,
    transfer_buffer_size: ?usize = null,
    transfer_queue_depth: ?u32 = null,
    version_str: [256]u8 = std.mem.zeroes([256]u8),
    version_len: usize = 0,

    freq_changed: bool = false,
    sample_rate_changed: bool = false,
    connect_requested: bool = false,
    disconnect_requested: bool = false,
    connect_error_msg: ?[]const u8 = null,

    reset_layout_requested: bool = false,
    theme_index: i32 = 0,

    pub fn cfHz(self: *const HackRFConfig) u64 {
        return @intFromFloat(self.cf_mhz * 1e6);
    }

    pub fn fsHz(self: *const HackRFConfig) f64 {
        return sample_rate_values[@intCast(self.sample_rate_index)];
    }

    pub fn readDeviceInfo(self: *HackRFConfig, device: hackrf.Device) void {
        if (device.boardIdRead()) |bid| {
            self.board_name = bid.name();
        } else |_| {}

        if (device.boardRevRead()) |rev| {
            self.board_rev_name = rev.name();
        } else |_| {}

        if (device.usbApiVersionRead()) |ver| {
            self.usb_api_version = ver;
        } else |_| {}

        if (device.boardPartIdSerialNoRead()) |info| {
            self.part_id_serial = info;
        } else |_| {}

        if (device.getClkinStatus()) |status| {
            self.clkin_status = status;
        } else |_| {}

        self.transfer_buffer_size = device.getTransferBufferSize();
        self.transfer_queue_depth = device.getTransferQueueDepth();

        _ = device.versionStringRead(&self.version_str) catch {};
        self.version_len = std.mem.indexOfScalar(u8, &self.version_str, 0) orelse 0;
    }

    pub fn clearDeviceInfo(self: *HackRFConfig) void {
        self.board_name = null;
        self.board_rev_name = null;
        self.usb_api_version = null;
        self.part_id_serial = null;
        self.clkin_status = null;
        self.transfer_buffer_size = null;
        self.transfer_queue_depth = null;
        self.version_str = std.mem.zeroes([256]u8);
        self.version_len = 0;
    }

    pub fn applyAll(self: *HackRFConfig, device: hackrf.Device) void {
        device.setSampleRate(self.fsHz()) catch {};
        if (self.bb_filter_index > 0) {
            device.setBasebandFilterBandwidth(bb_filter_values[@intCast(self.bb_filter_index - 1)]) catch {};
        }
        device.setFreq(self.cfHz()) catch {};
        device.setLnaGain(@intCast(self.lna_gain)) catch {};
        device.setVgaGain(@intCast(self.vga_gain)) catch {};
        device.setAmpEnable(self.amp_enable) catch {};
        device.setAntennaEnable(false) catch {};
        device.setClkoutEnable(self.clkout_enable) catch {};
        device.setHwSyncMode(self.hw_sync) catch {};
        device.setUiEnable(self.ui_enable) catch {};
        device.setRxOverrunLimit(@intCast(self.rx_overrun_limit)) catch {};
    }

    pub fn render(self: *HackRFConfig, device: ?hackrf.Device) void {
        zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 340, .h = 650, .cond = .first_use_ever });

        if (!zgui.begin("HackRF Config###HackRF Config", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        if (zgui.beginTabBar("ConfigTabs", .{})) {
            if (zgui.beginTabItem("HackRF", .{})) {
                self.renderHackRFTab(device);
                zgui.endTabItem();
            }
            if (zgui.beginTabItem("GUI", .{})) {
                self.renderGuiTab();
                zgui.endTabItem();
            }
            zgui.endTabBar();
        }
    }

    fn renderHackRFTab(self: *HackRFConfig, device: ?hackrf.Device) void {
        if (device != null) {
            if (zgui.button("Disconnect", .{})) {
                self.disconnect_requested = true;
            }
        } else {
            if (zgui.button("Connect", .{})) {
                self.connect_requested = true;
            }
        }

        if (self.connect_error_msg) |msg| {
            zgui.textColored(.{ 0.9, 0.1, 0.1, 1 }, "Error: {s}", .{msg});
        }

        if (self.version_len > 0) {
            zgui.text("Firmware: {s}", .{self.version_str[0..self.version_len]});
        }

        if (zgui.collapsingHeader("Device Info", .{})) {
            if (device == null) {
                zgui.text("Not connected", .{});
            } else {
                if (self.board_name) |name| {
                    zgui.text("Board: {s}", .{name});
                }
                if (self.board_rev_name) |name| {
                    zgui.text("Revision: {s}", .{name});
                }
                if (self.part_id_serial) |info| {
                    zgui.text("Serial: {x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{
                        info.serial_no[0], info.serial_no[1],
                        info.serial_no[2], info.serial_no[3],
                    });
                }
                if (self.usb_api_version) |ver| {
                    zgui.text("USB API: 0x{x:0>4}", .{ver});
                }
                if (self.clkin_status) |status| {
                    zgui.text("CLKIN: {s}", .{if (status != 0) "detected" else "not detected"});
                }
                if (self.transfer_buffer_size) |size| {
                    zgui.text("Transfer buf: {d} bytes", .{size});
                }
                if (self.transfer_queue_depth) |depth| {
                    zgui.text("Queue depth: {d}", .{depth});
                }
            }
        }

        const disabled = device == null;
        if (disabled) zgui.beginDisabled(.{});

        zgui.separatorText("RF Configuration");

        if (zgui.sliderFloat("Center Freq (MHz)", .{ .v = &self.cf_mhz, .min = 1.0, .max = 6000.0 })) {
            self.freq_changed = true;
            if (device) |dev| {
                dev.setFreq(self.cfHz()) catch {};
            }
        }

        if (zgui.combo("Sample Rate", .{
            .current_item = &self.sample_rate_index,
            .items_separated_by_zeros = sample_rate_labels,
        })) {
            self.sample_rate_changed = true;
            if (device) |dev| {
                dev.setSampleRate(self.fsHz()) catch {};
                if (self.bb_filter_index > 0) {
                    dev.setBasebandFilterBandwidth(bb_filter_values[@intCast(self.bb_filter_index - 1)]) catch {};
                }
            }
        }

        if (zgui.combo("BB Filter BW", .{
            .current_item = &self.bb_filter_index,
            .items_separated_by_zeros = bb_filter_labels,
        })) {
            if (device) |dev| {
                if (self.bb_filter_index > 0) {
                    dev.setBasebandFilterBandwidth(bb_filter_values[@intCast(self.bb_filter_index - 1)]) catch {};
                } else {
                    dev.setSampleRate(self.fsHz()) catch {};
                }
            }
        }

        zgui.separatorText("RX Gain");

        if (zgui.sliderInt("LNA (dB)", .{ .v = &self.lna_gain, .min = 0, .max = 40 })) {
            self.lna_gain = @divTrunc(self.lna_gain + 4, 8) * 8;
            self.lna_gain = std.math.clamp(self.lna_gain, 0, 40);
            if (device) |dev| {
                dev.setLnaGain(@intCast(self.lna_gain)) catch {};
            }
        }

        if (zgui.sliderInt("VGA (dB)", .{ .v = &self.vga_gain, .min = 0, .max = 62 })) {
            self.vga_gain = @divTrunc(self.vga_gain + 1, 2) * 2;
            self.vga_gain = std.math.clamp(self.vga_gain, 0, 62);
            if (device) |dev| {
                dev.setVgaGain(@intCast(self.vga_gain)) catch {};
            }
        }

        if (zgui.checkbox("RF Amp (+14 dB)", .{ .v = &self.amp_enable })) {
            if (device) |dev| {
                dev.setAmpEnable(self.amp_enable) catch {};
            }
        }

        zgui.separatorText("Antenna & Clock");

        {
            zgui.beginDisabled(.{});
            var bias_tee = false;
            _ = zgui.checkbox("Bias Tee (3.3V)", .{ .v = &bias_tee });
            zgui.endDisabled();
            zgui.sameLine(.{});
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "(safety lock)", .{});
        }

        if (zgui.checkbox("Clock Output (10 MHz)", .{ .v = &self.clkout_enable })) {
            if (device) |dev| {
                dev.setClkoutEnable(self.clkout_enable) catch {};
            }
        }

        zgui.separatorText("Advanced");

        if (zgui.checkbox("HW Sync Mode", .{ .v = &self.hw_sync })) {
            if (device) |dev| {
                dev.setHwSyncMode(self.hw_sync) catch {};
            }
        }

        if (zgui.checkbox("Device UI", .{ .v = &self.ui_enable })) {
            if (device) |dev| {
                dev.setUiEnable(self.ui_enable) catch {};
            }
        }

        if (zgui.sliderInt("RX Overrun Limit", .{ .v = &self.rx_overrun_limit, .min = 0, .max = 100 })) {
            if (device) |dev| {
                dev.setRxOverrunLimit(@intCast(self.rx_overrun_limit)) catch {};
            }
        }

        if (disabled) zgui.endDisabled();
    }

    const theme_labels: [:0]const u8 = "Dark\x00Light\x00Classic\x00";

    fn renderGuiTab(self: *HackRFConfig) void {
        zgui.separatorText("Theme");

        if (zgui.combo("Theme", .{
            .current_item = &self.theme_index,
            .items_separated_by_zeros = theme_labels,
        })) {
            const style = zgui.getStyle();
            switch (self.theme_index) {
                0 => style.setColorsBuiltin(.dark),
                1 => style.setColorsBuiltin(.light),
                2 => style.setColorsBuiltin(.classic),
                else => {},
            }
        }

        zgui.separatorText("Font");

        const style = zgui.getStyle();
        if (zgui.sliderFloat("Font Size", .{
            .v = &style.font_size_base,
            .min = 8.0,
            .max = 32.0,
        })) {
            style._next_frame_font_size_base = style.font_size_base;
        }

        zgui.separatorText("Layout");

        if (zgui.button("Reset Layout", .{})) {
            self.reset_layout_requested = true;
        }
    }
};
