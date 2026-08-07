const std = @import("std");

pub const Pattern = enum {
    waves,
    pulse,
    bars,
    spectrum,

    pub fn name(self: Pattern) []const u8 {
        return @tagName(self);
    }

    pub fn next(self: Pattern) Pattern {
        return switch (self) {
            .waves => .pulse,
            .pulse => .bars,
            .bars => .spectrum,
            .spectrum => .waves,
        };
    }

    pub fn random(rng: std.Random) Pattern {
        const all = [_]Pattern{ .waves, .pulse, .bars, .spectrum };
        return all[rng.uintLessThan(usize, all.len)];
    }
};

const ansi_colors = [_][]const u8{ "36", "34", "35", "31", "33", "32" }; // cyan blue magenta red yellow green

/// Fake-but-pretty animated visualizer, mirroring the JS version. Renders
/// rows of ANSI-colored unicode block characters.
pub const Visualizer = struct {
    bars: usize,
    height: usize,
    pattern: Pattern,
    values: []f64,
    targets: []f64,
    frame_count: u64 = 0,
    color_index: u64 = 0,
    current_color: []const u8 = "36",
    rng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, bars: usize, height: usize, pattern: Pattern) !Visualizer {
        const seed: u64 = @intCast(std.time.milliTimestamp() & 0x7fffffffffffffff);
        return .{
            .bars = bars,
            .height = height,
            .pattern = pattern,
            .values = try allocator.alloc(f64, bars),
            .targets = try allocator.alloc(f64, bars),
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *Visualizer, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        allocator.free(self.targets);
    }

    pub fn resize(self: *Visualizer, allocator: std.mem.Allocator, bars: usize, height: usize) !void {
        if (bars != self.bars) {
            self.values = try allocator.realloc(self.values, bars);
            self.targets = try allocator.realloc(self.targets, bars);
        }
        self.bars = bars;
        self.height = height;
        @memset(self.values, 0);
        @memset(self.targets, 0);
    }

    pub fn reset(self: *Visualizer) void {
        @memset(self.values, 0);
        @memset(self.targets, 0);
    }

    /// Advance one animation frame and produce the rendered rows.
    /// Returned lines are owned by `allocator`.
    pub fn render(self: *Visualizer, allocator: std.mem.Allocator) ![][]const u8 {
        self.generateTargets();
        self.smoothValues();
        self.frame_count += 1;

        if (self.color_index % 8 == 0) {
            self.current_color = ansi_colors[self.rng.random().uintLessThan(usize, ansi_colors.len)];
        }
        self.color_index += 1;

        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line = std.ArrayList(u8).init(allocator);
            const w = line.writer();
            try w.print("\x1b[{s}m", .{self.current_color});
            for (0..self.bars) |i| {
                const bar_h = self.values[i] * @as(f64, @floatFromInt(self.height));
                const bar_pos = bar_h - @as(f64, @floatFromInt(row));
                if (bar_pos >= 0.9) {
                    try w.writeAll("█");
                } else if (bar_pos >= 0.75) {
                    try w.writeAll("▇");
                } else if (bar_pos >= 0.5) {
                    try w.writeAll("▅");
                } else if (bar_pos >= 0.25) {
                    try w.writeAll("▃");
                } else if (bar_pos > 0) {
                    try w.writeAll("▁");
                } else {
                    try w.writeAll(" ");
                }
            }
            try w.writeAll("\x1b[0m");
            lines[row] = line.items;
        }
        return lines;
    }

    fn generateTargets(self: *Visualizer) void {
        const rng = self.rng.random();
        const t = @as(f64, @floatFromInt(self.frame_count)) * 0.15;
        const bars_f: f64 = @floatFromInt(self.bars);

        for (0..self.bars) |i| {
            const fi: f64 = @floatFromInt(i);
            var val: f64 = switch (self.pattern) {
                .waves => (@sin(t + fi * 0.3) * 0.5 + 0.5) * (@sin(fi * 0.5 + t * 0.7) * 0.5 + 0.7),
                .pulse => @abs(@sin(t - fi * 0.15)) * (0.4 + @sin(fi * 0.4) * 0.3),
                .bars => @abs(@sin(t * 1.3 + fi * 0.25)) * (0.3 + rng.float(f64) * 0.7),
                .spectrum => blk: {
                    const bass = @sin(t * 0.8) * 0.5 + 0.5;
                    const mid = @sin(t * 1.5 + fi * 0.2) * 0.4 + 0.4;
                    break :blk if (fi < bars_f * 0.25)
                        bass * (1 - fi / (bars_f * 0.25)) * 0.8
                    else if (fi < bars_f * 0.6)
                        mid * 0.6
                    else
                        mid * (1 - (fi - bars_f * 0.6) / (bars_f * 0.4)) * 0.4;
                },
            };
            val = @max(0.05, @min(1.0, val + rng.float(f64) * 0.1));
            self.targets[i] = val;
        }
    }

    fn smoothValues(self: *Visualizer) void {
        const speed = 0.3;
        for (0..self.bars) |i| {
            self.values[i] += (self.targets[i] - self.values[i]) * speed;
        }
    }
};
