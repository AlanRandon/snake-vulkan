const std = @import("std");
const vk = @import("./vulkan.zig");
const Renderer = @import("./renderer.zig").Renderer(2);
const game = @import("./game.zig");
const GameRenderer = @import("./game/renderer.zig").GameRenderer;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // const grid = game.Grid(10, 10).init();

    var window = try vk.GlfwWindow.init(800, 600, "Vulkan");
    defer window.deinit();

    var framebuffer_resized = false;
    window.resizeCallback(struct {
        fn callback(opts: anytype) void {
            opts.user_data.* = true;
        }
    }.callback, &framebuffer_resized);

    var instance = try vk.Instance.init(allocator);
    defer instance.deinit();

    var surface = try vk.Surface.init(&instance, &window);
    defer surface.deinit();

    const physical_device = try vk.PhysicalDevice.findSuitable(&instance, &surface, allocator);
    var logical_device = try vk.LogicalDevice.init(&physical_device, &surface, allocator);
    defer logical_device.deinit();

    var gr = try GameRenderer.init(
        &logical_device,
        &physical_device,
        &window,
        &surface,
        allocator,
    );
    defer gr.deinit();

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        framebuffer_resized = false;

        vk.c.glfwPollEvents();

        try gr.render(.{ .framebuffer_resized = &framebuffer_resized });

        if (framebuffer_resized) {
            try gr.handleResize();
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
