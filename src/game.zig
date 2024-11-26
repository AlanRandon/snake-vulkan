const std = @import("std");

pub const Direction = enum {
    north,
    south,
    east,
    west,
};

pub const CellTextureOffset = enum(u8) {
    background_1 = 0,
    background_2 = 1,
    background_3 = 2,
};

pub const Cell = struct {
    state: union(enum) {
        empty,
        head: struct {
            direction: Direction,
        },
        tail: struct {
            from: ?Direction,
            to: Direction,
        },
        apple,
        wall,
    },
    background: CellTextureOffset,
};

pub fn Grid(comptime rows: usize, comptime cols: usize) type {
    const size = rows * cols;
    return struct {
        cells: [size]Cell,

        const Self = @This();

        pub fn init() Self {
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
            };
        }
    };
}
