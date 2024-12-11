const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("ao/ao.h");
});
const mp3 = @import("minimp3");

pub const Audio = struct {
    driver: c_int,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Audio {
        c.ao_initialize();

        return .{
            .driver = c.ao_default_driver_id(),
            .allocator = allocator,
        };
    }

    pub fn deinit(audio: *Audio) void {
        _ = audio;
        c.ao_shutdown();
    }

    pub fn sound(audio: *const Audio, data: []const u8) !Sound {
        var output = std.ArrayList(u8).init(audio.allocator);

        var decoder: mp3.Decoder = undefined;
        decoder.init();

        var i: usize = 0;
        var num_samples: usize = 0;
        var info: mp3.FrameInfo = undefined;
        while (i < data.len) {
            const frame = decoder.decode(data[i..]);
            if (frame.output) |buffer| {
                num_samples += try output.writer().write(buffer.bytes);
            }
            i += frame.info.frame_bytes;
            info = frame.info;
        }

        var format = c.ao_sample_format{
            .bits = @as(c_int, info.channels) * 8,
            .rate = @intCast(info.hz),
            .channels = info.channels,
            .byte_format = c.AO_FMT_NATIVE,
            .matrix = 0,
        };
        const device = c.ao_open_live(audio.driver, &format, null);

        return .{
            .audio = audio,
            .device = device,
            .buffer = try output.toOwnedSlice(),
        };
    }
};

pub const Sound = struct {
    audio: *const Audio,
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
