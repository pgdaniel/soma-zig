const std = @import("std");

pub const SOMA_API = "https://somafm.com/channels.json";

pub const Channel = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    genre: []const u8,
    dj: []const u8,
    listeners: []const u8,
    last_playing: []const u8,
    /// Playlist (.pls) URLs: mp3 format, highest quality.
    urls: [][]const u8,
};

const JsonPlaylist = struct {
    url: []const u8 = "",
    format: []const u8 = "",
    quality: []const u8 = "",
};

const JsonChannel = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    genre: []const u8 = "",
    dj: []const u8 = "",
    listeners: []const u8 = "?",
    lastPlaying: []const u8 = "",
    playlists: []JsonPlaylist = &.{},
};

const JsonResponse = struct {
    channels: []JsonChannel = &.{},
};

/// Fetch the channel list from the SomaFM API. The returned slice and all
/// strings are owned by `arena`.
pub fn fetchChannels(
    arena: std.mem.Allocator,
    client: *std.http.Client,
) ![]Channel {
    var body = std.ArrayList(u8).init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = SOMA_API },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 8 * 1024 * 1024,
        .extra_headers = &.{.{ .name = "User-Agent", .value = "soma-zig/1.0" }},
    });
    if (res.status != .ok) return error.SomaApiError;

    const parsed = try std.json.parseFromSlice(
        JsonResponse,
        arena,
        body.items,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    var channels = std.ArrayList(Channel).init(arena);
    for (parsed.value.channels) |ch| {
        var urls = std.ArrayList([]const u8).init(arena);
        for (ch.playlists) |p| {
            if (std.mem.eql(u8, p.format, "mp3") and
                std.mem.eql(u8, p.quality, "highest"))
            {
                try urls.append(p.url);
            }
        }
        try channels.append(.{
            .id = ch.id,
            .title = ch.title,
            .description = ch.description,
            .genre = ch.genre,
            .dj = ch.dj,
            .listeners = ch.listeners,
            .last_playing = ch.lastPlaying,
            .urls = urls.items,
        });
    }
    return channels.items;
}

/// Fetch a .pls playlist and return the stream URLs it contains
/// (File1..FileN), in order. Owned by `arena`.
pub fn resolvePlaylist(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    pls_url: []const u8,
) ![][]const u8 {
    var body = std.ArrayList(u8).init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = pls_url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 64 * 1024,
        .extra_headers = &.{.{ .name = "User-Agent", .value = "soma-zig/1.0" }},
    });
    if (res.status != .ok) return error.PlaylistError;

    var urls = std.ArrayList([]const u8).init(arena);
    var lines = std.mem.splitScalar(u8, body.items, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "File")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const url = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (url.len > 0) try urls.append(url);
    }
    if (urls.items.len == 0) return error.NoStreamUrls;
    return urls.items;
}

/// One-line channel summary for the list widget (mirrors the JS version).
pub fn formatChannel(buf: []u8, ch: Channel, width: usize) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Listeners, right-aligned in 4 columns.
    const listeners = ch.listeners;
    var pad: usize = if (listeners.len < 4) 4 - listeners.len else 0;
    while (pad > 0) : (pad -= 1) w.writeByte(' ') catch break;
    w.writeAll(listeners) catch return fbs.getWritten();
    w.writeByte(' ') catch return fbs.getWritten();

    // Genre, left-aligned in 15 columns.
    const genre = ch.genre[0..@min(ch.genre.len, 15)];
    w.writeAll(genre) catch return fbs.getWritten();
    var gpad: usize = 15 - genre.len;
    while (gpad > 0) : (gpad -= 1) w.writeByte(' ') catch break;
    w.writeByte(' ') catch return fbs.getWritten();

    // Title (+ DJ), truncated to fit.
    const remaining = if (width > 4 + 15 + 4) width - 4 - 15 - 4 else 0;
    var written: usize = 0;
    for (ch.title) |c| {
        if (written >= remaining) break;
        w.writeByte(c) catch return fbs.getWritten();
        written += 1;
    }
    if (ch.dj.len > 0) {
        const suffix = [_][]const u8{ " [", ch.dj, "]" };
        for (suffix) |part| {
            for (part) |c| {
                if (written >= remaining) break;
                w.writeByte(c) catch return fbs.getWritten();
                written += 1;
            }
        }
    }
    return fbs.getWritten();
}
