const vk = @import("../vulkan.zig");
const std = @import("std");
const c = vk.c;
const DevicePtr = *const vk.LogicalDevice;

pub const Semaphore = struct {
    device: DevicePtr,
    semaphore: c.VkSemaphore,

    pub fn init(device: DevicePtr) !Semaphore {
        var semaphore: c.VkSemaphore = undefined;
        if (c.vkCreateSemaphore(device.device, &c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        }, null, &semaphore) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateSemaphore;
        }

        return .{
            .device = device,
            .semaphore = semaphore,
        };
    }

    pub fn deinit(semaphore: *const Semaphore) void {
        c.vkDestroySemaphore(semaphore.device.device, semaphore.semaphore, null);
    }
};

pub const Fence = struct {
    device: DevicePtr,
    fence: c.VkFence,

    pub fn init(device: DevicePtr, is_signalled: bool) !Fence {
        var fence: c.VkFence = undefined;
        if (c.vkCreateFence(device.device, &c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = if (is_signalled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0,
        }, null, &fence) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateFence;
        }

        return .{
            .device = device,
            .fence = fence,
        };
    }

    pub fn deinit(fence: *const Fence) void {
        c.vkDestroyFence(fence.device.device, fence.fence, null);
    }

    pub fn wait(fence: *const Fence, timeout: ?u8) void {
        _ = c.vkWaitForFences(fence.device.device, 1, &fence.fence, c.VK_TRUE, timeout orelse std.math.maxInt(u64));
    }

    pub fn reset(fence: *const Fence) void {
        _ = c.vkResetFences(fence.device.device, 1, &fence.fence);
    }
};
