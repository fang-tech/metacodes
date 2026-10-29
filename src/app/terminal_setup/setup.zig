//! `/terminal-setup` and `metacodes terminal-setup` (metacodes#386): teach a
//! terminal that cannot report Shift+Enter on its own to send a sequence
//! metacodes reads as a newline.
//!
//! Terminals that speak the Kitty keyboard protocol need nothing (metacodes
//! turns it on, `repl/input.zig`). Apple Terminal speaks no such protocol and
//! VS Code's xterm.js is on the protocol's deny-list, so on both Shift+Enter is
//! a plain Return. Their own configuration can bind it instead:
//! - Apple Terminal: Shift+Return in the profile's key map (`apple_terminal.zig`);
//! - VS Code and its forks: a `keybindings.json` entry (`vscode.zig`).
//!
//! Both send ESC CR (`newline_sequence`): the Meta+Return Claude Code's own
//! VS Code binding sends, which `KeyParser` reads as `.shift_enter`, and which
//! shells take for a line break rather than for a command to run.
//!
//! Every change is backed up first (`<state root>/terminal-setup/`) and
//! recorded (`installed.json` there), so `--restore` undoes exactly what this
//! command did and leaves the user's own settings alone.

const std = @import("std");
const builtin = @import("builtin");
const paths = @import("platform").paths;
const process = @import("platform").process;
const util_fs = @import("../../util/fs.zig");
const util_time = @import("../../util/time.zig");
const files = @import("files.zig");
const vscode = @import("vscode.zig");
const apple = @import("apple_terminal.zig");

/// What Shift+Enter sends once set up: ESC CR.
pub const newline_sequence = "\x1b\r";

/// The process environment this module reads (one struct so detection is a
/// pure function of it in tests).
pub const Env = struct {
    term_program: ?[]const u8 = null,
    term_program_version: ?[]const u8 = null,
    term: ?[]const u8 = null,
    tmux: bool = false,
    /// `VSCODE_GIT_ASKPASS_MAIN`: a script inside the VS Code install.
    vscode_askpass_main: ?[]const u8 = null,
    path: ?[]const u8 = null,
    cursor_trace_id: bool = false,
    /// `__CFBundleIdentifier` (macOS: the app that started the shell).
    bundle_id: ?[]const u8 = null,
    vscode_portable: ?[]const u8 = null,
    vscode_appdata: ?[]const u8 = null,
    /// Codespaces, a dev container, or WSL: the editor window is elsewhere.
    remote_session: bool = false,
    appdata: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    os: Os = switch (builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        else => .other,
    },

    pub const Os = enum { macos, windows, other };

    pub fn fromProcess(arena: std.mem.Allocator) error{OutOfMemory}!Env {
        const vars = try paths.environment(arena);
        const Lookup = struct {
            vars: []const [:0]const u8,
            fn get(self: @This(), name: []const u8) ?[]const u8 {
                for (self.vars) |entry| {
                    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                    if (eq == 0) continue; // Windows' per-drive `=C:` entries
                    const key = entry[0..eq];
                    const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(key, name) else std.mem.eql(u8, key, name);
                    if (same) return if (entry.len > eq + 1) entry[eq + 1 ..] else null;
                }
                return null;
            }
        };
        const env: Lookup = .{ .vars = vars };
        return .{
            .term_program = env.get("TERM_PROGRAM"),
            .term_program_version = env.get("TERM_PROGRAM_VERSION"),
            .term = env.get("TERM"),
            .tmux = env.get("TMUX") != null,
            .vscode_askpass_main = env.get("VSCODE_GIT_ASKPASS_MAIN"),
            .path = env.get("PATH"),
            .cursor_trace_id = env.get("CURSOR_TRACE_ID") != null,
            .bundle_id = env.get("__CFBundleIdentifier"),
            .vscode_portable = env.get("VSCODE_PORTABLE"),
            .vscode_appdata = env.get("VSCODE_APPDATA"),
            .remote_session = env.get("CODESPACES") != null or env.get("REMOTE_CONTAINERS") != null or env.get("WSL_DISTRO_NAME") != null,
            .appdata = env.get("APPDATA"),
            .xdg_config_home = env.get("XDG_CONFIG_HOME"),
            .home = paths.homeDir(),
        };
    }
};

/// The terminal this session runs in, as far as setup goes.
pub const Host = union(enum) {
    apple_terminal,
    vscode,
    /// A VS Code window on another machine (Remote-SSH, WSL, a container).
    vscode_remote,
    /// Reports Shift+Enter distinctly already; the display name.
    native: []const u8,
    tmux,
    /// Anything else: `TERM_PROGRAM`, when set.
    other: ?[]const u8,
};

/// Terminals metacodes turns the Kitty keyboard protocol on for from their
/// environment alone (`input.classifyKittyKeyboard`'s allow-list; a test keeps
/// the two in step), with the names people know them by.
const native_term_programs = [_]struct { []const u8, []const u8 }{
    .{ "iTerm.app", "iTerm2" },
    .{ "WezTerm", "WezTerm" },
    .{ "ghostty", "Ghostty" },
    .{ "WarpTerminal", "Warp" },
};

pub fn detect(env: Env) Host {
    if (env.tmux) return .tmux;
    // TERM is the terminal's own; TERM_PROGRAM may be inherited from the one
    // that started it (kitty opened from Terminal.app), as in input.zig.
    if (env.term) |term| {
        if (std.mem.indexOf(u8, term, "kitty") != null) return .{ .native = "kitty" };
        if (std.mem.eql(u8, term, "xterm-ghostty")) return .{ .native = "Ghostty" };
    }
    const tp = env.term_program orelse return .{ .other = null };
    if (std.mem.eql(u8, tp, "Apple_Terminal")) return .apple_terminal;
    if (std.mem.eql(u8, tp, "vscode")) return if (vscode.isRemote(env)) .vscode_remote else .vscode;
    for (native_term_programs) |entry| if (std.mem.eql(u8, tp, entry[0])) return .{ .native = entry[1] };
    return .{ .other = tp };
}

// ── The install record ─────────────────────────────────────────────────────

pub const Record = struct {
    schema: u32 = 1,
    apple_terminal: ?AppleEntry = null,
    vscode: []const VscodeEntry = &.{},

    pub const AppleEntry = struct {
        domain: []const u8,
        profiles: []const apple.Installed,
        /// The Terminal process that was running when the mapping went in: it
        /// still sends a plain Return, a later one does not.
        terminal_pid: ?i32 = null,
        backups: []const []const u8 = &.{},
    };

    pub const VscodeEntry = struct {
        keybindings: []const u8,
        /// The file before the binding went in; null when there was no file.
        backup: ?[]const u8 = null,
    };
};

fn setupDir(arena: std.mem.Allocator, state_root: []const u8) error{OutOfMemory}![]const u8 {
    return std.fs.path.join(arena, &.{ state_root, "terminal-setup" });
}

fn recordPath(arena: std.mem.Allocator, state_root: []const u8) error{OutOfMemory}![]const u8 {
    return std.fs.path.join(arena, &.{ state_root, "terminal-setup", "installed.json" });
}

/// The record under `state_root`; empty when there is none (or it is not one).
pub fn loadRecord(arena: std.mem.Allocator, state_root: []const u8) Record {
    if (state_root.len == 0) return .{};
    const path = recordPath(arena, state_root) catch return .{};
    const bytes = files.read(arena, path) catch return .{};
    return std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

fn saveRecord(arena: std.mem.Allocator, state_root: []const u8, record: Record) !void {
    const path = try recordPath(arena, state_root);
    if (record.apple_terminal == null and record.vscode.len == 0) {
        files.remove(path);
        return;
    }
    const body = try std.json.Stringify.valueAlloc(arena, record, .{ .whitespace = .indent_2 });
    try files.writeAtomic(path, body, true);
}

// ── Running the command ────────────────────────────────────────────────────

pub const Action = enum {
    install,
    /// Undo what the record says this command did.
    restore,
    /// Say what `install` would change, and change nothing.
    preview,
};

/// What to configure when the user names it instead of detection.
pub const Target = union(enum) {
    apple_terminal,
    vscode: vscode.Product,
    /// A `keybindings.json` of a VS Code build (custom `--user-data-dir`, a profile).
    keybindings: []const u8,
};

pub const Request = struct {
    action: Action = .install,
    target: ?Target = null,
};

pub const Context = struct {
    env: Env,
    state_root: []const u8,
    apple: apple.Store = .{},
    now_unix: i64,
    /// The Terminal.app process this one runs under (`apple.terminalPid`).
    terminal_pid: ?i32 = null,
    /// How to spell the undo command where the report is read.
    restore_hint: []const u8 = "metacodes terminal-setup --restore",
};

pub const Outcome = enum { changed, unchanged, refused, failed };

pub const Report = struct {
    outcome: Outcome,
    /// What the footer's newline hint should say from now on, when this run
    /// settles it: a VS Code binding takes effect at once; an Apple Terminal
    /// mapping only once Terminal is reopened, so it leaves the hint (null).
    binding_live: ?bool = null,
};

fn say(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    out.print(fmt ++ "\n", args) catch {};
}

/// `bytes` with control characters spelled out (`\e`, `\r`, `\xNN`), for a
/// mapping's value in a message.
fn printable(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |c| switch (c) {
        0x1b => try out.appendSlice(arena, "\\e"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => try out.print(arena, "\\x{x:0>2}", .{c}),
        else => try out.append(arena, c),
    };
    return out.items;
}

const effect_note = "Shift+Enter sends Esc+Return to every program there, not only to metacodes: zsh, for one, inserts a line break instead of running the command.";

/// Runs `req`, writing what it found, what it changes, where the backup goes
/// and what happened to `out`, in that order.
pub fn run(gpa: std.mem.Allocator, ctx: Context, req: Request, out: *std.Io.Writer) Report {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return runIn(arena, ctx, req, out) catch |err| {
        say(out, "Terminal setup failed: {s}.", .{@errorName(err)});
        return .{ .outcome = .failed };
    };
}

fn runIn(arena: std.mem.Allocator, ctx: Context, req: Request, out: *std.Io.Writer) !Report {
    if (req.action == .restore) return restoreAll(arena, ctx, req.target, out);
    const target: Target = req.target orelse switch (detect(ctx.env)) {
        .apple_terminal => .apple_terminal,
        .vscode => .{ .vscode = vscode.product(arena, ctx.env) },
        .vscode_remote => {
            say(out, "Terminal: VS Code, attached to another machine (remote, WSL or container).", .{});
            say(out, "Its key bindings live on the machine that shows the window, not here. There, open the Command Palette, run \"Preferences: Open Keyboard Shortcuts (JSON)\", and add:", .{});
            say(out, "{s}", .{vscode.manual_snippet});
            say(out, "(or run `metacodes terminal-setup` in a terminal on that machine).", .{});
            return .{ .outcome = .refused };
        },
        .native => |name| {
            say(out, "Terminal: {s}. It reports Shift+Enter distinctly and metacodes turns its keyboard protocol on there: Shift+Enter already inserts a newline. Nothing to set up.", .{name});
            return .{ .outcome = .unchanged };
        },
        .tmux => {
            say(out, "Terminal: tmux. metacodes cannot configure tmux, and the terminal around it is not visible from here.", .{});
            say(out, "Run /terminal-setup in that terminal outside tmux if it needs setup. For Shift+Enter inside tmux, tmux must forward extended keys in CSI u form (see `extended-keys` and `extended-keys-format` in tmux(1)).", .{});
            say(out, "Without it, end a line with \\ and press Enter for a newline.", .{});
            return .{ .outcome = .refused };
        },
        .other => |name| {
            say(out, "Terminal: {s}. metacodes has no setup for it.", .{name orelse "not recognized (TERM_PROGRAM is not set)"});
            say(out, "To get a newline from Shift+Enter, bind Shift+Enter in the terminal's own settings to send Esc followed by Return (the bytes 1b 0d, often written \\e\\r or \\u001b\\r); metacodes reads that as a newline.", .{});
            say(out, "  Alacritty (alacritty.toml): [[keyboard.bindings]] key = \"Return\", mods = \"Shift\", chars = \"\\u001b\\r\"", .{});
            say(out, "Apple Terminal and VS Code (or Cursor, Windsurf, VSCodium) can be set up from here: metacodes terminal-setup --terminal apple-terminal|vscode|cursor|windsurf|vscodium.", .{});
            say(out, "Until then, end a line with \\ and press Enter for a newline.", .{});
            return .{ .outcome = .unchanged };
        },
    };
    if (ctx.state_root.len == 0) {
        say(out, "Terminal setup needs metacodes' state directory for its backup and record, and none is set (--state-dir / METACODES_HOME / HOME).", .{});
        return .{ .outcome = .refused };
    }
    return switch (target) {
        .apple_terminal => installApple(arena, ctx, req.action == .preview, out),
        .vscode => |p| blk: {
            const path = try vscode.keybindingsPath(arena, ctx.env, p) orelse {
                say(out, "Terminal: {s}. No home directory to find its keybindings.json under; pass it with --keybindings <file>.", .{p.display});
                break :blk .{ .outcome = .refused };
            };
            break :blk installVscode(arena, ctx, p.display, p.data_folder, path, req.action == .preview, out);
        },
        .keybindings => |path| installVscode(arena, ctx, "VS Code", "vscode", path, req.action == .preview, out),
    };
}

fn installVscode(arena: std.mem.Allocator, ctx: Context, display: []const u8, folder: []const u8, path: []const u8, preview: bool, out: *std.Io.Writer) !Report {
    say(out, "Terminal: {s} (integrated terminal).", .{display});
    const user_dir = std.fs.path.dirname(path) orelse path;
    if (!files.exists(user_dir)) {
        say(out, "Its settings folder is not at {s}. For an install started with --user-data-dir, a portable one, or a profile with its own shortcuts, name the file: metacodes terminal-setup --keybindings <path to keybindings.json>.", .{user_dir});
        return .{ .outcome = .refused };
    }
    const src: ?[]const u8 = files.read(arena, path) catch |err| switch (err) {
        error.NotFound => null,
        else => {
            say(out, "Could not read {s} ({s}).", .{ path, @errorName(err) });
            return .{ .outcome = .failed };
        },
    };
    const status = vscode.classify(arena, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJsonc, error.NotAnArray => {
            say(out, "{s} is not a list of key bindings ({s}): left unchanged. Fix it in {s}, then run this again.", .{ path, if (err == error.NotAnArray) "its top level is not an array" else "it does not parse", display });
            return .{ .outcome = .refused };
        },
    };
    switch (status) {
        .installed => {
            say(out, "Already set up: {s} makes Shift+Enter send Esc+Return in the terminal, which metacodes reads as a newline. Nothing changed.", .{path});
            return .{ .outcome = .unchanged, .binding_live = true };
        },
        .conflict => |text| {
            say(out, "{s} already binds Shift+Enter in the terminal:", .{path});
            say(out, "{s}", .{text});
            say(out, "Left unchanged. Remove that binding, or give it a \"when\" that leaves the terminal out (\"editorTextFocus\"), then run this again.", .{});
            return .{ .outcome = .refused };
        },
        .absent => {},
    }
    say(out, "Adds to {s}{s}:", .{ path, if (src == null) " (a new file)" else "" });
    say(out, "  shift+enter -> workbench.action.terminal.sendSequence \"\\u001b\\r\" (when terminalFocus)", .{});
    const dir = try setupDir(arena, ctx.state_root);
    const stem = try std.fmt.allocPrint(arena, "{s}-keybindings", .{try fileStem(arena, folder)});
    const backup: ?[]const u8 = if (src != null) try files.freshName(arena, dir, stem, ".json", ctx.now_unix) else null;
    if (backup) |b| say(out, "Backup: {s}", .{b});
    if (preview) {
        say(out, "Dry run: nothing changed.", .{});
        return .{ .outcome = .unchanged };
    }
    const updated = try vscode.withBinding(arena, src);
    if (backup) |b| files.writeAtomic(b, src.?, true) catch |err| {
        say(out, "Could not write the backup ({s}): left unchanged.", .{@errorName(err)});
        return .{ .outcome = .failed };
    };
    files.writeAtomic(path, updated, false) catch |err| {
        say(out, "Could not write {s} ({s}): left unchanged.", .{ path, @errorName(err) });
        return .{ .outcome = .failed };
    };
    const written = files.read(arena, path) catch null;
    if (written == null or (vscode.classify(arena, written) catch Status.absent) != .installed) {
        say(out, "{s} did not read back with the binding in it.", .{path});
        return .{ .outcome = .failed };
    }

    var record = loadRecord(arena, ctx.state_root);
    var entries: std.ArrayList(Record.VscodeEntry) = .empty;
    for (record.vscode) |e| if (!std.mem.eql(u8, e.keybindings, path)) try entries.append(arena, e);
    try entries.append(arena, .{ .keybindings = path, .backup = backup });
    record.vscode = entries.items;
    saveRecord(arena, ctx.state_root, record) catch |err| say(out, "Note: could not save the install record ({s}); undo it by hand from the backup.", .{@errorName(err)});

    say(out, "Done. {s} reloads keybindings.json by itself: Shift+Enter inserts a newline in metacodes now.", .{display});
    say(out, "{s}", .{effect_note});
    say(out, "Undo: {s}", .{ctx.restore_hint});
    return .{ .outcome = .changed, .binding_live = true };
}

const Status = vscode.Status;

/// A name safe as part of a file name.
fn fileStem(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    const out = try arena.dupe(u8, name);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_' and c.* != '.') c.* = '-';
    }
    return out;
}

fn workPath(arena: std.mem.Allocator, dir: []const u8, what: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}apple-terminal.{s}-{d}.plist", .{ dir, std.fs.path.sep_str, what, process.currentPid() });
}

fn installApple(arena: std.mem.Allocator, ctx: Context, preview: bool, out: *std.Io.Writer) !Report {
    say(out, "Terminal: Apple Terminal.", .{});
    if (builtin.os.tag != .macos) {
        say(out, "Its settings are on the Mac it runs on: run `metacodes terminal-setup` there.", .{});
        return .{ .outcome = .refused };
    }
    const dir = try setupDir(arena, ctx.state_root);
    util_fs.mkdirParents(dir) catch {
        say(out, "Could not create {s} for the backup: left unchanged.", .{dir});
        return .{ .outcome = .failed };
    };
    const work = try workPath(arena, dir, "work");
    defer files.remove(work);
    const prefs = apple.Prefs.exportTo(arena, ctx.apple, work) catch {
        say(out, "Could not read Terminal's settings (`defaults export {s}` failed): left unchanged.", .{ctx.apple.domain});
        return .{ .outcome = .failed };
    };
    const plan = try apple.plan(&prefs);
    const ready = switch (plan) {
        .ready => |r| r,
        .not_saved => {
            say(out, "Terminal has not saved any profiles yet. Quit Terminal (Cmd+Q), open it again, then run this again.", .{});
            return .{ .outcome = .refused };
        },
        .unaddressable => |name| {
            say(out, "The profile \"{s}\" has a backslash in its name, which the settings tools cannot address: left unchanged. Rename the profile in Terminal > Settings > Profiles, then run this again.", .{name});
            return .{ .outcome = .refused };
        },
        .missing_profile => |name| {
            say(out, "Terminal's settings name the profile \"{s}\", which is not among its saved profiles: left unchanged. Pick a default profile in Terminal > Settings > Profiles, then run this again.", .{name});
            return .{ .outcome = .refused };
        },
        .conflict => |c| {
            say(out, "Shift+Return in the profile \"{s}\" already sends {s}: left unchanged.", .{ c.profile, try printable(arena, c.value) });
            say(out, "Remove that key in Terminal > Settings > Profiles > {s} > Keyboard, then run this again.", .{c.profile});
            return .{ .outcome = .refused };
        },
    };
    const previous = loadRecord(arena, ctx.state_root).apple_terminal;
    if (ready.steps.len == 0) {
        say(out, "Already set up: Shift+Return in the profile{s} {s} sends Esc+Return, which metacodes reads as a newline. Nothing changed.", .{ if (ready.already.len > 1) "s" else "", try quotedList(arena, ready.already) });
        if (previous) |p| if (p.terminal_pid != null and ctx.terminal_pid != null and p.terminal_pid.? == ctx.terminal_pid.?)
            say(out, "This Terminal was running when it was set up: quit it (Cmd+Q) and open it again for Shift+Return to send the newline.", .{});
        return .{ .outcome = .unchanged };
    }

    say(out, "Changes Terminal's settings (the {s} domain), only Shift+Return in:", .{ctx.apple.domain});
    for (ready.steps) |step| {
        if (step.seed) {
            say(out, "  the profile \"{s}\": it has no key map of its own, so it gets a copy of Terminal's built-in one (a profile's own map replaces the built-in one) with Shift+Return -> Esc+Return added", .{step.profile});
        } else {
            say(out, "  the profile \"{s}\": Shift+Return -> Esc+Return added to its key map", .{step.profile});
        }
    }
    const backup = try files.freshName(arena, dir, "apple-terminal", ".plist", ctx.now_unix);
    say(out, "Backup (the whole of Terminal's settings): {s}", .{backup});
    if (preview) {
        say(out, "Dry run: nothing changed.", .{});
        return .{ .outcome = .unchanged };
    }
    const snapshot = try files.read(arena, work);
    files.writeAtomic(backup, snapshot, true) catch |err| {
        say(out, "Could not write the backup ({s}): left unchanged.", .{@errorName(err)});
        return .{ .outcome = .failed };
    };
    const names = try arena.alloc([]const u8, ready.steps.len);
    for (ready.steps, names) |step, *n| n.* = step.profile;
    const verify_path = try workPath(arena, dir, "verify");
    defer files.remove(verify_path);
    const applied = blk: {
        apple.apply(&prefs, ready.steps) catch break :blk false;
        break :blk apple.verify(arena, ctx.apple, verify_path, names) catch false;
    };
    if (!applied) {
        const rolled_back = rollback(arena, ctx.apple, backup);
        say(out, "Terminal's settings did not take the change; {s}.", .{if (rolled_back) "they are back as they were" else "restoring them failed too"});
        say(out, "To put them back by hand: defaults import {s} '{s}'", .{ ctx.apple.domain, backup });
        return .{ .outcome = .failed };
    }

    var record = loadRecord(arena, ctx.state_root);
    var installed: std.ArrayList(apple.Installed) = .empty;
    var backups: std.ArrayList([]const u8) = .empty;
    if (previous) |p| {
        try installed.appendSlice(arena, p.profiles);
        try backups.appendSlice(arena, p.backups);
    }
    for (ready.steps) |step| {
        for (installed.items) |*seen| {
            if (std.mem.eql(u8, seen.profile, step.profile)) {
                seen.seeded = seen.seeded or step.seed;
                break;
            }
        } else try installed.append(arena, .{ .profile = step.profile, .seeded = step.seed });
    }
    try backups.append(arena, backup);
    record.apple_terminal = .{ .domain = ctx.apple.domain, .profiles = installed.items, .terminal_pid = ctx.terminal_pid, .backups = backups.items };
    saveRecord(arena, ctx.state_root, record) catch |err| say(out, "Note: could not save the install record ({s}); `--restore` will not find this change. The backup above has the settings as they were.", .{@errorName(err)});

    say(out, "Done. Quit Terminal (Cmd+Q) and open it again: it reads its profiles when it starts, so this window and any new one keep sending a plain Return until then.", .{});
    say(out, "{s}", .{effect_note});
    say(out, "Undo: {s}. To put back all of Terminal's settings as they were: defaults import {s} '{s}' (with Terminal quit).", .{ ctx.restore_hint, ctx.apple.domain, backups.items[0] });
    return .{ .outcome = .changed };
}

fn rollback(arena: std.mem.Allocator, store: apple.Store, backup: []const u8) bool {
    const prefs: apple.Prefs = .{ .arena = arena, .store = store, .path = backup };
    prefs.importBack() catch return false;
    return true;
}

fn quotedList(arena: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "\"{s}\"", .{n});
    }
    return out.items;
}

fn restoreAll(arena: std.mem.Allocator, ctx: Context, target: ?Target, out: *std.Io.Writer) !Report {
    var record = loadRecord(arena, ctx.state_root);
    const want_apple = if (target) |t| t == .apple_terminal else true;
    const want_vscode = if (target) |t| t != .apple_terminal else true;
    const has_apple = want_apple and record.apple_terminal != null;
    const has_vscode = want_vscode and record.vscode.len > 0;
    if (!has_apple and !has_vscode) {
        const where = if (ctx.state_root.len > 0) try recordPath(arena, ctx.state_root) else "(no state directory)";
        say(out, "Nothing to undo: no terminal setup is recorded in {s}.", .{where});
        return .{ .outcome = .unchanged };
    }
    var outcome: Outcome = .unchanged;
    var binding_live: ?bool = null;

    if (has_apple) apple_blk: {
        const entry = record.apple_terminal.?;
        say(out, "Apple Terminal: undoing Shift+Return in {s}.", .{try quotedList(arena, try profileNames(arena, entry.profiles))});
        if (builtin.os.tag != .macos) {
            say(out, "  Its settings are on the Mac it runs on: run `metacodes terminal-setup --restore` there.", .{});
            outcome = .refused;
            break :apple_blk;
        }
        const store: apple.Store = .{ .domain = entry.domain, .app = ctx.apple.app };
        const dir = try setupDir(arena, ctx.state_root);
        const work = try workPath(arena, dir, "work");
        defer files.remove(work);
        const undone = blk: {
            const prefs = apple.Prefs.exportTo(arena, store, work) catch break :blk null;
            break :blk apple.restore(&prefs, entry.profiles) catch null;
        } orelse {
            say(out, "  Could not change Terminal's settings: left as they are. The settings from before setup: defaults import {s} '{s}'", .{ entry.domain, if (entry.backups.len > 0) entry.backups[0] else "(no backup recorded)" });
            outcome = .failed;
            break :apple_blk;
        };
        var any = false;
        for (entry.profiles, undone) |p, u| {
            switch (u) {
                .removed_map => say(out, "  \"{s}\": the key map setup added is gone; the profile uses Terminal's built-in one again.", .{p.profile}),
                .removed_key => say(out, "  \"{s}\": Shift+Return removed from its key map.", .{p.profile}),
                .changed_since => say(out, "  \"{s}\": Shift+Return sends something else now: left alone.", .{p.profile}),
                .gone => say(out, "  \"{s}\": no Shift+Return mapping any more: nothing to undo.", .{p.profile}),
            }
            if (u == .removed_map or u == .removed_key) any = true;
        }
        record.apple_terminal = null;
        if (any) {
            outcome = .changed;
            say(out, "  Quit Terminal (Cmd+Q) and open it again for this to take effect.", .{});
        }
        if (entry.backups.len > 0) say(out, "  Backups kept in {s}.", .{dir});
    }

    if (has_vscode) {
        var kept: std.ArrayList(Record.VscodeEntry) = .empty;
        for (record.vscode) |entry| {
            if (target) |t| if (t == .keybindings and !std.mem.eql(u8, t.keybindings, entry.keybindings)) {
                try kept.append(arena, entry);
                continue;
            };
            const src = files.read(arena, entry.keybindings) catch |err| {
                if (err == error.NotFound) {
                    say(out, "{s}: gone; nothing to undo.", .{entry.keybindings});
                } else {
                    say(out, "{s}: could not read it ({s}); left as it is.", .{ entry.keybindings, @errorName(err) });
                    try kept.append(arena, entry);
                    outcome = .failed;
                }
                continue;
            };
            const updated = (vscode.withoutBinding(arena, src) catch null) orelse {
                say(out, "{s}: the binding setup added is not in it any more; nothing to undo.", .{entry.keybindings});
                continue;
            };
            files.writeAtomic(entry.keybindings, updated, false) catch |err| {
                say(out, "{s}: could not write it ({s}); left as it is.", .{ entry.keybindings, @errorName(err) });
                try kept.append(arena, entry);
                outcome = .failed;
                continue;
            };
            say(out, "{s}: the Shift+Enter binding setup added is removed.", .{entry.keybindings});
            if (entry.backup) |b| say(out, "  The file as it was before setup: {s}", .{b});
            if (outcome != .failed) outcome = .changed;
            binding_live = (vscode.classify(arena, updated) catch Status.absent) == .installed;
        }
        record.vscode = kept.items;
    }
    if (ctx.state_root.len > 0) saveRecord(arena, ctx.state_root, record) catch |err| say(out, "Note: could not update the install record ({s}).", .{@errorName(err)});
    return .{ .outcome = outcome, .binding_live = binding_live };
}

fn profileNames(arena: std.mem.Allocator, profiles: []const apple.Installed) error{OutOfMemory}![]const []const u8 {
    const names = try arena.alloc([]const u8, profiles.len);
    for (profiles, names) |p, *n| n.* = p.profile;
    return names;
}

// ── The footer hint ────────────────────────────────────────────────────────

/// Whether Shift+Enter reaches this session as a newline through a terminal
/// binding, so the footer can say so (`input.recordNewlineBinding`):
/// - VS Code: its `keybindings.json` binds Shift+Enter to the newline sequence
///   (whoever wrote it; a file read);
/// - Apple Terminal: this command recorded a mapping, Terminal has been
///   reopened since (a different pid), and the mapping is still in its
///   preferences (one plutil run, paid only by sessions that ran setup).
pub fn bindingLive(gpa: std.mem.Allocator, env: Env, state_root: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (detect(env)) {
        .vscode => {
            const path = (vscode.keybindingsPath(arena, env, vscode.product(arena, env)) catch return false) orelse return false;
            const src = files.read(arena, path) catch return false;
            return (vscode.classify(arena, src) catch return false) == .installed;
        },
        .apple_terminal => {
            if (builtin.os.tag != .macos) return false;
            const entry = loadRecord(arena, state_root).apple_terminal orelse return false;
            return appleLive(arena, entry, apple.terminalPid(), env.home);
        },
        else => return false,
    }
}

/// `bindingLive` for this process's environment. Cheap when the terminal is
/// neither VS Code nor Apple Terminal: one look at the environment.
pub fn bindingLiveHere(gpa: std.mem.Allocator, state_root: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const env = Env.fromProcess(arena_state.allocator()) catch return false;
    return bindingLive(gpa, env, state_root);
}

/// The preferences file behind a `defaults` domain: an absolute domain is a
/// file path without its `.plist`; a name lives in `~/Library/Preferences`.
fn prefsFile(arena: std.mem.Allocator, domain: []const u8, home: ?[]const u8) error{OutOfMemory}!?[]const u8 {
    if (std.fs.path.isAbsolute(domain)) return try std.fmt.allocPrint(arena, "{s}.plist", .{domain});
    const h = home orelse return null;
    return try std.fs.path.join(arena, &.{ h, "Library", "Preferences", try std.fmt.allocPrint(arena, "{s}.plist", .{domain}) });
}

fn appleLive(arena: std.mem.Allocator, entry: Record.AppleEntry, terminal_pid: ?i32, home: ?[]const u8) bool {
    // Not under Terminal, or under the very Terminal that was running when the
    // mapping went in: it sends a plain Return still.
    const pid = terminal_pid orelse return false;
    if (entry.terminal_pid) |installed_under| if (installed_under == pid) return false;
    const file = (prefsFile(arena, entry.domain, home) catch return false) orelse return false;
    const names = profileNames(arena, entry.profiles) catch return false;
    return apple.mapped(arena, file, names);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the newline sequence is what KeyParser reads as Shift+Enter" {
    const input = @import("../../repl/input.zig");
    var parser: input.KeyParser = .{};
    var keys: std.ArrayList(input.Key) = .empty;
    defer keys.deinit(testing.allocator);
    for (newline_sequence) |b| {
        if (parser.feed(b)) |k| try keys.append(testing.allocator, k);
        while (parser.drain()) |k| try keys.append(testing.allocator, k);
    }
    try testing.expectEqual(@as(usize, 1), keys.items.len);
    try testing.expect(keys.items[0] == .shift_enter);
    try testing.expect(!parser.pendingEsc());
}

test "detect: the terminals with a setup, the native ones, and the rest" {
    try testing.expect(detect(.{ .term_program = "Apple_Terminal", .term = "xterm-256color" }) == .apple_terminal);
    try testing.expect(detect(.{ .term_program = "vscode", .term = "xterm-256color" }) == .vscode);
    try testing.expect(detect(.{ .term_program = "vscode", .remote_session = true }) == .vscode_remote);
    try testing.expectEqualStrings("iTerm2", detect(.{ .term_program = "iTerm.app" }).native);
    try testing.expectEqualStrings("Warp", detect(.{ .term_program = "WarpTerminal" }).native);
    try testing.expectEqualStrings("Ghostty", detect(.{ .term_program = "ghostty" }).native);
    try testing.expectEqualStrings("WezTerm", detect(.{ .term_program = "WezTerm" }).native);
    // TERM is the terminal's own: kitty started from Terminal.app is kitty.
    try testing.expectEqualStrings("kitty", detect(.{ .term_program = "Apple_Terminal", .term = "xterm-kitty" }).native);
    try testing.expect(detect(.{ .term_program = "Apple_Terminal", .tmux = true }) == .tmux);
    try testing.expectEqualStrings("Hyper", detect(.{ .term_program = "Hyper" }).other.?);
    try testing.expect(detect(.{}).other == null);
}

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    out: std.Io.Writer.Allocating,

    fn init() !*Harness {
        const h = try testing.allocator.create(Harness);
        h.* = .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = undefined, .out = .init(testing.allocator) };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        h.root = try h.arena_state.allocator().dupe(u8, buf[0..try h.tmp.dir.realPath(testing.io, &buf)]);
        return h;
    }

    fn deinit(h: *Harness) void {
        h.out.deinit();
        h.tmp.cleanup();
        h.arena_state.deinit();
        testing.allocator.destroy(h);
    }

    fn join(h: *Harness, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(h.arena_state.allocator(), h.root);
        try all.appendSlice(h.arena_state.allocator(), parts);
        return std.fs.path.join(h.arena_state.allocator(), all.items);
    }

    fn ctx(h: *Harness, env: Env) !Context {
        return .{ .env = env, .state_root = try h.join(&.{"state"}), .now_unix = 1_793_240_134 };
    }

    fn report(h: *Harness) []const u8 {
        return h.out.written();
    }

    fn reset(h: *Harness) void {
        h.out.clearRetainingCapacity();
    }
};

test "run vscode: a missing file is created, a second run changes nothing, restore removes the binding" {
    const h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(testing.io, "appdata/Code/User");
    const env: Env = .{ .term_program = "vscode", .os = .windows, .home = h.root, .appdata = try h.join(&.{"appdata"}) };
    const ctx = try h.ctx(env);
    const file = try h.join(&.{ "appdata", "Code", "User", "keybindings.json" });

    const first = run(testing.allocator, ctx, .{}, &h.out.writer);
    try testing.expectEqual(Outcome.changed, first.outcome);
    try testing.expectEqual(@as(?bool, true), first.binding_live);
    try testing.expect(std.mem.indexOf(u8, h.report(), "(a new file)") != null);
    // No file before, so no backup.
    try testing.expect(std.mem.indexOf(u8, h.report(), "Backup:") == null);
    try testing.expect(bindingLive(testing.allocator, env, ctx.state_root));
    const written = try files.read(h.arena_state.allocator(), file);
    try testing.expectEqual(Status.installed, try vscode.classify(testing.allocator, written));

    h.reset();
    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, ctx, .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Already set up") != null);

    h.reset();
    const undo = run(testing.allocator, ctx, .{ .action = .restore }, &h.out.writer);
    try testing.expectEqual(Outcome.changed, undo.outcome);
    try testing.expectEqual(@as(?bool, false), undo.binding_live);
    const after = try files.read(h.arena_state.allocator(), file);
    try testing.expectEqual(Status.absent, try vscode.classify(testing.allocator, after));
    try testing.expect(!bindingLive(testing.allocator, env, ctx.state_root));
    // The record is gone with the last entry.
    try testing.expect(loadRecord(h.arena_state.allocator(), ctx.state_root).vscode.len == 0);
    h.reset();
    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, ctx, .{ .action = .restore }, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Nothing to undo") != null);
}

test "run vscode: comments and trailing commas survive, the backup is the file before, restore gives it back" {
    const h = try Harness.init();
    defer h.deinit();
    const original =
        \\// Place your key bindings in this file to override the defaults
        \\[
        \\    // copy line
        \\    { "key": "ctrl+shift+d", "command": "editor.action.copyLinesDownAction" },
        \\]
    ;
    try h.tmp.dir.createDirPath(testing.io, "cfg/Cursor/User");
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "cfg/Cursor/User/keybindings.json", .data = original });
    const env: Env = .{ .term_program = "vscode", .cursor_trace_id = true, .os = .other, .home = h.root, .xdg_config_home = try h.join(&.{"cfg"}) };
    const ctx = try h.ctx(env);
    const file = try h.join(&.{ "cfg", "Cursor", "User", "keybindings.json" });

    // A dry run says where things go and touches nothing.
    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, ctx, .{ .action = .preview }, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Terminal: Cursor") != null);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Dry run") != null);
    try testing.expectEqualStrings(original, try files.read(h.arena_state.allocator(), file));

    h.reset();
    const installed = run(testing.allocator, ctx, .{}, &h.out.writer);
    if (installed.outcome != .changed) std.debug.print("report:\n{s}\n", .{h.report()});
    try testing.expectEqual(Outcome.changed, installed.outcome);
    const backup = try h.join(&.{ "state", "terminal-setup", "Cursor-keybindings-20261029-021534.json" });
    try testing.expect(std.mem.indexOf(u8, h.report(), backup) != null);
    try testing.expectEqualStrings(original, try files.read(h.arena_state.allocator(), backup));
    const changed = try files.read(h.arena_state.allocator(), file);
    try testing.expect(std.mem.indexOf(u8, changed, "// copy line") != null);

    h.reset();
    try testing.expectEqual(Outcome.changed, run(testing.allocator, ctx, .{ .action = .restore }, &h.out.writer).outcome);
    try testing.expectEqualStrings(original, try files.read(h.arena_state.allocator(), file));
}

test "run vscode: a conflicting binding and a broken file are left alone, without a backup" {
    const h = try Harness.init();
    defer h.deinit();
    const conflicting =
        \\[{ "key": "shift+enter", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\n" }, "when": "terminalFocus" }]
    ;
    try h.tmp.dir.createDirPath(testing.io, "home/Library/Application Support/Code/User");
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/Library/Application Support/Code/User/keybindings.json", .data = conflicting });
    const env: Env = .{ .term_program = "vscode", .os = .macos, .home = try h.join(&.{"home"}) };
    const ctx = try h.ctx(env);
    const file = try h.join(&.{ "home", "Library", "Application Support", "Code", "User", "keybindings.json" });

    try testing.expectEqual(Outcome.refused, run(testing.allocator, ctx, .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "already binds Shift+Enter") != null);
    try testing.expect(std.mem.indexOf(u8, h.report(), "\"text\": \"\\n\"") != null);
    try testing.expectEqualStrings(conflicting, try files.read(h.arena_state.allocator(), file));
    try testing.expect(!files.exists(try h.join(&.{ "state", "terminal-setup" })));
    try testing.expect(!bindingLive(testing.allocator, env, ctx.state_root));

    h.reset();
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/Library/Application Support/Code/User/keybindings.json", .data = "[{" });
    try testing.expectEqual(Outcome.refused, run(testing.allocator, ctx, .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "does not parse") != null);

    // A settings folder that is not there is not created.
    h.reset();
    const nowhere: Env = .{ .term_program = "vscode", .os = .macos, .home = try h.join(&.{"nobody"}) };
    try testing.expectEqual(Outcome.refused, run(testing.allocator, try h.ctx(nowhere), .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "--keybindings") != null);
}

test "run: native terminals, tmux and unknown ones change nothing" {
    const h = try Harness.init();
    defer h.deinit();
    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, try h.ctx(.{ .term_program = "iTerm.app" }), .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "iTerm2") != null);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Nothing to set up") != null);
    h.reset();
    try testing.expectEqual(Outcome.refused, run(testing.allocator, try h.ctx(.{ .tmux = true }), .{}, &h.out.writer).outcome);
    h.reset();
    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, try h.ctx(.{ .term_program = "Hyper" }), .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "\\e\\r") != null);
    h.reset();
    try testing.expectEqual(Outcome.refused, run(testing.allocator, try h.ctx(.{ .term_program = "vscode", .remote_session = true }), .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "workbench.action.terminal.sendSequence") != null);
    try testing.expect(!files.exists(try h.join(&.{"state"})));
}

test "appleLive: only a Terminal reopened since setup, with the mapping still there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry: Record.AppleEntry = .{ .domain = "/nonexistent/terminal", .profiles = &.{.{ .profile = "Basic", .seeded = true }}, .terminal_pid = 100 };
    // Not under Terminal, or under the one that was running at setup.
    try testing.expect(!appleLive(arena, entry, null, null));
    try testing.expect(!appleLive(arena, entry, 100, null));
    // Reopened, but the preferences do not have the mapping (here: no file).
    try testing.expect(!appleLive(arena, entry, 200, null));
    const want = try std.fs.path.join(arena, &.{ "/Users/a", "Library", "Preferences", "com.apple.Terminal.plist" });
    try testing.expectEqualStrings(want, (try prefsFile(arena, "com.apple.Terminal", "/Users/a")).?);
    try testing.expect((try prefsFile(arena, "com.apple.Terminal", null)) == null);
}

test "record: round trip, and an empty record removes the file" {
    const h = try Harness.init();
    defer h.deinit();
    const arena = h.arena_state.allocator();
    const root = try h.join(&.{"state"});
    const rec: Record = .{
        .apple_terminal = .{ .domain = "com.apple.Terminal", .profiles = &.{.{ .profile = "Clear Dark", .seeded = true }}, .terminal_pid = 4064, .backups = &.{"/b/apple-terminal-1.plist"} },
        .vscode = &.{.{ .keybindings = "/k.json", .backup = null }},
    };
    try saveRecord(arena, root, rec);
    const back = loadRecord(arena, root);
    try testing.expectEqualStrings("Clear Dark", back.apple_terminal.?.profiles[0].profile);
    try testing.expect(back.apple_terminal.?.profiles[0].seeded);
    try testing.expectEqual(@as(?i32, 4064), back.apple_terminal.?.terminal_pid);
    try testing.expectEqualStrings("/k.json", back.vscode[0].keybindings);
    try saveRecord(arena, root, .{});
    try testing.expect(!files.exists(try recordPath(arena, root)));
    // Garbage reads as no record.
    try h.tmp.dir.createDirPath(testing.io, "state/terminal-setup");
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "state/terminal-setup/installed.json", .data = "{nope" });
    try testing.expect(loadRecord(arena, root).apple_terminal == null);
}

test "printable spells out control characters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("\\e[13;2u", try printable(arena_state.allocator(), "\x1b[13;2u"));
    try testing.expectEqualStrings("\\e\\r\\x01", try printable(arena_state.allocator(), "\x1b\r\x01"));
}

test "run apple terminal (macOS): set up, a dry run, a second run, the record, restore" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const h = try Harness.init();
    defer h.deinit();
    const arena = h.arena_state.allocator();
    try h.tmp.dir.createDirPath(testing.io, "domain");
    // A path domain under the temporary directory, never the runner's own.
    const store: apple.Store = .{ .domain = try h.join(&.{ "domain", "terminal" }) };
    const seed_json = try h.join(&.{"seed.json"});
    const seed_plist = try h.join(&.{"seed.plist"});
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "seed.json", .data =
        \\{"Default Window Settings":"Basic","Startup Window Settings":"Basic","Window Settings":{"Basic":{"name":"Basic"}}}
    });
    const plist_ok = (try process.capture(&.{ "/usr/bin/plutil", "-convert", "binary1", "-o", (try arena.dupeZ(u8, seed_plist)).ptr, (try arena.dupeZ(u8, seed_json)).ptr, null }, arena, .{})).exit_code == 0;
    try testing.expect(plist_ok);
    const import_ok = (try process.capture(&.{ "/usr/bin/defaults", "import", (try arena.dupeZ(u8, store.domain)).ptr, (try arena.dupeZ(u8, seed_plist)).ptr, null }, arena, .{ .inherit_env = true })).exit_code == 0;
    try testing.expect(import_ok);

    var ctx = try h.ctx(.{ .term_program = "Apple_Terminal", .home = h.root });
    ctx.apple = store;
    ctx.terminal_pid = 4242;

    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, ctx, .{ .action = .preview }, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "copy of Terminal's built-in one") != null);
    try testing.expect(loadRecord(arena, ctx.state_root).apple_terminal == null);

    h.reset();
    const r = run(testing.allocator, ctx, .{}, &h.out.writer);
    try testing.expectEqual(Outcome.changed, r.outcome);
    try testing.expectEqual(@as(?bool, null), r.binding_live);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Quit Terminal") != null);
    const backup = try h.join(&.{ "state", "terminal-setup", "apple-terminal-20261029-021534.plist" });
    try testing.expect(files.exists(backup));
    const rec = loadRecord(arena, ctx.state_root).apple_terminal.?;
    try testing.expectEqualStrings("Basic", rec.profiles[0].profile);
    try testing.expect(rec.profiles[0].seeded);
    try testing.expectEqual(@as(?i32, 4242), rec.terminal_pid);
    // No work files left behind.
    try testing.expect(!files.exists(try workPath(arena, try setupDir(arena, ctx.state_root), "work")));

    // The footer: the same Terminal still sends Return; a reopened one maps it.
    try testing.expect(!appleLive(arena, rec, 4242, h.root));
    try testing.expect(appleLive(arena, rec, 4343, h.root));

    h.reset();
    try testing.expectEqual(Outcome.unchanged, run(testing.allocator, ctx, .{}, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "Already set up") != null);
    try testing.expect(std.mem.indexOf(u8, h.report(), "was running when it was set up") != null);

    h.reset();
    try testing.expectEqual(Outcome.changed, run(testing.allocator, ctx, .{ .action = .restore }, &h.out.writer).outcome);
    try testing.expect(std.mem.indexOf(u8, h.report(), "built-in one again") != null);
    try testing.expect(loadRecord(arena, ctx.state_root).apple_terminal == null);
    try testing.expect(!appleLive(arena, rec, 4343, h.root));
    try testing.expect(files.exists(backup));
}
