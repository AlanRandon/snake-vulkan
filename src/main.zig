const std = @import("std");
const vk = @import("./vulkan.zig");
const Renderer = @import("./renderer.zig").Renderer;

const Vertex = struct {
    pos: vk.vertex.Vec2,
    color: vk.vertex.Vec3,

    const bind_desc = vk.vertex.bindVertex(Vertex, .{
        .binding = 0,
    });

    const attr_descs = vk.vertex.attributeDescriptions(Vertex, .{
        .binds = .{
            .pos = .{ .location = 0 },
            .color = .{ .location = 1 },
        },
        .binding = 0,
    });
};

const vertices = [_]Vertex{
    .{ .pos = [_]f32{ 0.0, -0.5 }, .color = [_]f32{ 1.0, 1.0, 1.0 } },
    .{ .pos = [_]f32{ 0.5, 0.5 }, .color = [_]f32{ 0.0, 1.0, 0.0 } },
    .{ .pos = [_]f32{ -0.5, 0.5 }, .color = [_]f32{ 1.0, 0.0, 1.0 } },
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

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

    var vertex_buffer = try vk.vertex.Buffer(Vertex).init(&vertices, &logical_device, &physical_device);
    defer vertex_buffer.deinit();

    var vert_shader = try vk.ShaderModule.initFromEmbed(&logical_device, "shader.vert.spv");
    defer vert_shader.deinit();

    var frag_shader = try vk.ShaderModule.initFromEmbed(&logical_device, "shader.frag.spv");
    defer frag_shader.deinit();

    var pipeline_layout = try vk.PipelineLayout.init(&logical_device);
    defer pipeline_layout.deinit();

    var swap_chain = try vk.SwapChain.init(&window, &surface, &physical_device, &logical_device, allocator);
    defer swap_chain.deinit();

    var render_pass = try vk.RenderPass.init(&swap_chain);
    defer render_pass.deinit();

    var pipeline = try vk.Pipeline.init(
        &pipeline_layout,
        &render_pass,
        &vert_shader,
        &frag_shader,
        &swap_chain,
        .{
            .vertex_binding_descs = &[_]vk.vertex.BindDesc{Vertex.bind_desc},
            .vertex_attribute_descs = &Vertex.attr_descs,
        },
    );
    defer pipeline.deinit();

    var framebuffers = try vk.Framebuffers.init(&render_pass, &swap_chain, allocator);
    defer framebuffers.deinit();

    var command_pool = try vk.CommandPool.init(&physical_device, &logical_device);
    defer command_pool.deinit();

    std.debug.print("Running...\n", .{});

    var renderer = try Renderer(2).init(&command_pool);
    defer renderer.deinit();

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        framebuffer_resized = false;
        vk.c.glfwPollEvents();
        var result: vk.c.VkResult = undefined;
        renderer.draw_frame(
            &swap_chain,
            &render_pass,
            &framebuffers,
            &pipeline,
            struct {
                fn draw(cmd_buf: anytype, vert_buf: anytype, verts: anytype) void {
                    vk.c.vkCmdBindVertexBuffers(cmd_buf, 0, 1, &vert_buf.buffer, &@as(u64, 0));
                    vk.c.vkCmdDraw(cmd_buf, verts.len, 1, 0, 0);
                }
            }.draw,
            .{ vertex_buffer, vertices },
            .{ .error_payload = &result },
        ) catch |err| switch (err) {
            error.VulkanFailedToAcquireImage => switch (result) {
                vk.c.VK_ERROR_OUT_OF_DATE_KHR => framebuffer_resized = true,
                vk.c.VK_SUBOPTIMAL_KHR => {},
                else => return,
            },
            error.VulkanFailedToPresent => switch (result) {
                vk.c.VK_ERROR_OUT_OF_DATE_KHR,
                vk.c.VK_SUBOPTIMAL_KHR,
                => framebuffer_resized = true,
                else => return,
            },
            else => return err,
        };

        if (framebuffer_resized) {
            _ = vk.c.vkDeviceWaitIdle(logical_device.device);
            framebuffers.deinit();
            swap_chain.deinit();
            swap_chain = try vk.SwapChain.init(&window, &surface, &physical_device, &logical_device, allocator);
            framebuffers = try vk.Framebuffers.init(&render_pass, &swap_chain, allocator);
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
