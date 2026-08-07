const std = @import("std");
const ring_mod = @import("ring.zig");
const channels = @import("channels.zig");

const c = @cImport({
    @cInclude("miniaudio.h");
});

const ByteRing = ring_mod.Ring(u8);
const PcmRing = ring_mod.Ring(f32);

const SAMPLE_RATE = 44100;
const CHANNELS = 2;
/// ~1 MiB of compressed stream (~60 s at 128 kbps).
const BYTE_RING_CAP = 1 * 1024 * 1024;
/// ~2 s of decoded stereo f32 audio.
const PCM_RING_CAP = SAMPLE_RATE * CHANNELS * 2;

pub const Player = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    byte_ring: ByteRing,
    pcm_ring: PcmRing,

    net_thread: ?std.Thread = null,
    dec_thread: ?std.Thread = null,

    /// Device pointer is owned by the decoder thread; guarded by device_mutex
    /// so the UI thread can retarget volume changes safely.
    device_mutex: std.Io.Mutex = .init,
    device: ?*c.ma_device = null,

    state_mutex: std.Io.Mutex = .init,
    playing: bool = false,
    connecting: bool = false,
    volume: u8 = 80,
    channel_title_buf: [128]u8 = undefined,
    channel_title_len: usize = 0,
    track_buf: [256]u8 = undefined,
    track_len: usize = 0,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    source_url_buf: [512]u8 = undefined,
    source_url_len: usize = 0,

    /// Rewind cache for the decoder. dr_mp3 needs seekable input while it
    /// probes for the first frame during init, so every byte served is
    /// cached and backward seeks within the cache are allowed. Only used
    /// during decoder init (probing); freed immediately after. Decode-thread
    /// local, no locking needed.
    cache: std.ArrayList(u8),
    cache_cursor: usize = 0,
    cache_enabled: bool = true,

    pub const Snapshot = struct {
        playing: bool,
        connecting: bool,
        volume: u8,
        channel_title: []const u8,
        track: []const u8,
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Player {
        const self = try allocator.create(Player);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .byte_ring = try ByteRing.init(allocator, BYTE_RING_CAP, io),
            .pcm_ring = try PcmRing.init(allocator, PCM_RING_CAP, io),
            .cache = .empty,
        };
        self.setMessage("");
        self.setTrack("");
        self.setChannelTitle("");
        return self;
    }

    pub fn deinit(self: *Player) void {
        self.stop();
        self.byte_ring.deinit(self.allocator);
        self.pcm_ring.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Start streaming a channel. `source` may be a .pls playlist URL or a
    /// direct stream URL. Returns immediately; progress is reported via the
    /// shared state (see snapshot()).
    pub fn play(self: *Player, source: []const u8, channel_title: []const u8) !void {
        if (source.len > self.source_url_buf.len) return error.UrlTooLong;

        // Allocate fresh rings first so a failure leaves the old state intact.
        var new_byte_ring = try ByteRing.init(self.allocator, BYTE_RING_CAP, self.io);
        errdefer new_byte_ring.deinit(self.allocator);
        var new_pcm_ring = try PcmRing.init(self.allocator, PCM_RING_CAP, self.io);
        errdefer new_pcm_ring.deinit(self.allocator);

        self.stop();
        self.byte_ring.deinit(self.allocator);
        self.pcm_ring.deinit(self.allocator);
        self.byte_ring = new_byte_ring;
        self.pcm_ring = new_pcm_ring;
        @memcpy(self.source_url_buf[0..source.len], source);
        self.source_url_len = source.len;
        self.setChannelTitle(channel_title);
        self.setTrack("");

        // Fresh rewind cache for the new stream.
        self.cache.clearRetainingCapacity();
        self.cache_cursor = 0;
        self.cache_enabled = true;

        self.state_mutex.lockUncancelable(self.io);
        self.connecting = true;
        self.playing = false;
        self.state_mutex.unlock(self.io);
        self.setMessage("Connecting...");

        self.net_thread = try std.Thread.spawn(.{}, netThreadMain, .{self});
        self.dec_thread = try std.Thread.spawn(.{}, decThreadMain, .{self});
    }

    pub fn stop(self: *Player) void {
        self.byte_ring.abort();
        self.pcm_ring.abort();
        if (self.net_thread) |t| {
            t.join();
            self.net_thread = null;
        }
        if (self.dec_thread) |t| {
            t.join();
            self.dec_thread = null;
        }
        self.state_mutex.lockUncancelable(self.io);
        self.playing = false;
        self.connecting = false;
        self.state_mutex.unlock(self.io);
    }

    pub fn setVolume(self: *Player, vol: u8) void {
        self.state_mutex.lockUncancelable(self.io);
        self.volume = vol;
        self.state_mutex.unlock(self.io);
        const gain: f32 = @as(f32, @floatFromInt(vol)) / 100.0;
        self.device_mutex.lockUncancelable(self.io);
        defer self.device_mutex.unlock(self.io);
        if (self.device) |dev| {
            _ = c.ma_device_set_master_volume(dev, gain);
        }
    }

    pub fn snapshot(
        self: *Player,
        channel_title: *[128]u8,
        track: *[256]u8,
        message: *[256]u8,
    ) Snapshot {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        @memcpy(channel_title[0..self.channel_title_len], self.channel_title_buf[0..self.channel_title_len]);
        @memcpy(track[0..self.track_len], self.track_buf[0..self.track_len]);
        @memcpy(message[0..self.message_len], self.message_buf[0..self.message_len]);
        return .{
            .playing = self.playing,
            .connecting = self.connecting,
            .volume = self.volume,
            .channel_title = channel_title[0..self.channel_title_len],
            .track = track[0..self.track_len],
            .message = message[0..self.message_len],
        };
    }

    fn setChannelTitle(self: *Player, s: []const u8) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const n = @min(s.len, self.channel_title_buf.len);
        @memcpy(self.channel_title_buf[0..n], s[0..n]);
        self.channel_title_len = n;
    }

    fn setTrack(self: *Player, s: []const u8) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const n = @min(s.len, self.track_buf.len);
        @memcpy(self.track_buf[0..n], s[0..n]);
        self.track_len = n;
    }

    fn setMessage(self: *Player, s: []const u8) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const n = @min(s.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], s[0..n]);
        self.message_len = n;
    }

    fn setPlaying(self: *Player, playing: bool, connecting: bool) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.playing = playing;
        self.connecting = connecting;
    }

    // ------------------------------------------------------------------
    // Network thread: resolve playlist, connect, demux ICY metadata,
    // push raw MP3 bytes into byte_ring.
    // ------------------------------------------------------------------
    fn netThreadMain(self: *Player) void {
        defer self.byte_ring.setEof();
        self.netRun() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Stream error: {s}", .{@errorName(err)}) catch "Stream error";
            self.setMessage(msg);
        };
    }

    fn netRun(self: *Player) !void {
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        var client: std.http.Client = .{ .allocator = arena, .io = self.io };
        defer client.deinit();

        const source = self.source_url_buf[0..self.source_url_len];

        // Resolve to direct stream URLs.
        var urls: [][]const u8 = undefined;
        if (std.mem.endsWith(u8, source, ".pls")) {
            urls = try channels.resolvePlaylist(arena, &client, source);
        } else {
            const list = try arena.alloc([]const u8, 1);
            list[0] = source;
            urls = list;
        }

        var last_err: ?anyerror = null;
        for (urls) |url| {
            self.streamOnce(&client, url) catch |err| {
                last_err = err;
                continue; // try the next mirror
            };
            return; // clean EOF
        }
        if (last_err) |err| return err;
        return error.NoStreamUrls;
    }

    fn streamOnce(
        self: *Player,
        client: *std.http.Client,
        url: []const u8,
    ) !void {
        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Icy-MetaData", .value = "1" },
                .{ .name = "User-Agent", .value = "soma-zig/1.0" },
            },
        });
        defer req.deinit();

        try req.sendBodiless();
        var redirect_buf: [8 * 1024]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);

        switch (res.head.status) {
            .ok, .partial_content => {},
            else => return error.StreamHttpError,
        }

        var metaint: usize = 0;
        var it = res.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "icy-metaint")) {
                metaint = std.fmt.parseInt(usize, std.mem.trim(u8, h.value, " "), 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase(h.name, "icy-name")) {
                self.setTrack(h.value);
            }
        }

        self.setMessage("");
        self.setPlaying(true, false);

        // NB: reader() invalidates the header strings, so it is created only
        // after the ICY headers above have been consumed.
        var transfer_buf: [4096]u8 = undefined;
        const reader = res.reader(&transfer_buf);
        var chunk: [16384]u8 = undefined;
        var until_meta: usize = metaint; // bytes of audio left before a metadata block

        while (!self.byte_ring.isAborted()) {
            // Push audio bytes, respecting the metadata interval.
            var want: usize = chunk.len;
            if (metaint > 0) {
                if (until_meta == 0) {
                    try self.readIcyMetadata(reader);
                    until_meta = metaint;
                }
                want = @min(want, until_meta);
            }
            const n = reader.readSliceShort(chunk[0..want]) catch return error.StreamReadError;
            if (n == 0) {
                self.setMessage("Stream ended");
                self.setPlaying(false, false);
                return;
            }
            var off: usize = 0;
            while (off < n) {
                off += self.byte_ring.pushBlocking(chunk[off..n]) catch return;
            }
            if (metaint > 0) until_meta -= n;
        }
    }

    fn readIcyMetadata(self: *Player, reader: anytype) !void {
        var len_byte: [1]u8 = undefined;
        const got = reader.readSliceShort(&len_byte) catch return error.MetadataReadError;
        if (got == 0) return error.MetadataReadError;
        const meta_len: usize = @as(usize, len_byte[0]) * 16;
        if (meta_len == 0) return;
        var meta_buf: [4096]u8 = undefined;
        if (meta_len > meta_buf.len) return error.MetadataTooLarge;
        reader.readSliceAll(meta_buf[0..meta_len]) catch return error.MetadataReadError;
        const meta = std.mem.sliceTo(meta_buf[0..meta_len], 0);

        if (extractIcyValue(meta, "StreamTitle='")) |title| {
            if (title.len > 0) self.setTrack(title);
        }
    }

    fn extractIcyValue(meta: []const u8, key: []const u8) ?[]const u8 {
        const start = std.mem.indexOf(u8, meta, key) orelse return null;
        const rest = meta[start + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '\'') orelse return null;
        return rest[0..end];
    }

    // ------------------------------------------------------------------
    // Decoder thread: pull MP3 bytes from byte_ring via miniaudio's
    // decoder, push PCM into pcm_ring, own the playback device.
    // ------------------------------------------------------------------
    fn decThreadMain(self: *Player) void {
        self.decRun() catch |err| {
            if (err != error.Aborted) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Audio error: {s}", .{@errorName(err)}) catch "Audio error";
                self.setMessage(msg);
                self.setPlaying(false, false);
            }
        };
    }

    fn readProc(dec: ?*c.ma_decoder, out: ?*anyopaque, bytes_to_read: usize, bytes_read: ?*usize) callconv(.c) c.ma_result {
        const self: *Player = @ptrCast(@alignCast(dec.?.pUserData));
        const buf: [*]u8 = @ptrCast(out.?);
        const slice = buf[0..bytes_to_read];

        if (self.cache_enabled) {
            // Serve from the rewind cache when possible.
            if (self.cache_cursor < self.cache.items.len) {
                const avail = self.cache.items.len - self.cache_cursor;
                const n = @min(avail, slice.len);
                @memcpy(slice[0..n], self.cache.items[self.cache_cursor..][0..n]);
                self.cache_cursor += n;
                bytes_read.?.* = n;
                return c.MA_SUCCESS;
            }
            const n = self.byte_ring.popBlocking(slice) catch blk: {
                break :blk 0;
            };
            if (n > 0) {
                self.cache.appendSlice(self.allocator, slice[0..n]) catch {
                    // OOM: stop caching; backward seeks will start failing.
                    self.cache_enabled = false;
                };
                self.cache_cursor += n;
            }
            bytes_read.?.* = n;
            if (n == 0) return c.MA_AT_END;
            return c.MA_SUCCESS;
        }

        const n = self.byte_ring.popBlocking(slice) catch blk: {
            break :blk 0;
        };
        bytes_read.?.* = n;
        if (n == 0) return c.MA_AT_END;
        return c.MA_SUCCESS;
    }

    fn audioCallback(
        device: ?*c.ma_device,
        output: ?*anyopaque,
        input: ?*const anyopaque,
        frame_count: c.ma_uint32,
    ) callconv(.c) void {
        _ = input;
        const self: *Player = @ptrCast(@alignCast(device.?.*.pUserData));
        const total: usize = @as(usize, frame_count) * CHANNELS;
        const out: [*]f32 = @ptrCast(@alignCast(output.?));
        const n = self.pcm_ring.popTry(out[0..total]);
        if (n < total) @memset(out[n..total], 0); // underrun: silence
    }

    fn seekProc(dec: ?*c.ma_decoder, offset: c.ma_int64, origin: c.ma_seek_origin) callconv(.c) c.ma_result {
        const self: *Player = @ptrCast(@alignCast(dec.?.pUserData));
        if (!self.cache_enabled) return c.MA_NOT_IMPLEMENTED;

        var abs: i64 = undefined;
        if (origin == c.ma_seek_origin_start) {
            abs = offset;
        } else if (origin == c.ma_seek_origin_current) {
            abs = @as(i64, @intCast(self.cache_cursor)) + offset;
        } else {
            return c.MA_NOT_IMPLEMENTED; // seek_origin_end: live stream has no end
        }
        if (abs < 0) return c.MA_ERROR;
        const pos: usize = @intCast(abs);
        if (pos > self.cache.items.len) return c.MA_ERROR;
        self.cache_cursor = pos;
        return c.MA_SUCCESS;
    }

    fn decRun(self: *Player) !void {
        var decoder: c.ma_decoder = undefined;
        var decoder_config = c.ma_decoder_config_init(c.ma_format_f32, CHANNELS, SAMPLE_RATE);
        // Skip trial-and-error backend probing (which would consume stream
        // bytes and require a working seek to rewind): we know it's MP3.
        decoder_config.encodingFormat = c.ma_encoding_format_mp3;
        // Pulls (blocking) from byte_ring until it has sniffed a valid format.
        const dec_res = c.ma_decoder_init(readProc, seekProc, self, &decoder_config, &decoder);
        // Probing is done; the rest of the stream is pull-only.
        self.cache_enabled = false;
        self.cache.clearRetainingCapacity();
        self.cache_cursor = 0;
        if (dec_res != c.MA_SUCCESS) return error.DecoderInitFailed;
        defer _ = c.ma_decoder_uninit(&decoder);

        var device: c.ma_device = undefined;
        var device_config = c.ma_device_config_init(c.ma_device_type_playback);
        device_config.playback.format = c.ma_format_f32;
        device_config.playback.channels = CHANNELS;
        device_config.sampleRate = SAMPLE_RATE;
        device_config.dataCallback = audioCallback;
        device_config.pUserData = self;
        if (c.ma_device_init(null, &device_config, &device) != c.MA_SUCCESS)
            return error.DeviceInitFailed;
        defer c.ma_device_uninit(&device);

        {
            self.device_mutex.lockUncancelable(self.io);
            defer self.device_mutex.unlock(self.io);
            self.device = &device;
        }
        defer {
            self.device_mutex.lockUncancelable(self.io);
            self.device = null;
            self.device_mutex.unlock(self.io);
        }

        self.setVolume(self.snapshotVolume());
        if (c.ma_device_start(&device) != c.MA_SUCCESS) return error.DeviceStartFailed;

        var frames_buf: [4096 * CHANNELS]f32 = undefined;
        while (!self.pcm_ring.isAborted()) {
            var frames_read: c.ma_uint64 = 0;
            const res = c.ma_decoder_read_pcm_frames(&decoder, &frames_buf, 4096, &frames_read);
            if (res != c.MA_SUCCESS or frames_read == 0) {
                // At EOF the decoder reports MA_AT_END; anything else while
                // aborted is just teardown noise.
                break;
            }
            const samples = frames_buf[0 .. @as(usize, @intCast(frames_read)) * CHANNELS];
            var off: usize = 0;
            while (off < samples.len) {
                off += self.pcm_ring.pushBlocking(samples[off..]) catch return;
            }
        }
    }

    fn snapshotVolume(self: *Player) u8 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.volume;
    }
};
