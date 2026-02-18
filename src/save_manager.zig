const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const wav_writer = @import("wav_writer.zig");
const HackRFConfig = @import("hackrf_config.zig").HackRFConfig;
const zgui = @import("zgui");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const SaveManager = struct {
    const Self = @This();

    path_buf: [1024]u8 = std.mem.zeroes([1024]u8),
    path_len: usize = 0,

    bits_per_sample_index: i32 = 0,

    status: enum { idle, saving, success, err } = .idle,
    status_msg: [256]u8 = undefined,
    status_msg_len: usize = 0,

    dialog_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    path_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn dialogCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata));

        if (filelist == null or filelist[0] == null) {
            self.dialog_pending.store(false, .release);
            return;
        }

        const selected = std.mem.span(filelist[0]);
        const copy_len = @min(selected.len, self.path_buf.len - 1);
        @memcpy(self.path_buf[0..copy_len], selected[0..copy_len]);
        self.path_buf[copy_len] = 0;
        self.path_len = copy_len;

        self.path_ready.store(true, .release);
        self.dialog_pending.store(false, .release);
    }

    pub fn render(self: *Self, sdr_mutex: ?*std.Thread.Mutex, rx_buffer: ?*FixedSizeRingBuffer(hackrf.IQSample), config: *const HackRFConfig, alloc: std.mem.Allocator, sdl_window: *c.SDL_Window) void {
        if (!zgui.begin("Save###Save", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        if (self.path_ready.load(.acquire)) {
            self.path_ready.store(false, .release);
        }

        // Path display
        if (self.path_len > 0) {
            zgui.text("File: {s}", .{self.path_buf[0..self.path_len]});
        } else {
            zgui.textDisabled("No file selected", .{});
        }

        // Browse button
        {
            const browse_disabled = self.dialog_pending.load(.acquire) or self.status == .saving;
            if (browse_disabled) zgui.beginDisabled(.{});
            if (zgui.button("Browse...", .{})) {
                self.dialog_pending.store(true, .release);
                const filter = c.SDL_DialogFileFilter{
                    .name = "WAV files",
                    .pattern = "wav",
                };
                c.SDL_ShowSaveFileDialog(dialogCallback, self, sdl_window, &filter, 1, null);
            }
            if (browse_disabled) zgui.endDisabled();
        }

        // Bit depth combo
        zgui.sameLine(.{});
        const bps_labels: [:0]const u8 = "8-bit PCM\x0016-bit PCM\x00";
        _ = zgui.combo("Bit Depth", .{
            .current_item = &self.bits_per_sample_index,
            .items_separated_by_zeros = bps_labels,
        });

        // Buffer info
        const has_sdr = rx_buffer != null;
        if (has_sdr) {
            const sample_count = rx_buffer.?.len();
            const bps: usize = if (self.bits_per_sample_index == 0) 8 else 16;
            const est_bytes = sample_count * 2 * (bps / 8);
            zgui.text("Samples: {d} | Est. size: {d:.1} MB", .{
                sample_count,
                @as(f64, @floatFromInt(est_bytes)) / (1024.0 * 1024.0),
            });
        } else {
            zgui.textDisabled("No device connected", .{});
        }

        // Save button
        {
            const empty_buffer = if (rx_buffer) |rb| rb.len() == 0 else true;
            const save_disabled = !has_sdr or self.path_len == 0 or
                self.dialog_pending.load(.acquire) or
                self.status == .saving or empty_buffer;
            if (save_disabled) zgui.beginDisabled(.{});
            if (zgui.button("Save", .{})) {
                self.save(sdr_mutex.?, rx_buffer.?, config, alloc);
            }
            if (save_disabled) zgui.endDisabled();
        }

        // Status
        switch (self.status) {
            .idle => {},
            .saving => {
                zgui.text("Saving...", .{});
            },
            .success => {
                zgui.textColored(.{ 0.1, 0.9, 0.1, 1.0 }, "{s}", .{self.status_msg[0..self.status_msg_len]});
            },
            .err => {
                zgui.textColored(.{ 0.9, 0.1, 0.1, 1.0 }, "{s}", .{self.status_msg[0..self.status_msg_len]});
            },
        }
    }

    fn save(self: *Self, mutex: *std.Thread.Mutex, rx_buffer: *FixedSizeRingBuffer(hackrf.IQSample), config: *const HackRFConfig, alloc: std.mem.Allocator) void {
        self.status = .saving;

        // Snapshot under lock
        mutex.lock();
        const s = rx_buffer.slices();
        const total = s.first.len + s.second.len;

        if (total == 0) {
            mutex.unlock();
            self.setStatus(.err, "Buffer is empty");
            return;
        }

        const snapshot = alloc.alloc(hackrf.IQSample, total) catch {
            mutex.unlock();
            self.setStatus(.err, "Out of memory for snapshot");
            return;
        };
        @memcpy(snapshot[0..s.first.len], s.first);
        @memcpy(snapshot[s.first.len..][0..s.second.len], s.second);
        mutex.unlock();
        defer alloc.free(snapshot);

        const sample_rate: u32 = @intFromFloat(config.fsHz());
        const bits_per_sample: u16 = if (self.bits_per_sample_index == 0) 8 else 16;

        // Ensure .wav extension
        var path = self.path_buf[0..self.path_len];
        var ext_buf: [1028]u8 = undefined;
        if (!std.mem.endsWith(u8, path, ".wav") and !std.mem.endsWith(u8, path, ".WAV")) {
            const new_len = @min(path.len + 4, ext_buf.len);
            @memcpy(ext_buf[0..path.len], path);
            @memcpy(ext_buf[path.len..new_len], ".wav");
            path = ext_buf[0..new_len];
        }

        wav_writer.writeWav(path, sample_rate, bits_per_sample, snapshot) catch |e| {
            self.setStatus(.err, @errorName(e));
            return;
        };

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Saved {d} samples ({d:.1} MB)", .{
            total,
            @as(f64, @floatFromInt(total * 2 * @as(usize, bits_per_sample / 8))) / (1024.0 * 1024.0),
        }) catch "Saved";
        self.setStatus(.success, msg);
    }

    fn setStatus(self: *Self, status: @TypeOf(self.status), msg: []const u8) void {
        self.status = status;
        const copy_len = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..copy_len], msg[0..copy_len]);
        self.status_msg_len = copy_len;
    }
};
