const std = @import("std");
const ui = @import("ui.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Single-threaded Io: all I/O blocks the calling thread; futex-based
    // locks/conditions still work across the app's own threads.
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    const app = ui.App.init(allocator, io) catch |err| {
        std.debug.print("Failed to start SomaFM TUI: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer app.deinit();

    try app.run();
}
