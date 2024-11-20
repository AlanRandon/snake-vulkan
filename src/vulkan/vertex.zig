const vk = @import("../vulkan.zig");
const std = @import("std");
const c = vk.c;

pub const Scalar = f32;
pub const Vec2 = [2]f32;
pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;

pub const BindDesc = c.VkVertexInputBindingDescription;

fn bindDescription(
    comptime Vertex: type,
    binding: u32,
    input_rate: c_uint,
) BindDesc {
    return .{
        .binding = binding,
        .stride = @sizeOf(Vertex),
        .inputRate = input_rate,
    };
}

pub fn bindVertex(
    comptime Vertex: type,
    opts: struct { binding: u32 },
) BindDesc {
    return bindDescription(Vertex, opts.binding, c.VK_VERTEX_INPUT_RATE_VERTEX);
}

pub fn bindInstanced(
    comptime Vertex: type,
    opts: struct { binding: u32 },
) BindDesc {
    return bindDescription(Vertex, opts.binding, c.VK_VERTEX_INPUT_RATE_INSTANCE);
}

pub const AttrDesc = c.VkVertexInputAttributeDescription;

const StructField = std.builtin.Type.StructField;

pub fn attributeDescriptions(
    comptime Vertex: type,
    comptime opts: anytype,
) blk: {
    const bind_opts_fields: []const StructField = std.meta.fields(@TypeOf(opts.binds));
    break :blk [bind_opts_fields.len]AttrDesc;
} {
    const vertex_fields: []const StructField = comptime std.meta.fields(Vertex);
    const bind_opts_fields: []const StructField = comptime std.meta.fields(@TypeOf(opts.binds));
    comptime var descs: [bind_opts_fields.len]AttrDesc = undefined;

    comptime for (bind_opts_fields, 0..) |f, i| {
        const bind_opts = @field(opts.binds, f.name);
        const field = vertex_fields[std.meta.fieldIndex(Vertex, f.name) orelse @compileError("missing field")];

        descs[i] = AttrDesc{
            .binding = opts.binding,
            .location = bind_opts.location,
            .format = switch (field.type) {
                Scalar => c.VK_FORMAT_R32_SFLOAT,
                Vec2 => c.VK_FORMAT_R32G32_SFLOAT,
                Vec3 => c.VK_FORMAT_R32G32B32_SFLOAT,
                Vec4 => c.VK_FORMAT_R32G32B32A32_SFLOAT,
                else => {
                    @compileError("binds must be of a supported type (Scalar, Vec2, Vec3, or Vec4)");
                },
            },
            .offset = @offsetOf(Vertex, field.name),
        };
    };

    return descs;
}

pub fn findMemoryType(
    physical_device: *const vk.PhysicalDevice,
    mem_requirements: c.VkMemoryRequirements,
    properties: c.VkMemoryPropertyFlags,
) !u32 {
    var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device.device, &mem_props);

    for (0..mem_props.memoryTypeCount) |i| {
        const filter: bool = mem_requirements.memoryTypeBits & (@as(u32, 1) << @as(u5, @intCast(i))) != 0;
        if (filter and (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
            return @intCast(i);
        }
    }

    return error.VulkanFailedToFindSuitableMemoryType;
}

const RawBuffer = struct { buffer: c.VkBuffer, memory: c.VkDeviceMemory };

pub fn createBuffer(
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    logical_device: *const vk.LogicalDevice,
    physical_device: *const vk.PhysicalDevice,
) !RawBuffer {
    var buffer: c.VkBuffer = undefined;
    if (c.vkCreateBuffer(
        logical_device.device,
        &c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        },
        null,
        &buffer,
    ) != c.VK_SUCCESS) {
        return error.VulkanFailedToCreateVertexBuffer;
    }
    errdefer c.vkDestroyBuffer(logical_device.device, buffer, null);

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(logical_device.device, buffer, &mem_requirements);

    const mem_type_index: u32 = try findMemoryType(physical_device, mem_requirements, properties);

    var memory: c.VkDeviceMemory = undefined;
    if (c.vkAllocateMemory(
        logical_device.device,
        &c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        },
        null,
        &memory,
    ) != c.VK_SUCCESS) {
        return error.VulkanFailedToAllocateVertexBufferMemory;
    }

    _ = c.vkBindBufferMemory(logical_device.device, buffer, memory, 0);

    return .{
        .buffer = buffer,
        .memory = memory,
    };
}

pub fn createStagedBuffer(
    comptime T: type,
    data: []const T,
    usage: c.VkBufferUsageFlags,
    logical_device: *const vk.LogicalDevice,
    physical_device: *const vk.PhysicalDevice,
    command_pool: *const vk.CommandPool,
) !RawBuffer {
    const size = @sizeOf(T) * data.len;
    const staging_buffer = try createBuffer(
        size,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        logical_device,
        physical_device,
    );
    defer c.vkDestroyBuffer(logical_device.device, staging_buffer.buffer, null);
    defer c.vkFreeMemory(logical_device.device, staging_buffer.memory, null);

    var gpu_data: ?*align(@alignOf(T)) anyopaque = undefined;
    gpu_data = undefined;
    _ = c.vkMapMemory(logical_device.device, staging_buffer.memory, 0, size, 0, &gpu_data);
    @memcpy(@as([*]T, @ptrCast(gpu_data)), data);
    c.vkUnmapMemory(logical_device.device, staging_buffer.memory);

    const dst_buffer = try createBuffer(
        size,
        usage | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        logical_device,
        physical_device,
    );

    const command_buffer = try vk.CommandBuffer.init(command_pool);
    try command_buffer.begin(c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
    c.vkCmdCopyBuffer(command_buffer.buffer, staging_buffer.buffer, dst_buffer.buffer, 1, &c.VkBufferCopy{
        .size = size,
    });
    try command_buffer.end();

    _ = c.vkQueueSubmit(logical_device.graphics_queue, 1, &c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer.buffer,
    }, @ptrCast(c.VK_NULL_HANDLE));
    _ = c.vkQueueWaitIdle(logical_device.graphics_queue);

    c.vkFreeCommandBuffers(logical_device.device, command_pool.pool, 1, &command_buffer.buffer);

    return .{
        .buffer = dst_buffer.buffer,
        .memory = dst_buffer.memory,
    };
}

pub fn VertexBuffer(comptime Vertex: type) type {
    return struct {
        const Self = @This();

        logical_device: *const vk.LogicalDevice,
        raw: RawBuffer,

        pub fn init(
            vertices: []const Vertex,
            logical_device: *const vk.LogicalDevice,
            physical_device: *const vk.PhysicalDevice,
            command_pool: *const vk.CommandPool,
        ) !Self {
            return .{
                .raw = try createStagedBuffer(
                    Vertex,
                    vertices,
                    c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                    logical_device,
                    physical_device,
                    command_pool,
                ),
                .logical_device = logical_device,
            };
        }

        pub fn deinit(buf: *Self) void {
            c.vkDestroyBuffer(buf.logical_device.device, buf.raw.buffer, null);
            c.vkFreeMemory(buf.logical_device.device, buf.raw.memory, null);
        }
    };
}

pub fn IndexBuffer(comptime IndexType: type) type {
    return struct {
        const Self = @This();

        logical_device: *const vk.LogicalDevice,
        raw: RawBuffer,

        pub fn init(
            indices: []const IndexType,
            logical_device: *const vk.LogicalDevice,
            physical_device: *const vk.PhysicalDevice,
            command_pool: *const vk.CommandPool,
        ) !Self {
            return .{
                .raw = try createStagedBuffer(
                    IndexType,
                    indices,
                    c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                    logical_device,
                    physical_device,
                    command_pool,
                ),
                .logical_device = logical_device,
            };
        }

        pub fn deinit(buf: *Self) void {
            c.vkDestroyBuffer(buf.logical_device.device, buf.raw.buffer, null);
            c.vkFreeMemory(buf.logical_device.device, buf.raw.memory, null);
        }
    };
}
