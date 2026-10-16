//! Minimal MQTT 3.1.1 client (QoS 0, no TLS) for a LAN broker: one
//! long-lived `Session` that subscribes, keeps alive, reconnects forever and
//! registers a retained last-will. Copied from deckd-zig's mqtt.zig (minus
//! its one-shot publisher) — keep the two in step.
//!
//! Host must be a literal IP (or "localhost") — no DNS.
const std = @import("std");

/// Incoming PUBLISH callback. `topic`/`payload` are only valid for the call.
pub const OnMessage = *const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8) void;
/// Connection up/down notification (called from the session thread).
pub const OnState = *const fn (ctx: *anyopaque, connected: bool) void;

/// Long-lived connection. `run` never returns — spawn it on its own thread.
/// `publish` and `ping` may be called from any other thread; they fail with
/// error.Offline while disconnected (callers surface that, never block).
pub const Session = struct {
    io: std.Io,
    host: []const u8,
    port: u16 = 1883,
    username: []const u8 = "",
    password: []const u8 = "",
    client_id: []const u8 = "deckd",
    will: ?Will = null,
    /// Exact topics to subscribe to on every (re)connect.
    subscriptions: []const []const u8 = &.{},
    ctx: *anyopaque,
    on_message: OnMessage,
    on_state: OnState,

    mtx: std.Io.Mutex = .init,
    connected: bool = false,
    stream: std.Io.net.Stream = undefined,
    wbuf: [1536]u8 = undefined,
    writer: std.Io.net.Stream.Writer = undefined,

    pub fn run(self: *Session) void {
        while (true) {
            self.connectAndRead() catch |err| {
                if (err != error.Offline) std.debug.print("mqtt: session ended: {s}\n", .{@errorName(err)});
            };
            self.markDown();
            std.Io.sleep(self.io, .fromMilliseconds(2000), .awake) catch {};
        }
    }

    fn markDown(self: *Session) void {
        self.mtx.lockUncancelable(self.io);
        const was = self.connected;
        self.connected = false;
        self.mtx.unlock(self.io);
        if (was) self.on_state(self.ctx, false);
    }

    fn connectAndRead(self: *Session) !void {
        if (self.host.len == 0) return error.NotConfigured;
        const ip_txt = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
        const addr = std.Io.net.IpAddress.parse(ip_txt, self.port) catch return error.BadHost;
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch return error.Offline;
        defer stream.close(self.io);

        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        const r = &reader.interface;

        // Handshake on a scratch writer; the shared one only goes live once
        // CONNACK is in, so no other thread can write before then.
        var hbuf: [512]u8 = undefined;
        var hw = stream.writer(self.io, &hbuf);
        var pkt: [512]u8 = undefined;
        try hw.interface.writeAll(try buildConnect(&pkt, self.client_id, self.username, self.password, self.will));
        try hw.interface.flush();
        var connack: [4]u8 = undefined;
        try r.readSliceAll(&connack);
        if (connack[0] != 0x20 or connack[3] != 0) return error.Refused;

        self.mtx.lockUncancelable(self.io);
        self.stream = stream;
        self.writer = stream.writer(self.io, &self.wbuf);
        self.connected = true;
        const sub_result = self.subscribeAllLocked();
        self.mtx.unlock(self.io);
        sub_result catch |err| return err;
        std.debug.print("mqtt: connected to {s}:{d} ({d} subscriptions)\n", .{ self.host, self.port, self.subscriptions.len });
        self.on_state(self.ctx, true);

        var body: [4096]u8 = undefined;
        while (true) {
            const b0 = try r.takeByte();
            var remaining: usize = 0;
            var shift: u5 = 0;
            while (true) {
                const b = try r.takeByte();
                remaining |= @as(usize, b & 0x7f) << shift;
                if (b & 0x80 == 0) break;
                shift += 7;
                if (shift > 21) return error.MalformedPacket;
            }
            if (remaining > body.len) { // too big to care about: skip it
                try r.discardAll(remaining);
                continue;
            }
            try r.readSliceAll(body[0..remaining]);
            if (b0 & 0xf0 == 0x30) self.handlePublish(b0, body[0..remaining]);
            // SUBACK / PINGRESP / anything else: nothing to do at QoS 0.
        }
    }

    fn handlePublish(self: *Session, b0: u8, b: []const u8) void {
        if (b.len < 2) return;
        const tlen = std.mem.readInt(u16, b[0..2], .big);
        var off: usize = 2 + @as(usize, tlen);
        if (off > b.len) return;
        const topic = b[2..off];
        const qos = (b0 >> 1) & 3;
        if (qos > 0) { // we only ask for QoS 0, but be polite if a broker disagrees
            if (off + 2 > b.len) return;
            const id = b[off .. off + 2];
            off += 2;
            if (qos == 1) self.send(&.{ 0x40, 0x02, id[0], id[1] }) catch {};
        }
        self.on_message(self.ctx, topic, b[off..]);
    }

    fn subscribeAllLocked(self: *Session) !void {
        for (self.subscriptions, 1..) |topic, id| {
            const w = &self.writer.interface;
            try w.writeByte(0x82);
            try writeVarint(w, 2 + 2 + topic.len + 1);
            try w.writeInt(u16, @intCast(id), .big);
            try writeStr(w, topic);
            try w.writeByte(0); // requested QoS 0
        }
        try self.writer.interface.flush();
    }

    /// Write raw bytes under the lock; a failed write drops the connection
    /// (shutdown unblocks the reader, which then triggers the reconnect).
    fn send(self: *Session, bytes: []const u8) !void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (!self.connected) return error.Offline;
        self.writer.interface.writeAll(bytes) catch return self.failLocked();
        self.writer.interface.flush() catch return self.failLocked();
    }

    fn failLocked(self: *Session) error{Offline} {
        self.connected = false;
        self.stream.shutdown(self.io, .both) catch {};
        return error.Offline;
    }

    pub fn publish(self: *Session, topic: []const u8, payload: []const u8, retain: bool) !void {
        var pkt: [1024]u8 = undefined;
        try self.send(try buildPublish(&pkt, topic, payload, retain));
    }

    /// Keepalive; call at least every ~30 s (we advertise 60).
    pub fn ping(self: *Session) void {
        self.send(&.{ 0xC0, 0x00 }) catch {};
    }
};

fn writeVarint(w: *std.Io.Writer, x: usize) !void {
    var v = x;
    while (true) {
        var b: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try w.writeByte(b);
        if (v == 0) break;
    }
}

fn writeStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeInt(u16, @intCast(s.len), .big);
    try w.writeAll(s);
}

/// Retained QoS 0 last-will: the broker publishes it if we drop off.
pub const Will = struct {
    topic: []const u8,
    payload: []const u8,
};

fn buildConnect(buf: []u8, client_id: []const u8, username: []const u8, password: []const u8, will: ?Will) error{PacketTooLarge}![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    const w = &fbs;
    buildConnectInner(w, client_id, username, password, will) catch return error.PacketTooLarge;
    return fbs.buffered();
}

fn buildConnectInner(w: *std.Io.Writer, client_id: []const u8, username: []const u8, password: []const u8, will: ?Will) !void {
    var flags: u8 = 0x02; // clean session
    if (will != null) flags |= 0x04 | 0x20; // will flag + will retain
    if (username.len > 0) flags |= 0x80;
    if (password.len > 0) flags |= 0x40;
    var remaining: usize = 10 + 2 + client_id.len;
    if (will) |wl| remaining += 2 + wl.topic.len + 2 + wl.payload.len;
    if (username.len > 0) remaining += 2 + username.len;
    if (password.len > 0) remaining += 2 + password.len;

    try w.writeByte(0x10);
    try writeVarint(w, remaining);
    try writeStr(w, "MQTT");
    try w.writeByte(4); // protocol level 3.1.1
    try w.writeByte(flags);
    try w.writeInt(u16, 60, .big); // keepalive — irrelevant for one-shot publishes
    try writeStr(w, client_id);
    if (will) |wl| {
        try writeStr(w, wl.topic);
        try writeStr(w, wl.payload);
    }
    if (username.len > 0) try writeStr(w, username);
    if (password.len > 0) try writeStr(w, password);
}

fn buildPublish(buf: []u8, topic: []const u8, payload: []const u8, retain: bool) error{PacketTooLarge}![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    const w = &fbs;
    buildPublishInner(w, topic, payload, retain) catch return error.PacketTooLarge;
    return fbs.buffered();
}

fn buildPublishInner(w: *std.Io.Writer, topic: []const u8, payload: []const u8, retain: bool) !void {
    try w.writeByte(if (retain) 0x31 else 0x30); // PUBLISH, QoS 0
    try writeVarint(w, 2 + topic.len + payload.len);
    try writeStr(w, topic);
    try w.writeAll(payload);
}

test "writeVarint" {
    var buf: [8]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeVarint(&fbs, 0);
    try writeVarint(&fbs, 127);
    try writeVarint(&fbs, 128);
    try writeVarint(&fbs, 321);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7f, 0x80, 0x01, 0xc1, 0x02 }, fbs.buffered());
}

test "buildConnect without auth" {
    var buf: [128]u8 = undefined;
    const pkt = try buildConnect(&buf, "deckd", "", "", null);
    try std.testing.expectEqualSlices(u8, &.{
        0x10, 17, // remaining length
        0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x02, 0x00, 0x3c,
        0x00, 0x05, 'd', 'e', 'c', 'k', 'd',
    }, pkt);
}

test "buildConnect with user/pass sets flags and appends them" {
    var buf: [128]u8 = undefined;
    const pkt = try buildConnect(&buf, "deckd", "u", "p", null);
    try std.testing.expectEqual(@as(u8, 0x10), pkt[0]);
    try std.testing.expectEqual(@as(u8, 23), pkt[1]); // 17 + 2+1 + 2+1
    try std.testing.expectEqual(@as(u8, 0xC2), pkt[9]); // clean | user | pass
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 'u', 0x00, 0x01, 'p' }, pkt[pkt.len - 6 ..]);
}

test "buildPublish" {
    var buf: [128]u8 = undefined;
    const pkt = try buildPublish(&buf, "a/b", "ON", false);
    try std.testing.expectEqualSlices(u8, &.{
        0x30, 0x07, 0x00, 0x03, 'a', '/', 'b', 'O', 'N',
    }, pkt);
}

test "buildConnect with will sets flags and appends topic/payload" {
    var buf: [128]u8 = undefined;
    const pkt = try buildConnect(&buf, "d", "", "", .{ .topic = "t", .payload = "off" });
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 't', 0x00, 0x03, 'o', 'f', 'f' }, pkt[pkt.len - 8 ..]);
    try std.testing.expectEqual(@as(u8, 0x26), pkt[9]); // clean | will | will-retain
}

test "buildPublish retain bit" {
    var buf: [128]u8 = undefined;
    const pkt = try buildPublish(&buf, "a", "1", true);
    try std.testing.expectEqual(@as(u8, 0x31), pkt[0]);
}

test "Session compiles" {
    _ = &Session.run;
    _ = &Session.publish;
    _ = &Session.ping;
}
