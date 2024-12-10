const std = @import("std");
const vk = @import("./vulkan.zig");
const Renderer = @import("./renderer.zig").Renderer(2);
const Game = @import("./game.zig").Game;
const Direction = @import("./game.zig").Direction;
const GameRenderer = @import("./game/renderer.zig").GameRenderer;
const audio = @import("./audio.zig");

const Controls = struct {
    const KeyState = enum { pressed, released };

    window: *const vk.GlfwWindow,
    states: [5]KeyState = [_]KeyState{.released} ** 5,
    direction: Direction = .east,
    paused: bool = false,

    fn read(controls: *Controls) void {
        inline for (.{
            .{ .key = vk.c.GLFW_KEY_H, .direction = Direction.west },
            .{ .key = vk.c.GLFW_KEY_J, .direction = Direction.south },
            .{ .key = vk.c.GLFW_KEY_K, .direction = Direction.north },
            .{ .key = vk.c.GLFW_KEY_L, .direction = Direction.east },
        }, 0..) |key, i| {
            const state = &controls.states[i];
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

        switch (vk.c.glfwGetKey(controls.window.window, vk.c.GLFW_KEY_P)) {
            vk.c.GLFW_PRESS => if (controls.states[4] == .released) {
                controls.paused = !controls.paused;
                controls.states[4] = .pressed;
            },
            vk.c.GLFW_RELEASE => controls.states[4] = .released,
            else => std.debug.panic("invalid key state", .{}),
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var sound = try audio.Audio.init(allocator);
    defer sound.deinit();

    var scream = try sound.sound(@embedFile("asset:sound.mp3"));
    defer scream.deinit();

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator });
    defer thread_pool.deinit();

    var rng = std.Random.DefaultPrng.init(0);
    var game = Game(10, 10).init(3, rng.random());
    game.put_head(7, 1);

    for (0..3) |_| {
        try game.move(.east);
    }

    game.spawn_apple();

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
        &game,
        @embedFile("asset:tiles.png"),
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
        if (now.since(last_tick) >= 200_000_000 and !controls.paused) {
            last_tick = now;

            game.move(controls.direction) catch |err| switch (err) {
                error.SnakeCollided => {
                    std.debug.print("You lost\n", .{});
                    try scream.playInThreadPool(&thread_pool);
                    controls.paused = true;
                },
            };
        }

        try gr.render(&game, .{ .framebuffer_resized = &framebuffer_resized });

        if (framebuffer_resized) {
            try gr.handleResize();
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
