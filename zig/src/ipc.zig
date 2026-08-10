//! Unix-socket control interface. A listener thread accepts line-based
//! commands and queues them for the UI thread to apply; state queries are
//! served from a status snapshot the UI thread publishes each frame.
//!
//! Socket path: $XDG_RUNTIME_DIR/soma.sock, else /tmp/soma-<uid>.sock.
//!
//! Commands (one per line, replies are one line):
//!   status            → JSON snapshot: {"playing","connecting","channel","track","volume"}
//!   vol <0-100>       → set volume        vol +N / vol -N → adjust
//!   mute              → toggle mute
//!   play [channel-id] → play selection / named channel
//!   stop              → stop playback
//!   toggle            → play selection if stopped, stop if playing
//!   next / prev       → move channel selection
//!   surf-next / surf-prev → move selection and play
//!   viz next          → cycle visualizer pattern
//! Anything else gets "err unknown command".
const std = @import("std");

pub const Command = union(enum) {
    vol_set: u8,
    vol_adj: i32,
    mute_toggle,
    play_selected,
    play_id: PlayId,
    stop,
    toggle,
    move: i32,
    surf: i32,
    viz_next,

    pub const PlayId = struct { buf: [64]u8, len: usize };
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    mtx: std.Io.Mutex = .init,
    io: std.Io = undefined,
    queue: std.ArrayList(Command) = .empty,
    status_buf: [768]u8 = undefined,
    status_len: usize = 0,
    path_buf: [108]u8 = undefined,
    path_len: usize = 0,

    pub fn socketPath(self: *Server) []const u8 {
        if (self.path_len > 0) return self.path_buf[0..self.path_len];
        var path: []const u8 = "/tmp/soma.sock";
        if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
            const d = std.mem.sliceTo(dir, 0);
            const n = std.fmt.bufPrint(&self.path_buf, "{s}/soma.sock", .{d}) catch "";
            if (n.len > 0) {
                self.path_len = n.len;
                return n;
            }
        } else {
            const uid = std.os.linux.getuid();
            const n = std.fmt.bufPrint(&self.path_buf, "/tmp/soma-{d}.sock", .{uid}) catch path;
            path = n;
        }
        self.path_len = path.len;
        return path;
    }

    /// Start the listener thread. Another live instance already bound to the
    /// socket makes this a no-op (returns error.AlreadyRunning).
    pub fn start(self: *Server, alloc: std.mem.Allocator, io: std.Io) !void {
        self.alloc = alloc;
        self.io = io;
        const path = self.socketPath();

        // If a live instance answers a connect, don't steal its socket.
        if (UnixAddressInit(path)) |addr| {
            if (std.Io.net.UnixAddress.connect(&addr, io)) |stream| {
                stream.close(io);
                return error.AlreadyRunning;
            } else |_| {}
        }

        // Remove any stale socket file, then bind.
        var path_z: [108]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        _ = std.os.linux.unlink(@ptrCast(path_z[0..path.len :0].ptr));

        const thread = try std.Thread.spawn(.{}, loop, .{ self, io, path });
        thread.detach();
    }

    /// UI thread: swap the pending-command queue into `out` (must be empty).
    pub fn drain(self: *Server, out: *std.ArrayList(Command)) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        std.mem.swap(std.ArrayList(Command), &self.queue, out);
    }

    /// UI thread: publish the latest status snapshot (JSON, one line).
    pub fn publishStatus(self: *Server, json: []const u8) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        const n = @min(json.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], json[0..n]);
        self.status_len = n;
    }

    fn loop(self: *Server, io: std.Io, path: []const u8) void {
        const addr = std.Io.net.UnixAddress.init(path) catch return;
        var server = addr.listen(io, .{}) catch return;
        defer server.deinit(io);
        while (true) {
            const stream = server.accept(io) catch continue;
            self.serve(io, stream);
        }
    }

    fn serve(self: *Server, io: std.Io, stream: std.Io.net.Stream) void {
        defer stream.close(io);
        var rbuf: [1024]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        const line = reader.interface.takeDelimiter('\n') catch null orelse return;
        const cmd_line = std.mem.trim(u8, line, " \t\r");

        var wbuf: [1024]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        const w = &writer.interface;

        if (std.mem.eql(u8, cmd_line, "status")) {
            self.mtx.lockUncancelable(self.io);
            const snap = self.status_buf[0..self.status_len];
            w.writeAll(snap) catch {};
            self.mtx.unlock(self.io);
            w.writeAll("\n") catch {};
            w.flush() catch {};
            return;
        }

        const cmd = parseCommand(cmd_line) orelse {
            w.writeAll("err unknown command\n") catch {};
            w.flush() catch {};
            return;
        };
        {
            self.mtx.lockUncancelable(self.io);
            defer self.mtx.unlock(self.io);
            self.queue.append(self.alloc, cmd) catch {};
        }
        w.writeAll("ok\n") catch {};
        w.flush() catch {};
    }

    fn parseCommand(line: []const u8) ?Command {
        if (std.mem.eql(u8, line, "mute")) return .mute_toggle;
        if (std.mem.eql(u8, line, "play")) return .play_selected;
        if (std.mem.eql(u8, line, "stop")) return .stop;
        if (std.mem.eql(u8, line, "toggle")) return .toggle;
        if (std.mem.eql(u8, line, "next")) return .{ .move = 1 };
        if (std.mem.eql(u8, line, "prev")) return .{ .move = -1 };
        if (std.mem.eql(u8, line, "surf-next")) return .{ .surf = 1 };
        if (std.mem.eql(u8, line, "surf-prev")) return .{ .surf = -1 };
        if (std.mem.eql(u8, line, "viz next")) return .viz_next;
        if (std.mem.startsWith(u8, line, "play ")) {
            const id = std.mem.trim(u8, line[5..], " \t");
            if (id.len == 0 or id.len > 64) return null;
            var pid: Command.PlayId = undefined;
            @memcpy(pid.buf[0..id.len], id);
            pid.len = id.len;
            return .{ .play_id = pid };
        }
        if (std.mem.startsWith(u8, line, "vol ")) {
            const arg = std.mem.trim(u8, line[4..], " \t");
            if (arg.len == 0) return null;
            if (arg[0] == '+' or arg[0] == '-') {
                const d = std.fmt.parseInt(i32, arg, 10) catch return null;
                return .{ .vol_adj = d };
            }
            const v = std.fmt.parseInt(u8, arg, 10) catch return null;
            return .{ .vol_set = @min(v, 100) };
        }
        return null;
    }
};

fn UnixAddressInit(path: []const u8) ?std.Io.net.UnixAddress {
    return std.Io.net.UnixAddress.init(path) catch null;
}

test "parseCommand" {
    try std.testing.expectEqual(Command{ .vol_set = 42 }, Server.parseCommand("vol 42").?);
    try std.testing.expectEqual(Command{ .vol_adj = -5 }, Server.parseCommand("vol -5").?);
    try std.testing.expectEqual(Command{ .surf = 1 }, Server.parseCommand("surf-next").?);
    try std.testing.expectEqual(Command.toggle, Server.parseCommand("toggle").?);
    const pid = Server.parseCommand("play groovesalad").?;
    try std.testing.expectEqualStrings("groovesalad", pid.play_id.buf[0..pid.play_id.len]);
    try std.testing.expect(Server.parseCommand("bogus") == null);
}
