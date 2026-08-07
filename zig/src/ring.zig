const std = @import("std");

/// Blocking single-producer/single-consumer ring buffer with EOF and abort
/// semantics. Used for the compressed audio byte stream (network -> decoder)
/// and the decoded PCM sample stream (decoder -> audio callback).
pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        read_pos: usize = 0,
        write_pos: usize = 0,
        len: usize = 0,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},
        eof: bool = false,
        aborted: bool = false,

        pub const Error = error{Aborted};

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{ .buf = try allocator.alloc(T, capacity) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }

        /// Push as many items as fit right now; blocks until at least one
        /// item could be written (or abort). Returns count written.
        pub fn pushBlocking(self: *Self, items: []const T) Error!usize {
            if (items.len == 0) return 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == self.buf.len and !self.aborted) {
                self.not_full.wait(&self.mutex);
            }
            if (self.aborted) return error.Aborted;
            const n = @min(items.len, self.buf.len - self.len);
            self.writeLocked(items[0..n]);
            self.not_empty.signal();
            return n;
        }

        /// Pop up to `out.len` items; blocks until at least one item is
        /// available, EOF is reached, or abort is signaled. Returns the
        /// number of items read (0 only on EOF/abort with empty buffer).
        pub fn popBlocking(self: *Self, out: []T) Error!usize {
            if (out.len == 0) return 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0 and !self.eof and !self.aborted) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.len == 0) {
                if (self.aborted) return error.Aborted;
                return 0; // clean EOF
            }
            const n = @min(out.len, self.len);
            self.readLocked(out[0..n]);
            self.not_full.signal();
            return n;
        }

        /// Non-blocking pop used from the real-time audio callback.
        /// Returns the number of items read (may be 0).
        pub fn popTry(self: *Self, out: []T) usize {
            if (out.len == 0) return 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = @min(out.len, self.len);
            if (n > 0) {
                self.readLocked(out[0..n]);
                self.not_full.signal();
            }
            return n;
        }

        pub fn available(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        /// Signal that no more data will ever be pushed.
        pub fn setEof(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.eof = true;
            self.not_empty.broadcast();
        }

        /// Wake all waiters with error.Aborted.
        pub fn abort(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.aborted = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        pub fn isAborted(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.aborted;
        }

        fn writeLocked(self: *Self, items: []const T) void {
            for (items) |item| {
                self.buf[self.write_pos] = item;
                self.write_pos = (self.write_pos + 1) % self.buf.len;
            }
            self.len += items.len;
        }

        fn readLocked(self: *Self, out: []T) void {
            for (out) |*slot| {
                slot.* = self.buf[self.read_pos];
                self.read_pos = (self.read_pos + 1) % self.buf.len;
            }
            self.len -= out.len;
        }
    };
}
