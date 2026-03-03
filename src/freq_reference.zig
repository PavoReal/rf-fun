const std = @import("std");
const freq_db = @import("freq_db.zig");
const radio_decoder_mod = @import("radio_decoder.zig");
const RadioDecoder = radio_decoder_mod.RadioDecoder;
const zgui = @import("zgui");

pub const FreqReference = struct {
    search_buf: [64:0]u8 = std.mem.zeroes([64:0]u8),
    prev_search: [64:0]u8 = std.mem.zeroes([64:0]u8),
    match_buf: [freq_db.flat_entries.len]bool = [_]bool{false} ** freq_db.flat_entries.len,
    cat_has_match: [freq_db.database.len]bool = [_]bool{true} ** freq_db.database.len,
    has_active_search: bool = false,
    collapse_requested: bool = false,
    pinned: [freq_db.flat_entries.len]bool = [_]bool{false} ** freq_db.flat_entries.len,
    visible_x_min: f64 = 0,
    visible_x_max: f64 = 0,
    hovered_flat_idx: ?u32 = null,
    active_flat_idx: ?u32 = null,

    pub fn render(self: *FreqReference, decoder: *RadioDecoder) void {
        if (!zgui.begin("Freq Ref###Freq Ref", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();
        self.hovered_flat_idx = null;

        _ = zgui.inputTextWithHint("##freq_search", .{
            .hint = "Search freq, name, mode...",
            .buf = &self.search_buf,
        });
        zgui.sameLine(.{});
        if (zgui.smallButton("X")) {
            self.search_buf = std.mem.zeroes([64:0]u8);
            self.has_active_search = false;
        }
        zgui.sameLine(.{});
        if (zgui.smallButton("Collapse All")) {
            self.collapse_requested = true;
        }

        if (!std.mem.eql(u8, &self.search_buf, &self.prev_search)) {
            self.updateSearch();
        }

        if (zgui.beginChild("##freq_list", .{})) {
            var flat_idx: usize = 0;
            for (freq_db.database, 0..) |cat, cat_idx| {
                if (self.has_active_search and !self.cat_has_match[cat_idx]) {
                    for (cat.subcategories) |sub| {
                        flat_idx += sub.entries.len;
                    }
                    continue;
                }

                if (self.has_active_search) {
                    zgui.setNextItemOpen(.{ .is_open = true, .cond = .always });
                } else if (self.collapse_requested) {
                    zgui.setNextItemOpen(.{ .is_open = false, .cond = .always });
                }

                if (zgui.treeNodeFlags(cat.name, .{})) {
                    for (cat.subcategories) |sub| {
                        var sub_has_match = false;
                        if (self.has_active_search) {
                            for (0..sub.entries.len) |j| {
                                if (self.match_buf[flat_idx + j]) {
                                    sub_has_match = true;
                                    break;
                                }
                            }
                            if (!sub_has_match) {
                                flat_idx += sub.entries.len;
                                continue;
                            }
                        }

                        if (self.has_active_search) {
                            zgui.setNextItemOpen(.{ .is_open = true, .cond = .always });
                        } else if (self.collapse_requested) {
                            zgui.setNextItemOpen(.{ .is_open = false, .cond = .always });
                        }

                        if (zgui.treeNodeFlags(sub.name, .{})) {
                            for (sub.entries, 0..) |*entry, ei| {
                                _ = ei;
                                if (self.has_active_search and !self.match_buf[flat_idx]) {
                                    flat_idx += 1;
                                    continue;
                                }
                                self.renderEntry(entry, @intCast(flat_idx), decoder);
                                flat_idx += 1;
                            }
                            zgui.treePop();
                        } else {
                            flat_idx += sub.entries.len;
                        }
                    }
                    zgui.treePop();
                } else {
                    for (cat.subcategories) |sub| {
                        flat_idx += sub.entries.len;
                    }
                }
            }
        }
        zgui.endChild();
        self.collapse_requested = false;
    }

    fn renderEntry(self: *FreqReference, entry: *const freq_db.FreqEntry, flat_idx: i32, decoder: *RadioDecoder) void {
        const idx: usize = @intCast(flat_idx);
        const draw_list = zgui.getWindowDrawList();
        const cursor_pos = zgui.getCursorScreenPos();
        const avail_w = zgui.getContentRegionAvail()[0];
        const line_h = zgui.getTextLineHeightWithSpacing();

        if (self.isEntryInView(entry)) {
            draw_list.addRectFilled(.{
                .pmin = .{ cursor_pos[0], cursor_pos[1] },
                .pmax = .{ cursor_pos[0] + avail_w, cursor_pos[1] + line_h },
                .col = 0x15_FF_C0_80,
            });
        }

        if (self.active_flat_idx) |active| {
            if (active == idx) {
                draw_list.addRectFilled(.{
                    .pmin = .{ cursor_pos[0], cursor_pos[1] },
                    .pmax = .{ cursor_pos[0] + 3.0, cursor_pos[1] + line_h },
                    .col = 0xFF_FF_00_FF,
                });
            }
        }

        zgui.pushIntId(flat_idx);
        defer zgui.popId();

        const was_pinned = self.pinned[idx];
        if (was_pinned) {
            zgui.pushStyleColor4f(.{ .idx = .button, .c = .{ 0.1, 0.6, 0.1, 1.0 } });
        }
        if (zgui.smallButton("P")) {
            self.pinned[idx] = !self.pinned[idx];
        }
        if (was_pinned) {
            zgui.popStyleColor(.{});
        }

        zgui.sameLine(.{});
        if (entry.freq_start_mhz == entry.freq_end_mhz) {
            zgui.text("{d:.4} MHz", .{entry.freq_start_mhz});
        } else {
            zgui.text("{d:.4}-{d:.4} MHz", .{ entry.freq_start_mhz, entry.freq_end_mhz });
        }

        zgui.sameLine(.{});
        zgui.textColored(entry.mode.color(), "[{s}]", .{entry.mode.label()});

        zgui.sameLine(.{});
        zgui.text("{s}", .{entry.name});
        if (zgui.isItemHovered(.{})) {
            self.hovered_flat_idx = @intCast(idx);
        }

        if (entry.description.len > 0) {
            zgui.sameLine(.{});
            zgui.textDisabled("{s}", .{entry.description});
        }

        zgui.sameLine(.{});
        if (zgui.smallButton("Tune")) {
            const mod_index: ?i32 = switch (entry.mode) {
                .am => 1,
                .fm => 0,
                .nfm => 2,
                .usb => 3,
                .lsb => 4,
                .cw => 6,
                .digital, .various, .none => null,
            };
            if (mod_index) |mi| {
                decoder.ui_modulation_index = mi;
                decoder.modulation.store(@intCast(mi), .release);
            }
            decoder.retune_center_requested.store(@bitCast(entry.freq_start_mhz), .release);
            decoder.reconfigure_flag.store(true, .release);
            self.active_flat_idx = @intCast(idx);
        }
    }

    fn isEntryInView(self: *const FreqReference, entry: *const freq_db.FreqEntry) bool {
        if (self.visible_x_max <= self.visible_x_min) return false;
        return entry.freq_end_mhz >= self.visible_x_min and
            entry.freq_start_mhz <= self.visible_x_max;
    }

    pub fn savePins(self: *const FreqReference) void {
        const file = std.fs.cwd().createFile("pins.ini", .{}) catch return;
        defer file.close();
        var write_buf: [4096]u8 = undefined;
        var w = file.writer(&write_buf);
        const iw = &w.interface;
        for (self.pinned, 0..) |is_pinned, i| {
            if (is_pinned) {
                iw.print("{d}\n", .{i}) catch return;
            }
        }
        iw.flush() catch {};
    }

    pub fn loadPins(self: *FreqReference) void {
        const file = std.fs.cwd().openFile("pins.ini", .{}) catch return;
        defer file.close();
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);
        const ir = &reader.interface;
        while (ir.takeDelimiter('\n') catch null) |line_raw| {
            const trimmed = std.mem.trimRight(u8, line_raw, "\r");
            const idx = std.fmt.parseInt(usize, trimmed, 10) catch continue;
            if (idx < self.pinned.len) {
                self.pinned[idx] = true;
            }
        }
    }

    fn updateSearch(self: *FreqReference) void {
        const search_len = std.mem.indexOfScalar(u8, &self.search_buf, 0) orelse self.search_buf.len;
        if (search_len == 0) {
            self.has_active_search = false;
            self.prev_search = self.search_buf;
            return;
        }

        self.has_active_search = true;

        var lower_search: [64]u8 = undefined;
        for (0..search_len) |i| {
            lower_search[i] = std.ascii.toLower(self.search_buf[i]);
        }
        const search_slice = lower_search[0..search_len];

        var freq_val: ?f64 = null;
        if (std.fmt.parseFloat(f64, self.search_buf[0..search_len])) |v| {
            freq_val = if (v > 1000.0) v / 1e6 else v;
        } else |_| {}

        for (&self.cat_has_match) |*m| m.* = false;

        for (freq_db.flat_entries, 0..) |fe, i| {
            var matched = false;

            if (containsLower(fe.entry.name, search_slice) or
                containsLower(fe.entry.description, search_slice) or
                containsLower(fe.entry.mode.label(), search_slice))
            {
                matched = true;
            }

            if (!matched) {
                if (freq_val) |fv| {
                    if (fv >= fe.entry.freq_start_mhz - 0.001 and fv <= fe.entry.freq_end_mhz + 0.001) {
                        matched = true;
                    }
                }
            }

            self.match_buf[i] = matched;
            if (matched) {
                self.cat_has_match[fe.cat_idx] = true;
            }
        }

        self.prev_search = self.search_buf;
    }

    fn containsLower(haystack: [:0]const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        const limit = haystack.len - needle.len + 1;
        for (0..limit) |start| {
            var found = true;
            for (0..needle.len) |j| {
                if (std.ascii.toLower(haystack[start + j]) != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
};
