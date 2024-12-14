const std = @import("std");

pub const Direction = enum(u8) {
    north = 0,
    south = 1,
    east = 2,
    west = 3,

    pub fn opposite(direction: *const Direction) Direction {
        return switch (direction.*) {
            .north => .south,
            .south => .north,
            .east => .west,
            .west => .east,
        };
    }
};

pub const CellTextureOffset = enum(u8) {
    background_1 = 0,
    background_2 = 1,
    background_3 = 2,
    tail_end = 3,
    tail = 4,
    head = 5,
    tail_corner = 6,
    apple = 7,
    wall = 8,
};

pub const Cell = struct {
    state: union(enum) {
        empty,
        head: struct {
            facing: Direction,
        },
        tail: struct {
            ticks_alive: usize,
            from: Direction,
            to: Direction,
        },
        apple,
        wall,
    },
    background: CellTextureOffset,
};

pub fn Game(comptime rows: usize, comptime cols: usize) type {
    const size = rows * cols;
    return struct {
        cells: [size]Cell,
        max_ticks_alive: usize,
        tail_length: usize = 0,
        score: usize = 0,
        rng: std.Random,
        comptime rows: usize = rows,
        comptime cols: usize = cols,

        const Self = @This();

        pub fn init(max_ticks_alive: usize, rng: std.Random) Self {
            var cells: [size]Cell = undefined;
            for (&cells) |*cell| {
                const bg_index = rng.intRangeAtMost(
                    u8,
                    @intFromEnum(CellTextureOffset.background_1),
                    @intFromEnum(CellTextureOffset.background_3),
                );

                cell.* = .{
                    .state = .empty,
                    .background = @enumFromInt(bg_index),
                };
            }

            return .{
                .cells = cells,
                .max_ticks_alive = max_ticks_alive,
                .rng = rng,
            };
        }

        pub fn put_head(game: *Self, col: usize, row: usize) void {
            game.cells[row * cols + col].state = .{
                .head = .{
                    .facing = .east,
                },
            };
        }

        pub fn put_wall(game: *Self, col: usize, row: usize) void {
            game.cells[row * cols + col].state = .wall;
        }

        pub fn spawn_apple(game: *Self) void {
            // TODO: handle grid full
            while (true) {
                const index = game.rng.intRangeLessThan(usize, 0, size);
                const cell = &game.cells[index];
                if (cell.state == .empty) {
                    cell.state = .apple;
                    return;
                }
            }
        }

        const MoveResult = enum {
            move,
            game_over,
            eat,
        };

        pub fn move(game: *Self, direction: Direction) MoveResult {
            var cells: [size]Cell = undefined;
            var head_index: usize = undefined;

            for (&game.cells, 0..) |*cell, i| {
                cells[i].background = cell.background;
                cells[i].state = switch (cell.state) {
                    .head => |*head| blk: {
                        head_index = i;

                        break :blk .{
                            .tail = .{
                                .to = direction,
                                .from = head.facing.opposite(),
                                .ticks_alive = 1,
                            },
                        };
                    },
                    .tail => |tail| if (tail.ticks_alive >= game.max_ticks_alive) .empty else blk: {
                        var t = tail;
                        t.ticks_alive += 1;
                        break :blk .{ .tail = t };
                    },
                    else => cell.state,
                };
            }

            const col = head_index % cols;
            const row = head_index / rows;
            const new_head_index = switch (direction) {
                .north => (row + rows - 1) % rows,
                .south => (row + 1) % rows,
                else => row,
            } * cols + switch (direction) {
                .east => (col + 1) % cols,
                .west => (col + cols - 1) % cols,
                else => col,
            };

            game.tail_length = @min(game.max_ticks_alive, game.tail_length + 1);

            switch (cells[new_head_index].state) {
                .empty => {
                    cells[new_head_index].state = .{
                        .head = .{
                            .facing = direction,
                        },
                    };

                    game.cells = cells;
                    return .move;
                },
                .tail, .wall, .head => {
                    game.tail_length = 0;

                    for (game.cells) |cell| {
                        switch (cell.state) {
                            .tail => game.tail_length += 1,
                            else => {},
                        }
                    }

                    return .game_over;
                },
                .apple => {
                    cells[new_head_index].state = .{
                        .head = .{
                            .facing = direction,
                        },
                    };

                    game.tail_length = game.max_ticks_alive;
                    game.score += 1;
                    game.max_ticks_alive += 1;
                    game.cells = cells;
                    game.spawn_apple();
                    return .eat;
                },
            }
        }
    };
}
