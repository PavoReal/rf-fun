const std = @import("std");

pub const ScanState = enum(u8) {
    idle = 0,
    scanning = 1,
    active = 2,
    holding = 3,
};

pub const ScanAction = union(enum) {
    none,
    tune_to_channel: u8,
    stop_on_channel: u8,
};

pub const ActivityEntry = struct {
    channel_index: u8,
    freq_mhz_bits: u64,
    tone_type: ToneType,
    tone_value: i16,
    start_ms: u64,
    end_ms: u64,

    pub const ToneType = enum(u8) {
        none = 0,
        ctcss = 1,
        dcs_normal = 2,
        dcs_inverted = 3,
    };

    pub fn durationMs(self: *const ActivityEntry) u64 {
        if (self.end_ms >= self.start_ms) return self.end_ms - self.start_ms;
        return 0;
    }

    pub fn freqMhz(self: *const ActivityEntry) f64 {
        return @bitCast(self.freq_mhz_bits);
    }
};

const empty_entry = ActivityEntry{
    .channel_index = 0,
    .freq_mhz_bits = 0,
    .tone_type = .none,
    .tone_value = -1,
    .start_ms = 0,
    .end_ms = 0,
};

pub const Scanner = struct {
    state: ScanState = .idle,

    current_channel: u8 = 0,
    num_channels: u8 = 0,

    dwell_ms: u32 = 250,
    hold_ms: u32 = 2000,

    require_tone_match: bool = false,

    state_entered_ms: u64 = 0,
    last_tick_ms: u64 = 0,

    activity_log: [64]ActivityEntry = [_]ActivityEntry{empty_entry} ** 64,
    log_write_idx: u8 = 0,
    log_count: u8 = 0,

    channel_last_active: [32]u64 = [_]u64{0} ** 32,

    active_entry: ?ActivityEntry = null,

    pub fn start(self: *Scanner, num_channels: u8, now_ms: u64) void {
        if (num_channels == 0) return;
        self.state = .scanning;
        self.num_channels = num_channels;
        self.current_channel = 0;
        self.state_entered_ms = now_ms;
        self.last_tick_ms = now_ms;
        self.active_entry = null;
    }

    pub fn stop(self: *Scanner) void {
        if (self.active_entry) |*entry| {
            entry.end_ms = self.last_tick_ms;
            self.pushLogEntry(entry.*);
            self.active_entry = null;
        }
        self.state = .idle;
    }

    pub fn tick(self: *Scanner, now_ms: u64, squelch_open: bool, tone_matched: bool) ScanAction {
        self.last_tick_ms = now_ms;

        const activity = if (self.require_tone_match)
            squelch_open and tone_matched
        else
            squelch_open;

        switch (self.state) {
            .idle => return .none,

            .scanning => {
                if (activity) {
                    self.state = .active;
                    self.state_entered_ms = now_ms;
                    self.channel_last_active[self.current_channel] = now_ms;
                    self.active_entry = .{
                        .channel_index = self.current_channel,
                        .freq_mhz_bits = 0,
                        .tone_type = .none,
                        .tone_value = -1,
                        .start_ms = now_ms,
                        .end_ms = 0,
                    };
                    return .{ .stop_on_channel = self.current_channel };
                }

                if (now_ms >= self.state_entered_ms + self.dwell_ms) {
                    self.current_channel = (self.current_channel + 1) % self.num_channels;
                    self.state_entered_ms = now_ms;
                    return .{ .tune_to_channel = self.current_channel };
                }

                return .none;
            },

            .active => {
                if (activity) {
                    self.channel_last_active[self.current_channel] = now_ms;
                    return .{ .stop_on_channel = self.current_channel };
                }

                self.state = .holding;
                self.state_entered_ms = now_ms;
                return .none;
            },

            .holding => {
                if (activity) {
                    self.state = .active;
                    self.state_entered_ms = now_ms;
                    self.channel_last_active[self.current_channel] = now_ms;
                    return .{ .stop_on_channel = self.current_channel };
                }

                if (now_ms >= self.state_entered_ms + self.hold_ms) {
                    if (self.active_entry) |*entry| {
                        entry.end_ms = now_ms;
                        self.pushLogEntry(entry.*);
                        self.active_entry = null;
                    }

                    self.state = .scanning;
                    self.current_channel = (self.current_channel + 1) % self.num_channels;
                    self.state_entered_ms = now_ms;
                    return .{ .tune_to_channel = self.current_channel };
                }

                return .none;
            },
        }
    }

    pub fn setActiveFreq(self: *Scanner, freq_mhz: f64) void {
        if (self.active_entry) |*entry| {
            entry.freq_mhz_bits = @bitCast(freq_mhz);
        }
    }

    pub fn setActiveTone(self: *Scanner, tone_type: ActivityEntry.ToneType, tone_value: i16) void {
        if (self.active_entry) |*entry| {
            entry.tone_type = tone_type;
            entry.tone_value = tone_value;
        }
    }

    fn pushLogEntry(self: *Scanner, entry: ActivityEntry) void {
        self.activity_log[self.log_write_idx] = entry;
        self.log_write_idx = (self.log_write_idx + 1) % 64;
        if (self.log_count < 64) self.log_count += 1;
    }

    pub fn getLogEntry(self: *const Scanner, reverse_index: u8) ?ActivityEntry {
        if (reverse_index >= self.log_count) return null;
        const idx = (self.log_write_idx + 64 - 1 - reverse_index) % 64;
        return self.activity_log[idx];
    }

    pub fn channelLastActive(self: *const Scanner, channel_index: u8) u64 {
        if (channel_index >= 32) return 0;
        return self.channel_last_active[channel_index];
    }

    pub fn isActive(self: *const Scanner) bool {
        return self.state == .active;
    }

    pub fn isScanning(self: *const Scanner) bool {
        return self.state == .scanning;
    }

    pub fn reset(self: *Scanner) void {
        self.stop();
        self.current_channel = 0;
        self.num_channels = 0;
        self.log_write_idx = 0;
        self.log_count = 0;
        self.channel_last_active = [_]u64{0} ** 32;
    }
};

test "scanner advances channels" {
    var s = Scanner{};
    s.start(4, 0);

    try std.testing.expectEqual(ScanState.scanning, s.state);
    try std.testing.expectEqual(@as(u8, 0), s.current_channel);

    var action = s.tick(250, false, false);
    try std.testing.expectEqual(ScanAction{ .tune_to_channel = 1 }, action);
    try std.testing.expectEqual(@as(u8, 1), s.current_channel);

    action = s.tick(500, false, false);
    try std.testing.expectEqual(ScanAction{ .tune_to_channel = 2 }, action);
    try std.testing.expectEqual(@as(u8, 2), s.current_channel);

    action = s.tick(750, false, false);
    try std.testing.expectEqual(ScanAction{ .tune_to_channel = 3 }, action);
    try std.testing.expectEqual(@as(u8, 3), s.current_channel);

    action = s.tick(1000, false, false);
    try std.testing.expectEqual(ScanAction{ .tune_to_channel = 0 }, action);
    try std.testing.expectEqual(@as(u8, 0), s.current_channel);
}

test "scanner stops on activity" {
    var s = Scanner{};
    s.start(4, 0);

    const action = s.tick(100, true, false);
    try std.testing.expectEqual(ScanAction{ .stop_on_channel = 0 }, action);
    try std.testing.expectEqual(ScanState.active, s.state);
    try std.testing.expect(s.active_entry != null);
}

test "scanner holds after activity ends" {
    var s = Scanner{};
    s.start(4, 0);

    _ = s.tick(100, true, false);
    try std.testing.expectEqual(ScanState.active, s.state);

    var action = s.tick(200, false, false);
    try std.testing.expectEqual(ScanState.holding, s.state);
    try std.testing.expectEqual(ScanAction.none, action);

    action = s.tick(300, false, false);
    try std.testing.expectEqual(ScanState.holding, s.state);
    try std.testing.expectEqual(ScanAction.none, action);

    action = s.tick(2200, false, false);
    try std.testing.expectEqual(ScanState.scanning, s.state);
    try std.testing.expectEqual(ScanAction{ .tune_to_channel = 1 }, action);
}

test "activity resumes during hold" {
    var s = Scanner{};
    s.start(4, 0);

    _ = s.tick(100, true, false);
    try std.testing.expectEqual(ScanState.active, s.state);

    _ = s.tick(200, false, false);
    try std.testing.expectEqual(ScanState.holding, s.state);

    const action = s.tick(500, true, false);
    try std.testing.expectEqual(ScanState.active, s.state);
    try std.testing.expectEqual(ScanAction{ .stop_on_channel = 0 }, action);
}

test "activity log records entries" {
    var s = Scanner{};
    s.start(4, 0);

    _ = s.tick(100, true, false);
    try std.testing.expectEqual(ScanState.active, s.state);
    s.setActiveFreq(462.5625);
    s.setActiveTone(.ctcss, 7);

    _ = s.tick(500, false, false);
    try std.testing.expectEqual(ScanState.holding, s.state);

    _ = s.tick(2500, false, false);
    try std.testing.expectEqual(ScanState.scanning, s.state);

    try std.testing.expectEqual(@as(u8, 1), s.log_count);

    const entry = s.getLogEntry(0).?;
    try std.testing.expectEqual(@as(u8, 0), entry.channel_index);
    try std.testing.expectEqual(@as(u64, 100), entry.start_ms);
    try std.testing.expectEqual(@as(u64, 2500), entry.end_ms);
    try std.testing.expectEqual(ActivityEntry.ToneType.ctcss, entry.tone_type);
    try std.testing.expectEqual(@as(i16, 7), entry.tone_value);
    try std.testing.expect(entry.freqMhz() == 462.5625);
    try std.testing.expectEqual(@as(u64, 2400), entry.durationMs());
}

test "log wraps around" {
    var s = Scanner{};
    s.start(4, 0);

    var t: u64 = 0;
    for (0..70) |i| {
        s.state = .scanning;
        s.current_channel = @intCast(i % 4);
        s.state_entered_ms = t;

        _ = s.tick(t + 10, true, false);
        s.setActiveFreq(@floatFromInt(i));

        _ = s.tick(t + 100, false, false);

        _ = s.tick(t + 2100, false, false);

        t += 3000;
    }

    try std.testing.expectEqual(@as(u8, 64), s.log_count);

    const newest = s.getLogEntry(0).?;
    try std.testing.expect(newest.freqMhz() == 69.0);

    const oldest = s.getLogEntry(63).?;
    try std.testing.expect(oldest.freqMhz() == 6.0);

    try std.testing.expect(s.getLogEntry(64) == null);
}

test "idle state does nothing" {
    var s = Scanner{};
    try std.testing.expectEqual(ScanState.idle, s.state);

    const action = s.tick(1000, true, true);
    try std.testing.expectEqual(ScanAction.none, action);
    try std.testing.expectEqual(ScanState.idle, s.state);
}

test "stop finalizes active entry" {
    var s = Scanner{};
    s.start(4, 0);

    _ = s.tick(100, true, false);
    try std.testing.expectEqual(ScanState.active, s.state);
    s.setActiveFreq(462.5625);

    _ = s.tick(500, true, false);

    s.stop();
    try std.testing.expectEqual(ScanState.idle, s.state);
    try std.testing.expectEqual(@as(u8, 1), s.log_count);

    const entry = s.getLogEntry(0).?;
    try std.testing.expectEqual(@as(u8, 0), entry.channel_index);
    try std.testing.expectEqual(@as(u64, 100), entry.start_ms);
    try std.testing.expectEqual(@as(u64, 500), entry.end_ms);
    try std.testing.expect(entry.freqMhz() == 462.5625);
}

test "require_tone_match gates activity" {
    var s = Scanner{};
    s.require_tone_match = true;
    s.start(4, 0);

    var action = s.tick(100, true, false);
    try std.testing.expectEqual(ScanAction.none, action);
    try std.testing.expectEqual(ScanState.scanning, s.state);

    action = s.tick(250, true, false);
    try std.testing.expectEqual(ScanAction{ .tune_to_channel = 1 }, action);
    try std.testing.expectEqual(ScanState.scanning, s.state);

    action = s.tick(300, true, true);
    try std.testing.expectEqual(ScanAction{ .stop_on_channel = 1 }, action);
    try std.testing.expectEqual(ScanState.active, s.state);
}
