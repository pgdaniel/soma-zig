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

const FREQ_MIN: f64 = 50.0; // Hz, low end of the analyzed band range
const FREQ_MAX: f64 = 16000.0; // Hz, high end (well below typical stream Nyquist)

/// Audio-reactive visualizer. Every pattern is driven by real PCM samples
/// captured from what's actually playing (see Player.vizWindow): bars,
/// spectrum, columns and mondrian read per-frequency-band energy via the
/// Goertzel algorithm; waves traces the raw time-domain waveform; pulse
/// tracks overall RMS loudness. With no audio (nothing playing yet), levels
/// decay to silence instead of faking motion.
pub const Visualizer = struct {
    bars: usize,
    height: usize,
    pattern: Pattern,
    values: []f64, // smoothed per-bar spectrum energy, 0..1
    targets: []f64, // latest raw per-bar spectrum energy, 0..1
    peak: []f64, // per-bar peak-hold level, 0..1, decays over time
    frame_count: u64 = 0,
    color_index: u64 = 0,
    current_color: []const u8 = "36",
    rng: std.Random.DefaultPrng,
    gain_band: f64 = 0.02, // auto-gain ceiling for per-band spectrum energy
    gain_rms: f64 = 0.02, // auto-gain ceiling for overall RMS loudness
    level: f64 = 0, // smoothed overall loudness, 0..1 (drives `.pulse`)

    pub fn init(allocator: std.mem.Allocator, bars: usize, height: usize, pattern: Pattern, seed: u64) !Visualizer {
        const values = try allocator.alloc(f64, bars);
        const targets = try allocator.alloc(f64, bars);
        const peak = try allocator.alloc(f64, bars);
        @memset(values, 0);
        @memset(targets, 0);
        @memset(peak, 0);
        return .{
            .bars = bars,
            .height = height,
            .pattern = pattern,
            .values = values,
            .targets = targets,
            .peak = peak,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *Visualizer, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        allocator.free(self.targets);
        allocator.free(self.peak);
    }

    pub fn resize(self: *Visualizer, allocator: std.mem.Allocator, bars: usize, height: usize) !void {
        if (bars != self.bars) {
            self.values = try allocator.realloc(self.values, bars);
            self.targets = try allocator.realloc(self.targets, bars);
            self.peak = try allocator.realloc(self.peak, bars);
        }
        self.bars = bars;
        self.height = height;
        @memset(self.values, 0);
        @memset(self.targets, 0);
        @memset(self.peak, 0);
    }

    pub fn reset(self: *Visualizer) void {
        @memset(self.values, 0);
        @memset(self.targets, 0);
        @memset(self.peak, 0);
        self.level = 0;
        // Fresh auto-gain reference so a new (possibly quieter/louder)
        // channel doesn't inherit the old one's loudness ceiling.
        self.gain_band = 0.02;
        self.gain_rms = 0.02;
    }

    /// Advance one animation frame from a rolling window of real mono PCM
    /// samples (or null if nothing is playing yet) and produce the
    /// rendered rows. Returned lines are owned by `allocator`.
    pub fn render(self: *Visualizer, allocator: std.mem.Allocator, samples: ?[]const f32, sample_rate: f64) ![][]const u8 {
        self.frame_count += 1;

        if (samples) |s| {
            switch (self.pattern) {
                .waves => {}, // oscilloscope reads the raw window directly
                .pulse => self.level += (self.analyzeLevel(s) - self.level) * 0.3,
                else => {
                    try self.analyzeSpectrum(allocator, s, sample_rate);
                    self.smoothValues();
                    self.updatePeaks();
                },
            }
        } else {
            // No audio yet: decay toward silence rather than faking motion.
            @memset(self.targets, 0);
            self.smoothValues();
            self.level *= 0.9;
            for (self.peak) |*p| p.* = @max(0, p.* - 0.02);
        }

        if (self.color_index % 8 == 0) {
            self.current_color = ansi_colors[self.rng.random().uintLessThan(usize, ansi_colors.len)];
        }
        self.color_index += 1;

        return switch (self.pattern) {
            .mondrian => self.renderMondrian(allocator),
            .columns => self.renderColumns(allocator),
            .spectrum => self.renderSpectrum(allocator),
            .waves => self.renderWaves(allocator, samples),
            .pulse => self.renderPulse(allocator),
            .bars => self.renderBars(allocator),
        };
    }

    /// Real per-band frequency energy (Goertzel algorithm, Hann-windowed,
    /// log-spaced bands from FREQ_MIN to FREQ_MAX, auto-gained to 0..1)
    /// from a raw mono PCM window. This is the shared spectrum data source
    /// for bars, spectrum, columns, and mondrian.
    fn analyzeSpectrum(self: *Visualizer, allocator: std.mem.Allocator, samples: []const f32, sample_rate: f64) !void {
        const n = samples.len;
        if (n < 2) return;
        const windowed = try allocator.alloc(f64, n);
        defer allocator.free(windowed);
        const n_f: f64 = @floatFromInt(n);
        for (windowed, 0..) |*w, i| {
            // Hann window tames spectral leakage between adjacent bands.
            const hann = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / (n_f - 1));
            w.* = @as(f64, samples[i]) * hann;
        }

        const fmax = @min(FREQ_MAX, sample_rate * 0.45);
        var peak_mag: f64 = 0;
        for (0..self.bars) |i| {
            const freq = bandFreq(i, self.bars, FREQ_MIN, fmax);
            const mag = goertzelMag(windowed, sample_rate, freq);
            self.targets[i] = mag;
            peak_mag = @max(peak_mag, mag);
        }

        // Auto-gain: track a ceiling that snaps up fast on louder peaks and
        // decays slowly, so quiet and loud streams both fill the display.
        self.gain_band = if (peak_mag > self.gain_band) peak_mag else self.gain_band * 0.97 + peak_mag * 0.03;
        const ceiling = @max(self.gain_band, 0.0008);
        for (self.targets) |*v| {
            // sqrt gives a perceptual boost to low-level detail.
            v.* = std.math.clamp(@sqrt(v.* / ceiling), 0, 1);
        }
    }

    /// Overall RMS loudness of the window, auto-gained to 0..1.
    fn analyzeLevel(self: *Visualizer, samples: []const f32) f64 {
        var sum: f64 = 0;
        for (samples) |s| sum += @as(f64, s) * @as(f64, s);
        const rms = @sqrt(sum / @as(f64, @floatFromInt(samples.len)));
        self.gain_rms = if (rms > self.gain_rms) rms else self.gain_rms * 0.95 + rms * 0.05;
        const ceiling = @max(self.gain_rms, 0.0008);
        return std.math.clamp(rms / ceiling, 0, 1);
    }

    fn updatePeaks(self: *Visualizer) void {
        for (self.values, self.peak) |v, *p| {
            p.* = if (v > p.*) v else p.* * 0.96;
        }
    }

    fn smoothValues(self: *Visualizer) void {
        const speed = 0.3;
        for (0..self.bars) |i| {
            self.values[i] += (self.targets[i] - self.values[i]) * speed;
        }
    }

    fn renderBars(self: *Visualizer, allocator: std.mem.Allocator) ![][]const u8 {
        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line: std.ArrayList(u8) = .empty;
            try line.print(allocator, "\x1b[{s}m", .{self.current_color});
            for (0..self.bars) |i| {
                try line.appendSlice(allocator, blockGlyph(self.values[i], self.height, row));
            }
            try line.appendSlice(allocator, "\x1b[0m");
            lines[row] = line.items;
        }
        return lines;
    }

    /// Bars plus a bright peak-hold marker line above each one, like a
    /// classic hardware spectrum analyzer.
    fn renderSpectrum(self: *Visualizer, allocator: std.mem.Allocator) ![][]const u8 {
        const h_f: f64 = @floatFromInt(self.height);
        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line: std.ArrayList(u8) = .empty;
            const row_f: f64 = @floatFromInt(row);
            for (0..self.bars) |i| {
                const peak_pos = self.peak[i] * h_f - row_f;
                if (self.peak[i] > 0.03 and peak_pos >= 0 and peak_pos < 1.0) {
                    try line.appendSlice(allocator, "\x1b[97m▔\x1b[0m");
                } else {
                    try line.print(allocator, "\x1b[{s}m{s}\x1b[0m", .{ self.current_color, blockGlyph(self.values[i], self.height, row) });
                }
            }
            lines[row] = line.items;
        }
        return lines;
    }

    /// Single full-width block whose height tracks overall RMS loudness —
    /// a simple real VU meter rather than a per-frequency display.
    fn renderPulse(self: *Visualizer, allocator: std.mem.Allocator) ![][]const u8 {
        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line: std.ArrayList(u8) = .empty;
            try line.print(allocator, "\x1b[{s}m", .{self.current_color});
            const glyph = blockGlyph(self.level, self.height, row);
            for (0..self.bars) |_| try line.appendSlice(allocator, glyph);
            try line.appendSlice(allocator, "\x1b[0m");
            lines[row] = line.items;
        }
        return lines;
    }

    /// Real oscilloscope trace of the raw time-domain waveform, downsampled
    /// to `bars` points and centered vertically.
    fn renderWaves(self: *Visualizer, allocator: std.mem.Allocator, samples: ?[]const f32) ![][]const u8 {
        const cells = try allocator.alloc(bool, self.bars * self.height);
        @memset(cells, false);

        if (samples) |s| {
            const mid: f64 = @as(f64, @floatFromInt(self.height)) / 2.0;
            const max_row: f64 = @floatFromInt(self.height - 1);
            for (0..self.bars) |i| {
                const idx = i * s.len / self.bars;
                const amp: f64 = s[idx]; // roughly -1..1
                const row_f = std.math.clamp(mid - amp * mid, 0, max_row);
                const row: usize = @intFromFloat(row_f);
                cells[row * self.bars + i] = true;
            }
        }

        var lines = try allocator.alloc([]const u8, self.height);
        for (0..self.height) |row| {
            var line: std.ArrayList(u8) = .empty;
            try line.print(allocator, "\x1b[{s}m", .{self.current_color});
            for (0..self.bars) |i| {
                try line.appendSlice(allocator, if (cells[row * self.bars + i]) "●" else " ");
            }
            try line.appendSlice(allocator, "\x1b[0m");
            lines[row] = line.items;
        }
        return lines;
    }

    /// Piet Mondrian "Composition" style: black grid lines dividing the
    /// canvas into rectangles filled with white and primary colors. The
    /// divider positions and pane colors follow real bass/mid/treble
    /// energy (self.values, populated by analyzeSpectrum).
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

/// Sub-character-resolution partial block for a bar at `value` (0..1)
/// height, at the given `row` (0 = top) of a `height`-row box.
fn blockGlyph(value: f64, height: usize, row: usize) []const u8 {
    const bar_h = value * @as(f64, @floatFromInt(height));
    const bar_pos = bar_h - @as(f64, @floatFromInt(row));
    if (bar_pos >= 0.9) return "█";
    if (bar_pos >= 0.75) return "▇";
    if (bar_pos >= 0.5) return "▅";
    if (bar_pos >= 0.25) return "▃";
    if (bar_pos > 0) return "▁";
    return " ";
}

/// Goertzel algorithm: magnitude of `samples` at `freq` Hz, normalized by
/// window length. Cheaper than a full FFT when only a handful of specific
/// frequencies (one per visual bar) are needed rather than the full
/// spectrum.
fn goertzelMag(samples: []const f64, sample_rate: f64, freq: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    const k = @round((n * freq) / sample_rate);
    const w = (2.0 * std.math.pi / n) * k;
    const cosine = @cos(w);
    const coeff = 2.0 * cosine;
    var q0: f64 = 0;
    var q1: f64 = 0;
    var q2: f64 = 0;
    for (samples) |s| {
        q0 = coeff * q1 - q2 + s;
        q2 = q1;
        q1 = q0;
    }
    const real = q1 - q2 * cosine;
    const imag = q2 * @sin(w);
    return @sqrt(real * real + imag * imag) / n;
}

/// Log-spaced center frequency for band `i` of `bars`, matching how real
/// spectrum analyzers allot more bars to bass than treble.
fn bandFreq(i: usize, bars: usize, fmin: f64, fmax: f64) f64 {
    if (bars <= 1) return fmin;
    const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(bars - 1));
    return fmin * std.math.pow(f64, fmax / fmin, t);
}

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
