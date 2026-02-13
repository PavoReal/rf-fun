const std = @import("std");

pub const Waterfall = struct {
    const Self = @This();

    fft_size: u32,
    history_len: u32,
    history: []f32,       // flat: history_len * fft_size (dB values)
    write_head: u32,
    row_count: u32,
    pixels: []u8,         // flat RGBA: history_len * fft_size * 4
    dirty: bool,
    db_min: f32,          // default -120
    db_max: f32,          // default 0

    pub fn init(alloc: std.mem.Allocator, fft_size: u32, history_len: u32) !Self {
        const total_bins = fft_size * history_len;
        const history = try alloc.alloc(f32, total_bins);
        @memset(history, 0);
        const pixels = try alloc.alloc(u8, total_bins * 4);
        @memset(pixels, 0);
        return Self{
            .fft_size = fft_size,
            .history_len = history_len,
            .history = history,
            .write_head = 0,
            .row_count = 0,
            .pixels = pixels,
            .dirty = false,
            .db_min = -120.0,
            .db_max = 0.0,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        alloc.free(self.history);
        alloc.free(self.pixels);
    }

    /// Append a new FFT magnitude row (in dB). Marks dirty.
    pub fn pushRow(self: *Self, fft_mag: []const f32) void {
        const row_start = self.write_head * self.fft_size;
        const dest = self.history[row_start..][0..self.fft_size];
        const len = @min(fft_mag.len, self.fft_size);
        @memcpy(dest[0..len], fft_mag[0..len]);
        // zero any remainder if fft_mag is shorter
        if (len < self.fft_size) {
            @memset(dest[len..], 0);
        }
        self.write_head = (self.write_head + 1) % self.history_len;
        if (self.row_count < self.history_len) self.row_count += 1;
        self.dirty = true;
    }

    /// Convert history ring buffer -> RGBA pixels if dirty.
    /// Output: row 0 = newest (top), falling down. Newest data appears at top and scrolls down.
    pub fn renderPixels(self: *Self) void {
        if (!self.dirty) return;

        const rows_to_render = self.row_count;
        // newest row is one before write_head
        // iterate from newest (out_row=0) to oldest (out_row=rows_to_render-1)
        for (0..rows_to_render) |out_row| {
            // ring_row: walk backwards from write_head
            const ring_row = (self.write_head + self.history_len - 1 - @as(u32, @intCast(out_row))) % self.history_len;
            const hist_offset = ring_row * self.fft_size;
            const pix_offset = @as(u32, @intCast(out_row)) * self.fft_size * 4;

            for (0..self.fft_size) |col| {
                const db = self.history[hist_offset + col];
                const rgba = dbToRgba(self, db);
                const p = pix_offset + @as(u32, @intCast(col)) * 4;
                self.pixels[p + 0] = rgba[0];
                self.pixels[p + 1] = rgba[1];
                self.pixels[p + 2] = rgba[2];
                self.pixels[p + 3] = rgba[3];
            }
        }

        // Clear empty rows at bottom (if history not full yet)
        if (rows_to_render < self.history_len) {
            const start = rows_to_render * self.fft_size * 4;
            const end = self.history_len * self.fft_size * 4;
            @memset(self.pixels[start..end], 0);
        }

        self.dirty = false;
    }

    pub fn clear(self: *Self) void {
        @memset(self.history, 0);
        @memset(self.pixels, 0);
        self.write_head = 0;
        self.row_count = 0;
        self.dirty = false;
    }

    /// Jet-style colormap: dark blue → blue → green → yellow → red
    fn dbToRgba(self: *const Self, db: f32) [4]u8 {
        const range = self.db_max - self.db_min;
        const t = if (range > 0.0)
            std.math.clamp((db - self.db_min) / range, 0.0, 1.0)
        else
            0.0;

        // 5 keypoints:
        // t=0.00 → (0, 0, 32)   dark blue
        // t=0.25 → (0, 0, 255)  blue
        // t=0.50 → (0, 255, 0)  green
        // t=0.75 → (255, 255, 0) yellow
        // t=1.00 → (255, 48, 0) red
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;

        if (t < 0.25) {
            const s = t / 0.25;
            r = 0;
            g = 0;
            b = 32.0 + s * (255.0 - 32.0);
        } else if (t < 0.5) {
            const s = (t - 0.25) / 0.25;
            r = 0;
            g = s * 255.0;
            b = 255.0 * (1.0 - s);
        } else if (t < 0.75) {
            const s = (t - 0.5) / 0.25;
            r = s * 255.0;
            g = 255.0;
            b = 0;
        } else {
            const s = (t - 0.75) / 0.25;
            r = 255.0;
            g = 255.0 * (1.0 - s) + 48.0 * s;
            b = 0;
        }

        return .{
            @intFromFloat(std.math.clamp(r, 0, 255)),
            @intFromFloat(std.math.clamp(g, 0, 255)),
            @intFromFloat(std.math.clamp(b, 0, 255)),
            255,
        };
    }
};
