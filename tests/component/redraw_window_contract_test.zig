//! L2: the generating region's merge window (#328), asserted on what the
//! virtual terminal shows (vterm.zig, #319): screen, scrollback and frame
//! counters, never the region's fields.
//!
//! Contracts:
//!   - a burst inside one window reaches the scrollback once, in order, with
//!     no blank row and one synchronized frame; the live region never does;
//!   - a resize while that frame is pending lays it out at the new width and
//!     leaves one region, nothing stranded above it;
//!   - the end of a provider turn (`endScrollLine`) seals a half line in one
//!     closed DEC 2026 frame, with no blank row after it (group A's finding:
//!     it used to be three separate writes).

const std = @import("std");
const harness = @import("region_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Clock = struct {
    var now: i64 = 0;
    fn read() i64 {
        return now;
    }
};

fn expectRegionOnScreenOnce(t: *harness.Term) !void {
    try t.sync();
    const on_screen = try t.screen.countRows(.screen, harness.isPromptRow);
    const in_history = try t.screen.countRows(.history, harness.isRegionRow);
    if (on_screen == 1 and in_history == 0 and t.screen.sync_depth == 0 and t.screen.stray_sync_ends == 0) return;
    std.debug.print("region on screen {d}x, region rows in scrollback {d}, sync depth {d}, stray ends {d}\n", .{
        on_screen, in_history, t.screen.sync_depth, t.screen.stray_sync_ends,
    });
    t.printDump();
    return error.TestExpectedEqual;
}

fn expectTranscript(t: *harness.Term, expected: []const u8) !void {
    const got = try t.transcriptAlloc(.{});
    defer gpa.free(got);
    if (std.mem.eql(u8, got, expected)) return;
    std.debug.print("transcript:\n{s}\n-- expected:\n{s}\n", .{ got, expected });
    t.printDump();
    return error.TestExpectedEqual;
}

/// A region with the merge window on, driven by the fake clock (no timer
/// thread: `pumpFrame` is its step).
fn mergingTerm(rows: usize, cols: usize) !*harness.Term {
    const t = try harness.Term.create(gpa, .{ .rows = rows, .cols = cols });
    t.region.merge = .{ .now_ms = Clock.read, .timer = false };
    Clock.now = 50_000;
    return t;
}

test "merge window: a burst reaches the scrollback once, in order, in one frame" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try mergingTerm(12, 60);
    defer t.destroy();
    const r = &t.region;
    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app); // nothing painted yet: this frame goes out at once
    try expectRegionOnScreenOnce(t);
    const frames_before = t.screen.sync_frames;

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (0..20) |i| { // all inside the window
        var buf: [32]u8 = undefined;
        r.writeGenText(try std.fmt.bufPrint(&buf, "burst {d}\n", .{i}));
        try expected.print(gpa, "burst {d}\n", .{i});
    }
    try t.sync();
    try testing.expectEqual(frames_before, t.screen.sync_frames); // still waiting for the window
    Clock.now += 16;
    try testing.expect(r.pumpFrame());
    try expectRegionOnScreenOnce(t);
    try testing.expectEqual(frames_before + 1, t.screen.sync_frames); // twenty lines, one frame

    r.leaveGenerating(fx.app);
    try expectTranscript(t, std.mem.trimEnd(u8, expected.items, "\n"));
}

test "merge window: a resize while the frame is pending lays it out at the new width" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    for ([_]bool{ true, false }) |reflow| {
        const t = try mergingTerm(14, 80);
        defer t.destroy();
        const r = &t.region;
        r.enterGenerating(fx.app, null);
        r.tickSpinner(fx.app);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        for (0..6) |i| {
            var buf: [32]u8 = undefined;
            r.writeGenText(try std.fmt.bufPrint(&buf, "pending {d}\n", .{i}));
            try expected.print(gpa, "pending {d}\n", .{i});
        }
        // The terminal narrows before the window ends: the region drawn at
        // 80 columns is re-wrapped (or clipped) under the pending frame.
        try t.resize(14, 50, reflow);
        Clock.now += 16;
        try testing.expect(r.pumpFrame());
        expectRegionOnScreenOnce(t) catch |err| {
            std.debug.print("reflow={}\n", .{reflow});
            return err;
        };
        r.leaveGenerating(fx.app);
        try expectTranscript(t, std.mem.trimEnd(u8, expected.items, "\n"));
    }
}

test "endScrollLine seals a half line in one closed frame, with no blank row after it" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 12, .cols = 60 });
    defer t.destroy();
    const r = &t.region;
    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app);
    try expectRegionOnScreenOnce(t);
    r.writeGenText("first\n");
    r.writeGenText("half"); // the provider turn ends without a newline
    try t.sync();
    const frames_before = t.screen.sync_frames;
    const bytes_before = t.written().len;
    r.endScrollLine();
    try expectRegionOnScreenOnce(t);
    const end_bytes = t.written()[bytes_before..];
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, end_bytes, "\x1b[?2026h"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, end_bytes, "\x1b[?2026l"));
    try testing.expectEqual(frames_before + 1, t.screen.sync_frames);
    r.writeGenText("next\n");
    r.leaveGenerating(fx.app);
    try expectTranscript(t, "first\nhalf\nnext");
}
