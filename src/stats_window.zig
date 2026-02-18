const std = @import("std");
const zgui = @import("zgui");
const ps = @import("dsp/pipeline_stats.zig");
const signal_stats = @import("signal_stats.zig");
const SignalStats = signal_stats.SignalStats;
const MAX_PEAKS = signal_stats.MAX_PEAKS;

pub const PipelineInfo = struct {
    name: [:0]const u8,
    pipeline: ps.PipelineView,
    thread_stats: *const ps.ThreadStats,
    dsp_rate: ?f32,
};

pub const StatsWindow = struct {
    num_display_peaks: usize = 0,

    pub fn render(
        self: *StatsWindow,
        pipelines: []const PipelineInfo,
        stats: *const SignalStats,
        has_data: bool,
    ) void {
        if (zgui.begin("Stats###Stats", .{})) {
            if (zgui.beginTabBar("stats_tabs", .{})) {
                defer zgui.endTabBar();
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

            zgui.separatorText(pipeline.name);

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

            const busy_raw = pipeline.thread_stats.busy_pct.load(.acquire);
            const busy: f64 = @as(f64, @floatFromInt(busy_raw)) / 100.0;
            zgui.text("Utilization: {d:.2}%%", .{busy});

            const iterations = pipeline.thread_stats.iteration_count.load(.acquire);
            zgui.text("Iterations:  {d}", .{iterations});

            if (pipeline.dsp_rate) |rate| {
                zgui.text("DSP Rate:    {d:.1} Hz", .{rate});
            } else {
                zgui.text("DSP Rate:    --", .{});
            }
        }
    }
};
