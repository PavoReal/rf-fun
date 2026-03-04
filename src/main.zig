const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const Waterfall = @import("waterfall.zig").Waterfall;
const util = @import("util.zig");
const hackrf_config = @import("hackrf_config.zig");
const HackRFConfig = hackrf_config.HackRFConfig;
const FreqWidget = @import("freq_widget.zig").FreqWidget;
const SpectrumAnalyzer = @import("spectrum_analyzer.zig").SpectrumAnalyzer;
const signal_stats = @import("signal_stats.zig");
const SaveManager = @import("save_manager.zig").SaveManager;
const SampleBuffer = @import("sample_buffer.zig").SampleBuffer;
const RFSource = @import("rf_source.zig").RFSource;
const FileSource = @import("file_source.zig").FileSource;
const stats_window_mod = @import("stats_window.zig");
const StatsWindow = stats_window_mod.StatsWindow;
const PipelineInfo = stats_window_mod.PipelineInfo;
const SystemSnapshot = stats_window_mod.SystemSnapshot;
const BufferSnapshot = stats_window_mod.BufferSnapshot;
const radio_decoder_mod = @import("radio_decoder.zig");
const RadioDecoder = radio_decoder_mod.RadioDecoder;
const ModulationType = radio_decoder_mod.ModulationType;
const channel_manager_mod = @import("channel_manager.zig");
const ChannelManager = channel_manager_mod.ChannelManager;
const ChannelStripUi = @import("channel_strip_ui.zig").ChannelStripUi;
const GuiState = @import("gui_state.zig").GuiState;
const FreqReference = @import("freq_reference.zig").FreqReference;
const freq_db = @import("freq_db.zig");
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
    state.sample_buf.mutex.lock();
    defer state.sample_buf.mutex.unlock();

    state.sample_buf.bytes_received += trans.validLength();
    state.sample_buf.rx_buffer.append(trans.iqSamples());

    if (!state.rx_running) return .stop;
    return .@"continue";
}

const SDR = struct {
    const Self = @This();

    device: hackrf.Device = undefined,
    rx_running: bool = false,
    sample_buf: *SampleBuffer,

    pub fn init(sample_buf: *SampleBuffer) !Self {
        var self = Self{ .sample_buf = sample_buf };
        try hackrf.init();

        var list = try hackrf.DeviceList.get();
        defer list.deinit();

        if (list.count() == 0) return error.NoDeviceFound;

        self.device = try hackrf.Device.open();
        self.device.stopTx() catch {};

        return self;
    }

    pub fn startRx(self: *Self) !void {
        self.rx_running = true;
        try self.device.startRx(*Self, sdrRxCallback, self);
    }

    pub fn deinit(self: *Self) !void {
        self.rx_running = false;

        var timeout: u32 = 0;
        while (self.device.isStreaming() and timeout < 100) : (timeout += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

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
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
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

    var left_top_id: zgui.Ident = undefined;
    var left_bottom_id: zgui.Ident = undefined;
    _ = zgui.dockBuilderSplitNode(left_id, .up, 0.53, &left_top_id, &left_bottom_id);

    zgui.dockBuilderDockWindow("###HackRF Config", left_top_id);
    zgui.dockBuilderDockWindow("###Save", left_top_id);
    zgui.dockBuilderDockWindow("###Freq Ref", left_top_id);
    zgui.dockBuilderDockWindow("###Radio Decoder", left_bottom_id);
    zgui.dockBuilderDockWindow("###Channel Monitor", left_bottom_id);
    zgui.dockBuilderDockWindow("###Analysis", analysis_id);
    zgui.dockBuilderDockWindow("###Stats", stats_id);
    zgui.dockBuilderDockWindow("###Data View", bottom_id);
    zgui.dockBuilderFinish(dockspace_id);
}

fn renderTopBar(freq_widget: *FreqWidget, config: *HackRFConfig, sdr: ?SDR) void {
    const bar_start = zgui.getCursorScreenPos();
    const draw_list = zgui.getWindowDrawList();
    const base = zgui.getStyle().font_size_base;
    const label_h = base + 2.0;
    const label_color: u32 = 0x99_FF_FF_FF;

    const top_bar_scale: f32 = 2.0;
    const scaled_base = base * top_bar_scale;

    zgui.setCursorScreenPos(.{ bar_start[0], bar_start[1] + label_h });

    zgui.pushFont(freq_widget.large_font, scaled_base);
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 4.0 * top_bar_scale, 3.0 * top_bar_scale } });

    const is_connected = sdr != null;
    if (is_connected) {
        if (zgui.button("Disconnect", .{})) config.disconnect_requested = true;
    } else {
        if (zgui.button("Connect", .{})) config.connect_requested = true;
    }

    if (config.connect_error_msg) |msg| {
        zgui.sameLine(.{});
        zgui.textColored(.{ 0.9, 0.1, 0.1, 1 }, "{s}", .{msg});
    }

    zgui.popStyleVar(.{});
    zgui.popFont();

    zgui.sameLine(.{ .spacing = 16 });

    const freq_pos = zgui.getCursorScreenPos();
    zgui.pushFont(freq_widget.large_font, scaled_base);
    draw_list.addTextUnformatted(.{ freq_pos[0], bar_start[1] }, label_color, "Center Freq");
    zgui.popFont();
    freq_widget.render(config, if (sdr != null) sdr.?.device else null);

}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    var sdr: ?SDR = null;
    var consumers_running: bool = false;
    var show_no_device_popup: bool = false;

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

    const has_saved_layout = blk: {
        std.fs.cwd().access("imgui.ini", .{}) catch break :blk false;
        break :blk true;
    };
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

    const large_font_config = blk: {
        var fc = zgui.FontConfig.init();
        fc.size_pixels = 64.0;
        break :blk fc;
    };
    const large_font = zgui.io.addFontDefault(large_font_config);

    var config: HackRFConfig = .{};
    config.load();
    defer config.save();

    var sample_buf = try SampleBuffer.init(alloc, config.rxBufSamples());
    defer sample_buf.deinit(alloc);

    var rf_source: RFSource = .{
        .file_source = .{ .sample_buf = &sample_buf },
    };

    var freq_widget = FreqWidget.init(config.cf_mhz, large_font);

    var gui_state: GuiState = .{};
    gui_state.load();

    config.theme_index = gui_state.theme_index;
    switch (gui_state.theme_index) {
        0 => zgui.getStyle().setColorsBuiltin(.dark),
        1 => zgui.getStyle().setColorsBuiltin(.light),
        2 => zgui.getStyle().setColorsBuiltin(.classic),
        else => {},
    }
    zgui.getStyle().font_size_base = gui_state.font_size;
    zgui.getStyle().scaleAllSizes(1.3);

    config.connect_requested = true;

    var save_mgr: SaveManager = .{};
    var freq_ref: FreqReference = .{};
    freq_ref.loadPins();

    var analyzer = try SpectrumAnalyzer.init(alloc, gui_state.spec_fft_size_index, gui_state.spec_window_index, config.cf_mhz, config.fsHz(), 256);
    defer analyzer.deinit();
    analyzer.avg_count = gui_state.spec_avg_count;
    analyzer.peak_hold_enabled = gui_state.spec_peak_hold_enabled;
    analyzer.peak_decay_rate = gui_state.spec_peak_decay_rate;
    analyzer.dc_filter_enabled = gui_state.spec_dc_filter_enabled;
    analyzer.waterfall.db_min = gui_state.spec_wf_db_min;
    analyzer.waterfall.db_max = gui_state.spec_wf_db_max;
    analyzer.waterfall.rebuildLut();
    analyzer.syncWorkerParams();

    var radio_decoder = try RadioDecoder.init(alloc, config.fsHz(), config.cf_mhz);
    defer radio_decoder.deinit();
    radio_decoder.applyGuiState(&gui_state);

    var channel_mgr = try ChannelManager.init(alloc, config.fsHz(), config.cf_mhz);
    defer channel_mgr.deinit();
    channel_mgr.master_volume = gui_state.channel_master_volume;
    channel_mgr.global_squelch_db = gui_state.channel_global_squelch;

    var channel_strip_ui: ChannelStripUi = .{};
    channel_strip_ui.preset_index = gui_state.channel_preset_index;

    var wf_gpu = WaterfallGpu.init(gpu_device, analyzer.fftSize(), 256);
    defer wf_gpu.deinit();

    var stats_win: StatsWindow = .{};
    stats_win.num_display_peaks = @intCast(@max(0, gui_state.stats_num_peaks));

    defer {
        freq_ref.savePins();
        gui_state.collect(&analyzer, &radio_decoder, &stats_win);
        gui_state.channel_master_volume = channel_mgr.master_volume;
        gui_state.channel_preset_index = channel_strip_ui.preset_index;
        gui_state.channel_global_squelch = channel_mgr.global_squelch_db;
        gui_state.theme_index = config.theme_index;
        gui_state.font_size = zgui.getStyle().font_size_base;
        gui_state.save();
    }

    var drag_freq: f64 = radio_decoder.ui_freq_mhz;
    var last_retune_time_ms: u64 = 0;
    var dock_init_frames: u32 = 0;
    var last_plot_limits: plot.PlotLimits = .{ .x_min = 0, .x_max = 0 };

    var running = true;
    while (running) {
        {
            var event: zsdl.Event = undefined;
            while (zsdl.pollEvent(&event)) {
                _ = zgui.backend.processEvent(@ptrCast(&event));
                if (event.type == .quit) {
                    running = false;
                }
                if (event.type == .mouse_wheel and freq_widget.widget_hovered) {
                    freq_widget.feedScrollDelta(event.wheel.y);
                }
            }
        }

        if (consumers_running) {
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

            const vp = zgui.getMainViewport();
            const vp_pos = vp.getPos();
            const vp_size = vp.getSize();
            const top_bar_h = FreqWidget.getBarHeight();

            zgui.setNextWindowPos(.{ .x = vp_pos[0], .y = vp_pos[1] });
            zgui.setNextWindowSize(.{ .w = vp_size[0], .h = top_bar_h });
            if (zgui.begin("##TopBar", .{ .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_scroll_with_mouse = true,
                .no_collapse = true,
                .no_docking = true,
                .no_saved_settings = true,
                .no_bring_to_front_on_focus = true,
            } })) {
                renderTopBar(&freq_widget, &config, sdr);
            }
            zgui.end();

            vp.work_pos[1] = vp_pos[1] + top_bar_h;
            vp.work_size[1] = vp_size[1] - top_bar_h;

            const dockspace_id: zgui.Ident = 0xB00B1E5;
            if (dock_init_frames < 3) {
                dock_init_frames += 1;
                if (dock_init_frames == 3 and !has_saved_layout) {
                    buildDefaultDockLayout(dockspace_id);
                }
            }
            _ = zgui.dockSpaceOverViewport(dockspace_id, vp, .{ .passthru_central_node = true });

            if (config.reset_layout_requested) {
                config.reset_layout_requested = false;
                buildDefaultDockLayout(dockspace_id);
            }

            {
                rf_source.render(&config, if (sdr != null) sdr.?.device else null, @ptrCast(window));

                save_mgr.render(
                    &sample_buf,
                    consumers_running,
                    &config,
                    alloc,
                    @ptrCast(window),
                );

                if (config.connect_requested) {
                    config.connect_requested = false;
                    config.connect_error_msg = null;

                    sdr = SDR.init(&sample_buf) catch |err| blk: {
                        config.connect_error_msg = lookupErrMsg(err);
                        break :blk null;
                    };

                    if (sdr == null) {
                        show_no_device_popup = true;
                        zgui.openPopup("No Device", .{});
                    } else {
                        show_no_device_popup = false;
                    }

                    if (sdr != null) {
                        config.readDeviceInfo(sdr.?.device);
                        config.applyAll(sdr.?.device);
                        analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                        radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                        channel_mgr.updateFreqs(config.cf_mhz, config.fsHz());
                        try sdr.?.startRx();
                        try analyzer.startThread(&sample_buf.mutex, &sample_buf.rx_buffer);
                        try radio_decoder.start(&sample_buf.mutex, &sample_buf.rx_buffer);
                        try channel_mgr.start(&sample_buf.mutex, &sample_buf.rx_buffer);
                        consumers_running = true;
                    }
                }

                if (show_no_device_popup) {
                    const popup_vp = zgui.getMainViewport();
                    const popup_vp_size = popup_vp.getSize();
                    zgui.setNextWindowPos(.{ .x = popup_vp_size[0] / 2.0 - 150.0, .y = popup_vp_size[1] / 2.0 - 60.0 });
                    zgui.setNextWindowSize(.{ .w = 300, .h = 120 });

                    if (zgui.beginPopupModal("No Device", .{ .flags = .{ .no_resize = true, .no_move = true } })) {
                        zgui.text("No HackRF device detected.", .{});
                        zgui.spacing();
                        zgui.separator();
                        zgui.spacing();

                        if (zgui.button("Scan for device", .{})) {
                            config.connect_requested = true;
                            zgui.closeCurrentPopup();
                        }
                        zgui.sameLine(.{});
                        if (zgui.button("Exit", .{})) {
                            running = false;
                        }
                        zgui.endPopup();
                    }
                }

                if (config.disconnect_requested) {
                    config.disconnect_requested = false;
                    channel_mgr.stop();
                    radio_decoder.stop();
                    analyzer.stopThread();
                    consumers_running = false;
                    sdr.?.rx_running = false;
                    try sdr.?.deinit();
                    sdr = null;
                    sample_buf.reset();
                    config.clearDeviceInfo();
                    config.connect_error_msg = null;
                    analyzer.resetAll();
                }

                if (config.freq_changed) {
                    config.freq_changed = false;
                    analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                    analyzer.resetSmoothing();
                    radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                    channel_mgr.updateFreqs(config.cf_mhz, config.fsHz());
                    drag_freq = radio_decoder.ui_freq_mhz;
                }

                if (config.sample_rate_changed) {
                    config.sample_rate_changed = false;
                    analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                    radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                    channel_mgr.updateFreqs(config.cf_mhz, config.fsHz());
                    drag_freq = radio_decoder.ui_freq_mhz;
                }

                {
                    const retune_raw = radio_decoder.retune_center_requested.swap(0, .acquire);
                    if (retune_raw != 0) {
                        const desired_freq: f64 = @bitCast(retune_raw);
                        if (sdr != null) {
                            const cf_offset_mhz = config.fsHz() / 4e6;
                            const new_cf_mhz = desired_freq - cf_offset_mhz;
                            const new_cf_hz: u64 = @intFromFloat(@max(0.0, new_cf_mhz * 1e6));
                            if (new_cf_hz > 0) {
                                sdr.?.device.setFreq(new_cf_hz) catch {};
                                config.cf_mhz = @floatCast(new_cf_mhz);
                                analyzer.updateFreqs(config.cf_mhz, config.fsHz());
                                analyzer.resetSmoothing();
                                radio_decoder.updateFreqs(config.cf_mhz, config.fsHz());
                                channel_mgr.updateFreqs(config.cf_mhz, config.fsHz());
                                radio_decoder.setFreqMhz(desired_freq);
                                drag_freq = radio_decoder.ui_freq_mhz;
                            }
                        }
                    }
                }

                if (config.rx_buf_size_changed) {
                    config.rx_buf_size_changed = false;
                    sample_buf.resizeBuffer(alloc, config.rxBufSamples()) catch {};
                }

                if (rf_source.source_changed) {
                    rf_source.source_changed = false;
                    if (consumers_running) {
                        rf_source.file_source.stop();
                        channel_mgr.stop();
                        radio_decoder.stop();
                        analyzer.stopThread();
                        consumers_running = false;
                    }
                    if (sdr != null) {
                        sdr.?.rx_running = false;
                        try sdr.?.deinit();
                        sdr = null;
                        config.clearDeviceInfo();
                    }
                    sample_buf.reset();
                    analyzer.resetAll();
                }

                if (rf_source.play_requested) {
                    rf_source.play_requested = false;
                    config.cf_mhz = rf_source.file_source.center_freq_mhz;
                    const file_sr: f64 = @floatFromInt(rf_source.file_source.sample_rate);
                    analyzer.updateFreqs(config.cf_mhz, file_sr);
                    radio_decoder.updateFreqs(config.cf_mhz, file_sr);
                    channel_mgr.updateFreqs(config.cf_mhz, file_sr);
                    try rf_source.file_source.play();
                    try analyzer.startThread(&sample_buf.mutex, &sample_buf.rx_buffer);
                    try radio_decoder.start(&sample_buf.mutex, &sample_buf.rx_buffer);
                    try channel_mgr.start(&sample_buf.mutex, &sample_buf.rx_buffer);
                    consumers_running = true;
                }

                if (rf_source.stop_requested) {
                    rf_source.stop_requested = false;
                    rf_source.file_source.stop();
                    channel_mgr.stop();
                    radio_decoder.stop();
                    analyzer.stopThread();
                    consumers_running = false;
                    sample_buf.reset();
                    analyzer.resetAll();
                }

                radio_decoder.renderUi();
                channel_strip_ui.render(&channel_mgr);
                freq_ref.visible_x_min = last_plot_limits.x_min;
                freq_ref.visible_x_max = last_plot_limits.x_max;
                freq_ref.render(&radio_decoder);

                if (@abs(drag_freq - radio_decoder.ui_freq_mhz) > 0.0001) {
                    drag_freq = radio_decoder.ui_freq_mhz;
                }

                const radio_ts = radio_decoder.threadStats();

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
                        .thread_stats = radio_ts,
                        .dsp_rate = radio_decoder.dspRate(),
                    },
                    .{
                        .name = "Channel Monitor",
                        .pipeline = channel_mgr.pipelineView(),
                        .thread_stats = channel_mgr.threadStats(),
                        .dsp_rate = channel_mgr.dspRate(),
                    },
                };

                const buf_snap: BufferSnapshot = if (consumers_running) blk: {
                    sample_buf.mutex.lock();
                    defer sample_buf.mutex.unlock();
                    break :blk .{
                        .count = sample_buf.rx_buffer.count,
                        .capacity = sample_buf.rx_buffer.buf.len,
                        .total_written = sample_buf.rx_buffer.total_written,
                        .rx_bytes = sample_buf.bytes_received,
                    };
                } else .{};

                const sys = SystemSnapshot{
                    .fps = zgui.io.getFramerate(),
                    .buf = buf_snap,
                    .sample_rate = config.fsHz(),
                    .sdr_connected = sdr != null,
                    .radio_enabled = radio_decoder.ui_enabled,
                    .squelch_open = radio_decoder.worker.squelch_open_atomic.load(.acquire) != 0,
                    .audio_underruns = radio_decoder.audioUnderruns(),
                    .channel_monitor_enabled = channel_mgr.isEnabled(),
                    .channel_count = channel_mgr.active_count,
                };

                stats_win.render(&pipelines, &analyzer.stats, analyzer.has_frame, sys);

                const ui_result = try analyzer.renderUi(zgui.io.getFramerate(), config.cf_mhz, config.fsHz());
                if (ui_result.resized) {
                    wf_gpu.resize(ui_result.new_fft_size, 256);
                    if (consumers_running) {
                        try analyzer.startThread(&sample_buf.mutex, &sample_buf.rx_buffer);
                    }
                }

                if (zgui.begin("FFT###Data View", .{})) {
                    if (analyzer.user_zoomed) {
                        const span = analyzer.zoom_x_max - analyzer.zoom_x_min;
                        zgui.text("{d:.3} - {d:.3} MHz ({d:.3} MHz span)", .{
                            analyzer.zoom_x_min, analyzer.zoom_x_max, span,
                        });
                        zgui.sameLine(.{});
                        if (zgui.button("Reset Zoom", .{})) {
                            analyzer.resetZoom();
                        }
                    }

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

                    var channel_bands: [channel_manager_mod.MAX_CHANNELS + freq_db.flat_entries.len + 2]plot.BandX = undefined;
                    var band_count: usize = 0;

                    if (radio_decoder.ui_enabled) {
                        const mod: ModulationType = @enumFromInt(@as(u8, @intCast(radio_decoder.ui_modulation_index)));
                        channel_bands[band_count] = .{
                            .center = drag_freq,
                            .half_width = mod.bandwidthMhz() / 2.0,
                            .color = .{ 1.0, 0.0, 1.0, 0.15 },
                        };
                        band_count += 1;
                    }

                    if (channel_mgr.isEnabled()) {
                        channel_mgr.channels_mutex.lock();
                        defer channel_mgr.channels_mutex.unlock();

                        for (&channel_mgr.channels) |*slot| {
                            if (slot.*) |*ch| {
                                if (!ch.enabled) continue;
                                const sq_open = ch.isSquelchOpen();
                                channel_bands[band_count] = .{
                                    .center = ch.config.freq_mhz,
                                    .half_width = ch.config.modulation.bandwidthMhz() / 2.0,
                                    .color = if (sq_open) .{ 0.1, 0.8, 0.1, 0.2 } else .{ 0.5, 0.5, 0.5, 0.1 },
                                    .label = ch.config.label,
                                    .label_len = ch.config.label_len,
                                };
                                band_count += 1;
                            }
                        }
                    }

                    for (freq_db.flat_entries, 0..) |fe, i| {
                        if (!freq_ref.pinned[i]) continue;
                        const entry = fe.entry;
                        var mode_color = entry.mode.color();
                        mode_color[3] = 0.12;
                        const center = (entry.freq_start_mhz + entry.freq_end_mhz) / 2.0;
                        const half_w = (entry.freq_end_mhz - entry.freq_start_mhz) / 2.0;
                        channel_bands[band_count] = .{
                            .center = center,
                            .half_width = if (half_w < 0.001) 0.005 else half_w,
                            .color = mode_color,
                        };
                        const name_len = @min(entry.name.len, 16);
                        @memcpy(channel_bands[band_count].label[0..name_len], entry.name[0..name_len]);
                        channel_bands[band_count].label_len = @intCast(name_len);
                        band_count += 1;
                    }

                    if (freq_ref.hovered_flat_idx) |hover_idx| {
                        const entry = freq_db.flat_entries[hover_idx].entry;
                        var hover_color = entry.mode.color();
                        hover_color[3] = 0.25;
                        const center = (entry.freq_start_mhz + entry.freq_end_mhz) / 2.0;
                        const half_w = (entry.freq_end_mhz - entry.freq_start_mhz) / 2.0;
                        channel_bands[band_count] = .{
                            .center = center,
                            .half_width = if (half_w < 0.001) 0.005 else half_w,
                            .color = hover_color,
                        };
                        const name_len = @min(entry.name.len, 16);
                        @memcpy(channel_bands[band_count].label[0..name_len], entry.name[0..name_len]);
                        channel_bands[band_count].label_len = @intCast(name_len);
                        band_count += 1;
                    }

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
                        channel_bands[0..band_count],
                    );
                    analyzer.refit_x = false;
                    last_plot_limits = plot_result.limits;
                    analyzer.updateZoomState(plot_result.limits.x_min, plot_result.limits.x_max);

                    if (plot_result.drag_line_moved) {
                        radio_decoder.setFreqMhz(drag_freq);
                    }

                    if (sdr != null and consumers_running and plot_result.hovered and !analyzer.user_zoomed) {
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
                        const wf_screen_pos = zgui.getCursorScreenPos();

                        var wf_uv0 = [2]f32{ 0.0, 0.0 };
                        var wf_uv1 = [2]f32{ 1.0, 1.0 };
                        if (analyzer.xRange()) |full| {
                            const full_span = full[1] - full[0];
                            if (full_span > 0) {
                                wf_uv0[0] = std.math.clamp(@as(f32, @floatCast(
                                    (plot_result.limits.x_min - full[0]) / full_span,
                                )), 0.0, 1.0);
                                wf_uv1[0] = std.math.clamp(@as(f32, @floatCast(
                                    (plot_result.limits.x_max - full[0]) / full_span,
                                )), 0.0, 1.0);
                            }
                        }
                        zgui.image(tex_ref, .{ .w = waterfall_width, .h = wf_h, .uv0 = wf_uv0, .uv1 = wf_uv1 });

                        {
                            const x_range = plot_result.limits.x_max - plot_result.limits.x_min;
                            if (x_range > 0) {
                                const wf_top = wf_screen_pos[1];
                                const wf_bot = wf_top + wf_h;
                                const draw_list = zgui.getWindowDrawList();

                                if (band_count > 0) {
                                    for (channel_bands[0..band_count]) |b| {
                                        const t_lo: f32 = @floatCast(((b.center - b.half_width) - plot_result.limits.x_min) / x_range);
                                        const t_hi: f32 = @floatCast(((b.center + b.half_width) - plot_result.limits.x_min) / x_range);
                                        if (t_hi < 0.0 or t_lo > 1.0) continue;
                                        const band_x0 = wf_screen_pos[0] + @max(0.0, t_lo) * waterfall_width;
                                        const band_x1 = wf_screen_pos[0] + @min(1.0, t_hi) * waterfall_width;
                                        draw_list.addRectFilled(.{
                                            .pmin = .{ band_x0, wf_top },
                                            .pmax = .{ band_x1, wf_bot },
                                            .col = zgui.colorConvertFloat4ToU32(b.color),
                                        });
                                    }
                                }

                                if (radio_decoder.ui_enabled) {
                                    const t: f32 = @floatCast((drag_freq - plot_result.limits.x_min) / x_range);
                                    if (t >= 0.0 and t <= 1.0) {
                                        const line_x = wf_screen_pos[0] + t * waterfall_width;
                                        draw_list.addLine(.{
                                            .p1 = .{ line_x, wf_top },
                                            .p2 = .{ line_x, wf_bot },
                                            .col = 0xE6_FF_00_FF,
                                            .thickness = 2.0,
                                        });
                                    }
                                }
                            }
                        }
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

    rf_source.file_source.stop();
    if (consumers_running) {
        channel_mgr.stop();
        radio_decoder.stop();
        analyzer.stopThread();
    }
    if (sdr != null) {
        sdr.?.rx_running = false;
        try sdr.?.deinit();
    }
}
