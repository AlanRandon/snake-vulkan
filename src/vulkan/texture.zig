const vk = @import("../vulkan.zig");
const std = @import("std");
const c = vk.c;

pub const TextureImage = struct {
    texture_image: c.VkImage,
    texture_image_memory: c.VkDeviceMemory,
    logical_device: *const vk.LogicalDevice,

    pub fn init(
        comptime path: []const u8,
        logical_device: *const vk.LogicalDevice,
        physical_device: *const vk.PhysicalDevice,
        command_pool: *const vk.CommandPool,
    ) !TextureImage {
        const data = @embedFile(path);
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;
        const pixels: *c.stbi_uc = c.stbi_load_from_memory(
            data.ptr,
            data.len,
            &width,
            &height,
            &channels,
            c.STBI_rgb_alpha,
        ) orelse return error.FailedToLoadStbImage;
        defer c.stbi_image_free(pixels);

        const image_size: u64 = @intCast(width * height * 4);
        const staging_buffer = try vk.vertex.createBuffer(
            image_size,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            logical_device,
            physical_device,
        );
        defer c.vkDestroyBuffer(logical_device.device, staging_buffer.buffer, null);
        defer c.vkFreeMemory(logical_device.device, staging_buffer.memory, null);

        var gpu_pixels: ?*align(@alignOf(u8)) anyopaque = undefined;
        gpu_pixels = undefined;
        _ = c.vkMapMemory(logical_device.device, staging_buffer.memory, 0, image_size, 0, &gpu_pixels);
        @memcpy(@as([*]u8, @ptrCast(gpu_pixels)), data);
        c.vkUnmapMemory(logical_device.device, staging_buffer.memory);

        var texture_image: c.VkImage = undefined;
        var texture_image_memory: c.VkDeviceMemory = undefined;

        if (c.vkCreateImage(logical_device.device, &c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .extent = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .format = c.VK_FORMAT_R8G8B8A8_SRGB,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
        }, null, &texture_image) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateTextureImage;
        }
        errdefer c.vkDestroyImage(logical_device.device, texture_image, null);

        var mem_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(logical_device.device, texture_image, &mem_requirements);

        if (c.vkAllocateMemory(
            logical_device.device,
            &c.VkMemoryAllocateInfo{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = mem_requirements.size,
                .memoryTypeIndex = try vk.vertex.findMemoryType(
                    physical_device,
                    mem_requirements,
                    c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                ),
            },
            null,
            &texture_image_memory,
        ) != c.VK_SUCCESS) {
            return error.VulkanFailedToAllocateTextureImageMemory;
        }
        errdefer c.vkFreeMemory(logical_device.device, texture_image_memory, null);

        _ = c.vkBindImageMemory(logical_device.device, texture_image, texture_image_memory, 0);

        var command_buffer = try vk.CommandBuffer.init(command_pool);
        try command_buffer.begin(c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);

        transitionImageLayout(
            &command_buffer,
            texture_image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        );

        c.vkCmdCopyBufferToImage(
            command_buffer.buffer,
            staging_buffer.buffer,
            texture_image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &c.VkBufferImageCopy{
                .bufferOffset = 0,
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .depth = 1,
                },
            },
        );

        transitionImageLayout(
            &command_buffer,
            texture_image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        );

        try command_buffer.end();

        _ = c.vkQueueSubmit(
            logical_device.graphics_queue,
            1,
            &c.VkSubmitInfo{
                .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .commandBufferCount = 1,
                .pCommandBuffers = &command_buffer.buffer,
            },
            @ptrCast(c.VK_NULL_HANDLE),
        );
        _ = c.vkQueueWaitIdle(logical_device.graphics_queue);

        _ = c.vkFreeCommandBuffers(logical_device.device, command_pool.pool, 1, &command_buffer.buffer);

        return .{
            .texture_image = texture_image,
            .texture_image_memory = texture_image_memory,
            .logical_device = logical_device,
        };
    }

    pub fn deinit(image: *TextureImage) void {
        c.vkDestroyImage(image.logical_device.device, image.texture_image, null);
        c.vkFreeMemory(image.logical_device.device, image.texture_image_memory, null);
    }
};

fn transitionImageLayout(
    command_buffer: *const vk.CommandBuffer,
    texture_image: c.VkImage,
    comptime old_layout: c.VkImageLayout,
    comptime new_layout: c.VkImageLayout,
) void {
    const info = if (old_layout == c.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) .{
        .src_access_mask = 0,
        .dst_access_mask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .src_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        .dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
    } else if (old_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) .{
        .src_access_mask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dst_access_mask = c.VK_ACCESS_SHADER_READ_BIT,
        .src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        .dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    } else {
        @compileError("Unsupported layour transition");
    };

    c.vkCmdPipelineBarrier(
        command_buffer.buffer,
        info.src_stage,
        info.dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = texture_image,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = info.src_access_mask,
            .dstAccessMask = info.dst_access_mask,
        },
    );
}