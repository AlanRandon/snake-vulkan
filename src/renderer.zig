const std = @import("std");
const vk = @import("./vulkan.zig");
const sync = vk.sync;

pub fn Renderer(comptime max_frames: u32) type {
    return struct {
        renderers: [max_frames]FrameRenderer,
        current_frame: u32 = 0,
        descriptor_pool: vk.DescriptorPool,

        const Self = @This();
        const FrameRenderer = struct {
            command_buffer: vk.CommandBuffer,
            image_available: sync.Semaphore,
            render_finished: sync.Semaphore,
            in_flight_fence: sync.Fence,
            descriptor_sets: vk.c.VkDescriptorSet,
        };

        pub fn init(
            command_pool: *const vk.CommandPool,
            descriptor_set_layout: *const vk.DescriptorSetLayout,
            comptime opts: struct {
                descriptor_set_types: []const vk.c.VkDescriptorType,
            },
        ) !Self {
            const logical_device = command_pool.logical_device;

            const pool = try vk.DescriptorPool.init(logical_device, .{
                .set_types = opts.descriptor_set_types,
                .descriptor_count = max_frames,
            });

            var descriptor_set_layouts: [max_frames]vk.c.VkDescriptorSetLayout = undefined;
            inline for (0..max_frames) |i| {
                descriptor_set_layouts[i] = descriptor_set_layout.descriptor_set_layout;
            }

            var descriptor_sets: [max_frames]vk.c.VkDescriptorSet = undefined;
            if (vk.c.vkAllocateDescriptorSets(logical_device.device, &vk.c.VkDescriptorSetAllocateInfo{
                .sType = vk.c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .descriptorPool = pool.pool,
                .descriptorSetCount = max_frames,
                .pSetLayouts = &descriptor_set_layouts,
            }, &descriptor_sets) != vk.c.VK_SUCCESS) {
                return error.VulkanFailedToAllocateDescriptorSets;
            }

            var renderers: [max_frames]FrameRenderer = undefined;
            for (&renderers, 0..) |*renderer, i| {
                renderer.* = FrameRenderer{
                    .command_buffer = try vk.CommandBuffer.init(command_pool),
                    .image_available = try sync.Semaphore.init(logical_device),
                    .render_finished = try sync.Semaphore.init(logical_device),
                    .in_flight_fence = try sync.Fence.init(logical_device, true),
                    .descriptor_sets = descriptor_sets[i],
                };
            }

            return .{
                .renderers = renderers,
                .descriptor_pool = pool,
            };
        }

        pub fn deinit(renderer: *Self) void {
            for (renderer.renderers) |r| {
                defer r.image_available.deinit();
                defer r.render_finished.deinit();
                defer r.in_flight_fence.deinit();
            }
            renderer.descriptor_pool.deinit();
        }

        pub const DescriptorSet = struct {
            binding: u32,
            data: union(enum) {
                image: struct {
                    view: *const vk.ImageView,
                    sampler: *const vk.ImageSampler,
                },
            },
        };

        pub fn updateDescriptorSets(
            renderer: *const Self,
            comptime len: usize,
            sets: [len]DescriptorSet,
        ) void {
            const logical_device = renderer.renderers[0].in_flight_fence.device;
            const size = len * max_frames;
            var writes: [size]vk.c.VkWriteDescriptorSet = undefined;

            for (renderer.renderers, 0..) |r, i| {
                for (sets, 0..) |set, j| {
                    writes[i * len + j] = switch (set.data) {
                        .image => |image| .{
                            .sType = vk.c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                            .dstSet = r.descriptor_sets,
                            .dstBinding = set.binding,
                            .dstArrayElement = 0,
                            .descriptorType = vk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                            .descriptorCount = 1,
                            .pImageInfo = &vk.c.VkDescriptorImageInfo{
                                .imageLayout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                .imageView = image.view.view,
                                .sampler = image.sampler.sampler,
                            },
                        },
                    };
                }
            }

            vk.c.vkUpdateDescriptorSets(logical_device.device, @intCast(size), &writes, 0, null);
        }

        pub fn begin_frame(
            renderer: *Self,
            swap_chain: *const vk.SwapChain,
            render_pass: *const vk.RenderPass,
            framebuffers: *const vk.Framebuffers,
            pipeline: *const vk.Pipeline,
            opts: struct {
                error_payload: *vk.c.VkResult,
            },
        ) !Frame {
            const frame_renderer = &renderer.renderers[renderer.current_frame];
            const logical_device = frame_renderer.in_flight_fence.device;
            frame_renderer.in_flight_fence.wait(null);

            var image_index: u32 = undefined;
            {
                const result = vk.c.vkAcquireNextImageKHR(
                    logical_device.device,
                    swap_chain.swap_chain,
                    std.math.maxInt(u64),
                    frame_renderer.image_available.semaphore,
                    @ptrCast(vk.c.VK_NULL_HANDLE),
                    &image_index,
                );

                if (result != vk.c.VK_SUCCESS) {
                    opts.error_payload.* = result;
                    return error.VulkanFailedToAcquireImage;
                }
            }

            frame_renderer.in_flight_fence.reset();

            _ = vk.c.vkResetCommandBuffer(frame_renderer.command_buffer.buffer, 0);

            try frame_renderer.command_buffer.begin(0);
            frame_renderer.command_buffer.beginRenderPass(render_pass, framebuffers, swap_chain, pipeline, image_index);

            return .{
                .image_index = image_index,
                .frame_renderer = frame_renderer,
                .renderer = renderer,
                .swap_chain = swap_chain,
            };
        }

        const Frame = struct {
            image_index: u32,
            frame_renderer: *const FrameRenderer,
            renderer: *Self,
            swap_chain: *const vk.SwapChain,

            pub fn commandBuffer(frame: *const Frame) *const vk.CommandBuffer {
                return &frame.frame_renderer.command_buffer;
            }

            pub fn bindDescriptorSets(frame: *const Frame, layout: *const vk.PipelineLayout) void {
                vk.c.vkCmdBindDescriptorSets(
                    frame.commandBuffer().buffer,
                    vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                    layout.layout,
                    0,
                    1,
                    &frame.frame_renderer.descriptor_sets,
                    0,
                    null,
                );
            }

            pub fn draw(
                frame: *const Frame,
                opts: struct {
                    error_payload: *vk.c.VkResult,
                },
            ) !void {
                const logical_device = frame.renderer.renderers[0].in_flight_fence.device;
                frame.frame_renderer.command_buffer.endRenderPass();
                try frame.frame_renderer.command_buffer.end();

                {
                    const result = vk.c.vkQueueSubmit(
                        logical_device.graphics_queue,
                        1,
                        &vk.c.VkSubmitInfo{
                            .sType = vk.c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
                            .waitSemaphoreCount = 1,
                            .pWaitSemaphores = &frame.frame_renderer.image_available.semaphore,
                            .pWaitDstStageMask = &[_]vk.c.VkPipelineStageFlags{vk.c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT},
                            .commandBufferCount = 1,
                            .pCommandBuffers = &frame.frame_renderer.command_buffer.buffer,
                            .signalSemaphoreCount = 1,
                            .pSignalSemaphores = &frame.frame_renderer.render_finished.semaphore,
                        },
                        frame.frame_renderer.in_flight_fence.fence,
                    );
                    if (result != vk.c.VK_SUCCESS) {
                        opts.error_payload.* = result;
                        return error.VulkanFailedToSubmitCommandBuffer;
                    }
                }

                if (vk.c.vkQueuePresentKHR(logical_device.present_queue, &vk.c.VkPresentInfoKHR{
                    .sType = vk.c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                    .waitSemaphoreCount = 1,
                    .pWaitSemaphores = &frame.frame_renderer.render_finished.semaphore,
                    .swapchainCount = 1,
                    .pSwapchains = &frame.swap_chain.swap_chain,
                    .pImageIndices = &frame.image_index,
                    .pResults = null,
                }) != vk.c.VK_SUCCESS) {
                    return error.VulkanFailedToPresent;
                }

                frame.renderer.current_frame = (frame.renderer.current_frame + 1) % max_frames;
            }
        };
    };
}
