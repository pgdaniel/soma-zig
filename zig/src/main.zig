const std = @import("std");
const ui = @import("ui.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const app = ui.App.init(allocator) catch |err| {
        std.debug.print("Failed to start SomaFM TUI: {s}\n", .{@errorName(err)});
        std.posix.exit(1);
    };
    defer app.deinit();

    try app.run();
}
