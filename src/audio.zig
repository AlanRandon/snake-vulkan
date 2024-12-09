const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("ao/ao.h");
    @cInclude("mpg123.h");
});

pub const Audio = struct {
    driver: c_int,
    mpg_handle: *c.mpg123_handle,
    buffer: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Audio {
        c.ao_initialize();
        _ = c.mpg123_init();
        const mh = c.mpg123_new(null, null) orelse unreachable;

        return .{
            .driver = c.ao_default_driver_id(),
            .mpg_handle = mh,
            .buffer = try allocator.alloc(u8, c.mpg123_outblock(mh)),
            .allocator = allocator,
        };
    }

    pub fn deinit(audio: *Audio) void {
        audio.allocator.free(audio.buffer);
        _ = c.mpg123_close(audio.mpg_handle);
        c.mpg123_delete(audio.mpg_handle);
        c.mpg123_exit();
        c.ao_shutdown();
    }

    pub fn sound(audio: *Audio, data: []const u8) !Sound {
        var fmt_buf: [8128]u8 = undefined;

        _ = c.mpg123_open_feed(audio.mpg_handle);

        var channels: c_int = undefined;
        var encoding: c_int = undefined;
        var rate: c_long = undefined;

        var size: usize = 0;

        if (c.mpg123_decode(
            audio.mpg_handle,
            data.ptr,
            data.len,
            &fmt_buf,
            fmt_buf.len,
            &size,
        ) == c.MPG123_NEW_FORMAT) {
            _ = c.mpg123_getformat(audio.mpg_handle, &rate, &channels, &encoding);
        }

        var format = c.ao_sample_format{
            .bits = c.mpg123_encsize(encoding) * 8,
            .rate = @intCast(rate),
            .channels = channels,
            .byte_format = c.AO_FMT_NATIVE,
            .matrix = 0,
        };
        const device = c.ao_open_live(audio.driver, &format, null);

        var output = std.ArrayList(u8).init(audio.allocator);

        while (c.mpg123_read(
            audio.mpg_handle,
            audio.buffer.ptr,
            audio.buffer.len,
            &size,
        ) == c.MPG123_OK) {
            try output.appendSlice(audio.buffer[0..size]);
        }

        return .{
            .audio = audio,
            .device = device,
            .buffer = try output.toOwnedSlice(),
        };
    }
};

pub const Sound = struct {
    audio: *Audio,
    device: ?*c.ao_device,
    buffer: []const u8,

    pub fn play(sound: *const Sound) void {
        _ = c.ao_play(sound.device, @constCast(sound.buffer.ptr), @intCast(sound.buffer.len));
    }

    pub fn playInThreadPool(sound: *const Sound, pool: *std.Thread.Pool) !void {
        try pool.spawn(struct {
            pub fn play(snd: *const Sound) void {
                snd.play();
            }
        }.play, .{sound});
    }

    pub fn deinit(sound: *Sound) void {
        _ = c.ao_close(sound.device);
        sound.audio.allocator.free(sound.buffer);
    }
};
