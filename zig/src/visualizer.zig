const std = @import("std");

pub const Pattern = enum {
    waves,
    pulse,
    bars,
    spectrum,
    columns,
    mondrian,

    pub fn name(self: Pattern) []const u8 {
        return @tagName(self);
    }

    pub fn next(self: Pattern) Pattern {
        return switch (self) {
            .waves => .pulse,
            .pulse => .bars,
            .bars => .spectrum,
            .spectrum => .columns,
            .columns => .mondrian,
            .mondrian => .waves,
        };
    }

    pub fn random(rng: std.Random) Pattern {
        const all = [_]Pattern{ .waves, .pulse, .bars, .spectrum, .columns, .mondrian };
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

    pub fn init(allocator: std.mem.Allocator, bars: usize, height: usize, pattern: Pattern, seed: u64) !Visualizer {
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

        if (self.pattern == .mondrian) return self.renderMondrian(allocator);
        if (self.pattern == .columns) return self.renderColumns(allocator);

        if (self.color_index % 8 == 0) {
            self.current_color = ansi_colors[self.rng.random().uintLessThan(usize, ansi_colors.len)];
        }
        self.color_index += 1;

        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line: std.ArrayList(u8) = .empty;
            try line.print(allocator, "\x1b[{s}m", .{self.current_color});
            for (0..self.bars) |i| {
                const bar_h = self.values[i] * @as(f64, @floatFromInt(self.height));
                const bar_pos = bar_h - @as(f64, @floatFromInt(row));
                if (bar_pos >= 0.9) {
                    try line.appendSlice(allocator, "█");
                } else if (bar_pos >= 0.75) {
                    try line.appendSlice(allocator, "▇");
                } else if (bar_pos >= 0.5) {
                    try line.appendSlice(allocator, "▅");
                } else if (bar_pos >= 0.25) {
                    try line.appendSlice(allocator, "▃");
                } else if (bar_pos > 0) {
                    try line.appendSlice(allocator, "▁");
                } else {
                    try line.appendSlice(allocator, " ");
                }
            }
            try line.appendSlice(allocator, "\x1b[0m");
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
                // columns reuses the same bass/mid/treble band shape as
                // spectrum; only the rendering differs.
                .spectrum, .columns => blk: {
                    const bass = @sin(t * 0.8) * 0.5 + 0.5;
                    const mid = @sin(t * 1.5 + fi * 0.2) * 0.4 + 0.4;
                    break :blk if (fi < bars_f * 0.25)
                        bass * (1 - fi / (bars_f * 0.25)) * 0.8
                    else if (fi < bars_f * 0.6)
                        mid * 0.6
                    else
                        mid * (1 - (fi - bars_f * 0.6) / (bars_f * 0.4)) * 0.4;
                },
                // Slow, smooth waves; the Mondrian layout reacts to band averages.
                .mondrian => @abs(@sin(t * 0.9 + fi * 0.2)) * (0.35 + 0.5 * @abs(@sin(t * 0.5 + fi * 0.05))),
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

    /// Piet Mondrian "Composition" style: black grid lines dividing the
    /// canvas into rectangles filled with white and primary colors. The
    /// divider positions follow the music, colored panes swap primaries
    /// every ~2s and turn bright on high energy.
    fn renderMondrian(self: *Visualizer, allocator: std.mem.Allocator) ![][]const u8 {
        const w = self.bars;
        const h = self.height;

        // SGR background codes.
        const white = "47";
        const black = "40";

        const cells = try allocator.alloc([]const u8, w * h);
        @memset(cells, white);

        if (w >= 8 and h >= 4) {
            const wf: f64 = @floatFromInt(w);
            const hf: f64 = @floatFromInt(h);

            // Drive the layout with per-band energy.
            const third = @max(1, w / 3);
            const a0 = avg(self.values[0..third]);
            const a1 = avg(self.values[third .. 2 * third]);
            const a2 = avg(self.values[2 * third ..]);

            // Two full-height vertical dividers, wobbling with the music.
            const v1 = clampUsize(@intFromFloat(wf * (0.22 + 0.12 * a0)), 2, w - 5);
            const v2 = clampUsize(@intFromFloat(wf * (0.58 + 0.14 * a2)), v1 + 2, w - 3);

            // Horizontal dividers, one per band (two in the middle band).
            const hA = clampUsize(@intFromFloat(hf * (0.55 + 0.25 * a0)), 1, h - 2);
            const hB1 = clampUsize(@intFromFloat(hf * (0.30 + 0.15 * a1)), 1, h - 3);
            const hB2 = clampUsize(@intFromFloat(hf * (0.68 + 0.15 * a1)), hB1 + 1, h - 2);
            const hC = clampUsize(@intFromFloat(hf * (0.75 - 0.25 * a2)), 1, h - 2);

            // Colored panes rotate through red/blue/yellow over time.
            const rot = (self.frame_count / 24) % 3;

            // Composition II homage: big red top-right, small blue
            // bottom-left, small yellow in the middle band, rest white.
            fillRect(cells, w, hA + 1, h, 0, v1, primary(1, rot, a0)); // blue
            fillRect(cells, w, hB1 + 1, hB2, v1 + 1, v2, primary(2, rot, a1)); // yellow
            fillRect(cells, w, 0, hC, v2 + 1, w, primary(0, rot, a2)); // red

            // Black grid lines on top of the fills.
            for (0..h) |r| {
                cells[r * w + v1] = black;
                cells[r * w + v2] = black;
            }
            for (0..v1) |c| cells[hA * w + c] = black;
            for (v1 + 1..v2) |c| {
                cells[hB1 * w + c] = black;
                cells[hB2 * w + c] = black;
            }
            for (v2 + 1..w) |c| cells[hC * w + c] = black;
        }

        var lines = try allocator.alloc([]const u8, h);
        for (0..h) |row| {
            var line: std.ArrayList(u8) = .empty;
            // Group runs of equal color into one escape sequence.
            var col: usize = 0;
            while (col < w) {
                const code = cells[row * w + col];
                var end = col + 1;
                while (end < w and std.mem.eql(u8, cells[row * w + end], code)) end += 1;
                try line.print(allocator, "\x1b[{s}m", .{code});
                for (col..end) |_| try line.appendSlice(allocator, " ");
                col = end;
            }
            try line.appendSlice(allocator, "\x1b[0m");
            lines[row] = line.items;
        }
        return lines;
    }

    /// Classic spectrum-analyzer look: solid LED-style blocks in narrow
    /// columns separated by gaps, colored green/yellow/red by height like a
    /// hardware VU meter, rather than one color per frame.
    fn renderColumns(self: *Visualizer, allocator: std.mem.Allocator) ![][]const u8 {
        const green = "32";
        const yellow = "33";
        const red = "31";
        const h_denom: f64 = @floatFromInt(if (self.height > 1) self.height - 1 else 1);

        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line: std.ArrayList(u8) = .empty;
            // Row's height fraction from the bottom of the box; low rows
            // stay green, mid rows turn yellow, only near the top does it
            // flash red, mirroring a real level meter's color bands.
            const from_bottom = @as(f64, @floatFromInt(self.height - 1 - row)) / h_denom;
            const color = if (from_bottom < 0.55) green else if (from_bottom < 0.8) yellow else red;
            try line.print(allocator, "\x1b[{s}m", .{color});
            for (0..self.bars) |i| {
                // Every other column is a gap, giving the segmented look.
                if (i % 2 == 1) {
                    try line.appendSlice(allocator, " ");
                    continue;
                }
                const bar_h = self.values[i] * @as(f64, @floatFromInt(self.height));
                const bar_pos = bar_h - @as(f64, @floatFromInt(row));
                try line.appendSlice(allocator, if (bar_pos >= 0.5) "█" else " ");
            }
            try line.appendSlice(allocator, "\x1b[0m");
            lines[row] = line.items;
        }
        return lines;
    }
};

fn avg(vals: []const f64) f64 {
    if (vals.len == 0) return 0;
    var s: f64 = 0;
    for (vals) |v| s += v;
    return s / @as(f64, @floatFromInt(vals.len));
}

fn clampUsize(x: usize, lo: usize, hi: usize) usize {
    return @max(lo, @min(x, hi));
}

fn fillRect(cells: [][]const u8, w: usize, r0: usize, r1: usize, c0: usize, c1: usize, code: []const u8) void {
    for (r0..r1) |r| {
        for (c0..c1) |c| {
            cells[r * w + c] = code;
        }
    }
}

/// A primary color (base 0=red, 1=blue, 2=yellow), rotated over time,
/// brightened when the band has high energy.
fn primary(base: usize, rot: usize, energy: f64) []const u8 {
    const bright = energy > 0.75;
    return switch ((base + rot) % 3) {
        0 => if (bright) "101" else "41", // red
        1 => if (bright) "104" else "44", // blue
        else => if (bright) "103" else "43", // yellow
    };
}
