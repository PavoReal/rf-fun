const std = @import("std");
const hackrf = @import("rf_fun");
const zgui = @import("zgui");
const HackRFConfig = @import("hackrf_config.zig").HackRFConfig;
const FileSource = @import("file_source.zig").FileSource;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const RFSource = struct {
    source_type: i32 = 0,
    file_source: FileSource,

    dialog_pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    path_ready: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    dialog_path_buf: [1024]u8 = std.mem.zeroes([1024]u8),
    dialog_path_len: usize = 0,

    play_requested: bool = false,
    stop_requested: bool = false,
    source_changed: bool = false,
    prev_source_type: i32 = 0,

    fn dialogCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const self: *RFSource = @ptrCast(@alignCast(userdata));
        if (filelist == null or filelist[0] == null) {
            self.dialog_pending.store(0, .release);
            return;
        }
        const selected = std.mem.span(filelist[0]);
        const copy_len = @min(selected.len, self.dialog_path_buf.len - 1);
        @memcpy(self.dialog_path_buf[0..copy_len], selected[0..copy_len]);
        self.dialog_path_buf[copy_len] = 0;
        self.dialog_path_len = copy_len;
        self.path_ready.store(1, .release);
        self.dialog_pending.store(0, .release);
    }

    pub fn render(self: *RFSource, config: *HackRFConfig, device: ?hackrf.Device, sdl_window: *c.SDL_Window) void {
        if (!zgui.begin("RF Source###HackRF Config", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        const source_labels: [:0]const u8 = "HackRF\x00File\x00";
        if (zgui.combo("Source", .{
            .current_item = &self.source_type,
            .items_separated_by_zeros = source_labels,
        })) {
            if (self.source_type != self.prev_source_type) {
                self.source_changed = true;
                self.prev_source_type = self.source_type;
            }
        }
        zgui.separator();

        if (self.source_type == 0) {
            if (zgui.beginTabBar("ConfigTabs", .{})) {
                if (zgui.beginTabItem("HackRF", .{})) {
                    config.renderHackRFTab(device);
                    zgui.endTabItem();
                }
                if (zgui.beginTabItem("GUI", .{})) {
                    config.renderGuiTab();
                    zgui.endTabItem();
                }
                zgui.endTabBar();
            }
        } else {
            self.renderFileControls(sdl_window);
        }
    }

    fn renderFileControls(self: *RFSource, sdl_window: *c.SDL_Window) void {
        if (self.path_ready.load(.acquire) != 0) {
            self.path_ready.store(0, .release);
            self.file_source.loadFile(self.dialog_path_buf[0..self.dialog_path_len]);
        }

        {
            const browse_disabled = self.dialog_pending.load(.acquire) != 0;
            if (browse_disabled) zgui.beginDisabled(.{});
            if (zgui.button("Browse...", .{})) {
                self.dialog_pending.store(1, .release);
                const filter = c.SDL_DialogFileFilter{
                    .name = "WAV files",
                    .pattern = "wav",
                };
                c.SDL_ShowOpenFileDialog(dialogCallback, self, sdl_window, &filter, 1, null, false);
            }
            if (browse_disabled) zgui.endDisabled();
        }

        if (self.file_source.file_path_len > 0) {
            zgui.sameLine(.{});
            zgui.text("{s}", .{self.file_source.file_path[0..self.file_source.file_path_len]});
        } else {
            zgui.sameLine(.{});
            zgui.textDisabled("No file loaded", .{});
        }

        if (self.file_source.load_error) |err| {
            zgui.textColored(.{ 0.9, 0.1, 0.1, 1.0 }, "Load error: {s}", .{err});
        }

        zgui.separatorText("Center Frequency");

        _ = zgui.inputFloat("Center Freq (MHz)", .{
            .v = &self.file_source.center_freq_mhz,
            .step = 0.1,
            .step_fast = 1.0,
            .cfmt = "%.3f",
        });

        if (self.file_source.reader != null) {
            zgui.separatorText("File Info");

            zgui.text("Sample Rate: {d} Hz", .{self.file_source.sample_rate});
            zgui.text("Bits/Sample: {d}", .{self.file_source.bits_per_sample});
            zgui.text("Total Samples: {d}", .{self.file_source.total_samples});
            zgui.text("Duration: {d:.2}s", .{self.file_source.duration_secs});

            if (self.file_source.file_size_bytes > 0) {
                const size_mb = @as(f64, @floatFromInt(self.file_source.file_size_bytes)) / (1024.0 * 1024.0);
                zgui.text("File Size: {d:.1} MB", .{size_mb});
            }

            zgui.separatorText("Playback");

            const is_playing = self.file_source.isPlaying();

            if (is_playing) {
                if (zgui.button("Stop", .{})) {
                    self.stop_requested = true;
                }
            } else {
                if (zgui.button("Play", .{})) {
                    self.play_requested = true;
                }
            }

            zgui.sameLine(.{});
            var loop_val = self.file_source.looping.load(.acquire) != 0;
            if (zgui.checkbox("Loop", .{ .v = &loop_val })) {
                self.file_source.looping.store(if (loop_val) 1 else 0, .release);
            }

            const prog = self.file_source.progress();
            const elapsed = self.file_source.elapsedSecs();
            const overlay_buf = zgui.formatZ("{d:.1}s / {d:.1}s", .{ elapsed, self.file_source.duration_secs });
            zgui.progressBar(.{ .fraction = prog, .overlay = overlay_buf });

            if (self.file_source.preview_ready) {
                zgui.separatorText("Preview");

                if (zgui.plot.beginPlot("Waveform", .{ .w = -1.0, .h = 120.0, .flags = .{ .no_legend = true, .no_mouse_text = true } })) {
                    zgui.plot.setupAxis(.x1, .{ .label = "Sample", .flags = .{ .no_tick_labels = true } });
                    zgui.plot.setupAxis(.y1, .{ .label = "Amp" });
                    zgui.plot.setupAxisLimits(.y1, .{ .min = -1.0, .max = 1.0, .cond = .once });
                    zgui.plot.setupFinish();

                    zgui.plot.plotLineValues("I max", f32, .{ .v = &self.file_source.waveform_max_i });
                    zgui.plot.plotLineValues("I min", f32, .{ .v = &self.file_source.waveform_min_i });
                    zgui.plot.plotLineValues("Q max", f32, .{ .v = &self.file_source.waveform_max_q });
                    zgui.plot.plotLineValues("Q min", f32, .{ .v = &self.file_source.waveform_min_q });

                    zgui.plot.endPlot();
                }

                if (zgui.plot.beginPlot("Spectrum", .{ .w = -1.0, .h = 120.0, .flags = .{ .no_legend = true, .no_mouse_text = true } })) {
                    zgui.plot.setupAxis(.x1, .{ .label = "Bin", .flags = .{ .no_tick_labels = true } });
                    zgui.plot.setupAxis(.y1, .{ .label = "dB" });
                    zgui.plot.setupFinish();

                    zgui.plot.plotLineValues("Mag", f32, .{ .v = &self.file_source.spectrum_mag });

                    zgui.plot.endPlot();
                }
            }
        }
    }
};
