const std = @import("std");
const vk = @import("./vulkan.zig");
const Renderer = @import("./renderer.zig").Renderer(2);
const Game = @import("./game.zig").Game;
const Direction = @import("./game.zig").Direction;
const GridRenderer = @import("./game/renderer.zig").GameRenderer;
const ImageRenderer = @import("./game/menu_renderer.zig").ImageRenderer;
const audio = @import("./audio.zig");
const Allocator = std.mem.Allocator;

const Event = union(enum) {
    turn: Direction,
    toggle_pause,
    tick,
};

const State = struct {
    direction: Direction = .east,
    last_direction: Direction = .east,
    state: enum {
        paused,
        no_game,
        playing,
    } = .no_game,
    game: Game(10, 10) = undefined,
    map: Map,
    rng: std.Random,
    assets: *const GameAssetBundle,
    tick_ns: usize = 200_000_000,

    pub fn handleEvent(state: *State, event: Event) !void {
        switch (event) {
            .turn => |direction| if (direction != state.last_direction.opposite()) {
                state.direction = direction;
            },
            .tick => {
                if (state.state != .playing) {
                    return;
                }

                state.last_direction = state.direction;
                switch (state.game.move(state.last_direction)) {
                    .move => {},
                    .game_over => {
                        try state.assets.game_over_sound.start();
                        state.state = .no_game;
                    },
                    .eat => {
                        state.tick_ns = @max(state.tick_ns - 10_000_000, 150_000_000);
                        try state.assets.eat_sounds[
                            state.rng.weightedIndex(
                                f32,
                                state.assets.eat_sound_probabilities,
                            )
                        ].start();
                    },
                }
            },
            .toggle_pause => {
                switch (state.state) {
                    .paused => state.state = .playing,
                    .playing => state.state = .paused,
                    .no_game => {
                        state.tick_ns = 200_000_000;

                        const head = state.map.head;
                        var game = Game(10, 10).init(head.initial_growth, state.rng);

                        for (state.map.walls) |wall| {
                            game.put_wall(wall.location[0], wall.location[1]);
                        }

                        game.put_head(head.location[0], head.location[1]);

                        for (0..head.initial_growth) |_| {
                            _ = game.move(head.direction);
                        }

                        game.spawn_apple();

                        state.game = game;
                        state.state = .playing;
                        state.last_direction = head.direction;
                        state.direction = head.direction;
                    },
                }
            },
        }
    }
};

const Controls = struct {
    window: *const vk.GlfwWindow,
    states: [5]KeyState = [_]KeyState{.released} ** 5,

    const KeyState = enum { pressed, released };

    fn readEvents(controls: *Controls, events: []Event) []Event {
        var result_len: usize = 0;

        inline for (.{
            .{ .key = vk.c.GLFW_KEY_H, .event = Event{ .turn = Direction.west } },
            .{ .key = vk.c.GLFW_KEY_J, .event = Event{ .turn = Direction.south } },
            .{ .key = vk.c.GLFW_KEY_K, .event = Event{ .turn = Direction.north } },
            .{ .key = vk.c.GLFW_KEY_L, .event = Event{ .turn = Direction.east } },
            .{ .key = vk.c.GLFW_KEY_SPACE, .event = Event.toggle_pause },
        }, 0..) |key, i| {
            const state = &controls.states[i];
            switch (vk.c.glfwGetKey(controls.window.window, key.key)) {
                vk.c.GLFW_PRESS => if (state.* == .released) {
                    events[result_len] = key.event;
                    result_len += 1;
                    state.* = .pressed;
                },
                vk.c.GLFW_RELEASE => state.* = .released,
                else => std.debug.panic("invalid key state", .{}),
            }
        }

        return events[0..result_len];
    }
};

const GameAssetBundle = struct {
    game_over_sound: audio.Sound,
    music: audio.Sound,
    eat_sounds: []audio.Sound,
    eat_sound_probabilities: []const f32,
    tiles_texture: vk.texture.Texture,
    play_texture: vk.texture.Texture,
    allocator: Allocator,

    const SoundOptionData = struct { data: []const u8, probability: f32 };

    pub fn initFromDir(
        allocator: Allocator,
        sound: *audio.Audio,
        logical_device: *const vk.LogicalDevice,
        physical_device: *const vk.PhysicalDevice,
        command_pool: *const vk.CommandPool,
        dir: *const std.fs.Dir,
    ) !GameAssetBundle {
        const max_file_size = std.math.maxInt(u32);

        const game_over = try dir.readFileAlloc(allocator, "game-over.mp3", max_file_size);
        defer allocator.free(game_over);

        const eat_1 = try dir.readFileAlloc(allocator, "eat-1.mp3", max_file_size);
        defer allocator.free(eat_1);

        const eat_2 = try dir.readFileAlloc(allocator, "eat-2.mp3", max_file_size);
        defer allocator.free(eat_2);

        const music = try dir.readFileAlloc(allocator, "music.mp3", max_file_size);
        defer allocator.free(music);

        const tiles = try dir.readFileAlloc(allocator, "tiles.png", max_file_size);
        defer allocator.free(tiles);

        const play = try dir.readFileAlloc(allocator, "play.png", max_file_size);
        defer allocator.free(play);

        return init(
            allocator,
            sound,
            logical_device,
            physical_device,
            command_pool,
            .{
                .game_over = game_over,
                .eat = &[_]GameAssetBundle.SoundOptionData{
                    .{ .data = eat_1, .probability = 0.75 },
                    .{ .data = eat_2, .probability = 0.25 },
                },
                .tiles = tiles,
                .play = play,
                .music = music,
            },
        );
    }

    pub fn init(
        allocator: Allocator,
        sound: *audio.Audio,
        logical_device: *const vk.LogicalDevice,
        physical_device: *const vk.PhysicalDevice,
        command_pool: *const vk.CommandPool,
        data: struct {
            game_over: []const u8,
            eat: []const SoundOptionData,
            tiles: []const u8,
            play: []const u8,
            music: []const u8,
        },
    ) !GameAssetBundle {
        var game_over_sound = try sound.sound(data.game_over);
        errdefer game_over_sound.deinit();

        var music = try sound.sound(data.music);
        errdefer music.deinit();

        var eat_sound_probabilities = std.ArrayList(f32).init(allocator);
        errdefer eat_sound_probabilities.deinit();
        var eat_sounds = std.ArrayList(audio.Sound).init(allocator);
        errdefer eat_sounds.deinit();

        for (data.eat) |s| {
            var eat_sound = try sound.sound(s.data);
            errdefer eat_sound.deinit();

            try eat_sounds.append(eat_sound);
            try eat_sound_probabilities.append(s.probability);
        }

        var tiles = try vk.texture.Texture.init(
            data.tiles,
            logical_device,
            physical_device,
            command_pool,
            .{},
        );
        errdefer tiles.deinit();

        var play = try vk.texture.Texture.init(
            data.play,
            logical_device,
            physical_device,
            command_pool,
            .{},
        );
        errdefer play.deinit();

        return .{
            .game_over_sound = game_over_sound,
            .eat_sounds = try eat_sounds.toOwnedSlice(),
            .eat_sound_probabilities = try eat_sound_probabilities.toOwnedSlice(),
            .tiles_texture = tiles,
            .play_texture = play,
            .music = music,
            .allocator = allocator,
        };
    }

    pub fn deinit(assets: *GameAssetBundle) void {
        assets.allocator.free(assets.eat_sound_probabilities);
        for (assets.eat_sounds) |*s| {
            s.deinit();
        }
        assets.allocator.free(assets.eat_sounds);
        assets.music.deinit();
        assets.game_over_sound.deinit();
        assets.tiles_texture.deinit();
        assets.play_texture.deinit();
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

    var args = std.process.args();
    _ = args.skip();

    var assets = if (args.next()) |assets_path| blk: {
        var assets_dir = try std.fs.cwd().openDir(assets_path, .{});
        defer assets_dir.close();

        break :blk try GameAssetBundle.initFromDir(
            allocator,
            &sound,
            &logical_device,
            &physical_device,
            &command_pool,
            &assets_dir,
        );
    } else try GameAssetBundle.init(
        allocator,
        &sound,
        &logical_device,
        &physical_device,
        &command_pool,
        .{
            .game_over = @embedFile("asset:game-over.mp3"),
            .music = @embedFile("asset:music.mp3"),
            .eat = &[_]GameAssetBundle.SoundOptionData{
                .{ .data = @embedFile("asset:eat-1.mp3"), .probability = 0.75 },
                .{ .data = @embedFile("asset:eat-2.mp3"), .probability = 0.25 },
            },
            .tiles = @embedFile("asset:tiles.png"),
            .play = @embedFile("asset:play.png"),
        },
    );
    defer assets.deinit();

    var map = try std.json.parseFromSlice(
        Map,
        allocator,
        @embedFile("asset:map.json"),
        .{},
    );
    defer map.deinit();

    var rng = std.Random.DefaultPrng.init(0);
    var state = State{
        .map = map.value,
        .rng = rng.random(),
        .assets = &assets,
    };

    var grid_renderer = try GridRenderer.init(
        &logical_device,
        &physical_device,
        &command_pool,
        &window,
        &swap_chain,
        &framebuffers,
        &render_pass,
        &state.game,
        &assets.tiles_texture,
        allocator,
    );
    defer grid_renderer.deinit();

    var image_renderer = try ImageRenderer.init(
        &logical_device,
        &physical_device,
        &command_pool,
        &window,
        &swap_chain,
        &framebuffers,
        &render_pass,
        allocator,
    );
    defer image_renderer.deinit();

    var last_tick = try std.time.Instant.now();
    var last_music_start = last_tick;
    var controls = Controls{ .window = &window };

    try assets.music.start();

    while (vk.c.glfwWindowShouldClose(window.window) == 0) {
        framebuffer_resized = false;
        vk.c.glfwPollEvents();

        var event_buf: [10]Event = undefined;
        for (controls.readEvents(&event_buf)) |event| {
            try state.handleEvent(event);
        }

        const now = try std.time.Instant.now();
        if (now.since(last_tick) >= state.tick_ns) {
            last_tick = now;
            try state.handleEvent(.tick);
        }

        if (now.since(last_music_start) >= state.assets.music.duration_ns()) {
            last_music_start = now;
            try assets.music.start();
        }

        switch (state.state) {
            .no_game, .paused => try image_renderer.render(&assets.play_texture, .{ .framebuffer_resized = &framebuffer_resized }),
            .playing => try grid_renderer.render(&state.game, .{ .framebuffer_resized = &framebuffer_resized }),
        }

        if (framebuffer_resized) {
            grid_renderer.handleResize();
            image_renderer.handleResize();

            _ = vk.c.vkDeviceWaitIdle(logical_device.device);
            framebuffers.deinit();
            swap_chain.deinit();
            swap_chain = try vk.SwapChain.init(
                &window,
                &surface,
                &physical_device,
                &logical_device,
                allocator,
            );
            framebuffers = try vk.Framebuffers.init(
                &render_pass,
                &swap_chain,
                allocator,
            );
        }
    }

    _ = vk.c.vkDeviceWaitIdle(logical_device.device);
}
