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

pub fn Buffer(comptime Vertex: type) type {
    return struct {
        const Self = @This();

        logical_device: *const vk.LogicalDevice,
        buffer: c.VkBuffer,
        memory: c.VkDeviceMemory,

        pub fn init(
            vertices: []const Vertex,
            logical_device: *const vk.LogicalDevice,
            physical_device: *const vk.PhysicalDevice,
        ) !Self {
            const size = @sizeOf(Vertex) * vertices.len;

            var buffer: c.VkBuffer = undefined;
            if (c.vkCreateBuffer(
                logical_device.device,
                &c.VkBufferCreateInfo{
                    .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                    .size = size,
                    .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
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

            var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
            c.vkGetPhysicalDeviceMemoryProperties(physical_device.device, &mem_props);

            const mem_type_index: u32 = blk: {
                for (0..mem_props.memoryTypeCount) |i| {
                    const filter: bool = mem_requirements.memoryTypeBits & (@as(u32, 1) << @as(u5, @intCast(i))) != 0;
                    const properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
                    if (filter and (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
                        break :blk @intCast(i);
                    }
                }
                return error.VulkanFailedToFindSuitableMemoryType;
            };

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
            var data: ?*align(@alignOf(Vertex)) anyopaque = undefined;
            data = undefined;
            _ = c.vkMapMemory(logical_device.device, memory, 0, size, 0, &data);
            @memcpy(@as([*]Vertex, @ptrCast(data)), vertices);
            c.vkUnmapMemory(logical_device.device, memory);

            return .{
                .buffer = buffer,
                .memory = memory,
                .logical_device = logical_device,
            };
        }

        pub fn deinit(buf: *Self) void {
            c.vkDestroyBuffer(buf.logical_device.device, buf.buffer, null);
            c.vkFreeMemory(buf.logical_device.device, buf.memory, null);
        }
    };
}
