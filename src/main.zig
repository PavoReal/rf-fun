const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const util = @import("util.zig");
const zsdl = @import("zsdl3");
const zgui = @import("zgui");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

fn sdrRxCallback(trans: hackrf.Transfer, state: *SDR) hackrf.StreamAction {
    state.mutex.lock();
    defer state.mutex.unlock();

    const valid_length = trans.validLength();
    state.rx_bytes_received += valid_length;

    const raw_samples = trans.iqSamples();

    std.log.debug("callback", .{});
    for (raw_samples) |sample| {
        state.rx_buffer.appendOne(sample.toFloat());
    }

    if (!state.rx_running) return .stop;
    return .@"continue";
}

const SDR = struct {
    const Self = @This();

    device: hackrf.Device = undefined,
    connected: bool = false,
    version_str: [256]u8 = std.mem.zeroes([256]u8),

    fs: f64 = util.mhz(20),
    cf: u64 = util.ghz(0.9),

    mutex: std.Thread.Mutex = .{},

    rx_running: bool = false,
    rx_bytes_received: u64 = 0,

    rx_buffer: FixedSizeRingBuffer([2]f32) = undefined,

    pub fn init(alloc: std.mem.Allocator, cf: u64, fs: f64) !Self {
        var self = Self{};
        self.cf = cf;
        self.fs = fs;
        try hackrf.init();

        var list = try hackrf.DeviceList.get();
        defer list.deinit();

        if (list.count() == 0) return self;

        self.device = try hackrf.Device.open();
        _ = try self.device.versionStringRead(&self.version_str);

        self.device.stopTx() catch {};
        try self.device.setSampleRate(self.fs);
        try self.device.setFreq(self.cf);
        try self.device.setAmpEnable(true);

        self.rx_buffer = try FixedSizeRingBuffer([2]f32).init(alloc, util.mb(256));

        return self;
    }

    pub fn startRx(self: *Self) !void {
        self.rx_running = true;
        try self.device.startRx(*Self, sdrRxCallback, self);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) !void {
        self.rx_buffer.deinit(alloc);
        self.device.close();

        try hackrf.deinit();
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    //
    // Setup hackrf one
    //
    var sdr: ?SDR = null;

    //
    // SDL3 + GPU init
    //

    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    const window = try zsdl.createWindow("rf-fun", 800, 700, .{ .resizable = true, .high_pixel_density = true });
    defer zsdl.destroyWindow(window);

    const gpu_device = c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_METALLIB | c.SDL_GPU_SHADERFORMAT_SPIRV,
        true,
        null,
    ) orelse {
        std.log.err("Failed to create GPU device", .{});
        return;
    };
    defer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, @ptrCast(window))) {
        std.log.err("Failed to claim window for GPU device", .{});
        return;
    }

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, @ptrCast(window));

    //
    // zgui + ImPlot init
    //

    zgui.init(alloc);
    defer zgui.deinit();

    zgui.plot.init();
    defer zgui.plot.deinit();

    zgui.getStyle().setColorsDark();

    zgui.backend.init(@ptrCast(window), .{
        .device = @ptrCast(gpu_device),
        .color_target_format = swapchain_format,
        .msaa_samples = @intCast(c.SDL_GPU_SAMPLECOUNT_1),
    });
    defer zgui.backend.deinit();

    //
    // FFT setup
    //
    
    const default_cf = util.mhz(900);
    const default_fs = util.mhz(20);

    const sample_rate_values = [_]f64{ util.mhz(2), util.mhz(4), util.mhz(8), util.mhz(10), util.mhz(16), util.mhz(20) };
    const sample_rate_labels: [:0]const u8 = "2 MHz\x004 MHz\x008 MHz\x0010 MHz\x0016 MHz\x0020 MHz";

    const fft_size_values = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096 };
    const fft_size_labels: [:0]const u8 = "64\x00128\x00256\x00512\x001024\x002048\x004096";

    var cf_slider: f32 = @as(f32, @floatFromInt(@as(u32, @intCast(default_cf)))) / 1e6;
    var fs_index: i32 = 5; // default = 20 MHz
    var fft_size_index: i32 = 3; // default = 512

    var fft = try SimpleFFT.init(alloc, 512, default_cf, default_fs);
    defer fft.deinit(alloc);

    var fft_buf: [4096][2]f32 = undefined;

    const next_fft_update_delay = 100;
    var next_fft_update_time = zsdl.getTicks() + next_fft_update_delay; // ms

    //
    // Main loop
    //

    var running = true;
    while (running) {
        // Event polling
        var event: zsdl.Event = undefined;
        while (zsdl.pollEvent(&event)) {
            _ = zgui.backend.processEvent(@ptrCast(&event));
            if (event.type == .quit) {
                running = false;
            }
        }

        if (sdr != null) {
            // FFT update
            const current_time = zsdl.getTicks();
            if (current_time >= next_fft_update_time) {
                sdr.?.mutex.lock();
                defer sdr.?.mutex.unlock();

                const fft_slice = fft_buf[0..fft.fft_size];
                const copied = sdr.?.rx_buffer.copyNewest(fft_slice);
                if (copied == fft.fft_size) {
                    fft.calc(fft_slice);
                }

                next_fft_update_time = current_time + next_fft_update_delay;
            }
        }

        const cmd_buf = c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse continue;

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var sw_w: u32 = 0;
        var sw_h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, @ptrCast(window), &swapchain_texture, &sw_w, &sw_h)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            continue;
        }

        if (swapchain_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            continue;
        }

        var win_w: c_int = 0;
        var win_h: c_int = 0;
        zsdl.getWindowSize(window, &win_w, &win_h) catch {};
        const fb_scale: f32 = if (win_w > 0) @as(f32, @floatFromInt(sw_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

        zgui.backend.newFrame(sw_w, sw_h, fb_scale);

        {
            const viewport = zgui.getMainViewport();
            const work_pos = viewport.getWorkPos();
            const work_size = viewport.getWorkSize();

            zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] });
            zgui.setNextWindowSize(.{ .w = work_size[0], .h = work_size[1] });

            if (zgui.begin("rf-fun", .{
                .flags = .{
                    .no_title_bar = true,
                    .no_resize = true,
                    .no_move = true,
                    .no_collapse = true,
                    .no_bring_to_front_on_focus = true,
                },
            })) {
                if (sdr != null) {
                    if (zgui.button("Disconnect", .{})) {
                        sdr.?.rx_running = false;
                        try sdr.?.deinit(alloc);
                        sdr = null;

                        @memset(fft.fft_mag, 0);
                    } else {
                        zgui.text("hackrf firmware verison {s}", .{sdr.?.version_str});
                        if (zgui.sliderFloat("Center Freq (MHz)", .{ .min = 0, .max = 6000, .v = &cf_slider })) {
                            const cf_hz: u64 = @intFromFloat(cf_slider * 1e6);
                            try sdr.?.device.setFreq(cf_hz);
                            fft.updateFreqs(cf_slider * 1e6, @floatCast(sample_rate_values[@intCast(fs_index)]));
                        }
                        if (zgui.combo("Sample Rate", .{
                            .current_item = &fs_index,
                            .items_separated_by_zeros = sample_rate_labels,
                        })) {
                            const new_fs = sample_rate_values[@intCast(fs_index)];
                            try sdr.?.device.setSampleRate(new_fs);
                            fft.updateFreqs(cf_slider * 1e6, @floatCast(new_fs));
                        }
                        if (zgui.combo("FFT Size", .{
                            .current_item = &fft_size_index,
                            .items_separated_by_zeros = fft_size_labels,
                        })) {
                            const new_size = fft_size_values[@intCast(fft_size_index)];
                            const fs_hz: f64 = sample_rate_values[@intCast(fs_index)];
                            fft.deinit(alloc);
                            fft = try SimpleFFT.init(alloc, new_size, cf_slider * 1e6, @floatCast(fs_hz));
                        }
                    }
                } else {
                    if (zgui.button("Connect", .{})) {
                        const cf_hz: u64 = @intFromFloat(cf_slider * 1e6);
                        const fs_hz: f64 = sample_rate_values[@intCast(fs_index)];
                        sdr = try SDR.init(alloc, cf_hz, fs_hz);
                        try sdr.?.startRx();
                        fft.updateFreqs(cf_slider * 1e6, @floatCast(fs_hz));
                    }
                }
                var title_buf: [64]u8 = undefined;
                const plot_title = std.fmt.bufPrintZ(&title_buf, "{d} point FFT", .{fft.fft_size}) catch "FFT";
                plot.render(plot_title, "Freq (MHz)", "dB", fft.fft_freqs, fft.fft_mag, .{ -120.0, 0.0 });
            }
            zgui.end();
        }

        zgui.backend.render();
        zgui.backend.prepareDrawData(@ptrCast(cmd_buf));

        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_texture,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = 0.12, .g = 0.12, .b = 0.12, .a = 1.0 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };

        const render_pass = c.SDL_BeginGPURenderPass(cmd_buf, &color_target, 1, null);
        if (render_pass != null) {
            zgui.backend.renderDrawData(@ptrCast(cmd_buf), @ptrCast(render_pass.?), null);
            c.SDL_EndGPURenderPass(render_pass);
        }

        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }

    if (sdr != null) {
        sdr.?.rx_running = false;
        try sdr.?.deinit(alloc);
    }
}

