const std = @import("std");
const Allocator = std.mem.Allocator;
const panic = std.debug.panic;
pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "");
    @cInclude("GLFW/glfw3.h");
    @cInclude("string.h");
});
pub const sync = @import("./vulkan/sync.zig");
pub const vertex = @import("./vulkan/vertex.zig");

pub const GlfwWindow = struct {
    window: *c.GLFWwindow,

    pub fn init(width: c_int, height: c_int, title: [*c]const u8) !GlfwWindow {
        _ = c.glfwInit();
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        // c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);
        const window: GlfwWindow = .{
            .window = c.glfwCreateWindow(width, height, title, null, null) orelse return error.FailedInitWindow,
        };
        return window;
    }

    pub fn deinit(window: *GlfwWindow) void {
        c.glfwDestroyWindow(window.window);
        c.glfwTerminate();
    }

    pub fn dimensions(window: *const GlfwWindow) struct { width: c_int, height: c_int } {
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.glfwGetFramebufferSize(window.window, &width, &height);
        return .{ .width = width, .height = height };
    }

    pub fn resizeCallback(
        window: *const GlfwWindow,
        callback: anytype,
        user_data: anytype,
    ) void {
        c.glfwSetWindowUserPointer(window.window, user_data);
        _ = c.glfwSetFramebufferSizeCallback(window.window, &struct {
            fn rawWindowResizeCallback(win: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
                @call(.auto, callback, .{.{
                    .width = width,
                    .height = height,
                    .user_data = @as(@TypeOf(user_data), @ptrCast(c.glfwGetWindowUserPointer(win))),
                    .window = win,
                }});
            }
        }.rawWindowResizeCallback);
    }
};

pub const Instance = struct {
    instance: c.VkInstance,

    pub fn init(allocator: Allocator) !Instance {
        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Vulkan Test",
            .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_0,
        };

        const validation_layers = if (@import("builtin").mode == .Debug) [_][*c]const u8{
            "VK_LAYER_KHRONOS_validation",
        } else [_][*c]const u8{};

        var available_layer_count: u32 = 0;
        _ = c.vkEnumerateInstanceLayerProperties(&available_layer_count, null);
        const available_layers = try allocator.alloc(c.VkLayerProperties, available_layer_count);
        defer allocator.free(available_layers);
        _ = c.vkEnumerateInstanceLayerProperties(&available_layer_count, available_layers.ptr);

        outer: for (validation_layers) |layer_name| {
            for (available_layers) |layer| {
                if (c.strcmp(&layer.layerName, layer_name) == 0) {
                    continue :outer;
                }
            }
            return error.VulkanValidationLayerNotAvailable;
        }

        var glfw_extension_count: u32 = 0;
        const glfw_extensions: [*c][*c]const u8 = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = glfw_extension_count,
            .ppEnabledExtensionNames = glfw_extensions,
            .enabledLayerCount = validation_layers.len,
            .ppEnabledLayerNames = &validation_layers,
        };

        var instance: c.VkInstance = undefined;
        if (c.vkCreateInstance(&create_info, null, &instance) != c.VK_SUCCESS) {
            return error.FailedToCreateVulkanInstance;
        }

        return .{ .instance = instance };
    }

    pub fn deinit(instance: *Instance) void {
        c.vkDestroyInstance(instance.instance, null);
    }
};

pub const Surface = struct {
    surface: c.VkSurfaceKHR,
    instance: *const Instance,

    pub fn init(instance: *const Instance, window: *const GlfwWindow) !Surface {
        var surface: c.VkSurfaceKHR = undefined;
        if (c.glfwCreateWindowSurface(instance.instance, window.window, null, &surface) != c.VK_SUCCESS) {
            return error.FailedToCreateSurface;
        }
        return .{ .surface = surface, .instance = instance };
    }

    pub fn deinit(surface: *Surface) void {
        defer c.vkDestroySurfaceKHR(surface.instance.instance, surface.surface, null);
    }
};

pub const QueueFamilyIndicies = struct {
    graphics_queue_index: u32,
    present_queue_index: u32,

    const CreateInfo = struct { info: []c.VkDeviceQueueCreateInfo, indices: QueueFamilyIndicies };

    fn toQueueCreateInfo(indices: *const QueueFamilyIndicies, buf: []u8) CreateInfo {
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const allocator = fba.allocator();

        const queue_priorities = &[_]f32{1.0};
        if (indices.graphics_queue_index == indices.present_queue_index) {
            const info = allocator.alloc(c.VkDeviceQueueCreateInfo, 1) catch panic("Buffer not large enough for QueueCreateInfo", .{});
            errdefer allocator.destroy(info);
            info[0] = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = indices.graphics_queue_index,
                .queueCount = 1,
                .pQueuePriorities = queue_priorities,
            };

            return .{
                .info = info,
                .indices = .{
                    .graphics_queue_index = 0,
                    .present_queue_index = 0,
                },
            };
        } else {
            const info = allocator.alloc(c.VkDeviceQueueCreateInfo, 2) catch panic("Buffer not large enough for QueueCreateInfo", .{});
            errdefer allocator.destroy(info);
            info[0] = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = indices.graphics_queue_index,
                .queueCount = 1,
                .pQueuePriorities = queue_priorities,
            };
            info[1] = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = indices.present_queue_index,
                .queueCount = 1,
                .pQueuePriorities = queue_priorities,
            };

            return .{
                .info = info,
                .indices = .{
                    .graphics_queue_index = 0,
                    .present_queue_index = 1,
                },
            };
        }
    }
};

pub const PhysicalDevice = struct {
    device: c.VkPhysicalDevice,
    queue_family_indices: QueueFamilyIndicies,

    pub fn findSuitable(instance: *const Instance, surface: *const Surface, allocator: Allocator) !PhysicalDevice {
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance.instance, &device_count, null);
        const devices = try allocator.alloc(c.VkPhysicalDevice, device_count);
        defer allocator.free(devices);
        _ = c.vkEnumeratePhysicalDevices(instance.instance, &device_count, devices.ptr);

        for (devices) |*device| {
            if (!try hasExtensions(device, &required_extensions, allocator)) {
                return error.VulkanMissingRequiredExtensions;
            }

            if (try findQueueFamilyIndicies(device, &surface.surface, allocator)) |queue_family_indices| {
                return .{ .device = device.*, .queue_family_indices = queue_family_indices };
            }
        }

        return error.VulkanMissingPhysicalDevice;
    }

    fn hasExtensions(device: *const c.VkPhysicalDevice, extensions: []const []const u8, allocator: Allocator) !bool {
        var found_extension_count: u32 = 0;
        _ = c.vkEnumerateDeviceExtensionProperties(device.*, null, &found_extension_count, null);
        const found_extensions = try allocator.alloc(c.VkExtensionProperties, found_extension_count);
        defer allocator.free(found_extensions);
        _ = c.vkEnumerateDeviceExtensionProperties(device.*, null, &found_extension_count, found_extensions.ptr);

        outer: for (extensions) |extension| {
            for (found_extensions) |found_extension| {
                if (c.strcmp(extension.ptr, &found_extension.extensionName) == 0) {
                    continue :outer;
                }
            }
            return false;
        }

        return true;
    }

    fn findQueueFamilyIndicies(device: *const c.VkPhysicalDevice, surface: *const c.VkSurfaceKHR, allocator: Allocator) !?QueueFamilyIndicies {
        var queue_family_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device.*, &queue_family_count, null);
        const queue_families = try allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);
        _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device.*, &queue_family_count, queue_families.ptr);

        var graphics_queue_family: ?usize = null;
        var present_queue_family: ?usize = null;
        for (queue_families, 0..) |queue_family, i| {
            if (queue_family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT % 2 == 1) {
                graphics_queue_family = i;
            }

            var present_support: c.VkBool32 = c.VK_FALSE;
            _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device.*, @intCast(i), surface.*, &present_support);
            if (present_support % 2 == 1) {
                present_queue_family = i;
            }

            if (graphics_queue_family) |g| {
                if (present_queue_family) |p| {
                    return .{
                        .graphics_queue_index = @intCast(g),
                        .present_queue_index = @intCast(p),
                    };
                }
            }
        }

        return null;
    }
};

pub const required_extensions = [_][]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

pub const logical_device_extensions = [_][*c]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

pub const LogicalDevice = struct {
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,
    swap_chain_support: SwapChainSupport,

    const SwapChainSupport = struct {
        capabilities: c.VkSurfaceCapabilitiesKHR,
        surface_formats: []c.VkSurfaceFormatKHR,
        present_modes: []c.VkPresentModeKHR,
        allocator: Allocator,

        fn query(physical_device: *const c.VkPhysicalDevice, surface: *const Surface, allocator: Allocator) !SwapChainSupport {
            var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
            _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.*, surface.surface, &capabilities);

            var surface_format_count: u32 = 0;
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device.*, surface.surface, &surface_format_count, null);
            const surface_formats = try allocator.alloc(c.VkSurfaceFormatKHR, surface_format_count);
            errdefer allocator.free(surface_formats);
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device.*, surface.surface, &surface_format_count, surface_formats.ptr);

            var present_mode_count: u32 = 0;
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device.*, surface.surface, &present_mode_count, null);
            const present_modes = try allocator.alloc(c.VkPresentModeKHR, present_mode_count);
            errdefer allocator.free(present_modes);
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device.*, surface.surface, &present_mode_count, present_modes.ptr);

            return .{
                .capabilities = capabilities,
                .surface_formats = surface_formats,
                .present_modes = present_modes,
                .allocator = allocator,
            };
        }

        fn preferredSwapSurfaceFormat(support: *const SwapChainSupport) c.VkSurfaceFormatKHR {
            std.debug.assert(support.surface_formats.len >= 1);

            for (support.surface_formats) |format| {
                if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                    return format;
                }
            }

            return support.surface_formats[0];
        }

        fn preferredSwapPresentMode(support: *const SwapChainSupport) c.VkPresentModeKHR {
            std.debug.assert(support.present_modes.len >= 1);

            for (support.present_modes) |mode| {
                if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                    return mode;
                }
            }

            return c.VK_PRESENT_MODE_FIFO_KHR;
        }

        fn preferredSwapExtent(support: *const SwapChainSupport, window: *const GlfwWindow) c.VkExtent2D {
            if (support.capabilities.currentExtent.width != std.math.maxInt(u32)) {
                return support.capabilities.currentExtent;
            }

            const dimensions = window.dimensions();
            const width = dimensions.width;
            const height = dimensions.height;

            return c.VkExtent2D{
                .width = std.math.clamp(
                    @as(u32, @intCast(width)),
                    support.capabilities.minImageExtent.width,
                    support.capabilities.maxImageExtent.width,
                ),
                .height = std.math.clamp(
                    @as(u32, @intCast(height)),
                    support.capabilities.minImageExtent.height,
                    support.capabilities.maxImageExtent.height,
                ),
            };
        }

        fn preferredImageCount(support: *const SwapChainSupport) u32 {
            return @max(support.capabilities.minImageCount + 1, support.capabilities.maxImageCount);
        }
    };

    pub fn init(physical_device: *const PhysicalDevice, surface: *const Surface, allocator: Allocator) !LogicalDevice {
        var buf = [_]u8{0} ** 1024;
        const queue_create_info = physical_device.queue_family_indices.toQueueCreateInfo(&buf);

        const create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = queue_create_info.info.ptr,
            .queueCreateInfoCount = @intCast(queue_create_info.info.len),
            .pEnabledFeatures = &c.VkPhysicalDeviceFeatures{},
            .enabledExtensionCount = logical_device_extensions.len,
            .ppEnabledExtensionNames = &logical_device_extensions,
        };

        var device: c.VkDevice = undefined;
        if (c.vkCreateDevice(@constCast(physical_device.device), &create_info, null, &device) != c.VK_SUCCESS) {
            return error.FailedToCreateVulkanLogicalDevice;
        }

        var graphics_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(
            device,
            physical_device.queue_family_indices.graphics_queue_index,
            queue_create_info.indices.graphics_queue_index,
            &graphics_queue,
        );

        var present_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(
            device,
            physical_device.queue_family_indices.present_queue_index,
            queue_create_info.indices.present_queue_index,
            &present_queue,
        );

        const swap_chain_support = try SwapChainSupport.query(&physical_device.device, surface, allocator);

        if (swap_chain_support.surface_formats.len == 0 or swap_chain_support.present_modes.len == 0) {
            return error.VulkanInsufficentSwapChainSupport;
        }

        return .{
            .device = device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .swap_chain_support = swap_chain_support,
        };
    }

    pub fn deinit(device: *LogicalDevice) void {
        c.vkDestroyDevice(device.device, null);
        device.swap_chain_support.allocator.free(device.swap_chain_support.surface_formats);
        device.swap_chain_support.allocator.free(device.swap_chain_support.present_modes);
    }
};

pub const SwapChain = struct {
    swap_chain: c.VkSwapchainKHR,
    logical_device: *const LogicalDevice,
    swap_chain_images: []c.VkImage,
    swap_chain_image_views: []c.VkImageView,
    swap_chain_format: c.VkFormat,
    swap_chain_extent: c.VkExtent2D,
    allocator: Allocator,

    pub fn init(
        window: *const GlfwWindow,
        surface: *const Surface,
        physical_device: *const PhysicalDevice,
        logical_device: *const LogicalDevice,
        allocator: Allocator,
    ) !SwapChain {
        const surface_format = logical_device.swap_chain_support.preferredSwapSurfaceFormat();
        const present_mode = logical_device.swap_chain_support.preferredSwapPresentMode();
        const extent = logical_device.swap_chain_support.preferredSwapExtent(window);
        const image_count = logical_device.swap_chain_support.preferredImageCount();

        var create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .preTransform = logical_device.swap_chain_support.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = @ptrCast(c.VK_NULL_HANDLE),
        };

        const queue_family_indices = [_]u32{
            physical_device.queue_family_indices.present_queue_index,
            physical_device.queue_family_indices.graphics_queue_index,
        };

        if (queue_family_indices[0] != queue_family_indices[1]) {
            create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            create_info.queueFamilyIndexCount = queue_family_indices.len;
            create_info.pQueueFamilyIndices = &queue_family_indices;
        } else {
            create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
            create_info.queueFamilyIndexCount = 0;
            create_info.pQueueFamilyIndices = null;
        }

        var swap_chain: c.VkSwapchainKHR = undefined;
        if (c.vkCreateSwapchainKHR(logical_device.device, &create_info, null, &swap_chain) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateSwapChain;
        }

        var swap_chain_image_count: u32 = 0;
        _ = c.vkGetSwapchainImagesKHR(logical_device.device, swap_chain, &swap_chain_image_count, null);
        const swap_chain_images = try allocator.alloc(c.VkImage, swap_chain_image_count);
        errdefer allocator.free(swap_chain_images);
        _ = c.vkGetSwapchainImagesKHR(logical_device.device, swap_chain, &swap_chain_image_count, swap_chain_images.ptr);

        const swap_chain_image_views = try allocator.alloc(c.VkImageView, swap_chain_image_count);
        errdefer allocator.free(swap_chain_image_views);
        for (swap_chain_image_views, 0..) |*image_view, i| {
            const view_create_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = swap_chain_images[i],
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = surface_format.format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            if (c.vkCreateImageView(logical_device.device, &view_create_info, null, image_view) != c.VK_SUCCESS) {
                return error.VulkanFailedToCreateImageView;
            }
        }

        return .{
            .swap_chain = swap_chain,
            .logical_device = logical_device,
            .swap_chain_images = swap_chain_images,
            .swap_chain_image_views = swap_chain_image_views,
            .swap_chain_format = surface_format.format,
            .swap_chain_extent = extent,
            .allocator = allocator,
        };
    }

    pub fn deinit(swap_chain: *SwapChain) void {
        for (swap_chain.swap_chain_image_views) |image_view| {
            c.vkDestroyImageView(swap_chain.logical_device.device, image_view, null);
        }
        c.vkDestroySwapchainKHR(swap_chain.logical_device.device, swap_chain.swap_chain, null);
        swap_chain.allocator.free(swap_chain.swap_chain_images);
        swap_chain.allocator.free(swap_chain.swap_chain_image_views);
    }

    pub fn viewport(swap_chain: *const SwapChain) c.VkViewport {
        return c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(swap_chain.swap_chain_extent.width),
            .height = @floatFromInt(swap_chain.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
    }

    pub fn scissor(swap_chain: *const SwapChain) c.VkRect2D {
        return c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swap_chain.swap_chain_extent,
        };
    }
};

pub const ShaderModule = struct {
    module: c.VkShaderModule,
    logical_device: *const LogicalDevice,

    pub fn initFromEmbed(logical_device: *const LogicalDevice, comptime name: []const u8) !ShaderModule {
        const bytecode = comptime std.mem.bytesAsSlice(u32, @embedFile(name));
        const aligned = comptime blk: {
            var bytes = [_]u32{0} ** bytecode.len;
            @memcpy(&bytes, bytecode);
            break :blk bytes;
        };
        return init(logical_device, &aligned);
    }

    pub fn init(logical_device: *const LogicalDevice, bytecode: []const u32) !ShaderModule {
        const create_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = bytecode.len * @sizeOf(u32),
            .pCode = bytecode.ptr,
        };

        var module: c.VkShaderModule = undefined;
        if (c.vkCreateShaderModule(logical_device.device, &create_info, null, &module) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateShaderModule;
        }

        return .{
            .module = module,
            .logical_device = logical_device,
        };
    }

    pub fn deinit(module: *ShaderModule) void {
        c.vkDestroyShaderModule(module.logical_device.device, module.module, null);
    }
};

const PushConstantInfo = struct {
    const Info = struct { stage_flags: u32, offset: u32 };

    info: []const Info,
    ranges: []const c.VkPushConstantRange,
};

pub const PushConstantDesc = struct {
    ty: type,
    stage_flags: u32 = c.VK_SHADER_STAGE_VERTEX_BIT,
    offset: u32,
};

pub fn pushConstantLayouts(comptime push_constants: []const PushConstantDesc) PushConstantInfo {
    comptime var push_constant_info: [push_constants.len]PushConstantInfo.Info = undefined;
    comptime var push_constant_ranges: [push_constants.len]c.VkPushConstantRange = undefined;

    inline for (push_constants, 0..) |constant, i| {
        const size = @sizeOf(constant.ty);
        push_constant_ranges[i] = c.VkPushConstantRange{
            .stageFlags = constant.stage_flags,
            .offset = constant.offset,
            .size = size,
        };
        push_constant_info[i] = .{
            .stage_flags = constant.stage_flags,
            .offset = constant.offset,
        };
    }

    const pc_info = push_constant_info;
    const pc_ranges = push_constant_ranges;

    return .{
        .info = &pc_info,
        .ranges = &pc_ranges,
    };
}

pub const PipelineLayout = struct {
    layout: c.VkPipelineLayout,
    logical_device: *const LogicalDevice,
    push_constant_info: PushConstantInfo,

    pub fn init(
        logical_device: *const LogicalDevice,
        opts: struct {
            push_constant_info: PushConstantInfo,
        },
    ) !PipelineLayout {
        const pipeline_layout_create_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pushConstantRangeCount = @intCast(opts.push_constant_info.ranges.len),
            .pPushConstantRanges = opts.push_constant_info.ranges.ptr,
        };

        var pipeline_layout: c.VkPipelineLayout = undefined;
        if (c.vkCreatePipelineLayout(
            logical_device.device,
            &pipeline_layout_create_info,
            null,
            &pipeline_layout,
        ) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreatePipelineLayout;
        }

        return .{
            .layout = pipeline_layout,
            .logical_device = logical_device,
            .push_constant_info = opts.push_constant_info,
        };
    }

    pub fn deinit(layout: *PipelineLayout) void {
        c.vkDestroyPipelineLayout(layout.logical_device.device, layout.layout, null);
    }
};

pub const RenderPass = struct {
    pass: c.VkRenderPass,
    logical_device: *const LogicalDevice,

    pub fn init(swap_chain: *const SwapChain) !RenderPass {
        const logical_device = swap_chain.logical_device;
        const render_pass_create_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &c.VkAttachmentDescription{
                .format = swap_chain.swap_chain_format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            },
            .subpassCount = 1,
            .pSubpasses = &c.VkSubpassDescription{
                .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                .colorAttachmentCount = 1,
                .pColorAttachments = &c.VkAttachmentReference{
                    .attachment = 0,
                    .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                },
            },
            .dependencyCount = 1,
            .pDependencies = &c.VkSubpassDependency{
                .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = 0,
                .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                .srcAccessMask = 0,
                .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            },
        };

        var render_pass: c.VkRenderPass = undefined;
        if (c.vkCreateRenderPass(
            logical_device.device,
            &render_pass_create_info,
            null,
            &render_pass,
        ) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateRenderPass;
        }

        return .{
            .pass = render_pass,
            .logical_device = logical_device,
        };
    }

    pub fn deinit(pass: *RenderPass) void {
        c.vkDestroyRenderPass(pass.logical_device.device, pass.pass, null);
    }
};

pub const Pipeline = struct {
    pipeline: c.VkPipeline,
    logical_device: *const LogicalDevice,

    pub fn init(
        pipeline_layout: *const PipelineLayout,
        render_pass: *const RenderPass,
        vert_shader_module: *const ShaderModule,
        frag_shader_module: *const ShaderModule,
        swap_chain: *const SwapChain,
        opts: struct {
            vertex_binding_descs: []const vertex.BindDesc,
            vertex_attribute_descs: []const vertex.AttrDesc,
        },
    ) !Pipeline {
        const logical_device = render_pass.logical_device;
        const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_shader_module.module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_shader_module.module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        const dynamic_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };

        const pipeline_create_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &c.VkPipelineVertexInputStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                .vertexBindingDescriptionCount = @intCast(opts.vertex_binding_descs.len),
                .pVertexBindingDescriptions = opts.vertex_binding_descs.ptr,
                .vertexAttributeDescriptionCount = @intCast(opts.vertex_attribute_descs.len),
                .pVertexAttributeDescriptions = opts.vertex_attribute_descs.ptr,
            },
            .pInputAssemblyState = &c.VkPipelineInputAssemblyStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                .primitiveRestartEnable = c.VK_FALSE,
            },
            .pViewportState = &c.VkPipelineViewportStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                .viewportCount = 1,
                .pViewports = &swap_chain.viewport(),
                .scissorCount = 1,
                .pScissors = &swap_chain.scissor(),
            },
            .pRasterizationState = &c.VkPipelineRasterizationStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                .depthClampEnable = c.VK_FALSE,
                .rasterizerDiscardEnable = c.VK_FALSE,
                .polygonMode = c.VK_POLYGON_MODE_FILL,
                .lineWidth = 1.0,
                .cullMode = c.VK_CULL_MODE_BACK_BIT,
                .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
                .depthBiasEnable = c.VK_FALSE,
            },
            .pMultisampleState = &c.VkPipelineMultisampleStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                .sampleShadingEnable = c.VK_FALSE,
                .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            },
            .pDepthStencilState = null,
            .pColorBlendState = &c.VkPipelineColorBlendStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                .logicOpEnable = c.VK_FALSE,
                .attachmentCount = 1,
                .pAttachments = &c.VkPipelineColorBlendAttachmentState{
                    .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
                    .blendEnable = c.VK_FALSE,
                },
            },
            .pDynamicState = &c.VkPipelineDynamicStateCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                .dynamicStateCount = dynamic_states.len,
                .pDynamicStates = &dynamic_states,
            },
            .layout = pipeline_layout.layout,
            .renderPass = render_pass.pass,
            .subpass = 0,
            .basePipelineHandle = @ptrCast(c.VK_NULL_HANDLE),
        };

        var pipeline: c.VkPipeline = undefined;
        if (c.vkCreateGraphicsPipelines(
            logical_device.device,
            @ptrCast(c.VK_NULL_HANDLE),
            1,
            &pipeline_create_info,
            null,
            &pipeline,
        ) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreatePipeline;
        }

        return .{
            .logical_device = logical_device,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(pipeline: *Pipeline) void {
        c.vkDestroyPipeline(pipeline.logical_device.device, pipeline.pipeline, null);
    }
};

pub const Framebuffers = struct {
    buffers: []c.VkFramebuffer,
    logical_device: *const LogicalDevice,

    pub fn init(
        render_pass: *const RenderPass,
        swap_chain: *const SwapChain,
        allocator: Allocator,
    ) !Framebuffers {
        const logical_device = render_pass.logical_device;
        const buffers = try allocator.alloc(c.VkFramebuffer, swap_chain.swap_chain_image_views.len);
        errdefer allocator.free(buffers);

        for (buffers, 0..) |*buf, i| {
            const framebuffer_create_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = render_pass.pass,
                .attachmentCount = 1,
                .pAttachments = &[_]c.VkImageView{swap_chain.swap_chain_image_views[i]},
                .width = swap_chain.swap_chain_extent.width,
                .height = swap_chain.swap_chain_extent.height,
                .layers = 1,
            };

            if (c.vkCreateFramebuffer(logical_device.device, &framebuffer_create_info, null, buf) != c.VK_SUCCESS) {
                return error.VulkanFailedToCreateFramebuffer;
            }

            errdefer c.vkDestroyFramebuffer(logical_device.device, buf, null);
        }

        return .{
            .buffers = buffers,
            .logical_device = logical_device,
        };
    }

    pub fn deinit(buffers: *Framebuffers) void {
        for (buffers.buffers) |buf| {
            c.vkDestroyFramebuffer(buffers.logical_device.device, buf, null);
        }
    }
};

pub const CommandPool = struct {
    pool: c.VkCommandPool,
    logical_device: *const LogicalDevice,

    pub fn init(physical_device: *const PhysicalDevice, logical_device: *const LogicalDevice) !CommandPool {
        const create_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = physical_device.queue_family_indices.graphics_queue_index,
        };

        var command_pool: c.VkCommandPool = undefined;
        if (c.vkCreateCommandPool(logical_device.device, &create_info, null, &command_pool) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateCommandPool;
        }

        return .{
            .pool = command_pool,
            .logical_device = logical_device,
        };
    }

    pub fn deinit(pool: *CommandPool) void {
        c.vkDestroyCommandPool(pool.logical_device.device, pool.pool, null);
    }
};

pub const CommandBuffer = struct {
    buffer: c.VkCommandBuffer,

    pub fn init(command_pool: *const CommandPool) !CommandBuffer {
        var buffer: c.VkCommandBuffer = undefined;
        if (c.vkAllocateCommandBuffers(
            command_pool.logical_device.device,
            &c.VkCommandBufferAllocateInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandPool = command_pool.pool,
                .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            },
            &buffer,
        ) != c.VK_SUCCESS) {
            return error.VulkanFailedToCreateCommandBuffer;
        }

        return .{
            .buffer = buffer,
        };
    }

    pub fn begin(buffer: *const CommandBuffer, flags: c.VkCommandBufferUsageFlags) !void {
        if (c.vkBeginCommandBuffer(buffer.buffer, &c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = flags,
        }) != c.VK_SUCCESS) {
            return error.VulkanFailedBeginRecordingCommandBuffer;
        }
    }

    pub fn end(buffer: *const CommandBuffer) !void {
        if (c.vkEndCommandBuffer(buffer.buffer) != c.VK_SUCCESS) {
            return error.VulkanFailedToRecordCommandBuffer;
        }
    }

    pub fn beginRenderPass(
        buffer: *const CommandBuffer,
        render_pass: *const RenderPass,
        framebuffers: *const Framebuffers,
        swap_chain: *const SwapChain,
        pipeline: *const Pipeline,
        image_index: u32,
    ) void {
        c.vkCmdBeginRenderPass(buffer.buffer, &c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = render_pass.pass,
            .framebuffer = framebuffers.buffers[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = swap_chain.swap_chain_extent,
            },
            .clearValueCount = 1,
            .pClearValues = &c.VkClearValue{ .color = .{ .float32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 } } },
        }, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(buffer.buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);
        c.vkCmdSetViewport(buffer.buffer, 0, 1, &swap_chain.viewport());
        c.vkCmdSetScissor(buffer.buffer, 0, 1, &swap_chain.scissor());
    }

    pub fn endRenderPass(buffer: *const CommandBuffer) void {
        c.vkCmdEndRenderPass(buffer.buffer);
    }

    pub fn bindVertexBuffers(buffer: *const CommandBuffer, vertex_buffers: anytype) void {
        const num_buffers = std.meta.fields(@TypeOf(vertex_buffers)).len;
        var raw_buffers: [num_buffers]c.VkBuffer = undefined;
        var offsets = [_]u64{0} ** num_buffers;
        inline for (0..num_buffers) |i| {
            raw_buffers[i] = vertex_buffers[i].raw.buffer;
        }

        c.vkCmdBindVertexBuffers(buffer.buffer, 0, num_buffers, &raw_buffers, &offsets);
    }

    pub fn bindIndexBuffer(buffer: *const CommandBuffer, index_buffer: anytype) void {
        c.vkCmdBindIndexBuffer(buffer.buffer, index_buffer.raw.buffer, 0, c.VK_INDEX_TYPE_UINT16);
    }

    pub fn pushConstants(
        buffer: *const CommandBuffer,
        pipeline_layout: *const PipelineLayout,
        constant: anytype,
        opts: struct { index: usize },
    ) void {
        var info: ?PushConstantInfo.Info = null;
        for (pipeline_layout.push_constant_info.info, 0..) |pc_info, i| {
            if (i == opts.index) {
                info = pc_info;
            }
        }

        if (info == null) {
            std.debug.panic("Could not find push constant, try specifying an index", .{});
        }

        c.vkCmdPushConstants(
            buffer.buffer,
            pipeline_layout.layout,
            info.?.stage_flags,
            info.?.offset,
            @sizeOf(@TypeOf(constant.*)),
            constant,
        );
    }
};
