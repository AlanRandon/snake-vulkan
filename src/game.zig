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
};

pub const Cell = struct {
    state: union(enum) {
        empty,
        head: struct {
            facing: Direction,
        },
        tail: struct {
            ttl: usize,
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
        ttl: usize,
        comptime rows: usize = rows,
        comptime cols: usize = cols,

        const Self = @This();

        pub fn init(ttl: usize) Self {
            var rng = std.Random.DefaultPrng.init(0);
            var cells: [size]Cell = undefined;
            for (&cells) |*cell| {
                const bg_index = rng.random().intRangeAtMost(
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
                .ttl = ttl,
            };
        }

        pub fn put_head(game: *Self, col: usize, row: usize) void {
            game.cells[row * cols + col].state = .{
                .head = .{
                    .facing = .east,
                },
            };
        }

        pub fn move(game: *Self, direction: Direction) !void {
            var cells: [size]Cell = undefined;
            var new_head_index: usize = undefined;

            for (&game.cells, 0..) |*cell, i| {
                cells[i].background = cell.background;
                cells[i].state = switch (cell.state) {
                    .head => |*head| blk: {
                        const col = i % cols;
                        const row = i / rows;

                        new_head_index = switch (direction) {
                            .north => (row + rows - 1) % rows,
                            .south => (row + 1) % rows,
                            else => row,
                        } * cols + switch (direction) {
                            .east => (col + 1) % cols,
                            .west => (col + cols - 1) % cols,
                            else => col,
                        };

                        break :blk .{
                            .tail = .{
                                .to = direction,
                                .from = head.facing.opposite(),
                                .ttl = game.ttl,
                            },
                        };
                    },
                    .tail => |*tail| if (tail.ttl <= 1) .empty else blk: {
                        tail.ttl -= 1;
                        break :blk .{ .tail = tail.* };
                    },
                    else => cell.state,
                };
            }

            switch (cells[new_head_index].state) {
                .empty => {
                    cells[new_head_index].state = .{
                        .head = .{
                            .facing = direction,
                        },
                    };
                },
                .tail, .wall, .head => return error.SnakeCollided,
                .apple => std.debug.panic("TODO: apples", .{}),
            }

            game.cells = cells;
        }
    };
}
