const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;

const fftw = @cImport({
    @cDefine("__float128", "double");
    @cInclude("fftw3.h");
});

const Plot = @import("plot.zig");
const rl = Plot.rl;

fn ghz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}

fn mhz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

fn khz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

fn kb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

fn mb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

fn gb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}

const CallbackState = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    should_stop: bool = true,
    bytes_transfered: u64 = 0,
    target_buffer: *FixedSizeRingBuffer(hackrf.IQSample),
};

fn rxCallback(trans: hackrf.Transfer, state: *CallbackState) hackrf.StreamAction {
    state.mutex.lock(state.io) catch {
        std.log.err("Failed to get rxCallback mutex lock", .{});
    };

    defer state.mutex.unlock(state.io);

    const valid_length = trans.validLength();
    state.bytes_transfered += valid_length;

    state.target_buffer.append(trans.iqSamples());

    if (state.should_stop) return .stop;
    return .@"continue";
}

const SimpleFFT = struct {
    const Self = @This();

    fft_size: u32 = 0,
    fft_in: *[]fftw.fftw_complex = undefined,
    fft_out: *[]fftw.fftw_complex = undefined,
    fft_plan: *fftw.fft_plan = undefined,
    fft_mag: []f32 = undefined,
    fft_freqs: []f32 = undefined,

    pub fn init(alloc: std.mem.Allocator, fft_size: u32, center_freq: f32, fs: f32) !Self {
        var self: Self = .{};

        self.fft_size = fft_size;
        if (self.fft_size == 0) {
            return;
        }

        self.fft_in = @ptrCast(@alignCast(fftw.fftw_malloc(@sizeOf(fftw.fftw_complex) * self.fft_size)));
        self.fft_out = @ptrCast(@alignCast(fftw.fftw_malloc(@sizeOf(fftw.fftw_complex) * self.fft_size)));
        self.fft_plan = fftw.fftw_plan_dft_1d(self.fft_size, self.fft_in, self.fft_out, fftw.FFTW_FORWARD, fftw.FFTW_ESTIMATE);
        self.fft_mag = try alloc.alloc(f32, self.fft_size);
        self.fft_freqs = try alloc.alloc(f32, self.fft_size);

        const center_freq_mhz = center_freq / mhz(1);
        const sample_rate_mhz = fs / mhz(1);

        for (0..self.fft_size) |i| {
            const bin: f32 = @as(f32, @floatFromInt(i)) - @as(f32, self.fft_size) / 2.0;
            self.fft_freqs[i] = center_freq_mhz + bin * sample_rate_mhz / @as(f32, self.fft_size);
        }

        return self;
    }

    pub fn calc(self: *Self, dat_i: []f32, dat_q: []f32) void {
        std.debug.assert(dat_i.len >= self.fft_size);
        std.debug.assert(dat_q.len >= self.fft_size);

        for (0..self.fft_size) |i| {
            self.fft_in[i][0] = dat_i;
            self.fft_in[i][1] = dat_q;
        }

        fftw.fftw_execute(self.fft_plan);

        const half = self.fft_size / 2;
        const n_sq: f64 = self.fft_size * self.fft_size;

        for (0..self.fft_size) |i| {
            const src = (i + half) % self.fft_size;
            const re = self.fft_out[src][0];
            const im = self.fft_out[src][1];

            const power = (re * re + im * im) / n_sq;
            self.fft_mag[i] = @floatCast(10.0 * @log10(@max(power, 1e-12)));
        }
    }

    pub fn deinit(self: *Self) void {
        fftw.fftw_free(self.fft_in);
        fftw.fftw_free(self.fft_out);
        fftw.fftw_destroy_plan(self.fft_plan);
        self.alloc.free(self.fft_mag);
        self.alloc.free(self.fft_freqs);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    //var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //defer allocator.deinit();

    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    //
    // Setup hackrf one
    //

    try hackrf.init();
    defer hackrf.deinit() catch {};

    var list = try hackrf.DeviceList.get();
    defer list.deinit();

    if (list.count() == 0) {
        std.log.err("Failed to find hackrf device", .{});
        return;
    }

    const device = try hackrf.Device.open();
    defer device.close();

    var version_buf: [256]u8 = undefined;
    const version = try device.versionStringRead(&version_buf);

    std.log.debug("Found hackrf device running firmware {s}", .{version});

    device.stopTx() catch {};
    try device.setSampleRate(mhz(10));
    try device.setFreq(ghz(0.9));
    try device.setAmpEnable(true);

    std.log.debug("hackrf config done", .{});

    var rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, mb(256));
    defer rx_buffer.deinit(alloc);

    var rf_state = RFDataState.calc(512);
    _ = rf_state;

    var rx_state = CallbackState{ .target_buffer = &rx_buffer, .should_stop = false, .mutex = std.Io.Mutex.init, .io = io };

    try device.startRx(*CallbackState, rxCallback, &rx_state);
    const start_time: f64 = rl.GetTime();

    const screen_width = 800;
    const screen_height = 700;

    rl.InitWindow(screen_width, screen_height, "rf-fun");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    const samples_to_show = 1024;
    const samples: []hackrf.IQSample = try alloc.alloc(hackrf.IQSample, samples_to_show);
    defer alloc.free(samples);

    // Separate float buffers for I and Q channels
    const i_samples: []f32 = try alloc.alloc(f32, samples_to_show);
    defer alloc.free(i_samples);
    const q_samples: []f32 = try alloc.alloc(f32, samples_to_show);
    defer alloc.free(q_samples);

    var fft_plot = Plot.init(.{
        .title = "1024 point FFT",
        .x_label = "Freq (MHz)",
        .y_label = "dB",
        .rect = .{ .x = 10, .y = 40, .width = @as(f32, screen_width - 20), .height = 512 },
        .y_range = .{ -120.0, 0.0 },
    });


    while (!rl.WindowShouldClose()) {
        // Update (zoom/pan/cursor input)
        fft_plot.update();

        // Copy sample data from ring buffer
        try rx_state.mutex.lock(io);
        const rx_total_bytes = rx_state.bytes_transfered;

        const sample_slices = rx_state.target_buffer.newest(samples_to_show);

        if (sample_slices.first.len > 0) {
            std.mem.copyForwards(hackrf.IQSample, samples, sample_slices.first);
        }

        if (sample_slices.second.len > 0) {
            std.mem.copyForwards(hackrf.IQSample, samples[sample_slices.first.len..], sample_slices.second);
        }
        rx_state.mutex.unlock(io);

        for (samples, 0..) |s, i| {
            const f = s.toFloat();
            i_samples[i] = f[0];
            q_samples[i] = f[1];
        }

        fft_plot.clear();
        fft_plot.plotXY(fft_freqs, fft_mag, .{ .color = rl.SKYBLUE, .label = "Magnitude" });

        // Draw
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(.{ .r = 30, .g = 30, .b = 30, .a = 255 });
        fft_plot.render();

        var rx_stat_str_buf = std.mem.zeroes([128]u8);

        const current_time: f64 = rl.GetTime();
        const elapsed_time = current_time - start_time;

        _ = try std.fmt.bufPrint(&rx_stat_str_buf, "Received {d} MB @ {d:.2} MB/s", .{ rx_total_bytes / mb(1), (@as(f64, @floatFromInt(rx_total_bytes)) / elapsed_time) / mb(1) });

        rl.DrawText(&rx_stat_str_buf, 10, 10, 20, rl.MAROON);
        //rl.DrawFPS(screen_width - 100, 10);
    }

    rx_state.should_stop = true;
}
