const std = @import("std");
const zgui = @import("zgui");
const ps = @import("dsp/pipeline_stats.zig");
const signal_stats = @import("signal_stats.zig");
const SignalStats = signal_stats.SignalStats;
const MAX_PEAKS = signal_stats.MAX_PEAKS;

const GREEN = [4]f32{ 0.2, 1.0, 0.2, 1.0 };
const YELLOW = [4]f32{ 1.0, 0.9, 0.2, 1.0 };
const RED = [4]f32{ 1.0, 0.3, 0.3, 1.0 };
const GRAY = [4]f32{ 0.5, 0.5, 0.5, 1.0 };
const WHITE = [4]f32{ 1.0, 1.0, 1.0, 1.0 };

fn healthColor(value: f32, warn_thresh: f32, crit_thresh: f32) [4]f32 {
    if (value >= crit_thresh) return RED;
    if (value >= warn_thresh) return YELLOW;
    return GREEN;
}

pub const BufferSnapshot = struct {
    count: usize = 0,
    capacity: usize = 0,
    total_written: usize = 0,
    rx_bytes: u64 = 0,
};

pub const SystemSnapshot = struct {
    fps: f32 = 0,
    buf: BufferSnapshot = .{},
    sample_rate: f64 = 0,
    sdr_connected: bool = false,
    radio_enabled: bool = false,
    squelch_open: bool = false,
    audio_underruns: u64 = 0,
    channel_monitor_enabled: bool = false,
    channel_count: u8 = 0,
};

pub const PipelineInfo = struct {
    name: [:0]const u8,
    pipeline: ps.PipelineView,
    thread_stats: *const ps.ThreadStats,
    dsp_rate: ?f32,
    overrun_count: u64 = 0,
    latency_ms: ?f32 = null,
};

const FRAME_HISTORY = 120;

pub const StatsWindow = struct {
    num_display_peaks: usize = 0,

    frame_times: [FRAME_HISTORY]f32 = [_]f32{0} ** FRAME_HISTORY,
    frame_time_head: usize = 0,

    prev_rx_bytes: u64 = 0,
    prev_time_ns: i128 = 0,
    throughput_mbps: f32 = 0,

    pub fn render(
        self: *StatsWindow,
        pipelines: []const PipelineInfo,
        stats: *const SignalStats,
        has_data: bool,
        sys: SystemSnapshot,
    ) void {
        if (zgui.begin("Stats###Stats", .{})) {
            if (zgui.beginTabBar("stats_tabs", .{})) {
                defer zgui.endTabBar();
                if (zgui.beginTabItem("Overview", .{ .flags = .{ .set_selected = false } })) {
                    defer zgui.endTabItem();
                    self.renderOverview(pipelines, sys);
                }
                if (zgui.beginTabItem("Signal Info", .{})) {
                    defer zgui.endTabItem();
                    self.renderSignalInfo(stats, has_data);
                }
                if (zgui.beginTabItem("Pipeline", .{})) {
                    defer zgui.endTabItem();
                    renderPipelines(pipelines);
                }
            }
        }
        zgui.end();
    }

    fn renderOverview(self: *StatsWindow, pipelines: []const PipelineInfo, sys: SystemSnapshot) void {
        self.updateFrameTime(sys.fps);
        self.updateThroughput(sys.buf.rx_bytes);

        zgui.separatorText("Status");
        self.renderStatusRow(pipelines, sys);

        zgui.separatorText("Metrics");
        self.renderMetrics(pipelines, sys);

        zgui.separatorText("Frame Time");
        self.renderSparkline();
    }

    fn updateFrameTime(self: *StatsWindow, fps: f32) void {
        const frame_ms: f32 = if (fps > 0) 1000.0 / fps else 0;
        self.frame_times[self.frame_time_head] = frame_ms;
        self.frame_time_head = (self.frame_time_head + 1) % FRAME_HISTORY;
    }

    fn updateThroughput(self: *StatsWindow, rx_bytes: u64) void {
        const now_ns = std.time.nanoTimestamp();
        if (self.prev_time_ns == 0) {
            self.prev_time_ns = now_ns;
            self.prev_rx_bytes = rx_bytes;
            return;
        }

        const elapsed_ns = now_ns - self.prev_time_ns;
        if (elapsed_ns >= 250_000_000) {
            const delta_bytes = rx_bytes -% self.prev_rx_bytes;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
            self.throughput_mbps = @floatCast(@as(f64, @floatFromInt(delta_bytes)) / elapsed_s / 1e6);
            self.prev_rx_bytes = rx_bytes;
            self.prev_time_ns = now_ns;
        }
    }

    fn renderStatusRow(self: *StatsWindow, pipelines: []const PipelineInfo, sys: SystemSnapshot) void {
        _ = self;

        if (sys.sdr_connected) {
            zgui.textColored(GREEN, "[OK] HackRF", .{});
        } else {
            zgui.textColored(RED, "[--] HackRF", .{});
        }

        zgui.sameLine(.{ .spacing = 16 });

        if (pipelines.len > 0) {
            const spec_busy = busyPct(pipelines[0].thread_stats);
            const spec_col = healthColor(spec_busy, 60, 85);
            const spec_label: [:0]const u8 = if (spec_busy >= 85) "[WARN] Spectrum" else "[OK] Spectrum";
            zgui.textColored(spec_col, "{s}", .{spec_label});
        }

        zgui.sameLine(.{ .spacing = 16 });

        if (sys.radio_enabled) {
            if (!sys.squelch_open) {
                zgui.textColored(YELLOW, "[SQ] Radio", .{});
            } else {
                zgui.textColored(GREEN, "[OK] Radio", .{});
            }
        } else {
            zgui.textColored(GRAY, "[--] Radio", .{});
        }

        zgui.sameLine(.{ .spacing = 16 });

        if (sys.audio_underruns == 0) {
            zgui.textColored(GREEN, "[OK] Audio", .{});
        } else if (sys.audio_underruns < 10) {
            zgui.textColored(YELLOW, "[WARN] Audio", .{});
        } else {
            zgui.textColored(RED, "[ERR] Audio", .{});
        }

        zgui.sameLine(.{ .spacing = 16 });

        if (sys.channel_monitor_enabled and sys.channel_count > 0) {
            zgui.textColored(GREEN, "[OK] Monitor ({d}ch)", .{sys.channel_count});
        } else if (sys.channel_monitor_enabled) {
            zgui.textColored(YELLOW, "[--] Monitor (0ch)", .{});
        } else {
            zgui.textColored(GRAY, "[--] Monitor", .{});
        }
    }

    fn renderMetrics(self: *StatsWindow, pipelines: []const PipelineInfo, sys: SystemSnapshot) void {
        const fps_col = if (sys.fps < 30) RED else WHITE;
        zgui.textColored(fps_col, "GUI FPS:     {d:.0}", .{sys.fps});

        if (sys.sdr_connected) {
            zgui.text("HackRF I/O:  {d:.1} MB/s", .{self.throughput_mbps});

        } else {
            zgui.textColored(GRAY, "HackRF I/O:  --", .{});
        }

        for (pipelines) |p| {
            const busy = busyPct(p.thread_stats);
            const busy_frac = busy / 100.0;
            const col = healthColor(busy, 60, 85);
            const rate_str = if (p.dsp_rate) |r| zgui.formatZ("{d:.0} Hz", .{r}) else zgui.formatZ("--", .{});

            zgui.text("{s}:", .{p.name});
            zgui.sameLine(.{});
            zgui.pushStyleColor4f(.{ .idx = .plot_histogram, .c = col });
            zgui.progressBar(.{ .fraction = busy_frac, .overlay = rate_str, .w = -1.0 });
            zgui.popStyleColor(.{ .count = 1 });

            if (p.overrun_count > 0) {
                zgui.sameLine(.{});
                zgui.textColored(RED, "OVR:{d}", .{p.overrun_count});
            }
        }

        if (sys.audio_underruns > 0) {
            zgui.textColored(RED, "Audio Underruns: {d}", .{sys.audio_underruns});
        } else {
            zgui.text("Audio Underruns: 0", .{});
        }
    }

    fn renderSparkline(self: *StatsWindow) void {
        var ordered: [FRAME_HISTORY]f32 = undefined;
        const head = self.frame_time_head;
        for (0..FRAME_HISTORY) |i| {
            ordered[i] = self.frame_times[(head + i) % FRAME_HISTORY];
        }

        const xs = comptime blk: {
            var arr: [FRAME_HISTORY]f32 = undefined;
            for (0..FRAME_HISTORY) |i| {
                arr[i] = @floatFromInt(i);
            }
            break :blk arr;
        };

        if (zgui.plot.beginPlot("##frame_sparkline", .{
            .w = -1.0,
            .h = 40,
            .flags = .{
                .no_title = true,
                .no_legend = true,
                .no_mouse_text = true,
                .no_inputs = true,
                .no_frame = true,
            },
        })) {
            const no_dec = zgui.plot.AxisFlags.no_decorations;
            zgui.plot.setupAxis(.x1, .{
                .flags = no_dec,
            });
            zgui.plot.setupAxis(.y1, .{
                .flags = @bitCast(@as(u32, @bitCast(no_dec)) | @as(u32, @bitCast(zgui.plot.AxisFlags{ .auto_fit = true }))),
            });
            zgui.plot.setupFinish();

            zgui.plot.plotLine("##ft", f32, .{
                .xv = &xs,
                .yv = &ordered,
            });

            zgui.plot.endPlot();
        }
    }

    fn renderSignalInfo(self: *StatsWindow, stats: *const SignalStats, has_data: bool) void {
        if (!has_data) {
            zgui.text("No data", .{});
            return;
        }

        const s = stats.*;

        zgui.separatorText("Overview");
        zgui.text("Noise Floor: {d:.1} dB", .{s.noise_floor_db});
        zgui.text("SNR:         {d:.1} dB", .{s.snr_db});

        zgui.separatorText("Top Peaks");

        if (zgui.smallButton("-")) {
            self.num_display_peaks -|= 1;
        }
        zgui.sameLine(.{});
        zgui.text("{d} Peaks", .{self.num_display_peaks});
        zgui.sameLine(.{});
        if (zgui.smallButton("+")) {
            if (self.num_display_peaks < MAX_PEAKS) {
                self.num_display_peaks += 1;
            }
        }

        if (self.num_display_peaks == 0) {
            zgui.text("No peak markers", .{});
            return;
        }

        const display_count = @min(self.num_display_peaks, s.num_peaks);
        if (display_count == 0) {
            zgui.text("No peaks detected", .{});
            return;
        }

        if (zgui.beginTable("peaks_table", .{
            .column = 5,
            .flags = .{ .borders = .{ .inner_h = true, .outer_h = true }, .row_bg = true, .sizing = .stretch_prop },
        })) {
            defer zgui.endTable();

            zgui.tableSetupColumn("#", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 24 });
            zgui.tableSetupColumn("Freq (MHz)", .{});
            zgui.tableSetupColumn("Power (dB)", .{});
            zgui.tableSetupColumn("Delta (dB)", .{});
            zgui.tableSetupColumn("SNR (dB)", .{});
            zgui.tableHeadersRow();

            for (0..display_count) |i| {
                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                zgui.text("{d}", .{i + 1});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.3}", .{s.peaks[i].freq_mhz});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.1}", .{s.peaks[i].power_db});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.1}", .{s.peaks[i].delta_db});
                _ = zgui.tableNextColumn();
                zgui.text("{d:.1}", .{s.peaks[i].snr_db});
            }
        }
    }

    fn renderPipelines(pipelines: []const PipelineInfo) void {
        for (pipelines) |pipeline| {
            zgui.pushStrId(pipeline.name);
            defer zgui.popId();

            const busy = busyPct(pipeline.thread_stats);
            const dot_col = healthColor(busy, 60, 85);
            zgui.textColored(dot_col, "\xe2\x97\x8f", .{});
            zgui.sameLine(.{});
            zgui.text("{s}", .{pipeline.name});

            if (pipeline.latency_ms) |lat| {
                zgui.sameLine(.{ .spacing = 16 });
                zgui.textColored(GRAY, "lat: {d:.1} ms", .{lat});
            }

            if (pipeline.overrun_count > 0) {
                zgui.sameLine(.{ .spacing = 16 });
                zgui.textColored(RED, "overruns: {d}", .{pipeline.overrun_count});
            }

            if (zgui.beginTable("stages", .{
                .column = 2,
                .flags = .{ .borders = .{ .inner_h = true, .outer_h = true }, .row_bg = true, .sizing = .stretch_prop },
            })) {
                defer zgui.endTable();

                zgui.tableSetupColumn("Stage", .{});
                zgui.tableSetupColumn("Time", .{});
                zgui.tableHeadersRow();

                for (0..pipeline.pipeline.stage_count) |i| {
                    zgui.tableNextRow(.{});
                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{pipeline.pipeline.labels[i]});
                    _ = zgui.tableNextColumn();
                    const ns = pipeline.pipeline.stage_ns[i].load(.acquire);
                    const us: f64 = @as(f64, @floatFromInt(ns)) / 1000.0;
                    zgui.text("{d:.1} us", .{us});
                }

                zgui.tableNextRow(.{});
                _ = zgui.tableNextColumn();
                zgui.textColored(.{ 1.0, 1.0, 0.4, 1.0 }, "Total", .{});
                _ = zgui.tableNextColumn();
                const total_ns = pipeline.pipeline.total_ns.load(.acquire);
                const total_us: f64 = @as(f64, @floatFromInt(total_ns)) / 1000.0;
                zgui.textColored(.{ 1.0, 1.0, 0.4, 1.0 }, "{d:.1} us", .{total_us});
            }

            zgui.text("Utilization: {d:.1}%%", .{busy});

            const iterations = pipeline.thread_stats.iteration_count.load(.acquire);
            zgui.text("Iterations:  {d}", .{iterations});

            if (pipeline.dsp_rate) |rate| {
                zgui.text("Refresh Rate:    {d:.1} Hz", .{rate});
            } else {
                zgui.text("Refresh Rate:    --", .{});
            }
        }
    }

    fn busyPct(ts: *const ps.ThreadStats) f32 {
        const raw = ts.busy_pct.load(.acquire);
        return @as(f32, @floatFromInt(raw)) / 100.0;
    }
};
