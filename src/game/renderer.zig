const std = @import("std");
const vk = @import("../vulkan.zig");
const Renderer = @import("../renderer.zig").Renderer(2);
const Allocator = std.mem.Allocator;
const CellTextureOffset = @import("../game.zig").CellTextureOffset;

const IndexBuffer = vk.vertex.IndexBuffer(u16);
const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

const TileInstance = struct {
    offset: vk.vertex.Vec2,
    tile_number: vk.vertex.Scalar,

    const bind_desc = vk.vertex.bindInstanced(TileInstance, .{
        .binding = 0,
    });

    const attr_descs = vk.vertex.attributeDescriptions(TileInstance, .{
        .binds = .{
            .offset = .{ .location = 0 },
            .tile_number = .{ .location = 1 },
        },
        .binding = 0,
    });

    const Buffer = vk.vertex.VertexBuffer(TileInstance);
};

const ShaderGlobals = struct {
    window_size: vk.vertex.Vec2,
    cell_size: vk.vertex.Vec2,
};

pub const GameRenderer = struct {
    allocator: Allocator,
    logical_device: *const vk.LogicalDevice,
    physical_device: *const vk.PhysicalDevice,
    window: *const vk.GlfwWindow,
    surface: *const vk.Surface,
    swap_chain: vk.SwapChain,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline: vk.Pipeline,
    framebuffers: vk.Framebuffers,
    command_pool: vk.CommandPool,
    renderer: Renderer,
    tiles: vk.texture.Texture,
    shader_modules: struct {
        vert: vk.ShaderModule,
        frag: vk.ShaderModule,
        globals: ShaderGlobals,
    },
    buffers: struct {
        index: IndexBuffer,
        instance: TileInstance.Buffer,
    },

    pub fn init(
        logical_device: *const vk.LogicalDevice,
        physical_device: *const vk.PhysicalDevice,
        window: *const vk.GlfwWindow,
        surface: *const vk.Surface,
        allocator: Allocator,
    ) !GameRenderer {
        var vert_shader = try vk.ShaderModule.initFromEmbed(logical_device, "spv:shader.vert");
        errdefer vert_shader.deinit();

        var frag_shader = try vk.ShaderModule.initFromEmbed(logical_device, "spv:shader.frag");
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

        var swap_chain = try vk.SwapChain.init(window, surface, physical_device, logical_device, allocator);
        errdefer swap_chain.deinit();

        var render_pass = try vk.RenderPass.init(&swap_chain);
        errdefer render_pass.deinit();

        var pipeline = try vk.Pipeline.init(
            &pipeline_layout,
            &render_pass,
            &vert_shader,
            &frag_shader,
            &swap_chain,
            .{
                .vertex_binding_descs = &[_]vk.vertex.BindDesc{TileInstance.bind_desc},
                .vertex_attribute_descs = &TileInstance.attr_descs,
            },
        );
        errdefer pipeline.deinit();

        var framebuffers = try vk.Framebuffers.init(&render_pass, &swap_chain, allocator);
        errdefer framebuffers.deinit();

        var command_pool = try vk.CommandPool.init(physical_device, logical_device);
        errdefer command_pool.deinit();

        var renderer = try Renderer.init(
            &command_pool,
            &descriptor_set_layout,
            .{
                .descriptor_set_types = &[_]vk.c.VkDescriptorType{vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER},
            },
        );
        errdefer renderer.deinit();

        var tiles = try vk.texture.Texture.init("asset:tiles.png", logical_device, physical_device, &command_pool, .{});
        errdefer tiles.deinit();

        var instance_buffer = try TileInstance.Buffer.init(
            &[_]TileInstance{.{ .offset = [_]f32{ 0.0, 0.0 }, .tile_number = 0.0 }},
            logical_device,
            physical_device,
            &command_pool,
        );
        errdefer instance_buffer.deinit();

        var index_buffer = try IndexBuffer.init(&indices, logical_device, physical_device, &command_pool);
        errdefer index_buffer.deinit();

        renderer.updateDescriptorSets(
            1,
            [_]Renderer.DescriptorSet{.{
                .binding = 0,
                .data = .{
                    .image = .{
                        .view = &tiles.view,
                        .sampler = &tiles.sampler,
                    },
                },
            }},
        );

        // TODO
        const rows = 10;
        const cols = 10;

        return .{
            .allocator = allocator,
            .logical_device = logical_device,
            .physical_device = physical_device,
            .window = window,
            .surface = surface,
            .swap_chain = swap_chain,
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline = pipeline,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .renderer = renderer,
            .tiles = tiles,
            .buffers = .{
                .index = index_buffer,
                .instance = instance_buffer,
            },
            .shader_modules = .{
                .vert = vert_shader,
                .frag = frag_shader,
                .globals = ShaderGlobals{
                    .window_size = [_]f32{
                        @floatFromInt(window.dimensions().width),
                        @floatFromInt(window.dimensions().height),
                    },
                    .cell_size = [_]f32{ 1.0 / @as(f32, @floatFromInt(rows)), 1.0 / @as(f32, @floatFromInt(cols)) },
                },
            },
        };
    }

    pub fn deinit(renderer: *GameRenderer) void {
        renderer.buffers.index.deinit();
        renderer.buffers.instance.deinit();
        renderer.tiles.deinit();
        renderer.renderer.deinit();
        renderer.render_pass.deinit();
        renderer.pipeline.deinit();
        renderer.pipeline_layout.deinit();
        renderer.descriptor_set_layout.deinit();
        renderer.command_pool.deinit();
        renderer.framebuffers.deinit();
        renderer.swap_chain.deinit();
        renderer.shader_modules.vert.deinit();
        renderer.shader_modules.frag.deinit();
    }

    pub fn handleResize(renderer: *GameRenderer) !void {
        renderer.shader_modules.globals.window_size = [_]f32{
            @floatFromInt(renderer.window.dimensions().width),
            @floatFromInt(renderer.window.dimensions().height),
        };

        _ = vk.c.vkDeviceWaitIdle(renderer.swap_chain.logical_device.device);
        renderer.framebuffers.deinit();
        renderer.swap_chain.deinit();
        renderer.swap_chain = try vk.SwapChain.init(
            renderer.window,
            renderer.surface,
            renderer.physical_device,
            renderer.logical_device,
            renderer.allocator,
        );
        renderer.framebuffers = try vk.Framebuffers.init(
            &renderer.render_pass,
            &renderer.swap_chain,
            renderer.allocator,
        );
    }

    pub fn render(renderer: *GameRenderer, game: anytype, opts: struct { framebuffer_resized: *bool }) !void {
        var result: vk.c.VkResult = undefined;

        const cell_count = game.rows * game.cols;
        var rendered_cells: [cell_count * 2]TileInstance = undefined;
        var rendered_cell_count: usize = 0;
        for (game.cells, 0..) |cell, i| {
            const offset = [_]f32{
                @floatFromInt(i % game.cols),
                @floatFromInt(@divFloor(i, game.cols)),
            };

            rendered_cells[rendered_cell_count] = .{
                .offset = offset,
                .tile_number = @floatFromInt(@intFromEnum(cell.background)),
            };
            rendered_cell_count += 1;

            switch (cell.state) {
                .empty => {},
                .head => {
                    // std.debug.panic("TODO: render head", .{});
                    rendered_cells[rendered_cell_count] = .{
                        .offset = offset,
                        .tile_number = @floatFromInt(@intFromEnum(CellTextureOffset.head)),
                    };
                    rendered_cell_count += 1;
                },
                .tail => {
                    rendered_cells[rendered_cell_count] = .{
                        .offset = offset,
                        .tile_number = @floatFromInt(@intFromEnum(CellTextureOffset.tail)),
                    };
                    rendered_cell_count += 1;
                },
                .apple => {
                    std.debug.panic("TODO: render apple", .{});
                },
                .wall => {
                    std.debug.panic("TODO: render wall", .{});
                },
            }
        }

        _ = vk.c.vkDeviceWaitIdle(renderer.swap_chain.logical_device.device);
        renderer.buffers.instance.deinit();
        renderer.buffers.instance = try TileInstance.Buffer.init(
            rendered_cells[0..rendered_cell_count],
            renderer.logical_device,
            renderer.physical_device,
            &renderer.command_pool,
        );

        const frame = renderer.renderer.begin_frame(
            &renderer.swap_chain,
            &renderer.render_pass,
            &renderer.framebuffers,
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
        frame.commandBuffer().bindVertexBuffers(.{&renderer.buffers.instance});
        frame.commandBuffer().pushConstants(&renderer.pipeline_layout, &renderer.shader_modules.globals, .{ .index = 0 });
        vk.c.vkCmdDrawIndexed(frame.commandBuffer().buffer, renderer.buffers.index.len, renderer.buffers.instance.len, 0, 0, 0);

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
