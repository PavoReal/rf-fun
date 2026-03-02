const std = @import("std");
const zgui = @import("zgui");
const ChannelManager = @import("channel_manager.zig").ChannelManager;
const MAX_CHANNELS = @import("channel_manager.zig").MAX_CHANNELS;
const ChannelConfig = @import("channel.zig").ChannelConfig;
const ModulationType = @import("radio_decoder.zig").ModulationType;
const demod = @import("demod_profile.zig");
const presets = @import("channel_presets.zig");
const c = @import("radio_decoder.zig").c;

pub const ChannelStripUi = struct {
    preset_index: i32 = 0,
    show_add_popup: bool = false,
    add_freq_text: [16]u8 = undefined,
    add_mod_index: i32 = 2,

    pub fn render(self: *ChannelStripUi, mgr: *ChannelManager) void {
        if (!zgui.begin("Channel Monitor###Channel Monitor", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        var ui_enabled = mgr.isEnabled();
        if (zgui.checkbox("Enable Monitor", .{ .v = &ui_enabled })) {
            mgr.setEnabled(ui_enabled);
        }

        zgui.sameLine(.{});
        if (zgui.sliderFloat("Master###master_vol", .{
            .v = &mgr.master_volume,
            .min = 0.0,
            .max = 3.0,
        })) {
            if (mgr.output_stream) |stream| {
                _ = c.SDL_SetAudioStreamGain(stream, mgr.master_volume);
            }
        }

        zgui.sameLine(.{});
        var master_muted = mgr.master_muted;
        if (zgui.checkbox("Mute All", .{ .v = &master_muted })) {
            mgr.master_muted = master_muted;
        }

        zgui.sameLine(.{});
        _ = zgui.checkbox("Click Filter", .{ .v = &mgr.click_filter });

        if (zgui.sliderFloat("Squelch###global_sq", .{
            .v = &mgr.global_squelch_db,
            .min = -100.0,
            .max = 0.0,
            .cfmt = "%.0f dB",
        })) {
            mgr.setGlobalSquelch(mgr.global_squelch_db);
        }

        zgui.separator();

        zgui.text("Channels: {d}", .{mgr.active_count});
        zgui.sameLine(.{});

        _ = zgui.combo("Preset###ch_preset", .{
            .current_item = &self.preset_index,
            .items_separated_by_zeros = presets.preset_labels,
        });
        zgui.sameLine(.{});
        if (zgui.smallButton("Load Preset")) {
            mgr.loadPreset(@intCast(std.math.clamp(self.preset_index, 0, @as(i32, @intCast(presets.preset_tables.len - 1))))) catch {};
        }
        zgui.sameLine(.{});
        if (zgui.smallButton("Clear All")) {
            mgr.removeAllChannels();
        }

        zgui.separator();

        self.renderChannelTable(mgr);
    }

    fn renderChannelTable(_: *ChannelStripUi, mgr: *ChannelManager) void {
        if (zgui.beginTable("channel_strips", .{
            .column = 8,
            .flags = .{
                .borders = .{ .inner_h = true, .outer_h = true, .inner_v = true },
                .row_bg = true,
                .sizing = .stretch_prop,
                .scroll_y = true,
            },
            .outer_size = .{ 0.0, 0.0 },
        })) {
            defer zgui.endTable();

            zgui.tableSetupColumn("#", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 25 });
            zgui.tableSetupColumn("Label", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 60 });
            zgui.tableSetupColumn("Freq (MHz)", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 80 });
            zgui.tableSetupColumn("Mod", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 55 });
            zgui.tableSetupColumn("Signal", .{});
            zgui.tableSetupColumn("Volume", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 100 });
            zgui.tableSetupColumn("M/S", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 50 });
            zgui.tableSetupColumn("Squelch", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 100 });
            zgui.tableHeadersRow();

            for (&mgr.channels, 0..) |*slot, i| {
                const ch = &(slot.* orelse continue);

                zgui.tableNextRow(.{});

                const sq_open = ch.isSquelchOpen();
                if (sq_open and ch.enabled and !ch.config.muted) {
                    zgui.tableSetBgColor(.{
                        .target = .row_bg0,
                        .color = zgui.colorConvertFloat4ToU32(.{ 0.1, 0.35, 0.1, 0.4 }),
                    });
                }

                _ = zgui.tableNextColumn();
                zgui.text("{d}", .{i + 1});

                _ = zgui.tableNextColumn();
                const label = ch.config.labelSlice();
                if (label.len > 0) {
                    zgui.text("{s}", .{label});
                } else {
                    zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "---", .{});
                }

                _ = zgui.tableNextColumn();
                zgui.text("{d:.4}", .{ch.config.freq_mhz});

                _ = zgui.tableNextColumn();
                zgui.pushIntId(@intCast(i + 3000));
                var mod_index: i32 = @intCast(@intFromEnum(ch.config.modulation));
                if (zgui.combo("###mod", .{
                    .current_item = &mod_index,
                    .items_separated_by_zeros = demod.combo_labels,
                })) {
                    ch.requestModulationChange(@enumFromInt(@as(u8, @intCast(mod_index))));
                }
                zgui.popId();

                _ = zgui.tableNextColumn();
                const level_db = ch.signalLevelDb();
                const level_frac = std.math.clamp((level_db + 100.0) / 100.0, 0.0, 1.0);
                zgui.progressBar(.{ .fraction = level_frac, .overlay = "", .w = -1.0 });
                {
                    const draw_list = zgui.getWindowDrawList();
                    const bar_min = zgui.getItemRectMin();
                    const bar_max = zgui.getItemRectMax();
                    const bar_width = bar_max[0] - bar_min[0];
                    const thresh_frac = std.math.clamp((ch.config.squelch_db + 100.0) / 100.0, 0.0, 1.0);
                    const thresh_x = bar_min[0] + thresh_frac * bar_width;
                    draw_list.addLine(.{
                        .p1 = .{ thresh_x, bar_min[1] },
                        .p2 = .{ thresh_x, bar_max[1] },
                        .col = 0xE0_00_FFFF,
                        .thickness = 2.0,
                    });
                }

                _ = zgui.tableNextColumn();
                zgui.pushIntId(@intCast(i));
                _ = zgui.sliderFloat("###vol", .{
                    .v = &ch.config.volume,
                    .min = 0.0,
                    .max = 3.0,
                    .cfmt = "%.1f",
                });
                zgui.popId();

                _ = zgui.tableNextColumn();
                zgui.pushIntId(@intCast(i + 1000));
                _ = zgui.checkbox("M###mute", .{ .v = &ch.config.muted });
                zgui.sameLine(.{});
                _ = zgui.checkbox("S###solo", .{ .v = &ch.solo });
                zgui.popId();

                _ = zgui.tableNextColumn();
                zgui.pushIntId(@intCast(i + 2000));
                if (zgui.sliderFloat("###sq", .{
                    .v = &ch.config.squelch_db,
                    .min = -100.0,
                    .max = 0.0,
                    .cfmt = "%.0f",
                })) {
                    ch.worker.squelch_threshold = ch.config.squelch_db;
                }
                zgui.popId();
            }
        }
    }
};
