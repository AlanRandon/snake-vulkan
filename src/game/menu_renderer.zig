const std = @import("std");
const vk = @import("../vulkan.zig");
const Allocator = std.mem.Allocator;
const Renderer = @import("../renderer.zig").Renderer(2);

pub const ShaderGlobals = struct {
    window_size: vk.vertex.Vec2,
};

const IndexBuffer = vk.vertex.IndexBuffer(u16);
const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

pub const ImageRenderer = struct {
    allocator: Allocator,
    window: *const vk.GlfwWindow,
    command_pool: *const vk.CommandPool,
    swap_chain: *const vk.SwapChain,
    framebuffers: *const vk.Framebuffers,
    render_pass: *const vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline: vk.Pipeline,
    renderer: Renderer,
    shader_globals: ShaderGlobals,
    shader_modules: struct {
        vert: vk.ShaderModule,
        frag: vk.ShaderModule,
    },
    buffers: struct {
        index: IndexBuffer,
    },

    pub fn init(
        logical_device: *const vk.LogicalDevice,
        physical_device: *const vk.PhysicalDevice,
        command_pool: *const vk.CommandPool,
        window: *const vk.GlfwWindow,
        swap_chain: *vk.SwapChain,
        framebuffers: *vk.Framebuffers,
        render_pass: *const vk.RenderPass,
        allocator: Allocator,
    ) !ImageRenderer {
        var vert_shader = try vk.ShaderModule.initFromEmbed(logical_device, "spv:menu.vert");
        errdefer vert_shader.deinit();

        var frag_shader = try vk.ShaderModule.initFromEmbed(logical_device, "spv:menu.frag");
        errdefer frag_shader.deinit();

        var descriptor_set_layout = try vk.DescriptorSetLayout.init(
            logical_device,
            &[_]vk.c.VkDescriptorSetLayoutBinding{.{
                .binding = 0,
                .descriptorCount = 1,
                .descriptorType = vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImmutableSamplers = null,
                .stageFlags = vk.c.VK_SHADER_STAGE_FRAGMENT_BIT,
            }},
        );
        errdefer descriptor_set_layout.deinit();

        var pipeline_layout = try vk.PipelineLayout.init(
            logical_device,
            .{
                .push_constant_info = vk.pushConstantLayouts(&[_]vk.PushConstantDesc{.{ .ty = ShaderGlobals, .offset = 0 }}),
                .descriptor_set_layout = &descriptor_set_layout,
            },
        );
        errdefer pipeline_layout.deinit();

        var pipeline = try vk.Pipeline.init(
            &pipeline_layout,
            render_pass,
            &vert_shader,
            &frag_shader,
            swap_chain,
            .{
                .vertex_binding_descs = &[_]vk.vertex.BindDesc{},
                .vertex_attribute_descs = &[_]vk.vertex.AttrDesc{},
            },
        );
        errdefer pipeline.deinit();

        var renderer = try Renderer.init(
            command_pool,
            &descriptor_set_layout,
            .{
                .descriptor_set_types = &[_]vk.c.VkDescriptorType{vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER},
            },
        );
        errdefer renderer.deinit();

        var index_buffer = try IndexBuffer.init(&indices, logical_device, physical_device, command_pool);
        errdefer index_buffer.deinit();

        return .{
            .allocator = allocator,
            .window = window,
            .swap_chain = swap_chain,
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline = pipeline,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .renderer = renderer,
            .buffers = .{
                .index = index_buffer,
            },
            .shader_globals = ShaderGlobals{
                .window_size = [_]f32{
                    @floatFromInt(window.dimensions().width),
                    @floatFromInt(window.dimensions().height),
                },
            },
            .shader_modules = .{
                .vert = vert_shader,
                .frag = frag_shader,
            },
        };
    }

    pub fn deinit(renderer: *ImageRenderer) void {
        renderer.buffers.index.deinit();
        renderer.renderer.deinit();
        renderer.pipeline.deinit();
        renderer.pipeline_layout.deinit();
        renderer.descriptor_set_layout.deinit();
        renderer.shader_modules.vert.deinit();
        renderer.shader_modules.frag.deinit();
    }

    pub fn handleResize(renderer: *ImageRenderer) void {
        renderer.shader_globals.window_size = [_]f32{
            @floatFromInt(renderer.window.dimensions().width),
            @floatFromInt(renderer.window.dimensions().height),
        };
    }

    pub fn render(renderer: *ImageRenderer, tex: *const vk.texture.Texture, opts: struct { framebuffer_resized: *bool }) !void {
        _ = vk.c.vkDeviceWaitIdle(renderer.swap_chain.logical_device.device);

        renderer.renderer.updateDescriptorSets(
            1,
            [_]Renderer.DescriptorSet{.{
                .binding = 0,
                .data = .{
                    .image = .{
                        .view = &tex.view,
                        .sampler = &tex.sampler,
                    },
                },
            }},
        );

        _ = vk.c.vkDeviceWaitIdle(renderer.swap_chain.logical_device.device);

        var result: vk.c.VkResult = undefined;
        const frame = renderer.renderer.begin_frame(
            renderer.swap_chain,
            renderer.render_pass,
            renderer.framebuffers,
            &renderer.pipeline,
            .{ .error_payload = &result },
        ) catch |err| switch (err) {
            error.VulkanFailedToAcquireImage => switch (result) {
                vk.c.VK_ERROR_OUT_OF_DATE_KHR => {
                    opts.framebuffer_resized.* = true;
                    return;
                },
                vk.c.VK_SUBOPTIMAL_KHR => return,
                else => return error.VulkanFailedToAcquireImage,
            },
            else => return err,
        };

        frame.bindDescriptorSets(&renderer.pipeline_layout);
        frame.commandBuffer().bindIndexBuffer(&renderer.buffers.index);
        frame.commandBuffer().pushConstants(&renderer.pipeline_layout, &renderer.shader_globals, .{ .index = 0 });
        vk.c.vkCmdDrawIndexed(frame.commandBuffer().buffer, renderer.buffers.index.len, 1, 0, 0, 0);

        frame.draw(.{ .error_payload = &result }) catch |err| switch (err) {
            error.VulkanFailedToPresent => switch (result) {
                vk.c.VK_ERROR_OUT_OF_DATE_KHR,
                vk.c.VK_SUBOPTIMAL_KHR,
                => opts.framebuffer_resized.* = true,
                else => return error.VulkanFailedToPresent,
            },
            else => return err,
        };
    }
};
