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
    inhibited_direction: Direction,
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
                    if (controls.inhibited_direction != key.direction) {
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

const GameAssetBundle = struct {
    game_over_sound: audio.Sound,
    eat_sound: audio.Sound,
    tiles_texture: vk.texture.Texture,

    pub fn init(
        sound: *audio.Audio,
        logical_device: *const vk.LogicalDevice,
        physical_device: *const vk.PhysicalDevice,
        command_pool: *const vk.CommandPool,
        game_over_data: []const u8,
        eat_data: []const u8,
        tiles_data: []const u8,
    ) !GameAssetBundle {
        var game_over_sound = try sound.sound(game_over_data);
        errdefer game_over_sound.deinit();
        var eat_sound = try sound.sound(eat_data);
        errdefer eat_sound.deinit();
        var tiles = try vk.texture.Texture.init(
            tiles_data,
            logical_device,
            physical_device,
            command_pool,
            .{},
        );
        errdefer tiles.deinit();

        return .{
            .game_over_sound = game_over_sound,
            .eat_sound = eat_sound,
            .tiles_texture = tiles,
        };
    }

    pub fn deinit(assets: *GameAssetBundle) void {
        assets.game_over_sound.deinit();
        assets.eat_sound.deinit();
        assets.tiles_texture.deinit();
    }
};

const Map = struct {
    const Point = [2]u8;

    walls: []const struct { location: Point },
    head: struct { location: Point, initial_growth: u8, direction: Direction },
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var sound = try audio.Audio.init(allocator);
    defer sound.deinit();

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator });
    defer thread_pool.deinit();

    var map = try std.json.parseFromSlice(
        Map,
        allocator,
        @embedFile("asset:map.json"),
        .{},
    );
    defer map.deinit();

    var rng = std.Random.DefaultPrng.init(0);

    const head = map.value.head;
    var game = Game(10, 10).init(head.initial_growth, rng.random());

    for (map.value.walls) |wall| {
        game.put_wall(wall.location[0], wall.location[1]);
    }

    game.put_head(head.location[0], head.location[1]);

    for (0..head.initial_growth) |_| {
        _ = game.move(head.direction);
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

    var command_pool = try vk.CommandPool.init(&physical_device, &logical_device);
    defer command_pool.deinit();

    var swap_chain = try vk.SwapChain.init(&window, &surface, &physical_device, &logical_device, allocator);
    defer swap_chain.deinit();

    var render_pass = try vk.RenderPass.init(&swap_chain);
    defer render_pass.deinit();

    var framebuffers = try vk.Framebuffers.init(&render_pass, &swap_chain, allocator);
    defer framebuffers.deinit();

    var assets = try GameAssetBundle.init(
        &sound,
        &logical_device,
        &physical_device,
        &command_pool,
        @embedFile("asset:game-over.mp3"),
        @embedFile("asset:eat.mp3"),
        @embedFile("asset:tiles.png"),
    );
    defer assets.deinit();

    var gr = try GameRenderer.init(
        &logical_device,
        &physical_device,
        &command_pool,
        &window,
        &surface,
        &swap_chain,
        &framebuffers,
        &render_pass,
        &game,
        &assets.tiles_texture,
        allocator,
    );
    defer gr.deinit();

    var last_tick = try std.time.Instant.now();

    var controls = Controls{ .window = &window, .inhibited_direction = .west };

    var tick_ns: usize = 200_000_000;

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        framebuffer_resized = false;

        vk.c.glfwPollEvents();
        controls.read();

        const now = try std.time.Instant.now();
        if (now.since(last_tick) >= tick_ns and !controls.paused) {
            last_tick = now;

            controls.inhibited_direction = controls.direction.opposite();
            switch (game.move(controls.direction)) {
                .move => {},
                .game_over => {
                    try assets.game_over_sound.playInThreadPool(&thread_pool);
                    controls.paused = true;
                    tick_ns = @max(tick_ns - 10_000_000, 120_000_000);
                },
                .eat => {
                    try assets.eat_sound.playInThreadPool(&thread_pool);
                },
            }
        }

        try gr.render(&game, .{ .framebuffer_resized = &framebuffer_resized });

        if (framebuffer_resized) {
            try gr.handleResize();
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
