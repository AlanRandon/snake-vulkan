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

        pub fn draw_frame(
            renderer: *Self,
            swap_chain: *const vk.SwapChain,
            logical_device: *const vk.LogicalDevice,
            render_pass: *const vk.RenderPass,
            framebuffers: *const vk.Framebuffers,
            pipeline: *const vk.Pipeline,
        ) !void {
            const r = renderer.renderers[renderer.current_frame];
            r.in_flight_fence.wait(null);
            r.in_flight_fence.reset();

            var image_index: u32 = undefined;
            if (vk.c.vkAcquireNextImageKHR(
                logical_device.device,
                swap_chain.swap_chain,
                std.math.maxInt(u64),
                r.image_available.semaphore,
                @ptrCast(vk.c.VK_NULL_HANDLE),
                &image_index,
            ) != vk.c.VK_SUCCESS) {
                return error.VulkanFailedToAcquireImage;
            }

            _ = vk.c.vkResetCommandBuffer(r.command_buffer.buffer, 0);

            {
                try r.command_buffer.begin_record(render_pass, framebuffers, swap_chain, pipeline, image_index);
                vk.c.vkCmdDraw(r.command_buffer.buffer, 3, 1, 0, 0);
                try r.command_buffer.submit();
            }

            if (vk.c.vkQueueSubmit(
                logical_device.graphics_queue,
                1,
                &vk.c.VkSubmitInfo{
                    .sType = vk.c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
                    .waitSemaphoreCount = 1,
                    .pWaitSemaphores = &r.image_available.semaphore,
                    .pWaitDstStageMask = &[_]vk.c.VkPipelineStageFlags{vk.c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT},
                    .commandBufferCount = 1,
                    .pCommandBuffers = &r.command_buffer.buffer,
                    .signalSemaphoreCount = 1,
                    .pSignalSemaphores = &r.render_finished.semaphore,
                },
                r.in_flight_fence.fence,
            ) != vk.c.VK_SUCCESS) {
                return error.VulkanFailedToDrawCommandBuffer;
            }

            if (vk.c.vkQueuePresentKHR(logical_device.present_queue, &vk.c.VkPresentInfoKHR{
                .sType = vk.c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                .waitSemaphoreCount = 1,
                .pWaitSemaphores = &r.render_finished.semaphore,
                .swapchainCount = 1,
                .pSwapchains = &swap_chain.swap_chain,
                .pImageIndices = &image_index,
                .pResults = null,
            }) != vk.c.VK_SUCCESS) {
                return error.VulkanFailedToPresent;
            }

            renderer.current_frame = (renderer.current_frame + 1) % max_frames;
        }
    };
}