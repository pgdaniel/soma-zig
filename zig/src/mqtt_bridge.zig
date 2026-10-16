//! Optional MQTT front end for the player, so a controller (deckd, Home
//! Assistant, mosquitto_pub) can drive soma and show what it's doing without
//! the Unix socket. Started by ipc.Server.start when SOMA_MQTT_HOST is set;
//! otherwise it does nothing.
//!
//! Environment: SOMA_MQTT_HOST (literal IP or "localhost"), SOMA_MQTT_PORT
//! (1883), SOMA_MQTT_USER / SOMA_MQTT_PASS, SOMA_MQTT_TOPIC (prefix, "soma").
//!
//! Commands (subscribed; <p> is the prefix):
//!   <p>/cmd        any socket command line: "play groovesalad", "toggle", "viz next", ...
//!   <p>/vol/set    0-100
//!   <p>/vol/adj    signed step, e.g. -5 / 5  (a dial's turn_topic)
//!   <p>/surf       >0 next channel, <0 previous, and play  (a dial's turn_topic)
//! State (published retained, only when it changes):
//!   <p>/status         "online" / "offline" (last-will)
//!   <p>/state/playing  "on" | "off"   (connecting counts as on)
//!   <p>/state/channel  channel name (the selection, even when stopped)
//!   <p>/state/channel_id  channel id while playing, "" otherwise
//!   <p>/state/track    current track title
//!   <p>/state/volume   0-100
const std = @import("std");
const ipc = @import("ipc.zig");
const mqtt = @import("mqtt.zig");

const Atomic = std.atomic.Value;

const JsonStatus = struct {
    playing: bool = false,
    connecting: bool = false,
    channel: []const u8 = "",
    channel_id: []const u8 = "",
    track: []const u8 = "",
    volume: u8 = 0,
};

const n_fields = 5;
const field_names = [n_fields][]const u8{ "playing", "channel", "channel_id", "track", "volume" };
const field_len = 256;

const Bridge = struct {
    io: std.Io,
    server: *ipc.Server,
    session: mqtt.Session,
    prefix: []const u8,
    t_cmd: []const u8,
    t_vol_set: []const u8,
    t_vol_adj: []const u8,
    t_surf: []const u8,
    t_status: []const u8,
    up: Atomic(bool) = .init(false),
    republish: Atomic(bool) = .init(true),

    fn onMessage(ctx: *anyopaque, topic: []const u8, raw: []const u8) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const payload = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, topic, self.t_cmd)) {
            if (ipc.Server.parseCommand(payload)) |cmd| self.server.enqueue(cmd);
        } else if (std.mem.eql(u8, topic, self.t_vol_set)) {
            const v = std.fmt.parseInt(u8, payload, 10) catch return;
            self.server.enqueue(.{ .vol_set = @min(v, 100) });
        } else if (std.mem.eql(u8, topic, self.t_vol_adj)) {
            const d = std.fmt.parseInt(i32, payload, 10) catch return;
            self.server.enqueue(.{ .vol_adj = d });
        } else if (std.mem.eql(u8, topic, self.t_surf)) {
            const n = std.fmt.parseInt(i32, payload, 10) catch return;
            if (n != 0) self.server.enqueue(.{ .surf = if (n > 0) 1 else -1 });
        }
    }

    fn onState(ctx: *anyopaque, connected: bool) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.up.store(connected, .release);
        if (connected) {
            self.republish.store(true, .release);
            self.session.publish(self.t_status, "online", true) catch {};
        }
    }

    fn stateLoop(self: *Bridge) void {
        var last: [n_fields][field_len]u8 = undefined;
        var last_len: [n_fields]usize = .{std.math.maxInt(usize)} ** n_fields;
        var ticks: u32 = 0;
        while (true) {
            std.Io.sleep(self.io, .fromMilliseconds(500), .awake) catch {};
            ticks +%= 1;
            if (ticks % 40 == 0) self.session.ping(); // every ~20 s; we advertise 60
            if (!self.up.load(.acquire)) continue;
            if (self.republish.swap(false, .acq_rel)) last_len = .{std.math.maxInt(usize)} ** n_fields;

            var snap_buf: [1024]u8 = undefined;
            const snap = self.server.statusSnapshot(&snap_buf);
            if (snap.len == 0) continue;
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const parsed = std.json.parseFromSlice(JsonStatus, fba.allocator(), snap, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch continue;
            const st = parsed.value;
            const on = st.playing or st.connecting;
            var vol_buf: [8]u8 = undefined;
            const vals = [n_fields][]const u8{
                if (on) "on" else "off",
                st.channel,
                if (on) st.channel_id else "",
                st.track,
                std.fmt.bufPrint(&vol_buf, "{d}", .{st.volume}) catch "0",
            };
            for (vals, 0..) |v, i| {
                const n = @min(v.len, field_len);
                if (last_len[i] == n and std.mem.eql(u8, last[i][0..n], v[0..n])) continue;
                var tbuf: [96]u8 = undefined;
                const topic = std.fmt.bufPrint(&tbuf, "{s}/state/{s}", .{ self.prefix, field_names[i] }) catch continue;
                self.session.publish(topic, v[0..n], true) catch continue; // retry next tick
                @memcpy(last[i][0..n], v[0..n]);
                last_len[i] = n;
            }
        }
    }
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    const s = std.mem.sliceTo(p, 0);
    return if (s.len == 0) null else s;
}

/// No-op unless SOMA_MQTT_HOST is set. Leaks on purpose: lives for the process.
pub fn start(server: *ipc.Server, alloc: std.mem.Allocator, io: std.Io) void {
    const host = env("SOMA_MQTT_HOST") orelse return;
    startInner(server, alloc, io, host) catch |err| {
        std.debug.print("soma: mqtt bridge not started: {s}\n", .{@errorName(err)});
    };
}

fn startInner(server: *ipc.Server, alloc: std.mem.Allocator, io: std.Io, host: []const u8) !void {
    const prefix = env("SOMA_MQTT_TOPIC") orelse "soma";
    const b = try alloc.create(Bridge);
    b.* = .{
        .io = io,
        .server = server,
        .prefix = prefix,
        .t_cmd = try std.fmt.allocPrint(alloc, "{s}/cmd", .{prefix}),
        .t_vol_set = try std.fmt.allocPrint(alloc, "{s}/vol/set", .{prefix}),
        .t_vol_adj = try std.fmt.allocPrint(alloc, "{s}/vol/adj", .{prefix}),
        .t_surf = try std.fmt.allocPrint(alloc, "{s}/surf", .{prefix}),
        .t_status = try std.fmt.allocPrint(alloc, "{s}/status", .{prefix}),
        .session = undefined,
    };
    const port: u16 = if (env("SOMA_MQTT_PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 1883 else 1883;
    const subs = try alloc.alloc([]const u8, 4);
    subs[0] = b.t_cmd;
    subs[1] = b.t_vol_set;
    subs[2] = b.t_vol_adj;
    subs[3] = b.t_surf;
    b.session = .{
        .io = io,
        .host = host,
        .port = port,
        .username = env("SOMA_MQTT_USER") orelse "",
        .password = env("SOMA_MQTT_PASS") orelse "",
        .client_id = "soma",
        .will = .{ .topic = b.t_status, .payload = "offline" },
        .subscriptions = subs,
        .ctx = b,
        .on_message = Bridge.onMessage,
        .on_state = Bridge.onState,
    };
    (try std.Thread.spawn(.{}, mqtt.Session.run, .{&b.session})).detach();
    (try std.Thread.spawn(.{}, Bridge.stateLoop, .{b})).detach();
}
