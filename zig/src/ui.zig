const std = @import("std");
const tui = @import("tui.zig");
const channels_mod = @import("channels.zig");
const player_mod = @import("player.zig");
const visualizer = @import("visualizer.zig");
const ipc = @import("ipc.zig");

const Channel = channels_mod.Channel;
const Player = player_mod.Player;

const HEADER_H = 4;
const INFO_H = 8;

const SortMode = enum {
    default,
    listeners,
    genre,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    term: tui.Term,
    player: *Player,
    client: std.http.Client,
    channel_arena: std.heap.ArenaAllocator,
    frame_arena: std.heap.ArenaAllocator,

    channels: []Channel = &.{},
    selected: usize = 0,
    scroll: usize = 0,
    playing_idx: ?usize = null,
    volume: u8 = 80,
    sort_mode: SortMode = .default,

    viz: ?visualizer.Visualizer = null,
    last_viz_ms: i64 = 0,
    fullscreen_viz: bool = false,

    ipc: ipc.Server,
    pre_mute_volume: ?u8 = null,

    status_buf: [256]u8 = undefined,
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*App {
        const self = try allocator.create(App);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .term = try tui.Term.init(allocator),
            .player = try Player.init(allocator, io),
            .client = .{ .allocator = allocator, .io = io },
            .channel_arena = std.heap.ArenaAllocator.init(allocator),
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .ipc = .{ .alloc = allocator },
        };
        self.setStatus("Loading SomaFM channels...");
        self.ipc.start(allocator, io) catch {};
        return self;
    }

    pub fn deinit(self: *App) void {
        self.ipc.shutdown();
        self.player.deinit();
        if (self.viz) |*v| v.deinit(self.allocator);
        self.client.deinit();
        self.channel_arena.deinit();
        self.frame_arena.deinit();
        self.term.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        self.draw();
        self.loadChannels();

        var ipc_cmds: std.ArrayList(ipc.Command) = .empty;
        defer ipc_cmds.deinit(self.allocator);

        while (true) {
            if (self.term.pollKey(40)) |key| {
                switch (key) {
                    .ctrl_c => break,
                    .char => |ch| switch (ch) {
                        'q' => break,
                        'k' => self.moveSelection(-1),
                        'j' => self.moveSelection(1),
                        's', 'S' => self.stopPlayback(),
                        '+', '=' => self.adjustVolume(5),
                        '-', '_' => self.adjustVolume(-5),
                        'v', 'V' => self.cycleViz(),
                        'f', 'F' => self.toggleFullscreenViz(),
                        'l', 'L' => self.sortByListeners(),
                        'g', 'G' => self.sortByGenre(),
                        else => {},
                    },
                    .up => self.moveSelection(-1),
                    .down => self.moveSelection(1),
                    .enter, .space => self.playSelected(),
                    .escape => if (self.fullscreen_viz) self.toggleFullscreenViz(),
                    else => {},
                }
                self.draw();
            }
            self.ipc.drain(&ipc_cmds);
            if (ipc_cmds.items.len > 0) {
                for (ipc_cmds.items) |cmd| self.applyCommand(cmd);
                ipc_cmds.clearRetainingCapacity();
                self.draw();
            }
            self.publishStatus();
            const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
            if (now - self.last_viz_ms >= 80) {
                self.last_viz_ms = now;
                self.draw();
            }
        }

        self.player.stop();
    }

    // --------------------------------------------------------------
    // IPC (see ipc.zig for the wire protocol)
    // --------------------------------------------------------------
    fn applyCommand(self: *App, cmd: ipc.Command) void {
        switch (cmd) {
            .vol_set => |v| {
                self.volume = v;
                self.player.setVolume(v);
                self.pre_mute_volume = null;
                var buf: [256]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&buf, "Volume: {d}%", .{self.volume}) catch "Volume");
            },
            .vol_adj => |d| self.adjustVolume(d),
            .mute_toggle => {
                if (self.pre_mute_volume) |prev| {
                    self.volume = prev;
                    self.pre_mute_volume = null;
                } else {
                    self.pre_mute_volume = self.volume;
                    self.volume = 0;
                }
                self.player.setVolume(self.volume);
                self.setStatus(if (self.pre_mute_volume == null) "Unmuted" else "Muted");
            },
            .play_selected => self.playSelected(),
            .play_id => |pid| {
                const id = pid.buf[0..pid.len];
                for (self.channels, 0..) |ch, i| {
                    if (std.mem.eql(u8, ch.id, id)) {
                        self.selected = i;
                        self.playSelected();
                        return;
                    }
                }
                self.setStatus("Unknown channel id");
            },
            .stop => self.stopPlayback(),
            .toggle => {
                var ct: [128]u8 = undefined;
                var tr: [256]u8 = undefined;
                var msg: [256]u8 = undefined;
                const snap = self.player.snapshot(&ct, &tr, &msg);
                if (snap.playing or snap.connecting) self.stopPlayback() else self.playSelected();
            },
            .move => |d| self.moveSelection(d),
            .surf => |d| {
                self.moveSelection(d);
                self.playSelected();
            },
            .viz_next => self.cycleViz(),
        }
    }

    /// Publishes the one-line JSON status snapshot the IPC thread serves.
    fn publishStatus(self: *App) void {
        var ct: [128]u8 = undefined;
        var tr: [256]u8 = undefined;
        var msg: [256]u8 = undefined;
        const snap = self.player.snapshot(&ct, &tr, &msg);
        const channel: []const u8 = if (self.playing_idx) |pi| self.channels[pi].title else "";
        const channel_id: []const u8 = if (self.playing_idx) |pi| self.channels[pi].id else "";

        var buf: [768]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeAll("{\"playing\":") catch return;
        w.writeAll(if (snap.playing) "true" else "false") catch return;
        w.writeAll(",\"connecting\":") catch return;
        w.writeAll(if (snap.connecting) "true" else "false") catch return;
        w.writeAll(",\"channel\":\"") catch return;
        writeJsonEscaped(&w, channel) catch return;
        w.writeAll("\",\"channel_id\":\"") catch return;
        writeJsonEscaped(&w, channel_id) catch return;
        w.writeAll("\",\"track\":\"") catch return;
        writeJsonEscaped(&w, snap.track) catch return;
        w.print("\",\"volume\":{d}}}", .{self.volume}) catch return;
        self.ipc.publishStatus(w.buffered());
    }

    fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
        for (s) |ch| {
            switch (ch) {
                '"', '\\' => {
                    try w.writeByte('\\');
                    try w.writeByte(ch);
                },
                '\n' => try w.writeAll("\\n"),
                else => {
                    if (ch < 0x20) {
                        try w.print("\\u{x:0>4}", .{ch});
                    } else try w.writeByte(ch);
                },
            }
        }
    }

    // --------------------------------------------------------------
    // Actions
    // --------------------------------------------------------------
    fn loadChannels(self: *App) void {
        const chans = channels_mod.fetchChannels(self.channel_arena.allocator(), &self.client) catch |err| {
            var buf: [256]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Error loading channels: {s}", .{@errorName(err)}) catch "Error loading channels");
            self.draw();
            return;
        };
        self.channels = chans;
        var buf: [256]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "{d} channels loaded", .{chans.len}) catch "Channels loaded");
        self.selected = 0;
        self.scroll = 0;
        self.draw();
    }

    fn moveSelection(self: *App, delta: i32) void {
        if (self.channels.len == 0) return;
        const n: i32 = @intCast(self.channels.len);
        var idx: i32 = @intCast(self.selected);
        idx = @max(0, @min(n - 1, idx + delta));
        self.selected = @intCast(idx);

        const view = self.listViewHeight();
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + view) self.scroll = self.selected - view + 1;
    }

    fn playSelected(self: *App) void {
        if (self.channels.len == 0) return;
        const ch = self.channels[self.selected];
        if (ch.urls.len == 0) {
            var buf: [256]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "No stream URL for {s}", .{ch.title}) catch "No stream URL");
            return;
        }
        var buf: [256]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Tuning in: {s}", .{ch.title}) catch "Tuning in...");
        self.playing_idx = self.selected;
        self.player.play(ch.urls[0], ch.title) catch {
            self.setStatus("Playback error");
            return;
        };
        if (self.viz) |*v| {
            v.reset();
        }
        self.setStatus(std.fmt.bufPrint(&buf, "Now playing: {s}", .{ch.title}) catch "Now playing");
    }

    fn stopPlayback(self: *App) void {
        self.player.stop();
        self.playing_idx = null;
        self.setStatus("Stopped");
    }

    fn adjustVolume(self: *App, delta: i32) void {
        const v: i32 = @as(i32, self.volume) + delta;
        self.volume = @intCast(@max(0, @min(100, v)));
        self.player.setVolume(self.volume);
        var buf: [256]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Volume: {d}%", .{self.volume}) catch "Volume");
    }

    fn cycleViz(self: *App) void {
        var ct: [128]u8 = undefined;
        var tr: [256]u8 = undefined;
        var msg: [256]u8 = undefined;
        const snap = self.player.snapshot(&ct, &tr, &msg);
        if (!snap.playing) return;
        if (self.viz) |*v| {
            v.pattern = v.pattern.next();
            var buf: [256]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Visualizer: {s}", .{v.pattern.name()}) catch "Visualizer");
        }
    }

    fn toggleFullscreenViz(self: *App) void {
        self.fullscreen_viz = !self.fullscreen_viz;
        self.setStatus(if (self.fullscreen_viz) "Fullscreen visualizer" else "Normal view");
    }

    fn sortByListeners(self: *App) void {
        if (self.channels.len == 0) return;
        const playing_id = if (self.playing_idx) |idx| self.channels[idx].id else null;
        const selected_id = self.channels[self.selected].id;
        
        std.mem.sort(Channel, self.channels, {}, struct {
            fn lessThan(ctx: void, a: Channel, b: Channel) bool {
                _ = ctx;
                const a_num = std.fmt.parseInt(u32, a.listeners, 10) catch 0;
                const b_num = std.fmt.parseInt(u32, b.listeners, 10) catch 0;
                return a_num > b_num;
            }
        }.lessThan);
        
        self.updateIndicesAfterSort(playing_id, selected_id);
        self.sort_mode = .listeners;
        var buf: [256]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Sorted by listeners", .{}) catch "Sorted by listeners");
    }

    fn sortByGenre(self: *App) void {
        if (self.channels.len == 0) return;
        const playing_id = if (self.playing_idx) |idx| self.channels[idx].id else null;
        const selected_id = self.channels[self.selected].id;
        
        std.mem.sort(Channel, self.channels, {}, struct {
            fn lessThan(ctx: void, a: Channel, b: Channel) bool {
                _ = ctx;
                return std.ascii.lessThanIgnoreCase(a.genre, b.genre);
            }
        }.lessThan);
        
        self.updateIndicesAfterSort(playing_id, selected_id);
        self.sort_mode = .genre;
        var buf: [256]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Sorted by genre", .{}) catch "Sorted by genre");
    }

    fn updateIndicesAfterSort(self: *App, playing_id: ?[]const u8, selected_id: []const u8) void {
        self.playing_idx = null;
        for (self.channels, 0..) |ch, i| {
            if (playing_id) |pid| {
                if (std.mem.eql(u8, ch.id, pid)) {
                    self.playing_idx = i;
                }
            }
            if (std.mem.eql(u8, ch.id, selected_id)) {
                self.selected = i;
            }
        }
        self.scroll = 0;
    }

    fn setStatus(self: *App, msg: []const u8) void {
        const n = @min(msg.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_len = n;
    }

    // --------------------------------------------------------------
    // Layout
    // --------------------------------------------------------------
    fn listViewHeight(self: *App) usize {
        const s = self.term.size();
        const h: usize = if (s.rows > HEADER_H + 1) s.rows - HEADER_H - 1 else 1;
        return if (h > 2) h - 2 else 1;
    }

    const Layout = struct {
        rows: usize,
        cols: usize,
        list_row: usize,
        list_col: usize,
        list_w: usize,
        list_h: usize,
        side_col: usize,
        side_w: usize,
        info_row: usize,
        viz_row: usize,
        viz_h: usize,
    };

    fn layout(self: *App) Layout {
        const s = self.term.size();
        const rows: usize = s.rows;
        const cols: usize = s.cols;
        const list_w = @max(20, cols * 60 / 100);
        const side_col = list_w + 1;
        const side_w = if (cols > side_col) cols - side_col + 1 else 10;
        const list_row = HEADER_H + 1;
        const list_h = if (rows > list_row) rows - list_row else 3; // leaves last row for status
        const viz_row = list_row + INFO_H;
        const viz_h = if (rows > viz_row) rows - viz_row else 3;
        return .{
            .rows = rows,
            .cols = cols,
            .list_row = list_row,
            .list_col = 1,
            .list_w = list_w,
            .list_h = list_h,
            .side_col = side_col,
            .side_w = side_w,
            .info_row = list_row,
            .viz_row = viz_row,
            .viz_h = viz_h,
        };
    }

    // --------------------------------------------------------------
    // Drawing
    // --------------------------------------------------------------
    fn draw(self: *App) void {
        const term = &self.term;
        term.begin();
        if (self.fullscreen_viz) {
            const s = term.size();
            term.clearRegion(1, 1, s.cols, s.rows);
            self.drawVizFullscreen(s.rows, s.cols);
            term.reset();
            term.flush() catch {};
            return;
        }
        const lay = self.layout();
        term.clearRegion(1, 1, lay.cols, lay.rows);
        self.drawHeader(lay);
        self.drawList(lay);
        self.drawInfo(lay);
        self.drawViz(lay);
        self.drawStatus(lay);
        term.reset();
        term.flush() catch {};
    }

    fn drawHeader(self: *App, lay: Layout) void {
        const term = &self.term;
        const art_w = 44;
        const col = if (lay.cols > art_w) (lay.cols - art_w) / 2 + 1 else 1;
        term.fg(.cyan, true);
        term.moveTo(1, col);
        term.text("╔══════════════════════════════════════════╗");
        term.moveTo(2, col);
        term.text("║");
        term.fg(.white, true);
        term.text("        S  O  M  A  F  M        ");
        term.fg(.cyan, true);
        term.text("║");
        term.moveTo(3, col);
        term.text("║");
        term.fg(.green, false);
        term.text("  Internet Radio Visualizer     ");
        term.fg(.cyan, true);
        term.text("║");
        term.moveTo(4, col);
        term.text("╚══════════════════════════════════════════╝");
        term.reset();
    }

    fn drawList(self: *App, lay: Layout) void {
        const term = &self.term;
        term.box(lay.list_row, lay.list_col, lay.list_w, lay.list_h, " SomaFM Channels ", .cyan);

        const view_h = if (lay.list_h > 2) lay.list_h - 2 else 0;
        const line_w = if (lay.list_w > 4) lay.list_w - 4 else 1;
        var buf: [512]u8 = undefined;

        var row: usize = 0;
        while (row < view_h) : (row += 1) {
            const idx = self.scroll + row;
            term.moveTo(lay.list_row + 1 + row, lay.list_col + 1);
            if (idx >= self.channels.len) break;
            const line = channels_mod.formatChannel(&buf, self.channels[idx], line_w);
            if (idx == self.selected) {
                term.text("\x1b[1;30;46m");
                term.textTrunc(line, line_w + 2);
                // Pad the selection highlight across the row.
                var pad: usize = if (line.len < line_w + 2) line_w + 2 - line.len else 0;
                while (pad > 0) : (pad -= 1) term.text(" ");
                term.reset();
            } else {
                term.fg(.white, false);
                term.textTrunc(line, line_w + 2);
            }
        }
        term.reset();
    }

    fn drawInfo(self: *App, lay: Layout) void {
        const term = &self.term;
        term.box(lay.info_row, lay.side_col, lay.side_w, INFO_H, " Now Playing ", .magenta);

        const inner_w = if (lay.side_w > 2) lay.side_w - 2 else 1;
        const row0 = lay.info_row + 1;
        const col0 = lay.side_col + 1;

        var ct: [128]u8 = undefined;
        var tr: [256]u8 = undefined;
        var msg: [256]u8 = undefined;
        const snap = self.player.snapshot(&ct, &tr, &msg);

        // Decide which channel to show.
        var show_idx: ?usize = null;
        if ((snap.playing or snap.connecting) and self.playing_idx != null) {
            show_idx = self.playing_idx;
        } else if (self.channels.len > 0) {
            show_idx = self.selected;
        }

        if (show_idx == null or self.channels.len == 0) {
            term.moveTo(row0 + 1, col0);
            term.fg(.gray, false);
            term.textTrunc("Select a channel to play", inner_w);
            term.reset();
            return;
        }

        const ch = self.channels[show_idx.?];
        const track = if (snap.track.len > 0 and show_idx.? == (self.playing_idx orelse std.math.maxInt(usize)))
            snap.track
        else if (ch.last_playing.len > 0)
            ch.last_playing
        else
            "Loading...";

        self.infoLine(row0 + 0, col0, inner_w, "Channel:", ch.title, true);
        self.infoLine(row0 + 1, col0, inner_w, "Genre:", ch.genre, false);
        self.infoLine(row0 + 2, col0, inner_w, "DJ:", if (ch.dj.len > 0) ch.dj else "None", false);
        self.infoLine(row0 + 3, col0, inner_w, "Listeners:", ch.listeners, false);
        self.infoLine(row0 + 4, col0, inner_w, "Now:", track, false);
        var vol_buf: [16]u8 = undefined;
        const vol_str = std.fmt.bufPrint(&vol_buf, "{d}%", .{self.volume}) catch "?";
        self.infoLine(row0 + 5, col0, inner_w, "Volume:", vol_str, false);
    }

    fn infoLine(self: *App, row: usize, col: usize, w: usize, label: []const u8, value: []const u8, bold: bool) void {
        const term = &self.term;
        term.moveTo(row, col);
        term.fg(.cyan, false);
        term.text(" ");
        term.text(label);
        term.text(" ");
        term.fg(.white, bold);
        const used = 1 + label.len + 1;
        term.textTrunc(value, if (w > used) w - used else 0);
        term.reset();
    }

    fn drawViz(self: *App, lay: Layout) void {
        const term = &self.term;
        term.box(lay.viz_row, lay.side_col, lay.side_w, lay.viz_h, " Visualizer ", .green);

        const inner_w = if (lay.side_w > 2) lay.side_w - 2 else 1;
        const inner_h = if (lay.viz_h > 2) lay.viz_h - 2 else 1;

        const bars = @max(8, inner_w);
        if (self.viz == null) {
            var seed: u64 = undefined;
            std.Io.random(self.io, std.mem.asBytes(&seed));
            self.viz = visualizer.Visualizer.init(self.allocator, bars, inner_h, .waves, seed) catch return;
        }
        if (self.viz.?.bars != bars or self.viz.?.height != inner_h) {
            self.viz.?.resize(self.allocator, bars, inner_h) catch return;
        }

        var window: [player_mod.VIZ_WINDOW]f32 = undefined;
        const has_audio = self.player.vizWindow(&window);

        _ = self.frame_arena.reset(.retain_capacity);
        const alloc = self.frame_arena.allocator();
        const lines = self.viz.?.render(alloc, if (has_audio) window[0..] else null, player_mod.SAMPLE_RATE) catch return;
        for (lines, 0..) |line, i| {
            if (i >= inner_h) break;
            term.moveTo(lay.viz_row + 1 + i, lay.side_col + 1);
            term.text(line);
        }
        term.reset();
    }

    /// Edge-to-edge visualizer: no border, no status row — the pattern
    /// itself covers every row and column of the terminal.
    fn drawVizFullscreen(self: *App, rows: usize, cols: usize) void {
        const term = &self.term;

        const bars = @max(8, cols);
        const height = @max(1, rows);
        if (self.viz == null) {
            var seed: u64 = undefined;
            std.Io.random(self.io, std.mem.asBytes(&seed));
            self.viz = visualizer.Visualizer.init(self.allocator, bars, height, .waves, seed) catch return;
        }
        if (self.viz.?.bars != bars or self.viz.?.height != height) {
            self.viz.?.resize(self.allocator, bars, height) catch return;
        }

        var window: [player_mod.VIZ_WINDOW]f32 = undefined;
        const has_audio = self.player.vizWindow(&window);

        _ = self.frame_arena.reset(.retain_capacity);
        const alloc = self.frame_arena.allocator();
        const lines = self.viz.?.render(alloc, if (has_audio) window[0..] else null, player_mod.SAMPLE_RATE) catch return;
        for (lines, 0..) |line, i| {
            if (i >= height) break;
            term.moveTo(1 + i, 1);
            term.text(line);
        }
        term.reset();
    }

    fn drawStatus(self: *App, lay: Layout) void {
        const term = &self.term;

        var ct: [128]u8 = undefined;
        var tr: [256]u8 = undefined;
        var msg: [256]u8 = undefined;
        const snap = self.player.snapshot(&ct, &tr, &msg);

        const status = if (snap.message.len > 0) snap.message else self.status_buf[0..self.status_len];

        term.moveTo(lay.rows, 1);
        term.text("\x1b[30;46m");
        term.text(" ");
        term.textTrunc(status, lay.cols -| 45);
        term.text(" | ");
        const hints = "↑↓nav Enter play s stop +/- vol v viz f fullscreen l listeners g genre q quit";
        term.textTrunc(hints, lay.cols);
        // Fill the rest of the row.
        var i: usize = 1 + @min(status.len, lay.cols -| 45) + 3 + @min(hints.len, lay.cols);
        while (i < lay.cols) : (i += 1) term.text(" ");
        term.reset();
    }
};
