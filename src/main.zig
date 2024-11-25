const std = @import("std");
const vk = @import("./vulkan.zig");
const Renderer = @import("./renderer.zig").Renderer(2);

const Vertex = struct {
    pos: vk.vertex.Vec2,
    color: vk.vertex.Vec3,
    tex_coord: vk.vertex.Vec2,

    const bind_desc = vk.vertex.bindVertex(Vertex, .{
        .binding = 0,
    });

    const attr_descs = vk.vertex.attributeDescriptions(Vertex, .{
        .binds = .{
            .pos = .{ .location = 0 },
            .color = .{ .location = 1 },
            .tex_coord = .{ .location = 2 },
        },
        .binding = 0,
    });
};

const Offset = struct {
    offset: vk.vertex.Vec2,
    tile_number: vk.vertex.Scalar,

    const bind_desc = vk.vertex.bindInstanced(Offset, .{
        .binding = 1,
    });

    const attr_descs = vk.vertex.attributeDescriptions(Offset, .{
        .binds = .{
            .offset = .{ .location = 3 },
            .tile_number = .{ .location = 4 },
        },
        .binding = 1,
    });
};

const ShaderGlobals = struct {
    winsize: vk.vertex.Vec2,
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

    var vert_shader = try vk.ShaderModule.initFromEmbed(&logical_device, "shader.vert.spv");
    defer vert_shader.deinit();

    var frag_shader = try vk.ShaderModule.initFromEmbed(&logical_device, "shader.frag.spv");
    defer frag_shader.deinit();

    var swap_chain = try vk.SwapChain.init(&window, &surface, &physical_device, &logical_device, allocator);
    defer swap_chain.deinit();

    var render_pass = try vk.RenderPass.init(&swap_chain);
    defer render_pass.deinit();

    var descriptor_set_layout = try vk.DescriptorSetLayout.init(
        &logical_device,
        &[_]vk.c.VkDescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptorCount = 1,
            .descriptorType = vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImmutableSamplers = null,
            .stageFlags = vk.c.VK_SHADER_STAGE_FRAGMENT_BIT,
        }},
    );
    defer descriptor_set_layout.deinit();

    var pipeline_layout = try vk.PipelineLayout.init(
        &logical_device,
        .{
            .push_constant_info = vk.pushConstantLayouts(&[_]vk.PushConstantDesc{.{ .ty = ShaderGlobals, .offset = 0 }}),
            .descriptor_set_layout = &descriptor_set_layout,
        },
    );
    defer pipeline_layout.deinit();

    var pipeline = try vk.Pipeline.init(
        &pipeline_layout,
        &render_pass,
        &vert_shader,
        &frag_shader,
        &swap_chain,
        .{
            .vertex_binding_descs = &[_]vk.vertex.BindDesc{ Vertex.bind_desc, Offset.bind_desc },
            .vertex_attribute_descs = &(Vertex.attr_descs ++ Offset.attr_descs),
        },
    );
    defer pipeline.deinit();

    var framebuffers = try vk.Framebuffers.init(&render_pass, &swap_chain, allocator);
    defer framebuffers.deinit();

    var command_pool = try vk.CommandPool.init(&physical_device, &logical_device);
    defer command_pool.deinit();

    var renderer = try Renderer.init(
        &command_pool,
        &descriptor_set_layout,
        .{
            .descriptor_set_types = &[_]vk.c.VkDescriptorType{vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER},
        },
    );
    defer renderer.deinit();

    var tiles = try vk.texture.TextureImage.init("asset:tiles.png", &logical_device, &physical_device, &command_pool);
    defer tiles.deinit();

    var tiles_view = try tiles.view();
    defer tiles_view.deinit();

    var tiles_sampler = try tiles_view.sampler(&physical_device, .{});
    defer tiles_sampler.deinit();

    const vertices = [_]Vertex{
        .{ .pos = [_]f32{ 0.0, 0.0 }, .color = [_]f32{ 1.0, 0.0, 0.0 }, .tex_coord = [_]f32{ 1.0, 0.0 } },
        .{ .pos = [_]f32{ 0.1, 0.0 }, .color = [_]f32{ 1.0, 0.0, 0.0 }, .tex_coord = [_]f32{ 0.0, 0.0 } },
        .{ .pos = [_]f32{ 0.1, 0.1 }, .color = [_]f32{ 1.0, 0.0, 0.0 }, .tex_coord = [_]f32{ 0.0, 1.0 } },
        .{ .pos = [_]f32{ 0.0, 0.1 }, .color = [_]f32{ 1.0, 0.0, 0.0 }, .tex_coord = [_]f32{ 1.0, 1.0 } },
    };
    const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
    const offsets = [_]Offset{
        .{ .offset = [_]f32{ 0.0, 0.0 }, .tile_number = 0.0 },
        .{ .offset = [_]f32{ 0.9, 0.0 }, .tile_number = 0.0 },
        .{ .offset = [_]f32{ 0.0, 0.9 }, .tile_number = 1.0 },
        .{ .offset = [_]f32{ 0.9, 0.9 }, .tile_number = 0.0 },
    };

    var vertex_buffer = try vk.vertex.VertexBuffer(Vertex).init(&vertices, &logical_device, &physical_device, &command_pool);
    defer vertex_buffer.deinit();

    var offset_buffer = try vk.vertex.VertexBuffer(Offset).init(&offsets, &logical_device, &physical_device, &command_pool);
    defer offset_buffer.deinit();

    var index_buffer = try vk.vertex.IndexBuffer(u16).init(&indices, &logical_device, &physical_device, &command_pool);
    defer index_buffer.deinit();

    var shader_globals = ShaderGlobals{
        .winsize = [_]f32{
            @floatFromInt(window.dimensions().width),
            @floatFromInt(window.dimensions().height),
        },
    };

    renderer.updateDescriptorSets(
        1,
        [_]Renderer.DescriptorSet{.{
            .binding = 0,
            .data = .{
                .image = .{
                    .view = &tiles_view,
                    .sampler = &tiles_sampler,
                },
            },
        }},
    );

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        framebuffer_resized = false;

        vk.c.glfwPollEvents();

        var result: vk.c.VkResult = undefined;
        const frame = renderer.begin_frame(&swap_chain, &render_pass, &framebuffers, &pipeline, .{ .error_payload = &result }) catch |err| switch (err) {
            error.VulkanFailedToAcquireImage => switch (result) {
                vk.c.VK_ERROR_OUT_OF_DATE_KHR => {
                    framebuffer_resized = true;
                    continue;
                },
                vk.c.VK_SUBOPTIMAL_KHR => continue,
                else => return,
            },
            else => return err,
        };

        frame.bindDescriptorSets(&pipeline_layout);
        frame.commandBuffer().bindIndexBuffer(&index_buffer);
        frame.commandBuffer().bindVertexBuffers(.{ &vertex_buffer, &offset_buffer });
        frame.commandBuffer().pushConstants(&pipeline_layout, &shader_globals, .{ .index = 0 });
        vk.c.vkCmdDrawIndexed(frame.commandBuffer().buffer, indices.len, offsets.len, 0, 0, 0);

        frame.draw(.{ .error_payload = &result }) catch |err| switch (err) {
            error.VulkanFailedToPresent => switch (result) {
                vk.c.VK_ERROR_OUT_OF_DATE_KHR,
                vk.c.VK_SUBOPTIMAL_KHR,
                => framebuffer_resized = true,
                else => return,
            },
            else => return err,
        };

        if (framebuffer_resized) {
            shader_globals = ShaderGlobals{
                .winsize = [_]f32{
                    @floatFromInt(window.dimensions().width),
                    @floatFromInt(window.dimensions().height),
                },
            };

            _ = vk.c.vkDeviceWaitIdle(logical_device.device);
            framebuffers.deinit();
            swap_chain.deinit();
            swap_chain = try vk.SwapChain.init(&window, &surface, &physical_device, &logical_device, allocator);
            framebuffers = try vk.Framebuffers.init(&render_pass, &swap_chain, allocator);
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
