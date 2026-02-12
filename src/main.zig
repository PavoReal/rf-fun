const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const util = @import("util.zig");

const zsdl = @import("zsdl3");
const zgui = @import("zgui");

// SDL3 GPU functions via C interop
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const RXCallbackState = struct {
    mutex: std.Thread.Mutex = .{},
    should_stop: bool = true,
    bytes_transfered: u64 = 0,
    target_buffer: *FixedSizeRingBuffer(hackrf.IQSample),
};

fn rxCallback(trans: hackrf.Transfer, state: *RXCallbackState) hackrf.StreamAction {
    state.mutex.lock();
    defer state.mutex.unlock();

    const valid_length = trans.validLength();
    state.bytes_transfered += valid_length;

    state.target_buffer.append(trans.iqSamples());

    if (state.should_stop) return .stop;
    return .@"continue";
}

pub fn main() !void {
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

    const fs = util.mhz(10);
    const center_freq = util.ghz(0.9);

    device.stopTx() catch {};
    try device.setSampleRate(fs);
    try device.setFreq(center_freq);
    try device.setAmpEnable(true);

    std.log.debug("hackrf config done", .{});

    var rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, util.mb(256));
    defer rx_buffer.deinit(alloc);

    var rx_state = RXCallbackState{
        .target_buffer = &rx_buffer,
        .should_stop = false,
    };

    try device.startRx(*RXCallbackState, rxCallback, &rx_state);

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

    var fft = try SimpleFFT.init(alloc, 512, center_freq, fs);
    defer fft.deinit(alloc);

    var next_fft_update_time = zsdl.getTicks() + 500; // ms

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

        // FFT update
        const current_time = zsdl.getTicks();
        if (current_time >= next_fft_update_time) {
            rx_state.mutex.lock();
            defer rx_state.mutex.unlock();

            std.log.debug("fft update", .{});
            next_fft_update_time = current_time + 500;
        }

        // Acquire GPU command buffer
        const cmd_buf = c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse continue;

        // Acquire swapchain texture
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

        // Calculate pixel scale for high-DPI
        var win_w: c_int = 0;
        var win_h: c_int = 0;
        zsdl.getWindowSize(window, &win_w, &win_h) catch {};
        const fb_scale: f32 = if (win_w > 0) @as(f32, @floatFromInt(sw_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

        // Begin ImGui frame
        zgui.backend.newFrame(sw_w, sw_h, fb_scale);

        // ImGui content
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
                zgui.text("FPS: {d:.0}", .{zgui.io.getFramerate()});
                plot.render("512 point FFT", "Freq (MHz)", "dB", fft.fft_freqs, fft.fft_mag, .{ -120.0, 0.0 });
            }
            zgui.end();
        }

        // Finalize ImGui rendering
        zgui.backend.render();

        // Prepare ImGui draw data (uploads to GPU before render pass)
        zgui.backend.prepareDrawData(@ptrCast(cmd_buf));

        // Begin render pass
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

        // Submit
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    }

    rx_state.should_stop = true;
}
