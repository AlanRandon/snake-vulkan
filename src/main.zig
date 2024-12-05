const std = @import("std");
const vk = @import("./vulkan.zig");
const Renderer = @import("./renderer.zig").Renderer(2);
const Game = @import("./game.zig").Game;
const Direction = @import("./game.zig").Direction;
const GameRenderer = @import("./game/renderer.zig").GameRenderer;

const Controls = struct {
    const KeyState = enum { pressed, released };

    window: *const vk.GlfwWindow,
    states: [4]KeyState = [_]KeyState{.released} ** 4,
    direction: Direction = .east,

    fn read(controls: *Controls) void {
        inline for (.{
            .{ .key = vk.c.GLFW_KEY_H, .direction = Direction.west },
            .{ .key = vk.c.GLFW_KEY_J, .direction = Direction.south },
            .{ .key = vk.c.GLFW_KEY_K, .direction = Direction.north },
            .{ .key = vk.c.GLFW_KEY_L, .direction = Direction.east },
        }) |key| {
            const state = &controls.states[@intFromEnum(key.direction)];
            switch (vk.c.glfwGetKey(controls.window.window, key.key)) {
                vk.c.GLFW_PRESS => if (state.* == .released) {
                    if (controls.direction.opposite() != key.direction) {
                        controls.direction = key.direction;
                    }

                    state.* = .pressed;
                },
                vk.c.GLFW_RELEASE => state.* = .released,
                else => std.debug.panic("invalid key state", .{}),
            }
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var game = Game(10, 10).init(3);
    game.put_head(1, 0);

    var window = try vk.GlfwWindow.init(800, 600, "Vulkan");
    defer window.deinit();

    var framebuffer_resized = false;
    window.resizeCallback(struct {
        fn callback(opts: anytype) void {
            opts.user_data.* = true;
        }
    }.callback, &framebuffer_resized);

    var instance = try vk.Instance.init(allocator);
    defer instance.deinit();

    var surface = try vk.Surface.init(&instance, &window);
    defer surface.deinit();

    const physical_device = try vk.PhysicalDevice.findSuitable(&instance, &surface, allocator);
    var logical_device = try vk.LogicalDevice.init(&physical_device, &surface, allocator);
    defer logical_device.deinit();

    var gr = try GameRenderer.init(
        &logical_device,
        &physical_device,
        &window,
        &surface,
        allocator,
    );
    defer gr.deinit();

    var last_tick = try std.time.Instant.now();

    var controls = Controls{ .window = &window };

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        framebuffer_resized = false;

        vk.c.glfwPollEvents();
        controls.read();

        const now = try std.time.Instant.now();
        if (now.since(last_tick) >= 200_000_000) {
            last_tick = now;

            game.move(controls.direction) catch |err| switch (err) {
                error.SnakeCollided => {
                    std.debug.print("You lost\n", .{});
                    break;
                },
                else => return err,
            };
        }

        try gr.render(&game, .{ .framebuffer_resized = &framebuffer_resized });

        if (framebuffer_resized) {
            try gr.handleResize();
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
