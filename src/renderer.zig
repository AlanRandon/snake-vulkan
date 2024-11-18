const std = @import("std");
const vk = @import("./vulkan.zig");
const sync = vk.sync;

pub fn Renderer(comptime max_frames: u32) type {
    return struct {
        renderers: [max_frames]FrameRenderer,
        current_frame: u32 = 0,

        const Self = @This();
        const FrameRenderer = struct {
            command_buffer: vk.CommandBuffer,
            image_available: sync.Semaphore,
            render_finished: sync.Semaphore,
            in_flight_fence: sync.Fence,
        };

        pub fn init(command_pool: *const vk.CommandPool) !Self {
            const logical_device = command_pool.logical_device;
            var renderers: [max_frames]FrameRenderer = undefined;
            for (&renderers) |*renderer| {
                renderer.* = FrameRenderer{
                    .command_buffer = try vk.CommandBuffer.init(command_pool),
                    .image_available = try sync.Semaphore.init(logical_device),
                    .render_finished = try sync.Semaphore.init(logical_device),
                    .in_flight_fence = try sync.Fence.init(logical_device, true),
                };
            }
            return .{ .renderers = renderers };
        }

        pub fn deinit(renderer: *Self) void {
            for (renderer.renderers) |r| {
                defer r.image_available.deinit();
                defer r.render_finished.deinit();
                defer r.in_flight_fence.deinit();
            }
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
