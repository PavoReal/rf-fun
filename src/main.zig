const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const Waterfall = @import("waterfall.zig").Waterfall;
const util = @import("util.zig");
const HackRFConfig = @import("hackrf_config.zig").HackRFConfig;
const SpectrumAnalyzer = @import("spectrum_analyzer.zig").SpectrumAnalyzer;
const zsdl = @import("zsdl3");
const zgui = @import("zgui");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

fn lookupErrMsg(err: anyerror) []const u8 {
    return switch (err) {
        error.NoDeviceFound => "No devices found ",
        else => @errorName(err),
    };
}

fn sdrRxCallback(trans: hackrf.Transfer, state: *SDR) hackrf.StreamAction {
    state.mutex.lock();
    defer state.mutex.unlock();

    state.rx_bytes_received += trans.validLength();
    state.rx_buffer.append(trans.iqSamples());

    if (!state.rx_running) return .stop;
    return .@"continue";
}

const SDR = struct {
    const Self = @This();

    device: hackrf.Device = undefined,

    mutex: std.Thread.Mutex = .{},

    rx_running: bool = false,
    rx_bytes_received: u64 = 0,

    rx_buffer: FixedSizeRingBuffer(hackrf.IQSample) = undefined,

    pub fn init(alloc: std.mem.Allocator) !Self {
        var self = Self{};
        try hackrf.init();

        var list = try hackrf.DeviceList.get();
        defer list.deinit();

        if (list.count() == 0) return error.NoDeviceFound;

        self.device = try hackrf.Device.open();
        self.device.stopTx() catch {};

        self.rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, util.mb(64));

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

const WaterfallGpu = struct {
    const Self = @This();

    gpu_device: *c.SDL_GPUDevice,
    texture: ?*c.SDL_GPUTexture,
    sampler: ?*c.SDL_GPUSampler,
    transfer_buf: ?*c.SDL_GPUTransferBuffer,
    tex_w: u32,
    tex_h: u32,
    binding: c.SDL_GPUTextureSamplerBinding,

    fn init(gpu_device: *c.SDL_GPUDevice, width: u32, height: u32) Self {
        var self = Self{
            .gpu_device = gpu_device,
            .texture = null,
            .sampler = null,
            .transfer_buf = null,
            .tex_w = 0,
            .tex_h = 0,
            .binding = .{ .texture = null, .sampler = null },
        };
        self.create(width, height);
        return self;
    }

    fn deinit(self: *Self) void {
        self.destroy();
    }

    fn resize(self: *Self, width: u32, height: u32) void {
        self.destroy();
        self.create(width, height);
    }

    fn upload(self: *Self, waterfall: *Waterfall) void {
        const tb = self.transfer_buf orelse return;
        const texture = self.texture orelse return;

        const mapped: ?[*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.gpu_device, tb, false));
        if (mapped) |ptr| {
            const byte_count = self.tex_w * self.tex_h * 4;
            @memcpy(ptr[0..byte_count], waterfall.pixels[0..byte_count]);
            c.SDL_UnmapGPUTransferBuffer(self.gpu_device, tb);
        }

        const cmd_buf = c.SDL_AcquireGPUCommandBuffer(self.gpu_device) orelse return;
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse return;

        const src = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = tb,
            .offset = 0,
            .pixels_per_row = self.tex_w,
            .rows_per_layer = self.tex_h,
        };

        const dst = c.SDL_GPUTextureRegion{
            .texture = texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = self.tex_w,
            .h = self.tex_h,
            .d = 1,
        };

        c.SDL_UploadToGPUTexture(copy_pass, &src, &dst, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }

    fn create(self: *Self, width: u32, height: u32) void {
        const tex_info = c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        };
        self.texture = c.SDL_CreateGPUTexture(self.gpu_device, &tex_info);

        const sampler_info = c.SDL_GPUSamplerCreateInfo{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .mip_lod_bias = 0,
            .max_anisotropy = 1,
            .compare_op = 0,
            .min_lod = 0,
            .max_lod = 0,
            .enable_anisotropy = false,
            .enable_compare = false,
            .padding1 = 0,
            .padding2 = 0,
            .props = 0,
        };
        self.sampler = c.SDL_CreateGPUSampler(self.gpu_device, &sampler_info);

        const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = width * height * 4,
            .props = 0,
        };
        self.transfer_buf = c.SDL_CreateGPUTransferBuffer(self.gpu_device, &transfer_info);

        self.tex_w = width;
        self.tex_h = height;
        self.binding.texture = self.texture;
        self.binding.sampler = self.sampler;
    }

    fn destroy(self: *Self) void {
        if (self.texture) |t| c.SDL_ReleaseGPUTexture(self.gpu_device, t);
        if (self.sampler) |s| c.SDL_ReleaseGPUSampler(self.gpu_device, s);
        if (self.transfer_buf) |tb| c.SDL_ReleaseGPUTransferBuffer(self.gpu_device, tb);
        self.texture = null;
        self.sampler = null;
        self.transfer_buf = null;
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    var sdr: ?SDR = null;

    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    const window = try zsdl.createWindow("rf-fun", 1920, 1080, .{ .resizable = true, .high_pixel_density = true });
    defer zsdl.destroyWindow(window);

    const gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_METALLIB | c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
        std.log.err("Failed to create GPU device", .{});
        return;
    };
    defer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, @ptrCast(window))) {
        std.log.err("Failed to claim window for GPU device", .{});
        return;
    }

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, @ptrCast(window));

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

    var config: HackRFConfig = .{};
    config.connect_requested = true;
    config.amp_enable = true;

    var analyzer = try SpectrumAnalyzer.init(alloc, 7, 3, config.cf_mhz, config.fsHz(), 256);
    defer analyzer.deinit();

    var wf_gpu = WaterfallGpu.init(gpu_device, analyzer.fftSize(), 256);
    defer wf_gpu.deinit();

    var last_retune_time_ms: u64 = 0;

    var running = true;
    while (running) {
        {
            var event: zsdl.Event = undefined;
            while (zsdl.pollEvent(&event)) {
                _ = zgui.backend.processEvent(@ptrCast(&event));
                if (event.type == .quit) {
                    running = false;
                }
            }
        }

        if (sdr != null) {
            _ = analyzer.processFrame(&sdr.?.mutex, &sdr.?.rx_buffer);
        }

        if (analyzer.waterfall.dirty) {
            analyzer.waterfall.renderPixels();
            wf_gpu.upload(&analyzer.waterfall);
        }

        {
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
                config.render(if (sdr != null) sdr.?.device else null);

                if (config.connect_requested) {
                    config.connect_requested = false;
                    config.connect_error_msg = null;

                    sdr = SDR.init(alloc) catch |err| blk: {
                        config.connect_error_msg = lookupErrMsg(err);
                        break :blk null;
                    };

                    if (sdr != null) {
                        config.readDeviceInfo(sdr.?.device);
                        config.applyAll(sdr.?.device);
                        analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                        try sdr.?.startRx();
                    }
                }

                if (config.disconnect_requested) {
                    config.disconnect_requested = false;
                    sdr.?.rx_running = false;
                    try sdr.?.deinit(alloc);
                    sdr = null;
                    config.clearDeviceInfo();
                    config.connect_error_msg = null;
                    analyzer.resetAll();
                }

                if (config.freq_changed) {
                    config.freq_changed = false;
                    analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                    analyzer.resetSmoothing();
                }

                if (config.sample_rate_changed) {
                    config.sample_rate_changed = false;
                    analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                }

                const ui_result = try analyzer.renderUi(zgui.io.getFramerate(), config.cf_mhz, config.fsHz());
                if (ui_result.resized) {
                    wf_gpu.resize(ui_result.new_fft_size, 256);
                }

                zgui.setNextWindowPos(.{ .x = 683, .y = 109, .cond = .first_use_ever });
                zgui.setNextWindowSize(.{ .w = 1149, .h = 810, .cond = .first_use_ever });

                if (zgui.begin("Data View", .{})) {
                    const avail = zgui.getContentRegionAvail();
                    const line_h = avail[1] * 0.35;
                    const wf_h = avail[1] * 0.60;

                    const display_data = analyzer.displayData();
                    const freq_data = analyzer.freqData();

                    var series_buf: [2]plot.PlotSeries = undefined;
                    var series_count: usize = 0;

                    series_buf[series_count] = .{
                        .label = "Magnitude",
                        .x_data = freq_data,
                        .y_data = display_data,
                    };
                    series_count += 1;

                    if (analyzer.peak_hold_enabled) {
                        series_buf[series_count] = .{
                            .label = "Peak Hold",
                            .x_data = freq_data,
                            .y_data = analyzer.peak_hold_data[0..analyzer.fftSize()],
                            .color = .{ 1.0, 0.2, 0.2, 0.8 },
                            .line_weight = 1.0,
                        };
                        series_count += 1;
                    }

                    const plot_result = plot.render(
                        "FFT",
                        "Freq (MHz)",
                        "dB",
                        series_buf[0..series_count],
                        .{ -120.0, 0.0 },
                        analyzer.xRange(),
                        analyzer.refit_x,
                        line_h,
                        null,
                    );
                    analyzer.refit_x = false;

                    if (sdr != null and plot_result.hovered) {
                        const plot_center = (plot_result.limits.x_min + plot_result.limits.x_max) / 2.0;
                        const cf_mhz: f64 = @floatCast(config.cf_mhz);
                        const diff = @abs(plot_center - cf_mhz);

                        if (diff > 0.1) {
                            const now = zsdl.getTicks();
                            if (now >= last_retune_time_ms + 100) {
                                last_retune_time_ms = now;
                                const new_cf_hz: u64 = @intFromFloat(@max(0.0, plot_center * 1e6));
                                if (new_cf_hz > 0) {
                                    sdr.?.device.setFreq(new_cf_hz) catch {};
                                    config.cf_mhz = @floatCast(plot_center);
                                    analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                                    analyzer.resetSmoothing();
                                }
                            }
                        }
                    }

                    if (wf_gpu.binding.texture != null) {
                        const tex_ref = zgui.TextureRef{
                            .tex_data = null,
                            .tex_id = @enumFromInt(@intFromPtr(&wf_gpu.binding)),
                        };
                        const window_pos = zgui.getWindowPos();
                        const plot_left_local = plot_result.plot_pos[0] - window_pos[0];
                        const waterfall_width = plot_result.plot_size[0];
                        zgui.setCursorPosX(plot_left_local);
                        zgui.image(tex_ref, .{ .w = waterfall_width, .h = wf_h });
                    }
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
    }

    if (sdr != null) {
        sdr.?.rx_running = false;
        try sdr.?.deinit(alloc);
    }
}
