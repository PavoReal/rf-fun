const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const Waterfall = @import("waterfall.zig").Waterfall;
const util = @import("util.zig");
const HackRFConfig = @import("hackrf_config.zig").HackRFConfig;
const SpectrumAnalyzer = @import("spectrum_analyzer.zig").SpectrumAnalyzer;
const signal_stats = @import("signal_stats.zig");
const SaveManager = @import("save_manager.zig").SaveManager;
const stats_window_mod = @import("stats_window.zig");
const StatsWindow = stats_window_mod.StatsWindow;
const PipelineInfo = stats_window_mod.PipelineInfo;
const radio_decoder_mod = @import("radio_decoder.zig");
const RadioDecoder = radio_decoder_mod.RadioDecoder;
const ModulationType = radio_decoder_mod.ModulationType;
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

    pub fn init(alloc: std.mem.Allocator, rx_buf_samples: usize) !Self {
        var self = Self{};
        try hackrf.init();

        var list = try hackrf.DeviceList.get();
        defer list.deinit();

        if (list.count() == 0) return error.NoDeviceFound;

        self.device = try hackrf.Device.open();
        self.device.stopTx() catch {};

        self.rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, rx_buf_samples);

        return self;
    }

    pub fn resizeBuffer(self: *Self, alloc: std.mem.Allocator, new_count: usize) !void {
        const new_buf = try alloc.alloc(hackrf.IQSample, new_count);
        self.mutex.lock();
        defer self.mutex.unlock();
        alloc.free(self.rx_buffer.buf);
        self.rx_buffer.buf = new_buf;
        self.rx_buffer.head = 0;
        self.rx_buffer.count = 0;
        self.rx_bytes_received = 0;
    }

    pub fn startRx(self: *Self) !void {
        self.rx_running = true;
        try self.device.startRx(*Self, sdrRxCallback, self);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) !void {
        self.rx_running = false;

        var timeout: u32 = 0;
        while (self.device.isStreaming() and timeout < 100) : (timeout += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

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

fn buildDefaultDockLayout(dockspace_id: zgui.Ident) void {
    zgui.dockBuilderRemoveNode(dockspace_id);
    _ = zgui.dockBuilderAddNode(dockspace_id, .{ .dock_space = true });
    const vp = zgui.getMainViewport();
    const vp_size = vp.getSize();
    zgui.dockBuilderSetNodeSize(dockspace_id, vp_size);

    var right_id: zgui.Ident = undefined;
    var left_id: zgui.Ident = undefined;
    _ = zgui.dockBuilderSplitNode(dockspace_id, .left, 0.30, &left_id, &right_id);

    var top_id: zgui.Ident = undefined;
    var bottom_id: zgui.Ident = undefined;
    _ = zgui.dockBuilderSplitNode(right_id, .up, 0.25, &top_id, &bottom_id);

    var analysis_id: zgui.Ident = undefined;
    var stats_id: zgui.Ident = undefined;
    _ = zgui.dockBuilderSplitNode(top_id, .left, 0.6, &analysis_id, &stats_id);

    zgui.dockBuilderDockWindow("###HackRF Config", left_id);
    zgui.dockBuilderDockWindow("###Save", left_id);
    zgui.dockBuilderDockWindow("###Radio Decoder", left_id);
    zgui.dockBuilderDockWindow("###Analysis", analysis_id);
    zgui.dockBuilderDockWindow("###Stats", stats_id);
    zgui.dockBuilderDockWindow("###Data View", bottom_id);
    zgui.dockBuilderFinish(dockspace_id);
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    var sdr: ?SDR = null;

    try zsdl.init(.{ .video = true, .events = true, .audio = true });
    defer zsdl.quit();

    const window = try zsdl.createWindow("rf-fun", 800, 600, .{ .resizable = true, .high_pixel_density = true, .maximized = true });
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

    //zgui.io.setIniFilename(null);
    zgui.io.setConfigFlags(.{ .dock_enable = true });

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

    var save_mgr: SaveManager = .{};

    var analyzer = try SpectrumAnalyzer.init(alloc, 7, 3, config.cf_mhz, config.fsHz(), 256);
    defer analyzer.deinit();

    var radio_decoder = try RadioDecoder.init(alloc, config.fsHz(), config.cf_mhz);
    defer radio_decoder.deinit();

    var wf_gpu = WaterfallGpu.init(gpu_device, analyzer.fftSize(), 256);
    defer wf_gpu.deinit();

    var stats_win: StatsWindow = .{};

    var drag_freq: f64 = radio_decoder.ui_freq_mhz;
    var last_retune_time_ms: u64 = 0;
    var dock_init_frames: u32 = 0;

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
            _ = analyzer.pollFrame();
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

            zgui.backend.newFrame(@intCast(win_w), @intCast(win_h), fb_scale);

            const dockspace_id: zgui.Ident = 0xB00B1E5;
            if (dock_init_frames < 3) {
                dock_init_frames += 1;
                if (dock_init_frames == 3) {
                    buildDefaultDockLayout(dockspace_id);
                }
            }
            _ = zgui.dockSpaceOverViewport(dockspace_id, zgui.getMainViewport(), .{ .passthru_central_node = true });

            if (config.reset_layout_requested) {
                config.reset_layout_requested = false;
                buildDefaultDockLayout(dockspace_id);
            }

            {
                config.render(if (sdr != null) sdr.?.device else null);

                save_mgr.render(
                    if (sdr != null) &sdr.?.mutex else null,
                    if (sdr != null) &sdr.?.rx_buffer else null,
                    &config,
                    alloc,
                    @ptrCast(window),
                );

                if (config.connect_requested) {
                    config.connect_requested = false;
                    config.connect_error_msg = null;

                    sdr = SDR.init(alloc, config.rxBufSamples()) catch |err| blk: {
                        config.connect_error_msg = lookupErrMsg(err);
                        break :blk null;
                    };

                    if (sdr != null) {
                        config.readDeviceInfo(sdr.?.device);
                        config.applyAll(sdr.?.device);
                        analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                        radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                        try sdr.?.startRx();
                        try analyzer.startThread(&sdr.?.mutex, &sdr.?.rx_buffer);
                        try radio_decoder.start(&sdr.?.mutex, &sdr.?.rx_buffer);
                    }
                }

                if (config.disconnect_requested) {
                    config.disconnect_requested = false;
                    radio_decoder.stop();
                    analyzer.stopThread();
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
                    radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                    drag_freq = radio_decoder.ui_freq_mhz;
                }

                if (config.sample_rate_changed) {
                    config.sample_rate_changed = false;
                    analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                    radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                    drag_freq = radio_decoder.ui_freq_mhz;
                }

                if (config.rx_buf_size_changed) {
                    config.rx_buf_size_changed = false;
                    if (sdr != null) {
                        sdr.?.resizeBuffer(alloc, config.rxBufSamples()) catch {};
                    }
                }

                radio_decoder.renderUi();

                const pipelines = [_]PipelineInfo{
                    .{
                        .name = "Spectrum Analyzer",
                        .pipeline = analyzer.pipelineView(),
                        .thread_stats = analyzer.threadStats(),
                        .dsp_rate = analyzer.dspRate(),
                    },
                    .{
                        .name = "Radio Decoder",
                        .pipeline = radio_decoder.pipelineView(),
                        .thread_stats = radio_decoder.threadStats(),
                        .dsp_rate = radio_decoder.dspRate(),
                    },
                };
                stats_win.render(&pipelines, &analyzer.stats, analyzer.has_frame);

                const ui_result = try analyzer.renderUi(zgui.io.getFramerate(), config.cf_mhz, config.fsHz());
                if (ui_result.resized) {
                    wf_gpu.resize(ui_result.new_fft_size, 256);
                    if (sdr != null) {
                        try analyzer.startThread(&sdr.?.mutex, &sdr.?.rx_buffer);
                    }
                }

                if (zgui.begin("FFT###Data View", .{})) {
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
                            .y_data = analyzer.cached_peak[0..analyzer.fftSize()],
                            .color = .{ 1.0, 0.2, 0.2, 0.8 },
                            .line_weight = 1.0,
                        };
                        series_count += 1;
                    }

                    var peak_x: [signal_stats.MAX_PEAKS]f32 = undefined;
                    var peak_y: [signal_stats.MAX_PEAKS]f32 = undefined;
                    const num_peaks = @min(analyzer.stats.num_peaks, stats_win.num_display_peaks);
                    for (0..num_peaks) |i| {
                        peak_x[i] = analyzer.stats.peaks[i].freq_mhz;
                        peak_y[i] = analyzer.stats.peaks[i].power_db;
                    }

                    var markers_buf: [1]plot.PlotMarker = undefined;
                    var marker_count: usize = 0;
                    if (num_peaks > 0) {
                        markers_buf[0] = .{
                            .x_data = peak_x[0..num_peaks],
                            .y_data = peak_y[0..num_peaks],
                        };
                        marker_count = 1;
                    }

                    const decode_band: ?plot.BandX = if (radio_decoder.ui_enabled) blk: {
                        const mod: ModulationType = @enumFromInt(@as(u8, @intCast(radio_decoder.ui_modulation_index)));
                        break :blk .{
                            .center = drag_freq,
                            .half_width = mod.bandwidthMhz() / 2.0,
                        };
                    } else null;

                    const plot_result = plot.render(
                        "FFT",
                        "Freq (MHz)",
                        "dB",
                        series_buf[0..series_count],
                        markers_buf[0..marker_count],
                        .{ -120.0, 0.0 },
                        analyzer.xRange(),
                        analyzer.refit_x,
                        line_h,
                        null,
                        if (radio_decoder.ui_enabled) .{ .value = &drag_freq } else null,
                        decode_band,
                    );
                    analyzer.refit_x = false;

                    if (plot_result.drag_line_moved) {
                        radio_decoder.setFreqMhz(drag_freq);
                    }

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
                                    radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                                    drag_freq = radio_decoder.ui_freq_mhz;
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
        radio_decoder.stop();
        analyzer.stopThread();
        sdr.?.rx_running = false;
        try sdr.?.deinit(alloc);
    }
}
