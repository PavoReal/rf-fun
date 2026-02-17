const std = @import("std");

pub const MAX_PEAKS = 10;
const NOISE_THRESHOLD_DB = 6.0;

pub const PeakInfo = struct {
    freq_mhz: f32 = 0,
    power_db: f32 = -200,
    bin: u32 = 0,
};

pub const SignalStats = struct {
    noise_floor_db: f32 = -200,
    peak_freq_mhz: f32 = 0,
    peak_power_db: f32 = -200,
    sfdr_db: f32 = 0,
    snr_db: f32 = 0,
    num_peaks: usize = 0,
    peaks: [MAX_PEAKS]PeakInfo = [_]PeakInfo{.{}} ** MAX_PEAKS,

    pub fn compute(
        spectrum_db: []const f32,
        freq_mhz: []const f32,
        min_distance: u32,
        scratch: []f32,
    ) SignalStats {
        var stats = SignalStats{};

        if (spectrum_db.len < 3) return stats;

        stats.noise_floor_db = estimateNoiseFloor(spectrum_db, scratch);
        stats.num_peaks = findPeaks(spectrum_db, freq_mhz, stats.noise_floor_db, min_distance, &stats.peaks);

        if (stats.num_peaks > 0) {
            stats.peak_freq_mhz = stats.peaks[0].freq_mhz;
            stats.peak_power_db = stats.peaks[0].power_db;
            stats.sfdr_db = computeSfdr(&stats.peaks, stats.num_peaks);
            stats.snr_db = computeSnr(spectrum_db, stats.peaks[0].bin, min_distance, stats.peak_power_db);
        }

        return stats;
    }

    pub fn estimateNoiseFloor(spectrum_db: []const f32, scratch: []f32) f32 {
        const len = @min(spectrum_db.len, scratch.len);
        @memcpy(scratch[0..len], spectrum_db[0..len]);
        std.sort.pdq(f32, scratch[0..len], {}, std.sort.asc(f32));
        return scratch[len / 2];
    }

    pub fn findPeaks(
        spectrum_db: []const f32,
        freq_mhz: []const f32,
        noise_floor: f32,
        min_distance: u32,
        out: *[MAX_PEAKS]PeakInfo,
    ) usize {
        const len = spectrum_db.len;
        if (len < 3) return 0;

        const threshold = noise_floor + NOISE_THRESHOLD_DB;
        var count: usize = 0;

        var i: usize = 1;
        while (i < len - 1) : (i += 1) {
            const val = spectrum_db[i];
            if (val < threshold) continue;
            if (val < spectrum_db[i + 1]) continue;
            if (val <= spectrum_db[i - 1]) continue;

            insertPeakSorted(out, &count, .{
                .freq_mhz = freq_mhz[i],
                .power_db = val,
                .bin = @intCast(i),
            });

            const skip = if (min_distance > 1) min_distance - 1 else 0;
            i += skip;
        }

        return count;
    }

    fn insertPeakSorted(peaks: *[MAX_PEAKS]PeakInfo, count: *usize, peak: PeakInfo) void {
        var pos: usize = count.*;
        for (0..count.*) |j| {
            if (peak.power_db > peaks[j].power_db) {
                pos = j;
                break;
            }
        }

        if (pos >= MAX_PEAKS) return;

        const end = @min(count.*, MAX_PEAKS - 1);
        if (end > pos) {
            var j: usize = end;
            while (j > pos) : (j -= 1) {
                peaks[j] = peaks[j - 1];
            }
        }

        peaks[pos] = peak;
        if (count.* < MAX_PEAKS) count.* += 1;
    }

    pub fn computeSfdr(peaks: *const [MAX_PEAKS]PeakInfo, num_peaks: usize) f32 {
        if (num_peaks < 2) return 0;
        return peaks[0].power_db - peaks[1].power_db;
    }

    pub fn computeSnr(spectrum_db: []const f32, peak_bin: u32, min_distance: u32, peak_power_db: f32) f32 {
        var noise_linear: f64 = 0;
        var noise_count: usize = 0;

        const excl_lo = if (peak_bin >= min_distance) peak_bin - min_distance else 0;
        const excl_hi = @min(peak_bin + min_distance, @as(u32, @intCast(spectrum_db.len - 1)));

        for (0..spectrum_db.len) |i| {
            const idx: u32 = @intCast(i);
            if (idx >= excl_lo and idx <= excl_hi) continue;
            noise_linear += std.math.pow(f64, 10.0, @as(f64, @floatCast(spectrum_db[i])) / 10.0);
            noise_count += 1;
        }

        if (noise_count == 0) return 0;

        const avg_noise_db: f32 = @floatCast(10.0 * std.math.log10(noise_linear / @as(f64, @floatFromInt(noise_count))));
        return peak_power_db - avg_noise_db;
    }

    pub fn minDistanceForWindow(window_index: i32) u32 {
        return switch (window_index) {
            0 => 4, // None
            1 => 6, // Hanning
            2 => 6, // Hamming
            3 => 10, // Blackman-Harris
            4 => 12, // Flat-Top
            else => 6,
        };
    }
};
