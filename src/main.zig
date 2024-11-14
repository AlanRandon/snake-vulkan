const std = @import("std");
const vk = @import("./vulkan.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var window = try vk.GlfwWindow.init(800, 600, "Vulkan");
    defer window.deinit();

    var instance = try vk.Instance.init(allocator);
    defer instance.deinit();

    var surface = try vk.Surface.init(&instance, &window);
    defer surface.deinit();

    const physical_device = try vk.PhysicalDevice.findSuitable(&instance, &surface, allocator);
    var logical_device = try vk.LogicalDevice.init(&physical_device, &surface, allocator);
    defer logical_device.deinit();

    var swap_chain = try vk.SwapChain.init(&window, surface, &physical_device, &logical_device, allocator);
    defer swap_chain.deinit();

    var vert_shader = try vk.ShaderModule.initFromEmbed(&logical_device, "shader.vert.spv");
    defer vert_shader.deinit();

    var frag_shader = try vk.ShaderModule.initFromEmbed(&logical_device, "shader.frag.spv");
    defer frag_shader.deinit();

    var pipeline_layout = try vk.PipelineLayout.init(&logical_device);
    defer pipeline_layout.deinit();

    var render_pass = try vk.RenderPass.init(&swap_chain, &logical_device);
    defer render_pass.deinit();

    var pipeline = try vk.Pipeline.init(&pipeline_layout, &render_pass, &vert_shader, &frag_shader, &swap_chain, &logical_device);
    defer pipeline.deinit();

    std.debug.print("Running...\n", .{});

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        vk.c.glfwPollEvents();
    }
}
