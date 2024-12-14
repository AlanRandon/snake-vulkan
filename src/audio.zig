const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("soundio/soundio.h");
});
const mp3 = @import("minimp3");

pub const Audio = struct {
    allocator: Allocator,
    soundio: *c.SoundIo,
    device: *c.SoundIoDevice,

    pub fn init(allocator: Allocator) !Audio {
        const soundio = c.soundio_create() orelse return error.Create;

        if (c.soundio_connect(soundio) != 0) {
            return error.Connect;
        }

        c.soundio_flush_events(soundio);

        const device_index: c_int = c.soundio_default_output_device_index(soundio);
        if (device_index < 0) {
            return error.NoOutputDevice;
        }

        const device = c.soundio_get_output_device(soundio, device_index) orelse return error.OutOfMemory;

        return .{
            .allocator = allocator,
            .device = device,
            .soundio = soundio,
        };
    }

    pub fn wait(audio: *const Audio) void {
        c.soundio_wait_events(audio.soundio);
    }

    pub fn deinit(audio: *Audio) void {
        c.soundio_device_unref(audio.device);
        c.soundio_destroy(audio.soundio);
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

        return .{
            .audio = audio,
            .info = info,
            .num_samples = num_samples,
            .buffer = try output.toOwnedSlice(),
        };
    }
};

pub const Sound = struct {
    audio: *const Audio,
    info: mp3.FrameInfo,
    buffer: []const u8,
    num_samples: usize,

    pub fn duration_ns(sound: *const Sound) u64 {
        const num_samples = @as(u64, sound.num_samples);
        return std.time.ns_per_s * num_samples / @as(u64, sound.info.hz) / @as(u64, sound.info.channels) / 2; // why 2???
    }

    const PlayingSound = struct {
        frames_played: usize = 0,
        sound: *const Sound,
        outstream: *allowzero c.SoundIoOutStream,
    };

    pub fn start(sound: *const Sound) !void {
        const outstream = &c.soundio_outstream_create(sound.audio.device)[0];
        outstream.write_callback = struct {
            fn write_callback(os: [*c]c.SoundIoOutStream, frame_count_min: c_int, frame_count_max: c_int) callconv(.C) void {
                var areas: [*c]c.SoundIoChannelArea = undefined;
                const userdata: ?*align(1) PlayingSound = @ptrCast(os[0].userdata);
                var playing = if (userdata) |playing| playing else return;

                const channel_count: usize = @intCast(os[0].layout.channel_count);

                const bytes_per_sample: usize = @as(usize, @intCast(os[0].bytes_per_sample));
                const bytes_per_frame = bytes_per_sample * channel_count;

                if (playing.frames_played * bytes_per_frame >= playing.sound.buffer.len) {
                    const allocator = playing.sound.audio.allocator;
                    allocator.destroy(playing);
                    os[0].userdata = null;
                    return;
                }

                std.debug.assert(channel_count == playing.sound.info.channels);

                const buf = playing.sound.buffer[playing.frames_played * bytes_per_frame ..];
                const num_frames: c_int = @intCast(@divFloor(buf.len, bytes_per_frame));
                var frames_to_write: c_int = @min(frame_count_max, num_frames);

                if (c.soundio_outstream_begin_write(os, &areas, &frames_to_write) != 0) {
                    return;
                }

                for (0..@intCast(frames_to_write)) |frame| {
                    if (frame > num_frames) {
                        for (0..channel_count) |channel| {
                            @memset(@as([*]u8, areas[channel].ptr)[0..bytes_per_sample], 0);
                            areas[channel].ptr += @intCast(areas[channel].step);
                        }
                    }

                    for (0..channel_count) |channel| {
                        @memcpy(
                            @as([*]u8, areas[channel].ptr)[0..bytes_per_sample],
                            buf[frame * bytes_per_frame + channel * bytes_per_sample ..][0..bytes_per_sample],
                        );
                        areas[channel].ptr += @intCast(areas[channel].step);
                    }

                    playing.frames_played += 1;
                }

                if (c.soundio_outstream_end_write(os) != 0) {
                    return;
                }

                _ = frame_count_min;
            }
        }.write_callback;
        outstream.format = c.SoundIoFormatS16NE;
        outstream.sample_rate = @intCast(sound.info.hz);

        const playing = try sound.audio.allocator.create(PlayingSound);
        errdefer sound.audio.allocator.destroy(playing);
        playing.* = .{
            .sound = sound,
            .outstream = outstream,
        };

        outstream.userdata = playing;

        if (c.soundio_outstream_open(outstream) != 0) {
            return error.OpenOutStream;
        }

        if (outstream.*.layout_error != 0) {
            return error.SetChannelLayout;
        }

        _ = c.soundio_outstream_start(outstream);
    }

    pub fn deinit(sound: *Sound) void {
        sound.audio.allocator.free(sound.buffer);
    }
};
