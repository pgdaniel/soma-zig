const std = @import("std");

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    gray,

    fn fgCode(self: Color) u8 {
        return switch (self) {
            .black => 30,
            .red => 31,
            .green => 32,
            .yellow => 33,
            .blue => 34,
            .magenta => 35,
            .cyan => 36,
            .white => 37,
            .gray => 90,
        };
    }
};

pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    space,
    ctrl_c,
    escape,
    char: u8,
};

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// Globals so the signal handler can restore the terminal.
var g_orig_termios: ?std.posix.termios = null;
var g_stdin_fd: std.posix.fd_t = 0;
var g_stdout_fd: std.posix.fd_t = 1;

/// write(2) via the raw syscall; loops over short writes and EINTR.
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.os.linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn restoreAndExit(_: std.posix.SIG) callconv(.c) void {
    if (g_orig_termios) |t| {
        std.posix.tcsetattr(g_stdin_fd, .NOW, t) catch {};
    }
    writeAll(g_stdout_fd, "\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
    std.process.exit(0);
}

/// Minimal raw-mode terminal: alternate screen, absolute cursor addressing,
/// ANSI colors, non-blocking key input.
pub const Term = struct {
    allocator: std.mem.Allocator,
    stdin_fd: std.posix.fd_t,
    stdout_fd: std.posix.fd_t,
    orig: std.posix.termios,
    buf: std.ArrayList(u8),
    // Pending input bytes not yet consumed as keys.
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Term {
        const stdin_fd: std.posix.fd_t = 0;
        const stdout_fd: std.posix.fd_t = 1;
        const orig = try std.posix.tcgetattr(stdin_fd);

        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin_fd, .NOW, raw);

        g_orig_termios = orig;
        g_stdin_fd = stdin_fd;
        g_stdout_fd = stdout_fd;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = restoreAndExit },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &act, null);
        std.posix.sigaction(.HUP, &act, null);

        try writeAll(stdout_fd, "\x1b[?1049h\x1b[?25l\x1b[2J");
        return .{
            .allocator = allocator,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .orig = orig,
            .buf = .empty,
        };
    }

    pub fn deinit(self: *Term) void {
        std.posix.tcsetattr(self.stdin_fd, .NOW, self.orig) catch {};
        writeAll(self.stdout_fd, "\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        g_orig_termios = null;
        self.buf.deinit(self.allocator);
    }

    pub fn size(self: *Term) struct { rows: u16, cols: u16 } {
        var w: Winsize = undefined;
        const rc = std.os.linux.ioctl(self.stdout_fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&w));
        if (std.os.linux.errno(rc) != .SUCCESS or w.ws_row == 0 or w.ws_col == 0) {
            return .{ .rows = 24, .cols = 80 };
        }
        return .{ .rows = w.ws_row, .cols = w.ws_col };
    }

    pub fn begin(self: *Term) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.allocator, "\x1b[H") catch {};
    }

    pub fn flush(self: *Term) !void {
        // write(2) may return short on a full pty buffer; loop until done.
        try writeAll(self.stdout_fd, self.buf.items);
    }

    pub fn moveTo(self: *Term, row: usize, col: usize) void {
        self.buf.print(self.allocator, "\x1b[{d};{d}H", .{ row, col }) catch {};
    }

    pub fn fg(self: *Term, color: Color, bold: bool) void {
        if (bold) {
            self.buf.print(self.allocator, "\x1b[1;{d}m", .{color.fgCode()}) catch {};
        } else {
            self.buf.print(self.allocator, "\x1b[{d}m", .{color.fgCode()}) catch {};
        }
    }

    pub fn bg(self: *Term, color: Color) void {
        self.buf.print(self.allocator, "\x1b[{d}m", .{color.fgCode() + 10}) catch {};
    }

    pub fn reset(self: *Term) void {
        self.buf.appendSlice(self.allocator, "\x1b[0m") catch {};
    }

    pub fn text(self: *Term, s: []const u8) void {
        self.buf.appendSlice(self.allocator, s) catch {};
    }

    /// Write at most `max_cols` columns without splitting a UTF-8 codepoint.
    pub fn textTrunc(self: *Term, s: []const u8, max_cols: usize) void {
        var cols: usize = 0;
        var i: usize = 0;
        while (i < s.len and cols < max_cols) {
            const b = s[i];
            // Start of a new codepoint unless this is a continuation byte.
            if ((b & 0xC0) != 0x80) {
                cols += 1;
                if (cols > max_cols) break;
            }
            i += 1;
        }
        self.buf.appendSlice(self.allocator, s[0..i]) catch {};
    }

    /// Draw a unicode line box with an optional label in the top border.
    pub fn box(
        self: *Term,
        row: usize,
        col: usize,
        w: usize,
        h: usize,
        label: []const u8,
        border: Color,
    ) void {
        if (w < 3 or h < 2) return;
        // Top border with label.
        self.moveTo(row, col);
        self.fg(border, false);
        self.text("┌─");
        self.fg(.white, true);
        self.textTrunc(label, w -| 4);
        self.fg(border, false);
        const label_cols = @min(label.len, w -| 4);
        var i: usize = 2 + label_cols;
        while (i < w - 1) : (i += 1) self.text("─");
        self.text("┐");
        // Sides.
        var r: usize = 1;
        while (r < h - 1) : (r += 1) {
            self.moveTo(row + r, col);
            self.text("│");
            self.moveTo(row + r, col + w - 1);
            self.text("│");
        }
        // Bottom.
        self.moveTo(row + h - 1, col);
        self.text("└");
        i = 2;
        while (i < w) : (i += 1) self.text("─");
        self.text("┘");
        self.reset();
    }

    /// Clear the interior of a region (rows are 1-based, inclusive range).
    pub fn clearRegion(self: *Term, row: usize, col: usize, w: usize, h: usize) void {
        var r: usize = 0;
        while (r < h) : (r += 1) {
            self.moveTo(row + r, col);
            var i: usize = 0;
            while (i < w) : (i += 1) self.text(" ");
        }
    }

    /// Poll for a key press, waiting up to `timeout_ms`. Returns null on
    /// timeout with no input.
    pub fn pollKey(self: *Term, timeout_ms: i32) ?Key {
        if (self.pending_len == 0) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const n = std.posix.poll(&fds, timeout_ms) catch return null;
            if (n == 0) return null;
            const got = std.posix.read(self.stdin_fd, &self.pending) catch return null;
            if (got == 0) return null;
            self.pending_len = got;
        }
        return self.takeKey();
    }

    fn takeKey(self: *Term) ?Key {
        if (self.pending_len == 0) return null;
        const b = self.pending[0];
        var consumed: usize = 1;
        var key: Key = undefined;

        switch (b) {
            0x03 => key = .ctrl_c,
            '\r', '\n' => key = .enter,
            ' ' => key = .space,
            0x1b => {
                if (self.pending_len >= 3 and self.pending[1] == '[') {
                    consumed = 3;
                    key = switch (self.pending[2]) {
                        'A' => .up,
                        'B' => .down,
                        'C' => .right,
                        'D' => .left,
                        else => .escape,
                    };
                } else {
                    key = .escape;
                }
            },
            else => key = .{ .char = b },
        }

        std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - consumed], self.pending[consumed..self.pending_len]);
        self.pending_len -= consumed;
        return key;
    }
};
