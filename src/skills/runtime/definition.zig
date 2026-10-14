const std = @import("std");
const frontmatter = @import("frontmatter.zig");

/// Skill execution mode. UI adapters may choose how to present it, but the
/// semantic value is owned by the shared Skill Runtime.
pub const ExecContext = enum { inline_ctx, fork };

/// Model-facing activation is behavioral routing metadata, not authority.
/// `required_first` asks a compatible provider dialect to select the Skill
/// tool once before ordinary work; dispatch and policy admission stay native.
pub const ModelActivation = enum {
    advisory,
    required_first,
};

/// Canonical parsed SKILL.md definition shared by every product adapter.
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// Claude Code `when_to_use`: appended to the description in listings.
    when_to_use: []const u8,
    /// Claude Code `argument-hint`: shown beside the command in the `/` menu.
    argument_hint: []const u8,
    body: []const u8,
    allowed_tools: []const []const u8,
    disallowed_tools: []const []const u8,
    arguments: []const []const u8,
    disable_model_invocation: bool,
    /// Claude Code `user-invocable: false` hides the Skill from the `/` menu
    /// while the model may still invoke it.
    user_invocable: bool,
    model_activation: ModelActivation = .advisory,
    context: ExecContext,
    agent: []const u8,
    model: []const u8,
    shell: []const u8,
    source_path: []const u8,

    pub fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.when_to_use);
        allocator.free(self.argument_hint);
        allocator.free(self.body);
        for (self.allowed_tools) |tool| allocator.free(tool);
        allocator.free(self.allowed_tools);
        for (self.disallowed_tools) |tool| allocator.free(tool);
        allocator.free(self.disallowed_tools);
        for (self.arguments) |argument| allocator.free(argument);
        allocator.free(self.arguments);
        allocator.free(self.agent);
        allocator.free(self.model);
        allocator.free(self.shell);
        allocator.free(self.source_path);
    }
};

pub const ParseError = error{
    OutOfMemory,
    MissingSkillName,
    InvalidFrontmatter,
    InvalidModelActivation,
    InvalidContext,
    InvalidShell,
    InvalidBoolean,
    InvalidFieldType,
};

pub const ParseOptions = struct {
    /// Claude Code fills a missing `description` with the first non-empty body
    /// line. AgentCore's canonical catalog keeps the field empty instead.
    description_fallback: bool = false,
};

/// Parse SKILL.md, using the directory name when frontmatter omits `name`.
///
/// The frontmatter is YAML (Claude Code and Codex both parse it as such), read
/// through the bounded subset parser in `frontmatter.zig`. Unknown keys are
/// ignored; the policy-bearing fields (`context`, `shell`, booleans,
/// `model-activation`) are validated strictly so a malformed value becomes a
/// typed failure instead of silently changing meaning.
pub fn parseSkillMdWithFallback(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
    dir_name: []const u8,
) ParseError!Skill {
    return parseSkillMdWithOptions(allocator, md, source_path, dir_name, .{});
}

pub fn parseSkillMdWithOptions(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
    dir_name: []const u8,
    options: ParseOptions,
) ParseError!Skill {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var body: []const u8 = md;
    var root: frontmatter.Node = .{ .mapping = &.{} };
    const split = frontmatter.splitFrontmatter(md) catch return error.InvalidFrontmatter;
    if (split) |parts| {
        body = parts.body;
        root = frontmatter.parse(arena, parts.yaml, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidYaml => return error.InvalidFrontmatter,
        };
    }

    var name = try optionalText(root, &.{"name"});
    var description = try optionalText(root, &.{"description"});
    const when_to_use = try optionalText(root, &.{ "when_to_use", "when-to-use" });
    const argument_hint = try optionalHint(arena, root, &.{ "argument-hint", "argument_hint" });
    const disable_invoke = try optionalBool(root, &.{ "disable-model-invocation", "disable_model_invocation" }) orelse false;
    const user_invocable = try optionalBool(root, &.{ "user-invocable", "user_invocable" }) orelse true;
    const model_activation: ModelActivation = if (try optionalText(root, &.{ "model-activation", "model_activation" })) |value|
        parseModelActivation(value) orelse return error.InvalidModelActivation
    else
        .advisory;
    const context: ExecContext = if (try optionalText(root, &.{"context"})) |value| blk: {
        if (value.len == 0 or std.mem.eql(u8, value, "inline")) break :blk .inline_ctx;
        if (std.mem.eql(u8, value, "fork")) break :blk .fork;
        return error.InvalidContext;
    } else .inline_ctx;
    const agent_str = try optionalText(root, &.{"agent"}) orelse "";
    const model_str = try optionalText(root, &.{"model"}) orelse "";
    const shell_str = if (try optionalText(root, &.{"shell"})) |value| blk: {
        if (value.len == 0) break :blk "bash";
        if (!std.mem.eql(u8, value, "bash") and !std.mem.eql(u8, value, "powershell"))
            return error.InvalidShell;
        break :blk value;
    } else "bash";

    if (name == null or name.?.len == 0) name = dir_name;
    if (name.?.len == 0) return error.MissingSkillName;
    if (description == null and options.description_fallback) description = firstBodyLine(body);

    const allowed_tools = try optionalList(allocator, root, &.{ "allowed-tools", "allowed_tools" });
    errdefer freeStringList(allocator, allowed_tools);
    const disallowed_tools = try optionalList(allocator, root, &.{ "disallowed-tools", "disallowed_tools" });
    errdefer freeStringList(allocator, disallowed_tools);
    const arguments = try optionalList(allocator, root, &.{"arguments"});
    errdefer freeStringList(allocator, arguments);

    const owned_name = try allocator.dupe(u8, name.?);
    errdefer allocator.free(owned_name);
    const owned_description = try allocator.dupe(u8, description orelse "");
    errdefer allocator.free(owned_description);
    const owned_when_to_use = try allocator.dupe(u8, when_to_use orelse "");
    errdefer allocator.free(owned_when_to_use);
    const owned_argument_hint = try allocator.dupe(u8, argument_hint orelse "");
    errdefer allocator.free(owned_argument_hint);
    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);
    const owned_agent = try allocator.dupe(u8, agent_str);
    errdefer allocator.free(owned_agent);
    const owned_model = try allocator.dupe(u8, model_str);
    errdefer allocator.free(owned_model);
    const owned_shell = try allocator.dupe(u8, shell_str);
    errdefer allocator.free(owned_shell);
    const owned_source_path = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source_path);

    return .{
        .name = owned_name,
        .description = owned_description,
        .when_to_use = owned_when_to_use,
        .argument_hint = owned_argument_hint,
        .body = owned_body,
        .allowed_tools = allowed_tools,
        .disallowed_tools = disallowed_tools,
        .arguments = arguments,
        .disable_model_invocation = disable_invoke,
        .user_invocable = user_invocable,
        .model_activation = model_activation,
        .context = context,
        .agent = owned_agent,
        .model = owned_model,
        .shell = owned_shell,
        .source_path = owned_source_path,
    };
}

/// Codex `agents/openai.yaml` sidecar policy relevant to discovery. Parsing
/// fails open (null), as Codex does: a broken sidecar never hides the Skill.
pub const CodexSidecar = struct {
    allow_implicit_invocation: bool = true,
};

pub fn parseCodexSidecar(allocator: std.mem.Allocator, yaml: []const u8) error{OutOfMemory}!?CodexSidecar {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = frontmatter.parse(scratch.allocator(), yaml, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidYaml => return null,
    };
    var sidecar = CodexSidecar{};
    if (root.get("policy")) |policy| {
        if (policy.get("allow_implicit_invocation")) |value| {
            const text = value.text() orelse return null;
            sidecar.allow_implicit_invocation = frontmatter.parseBool(text) orelse return null;
        }
    }
    return sidecar;
}

fn lookup(root: frontmatter.Node, keys: []const []const u8) ?frontmatter.Node {
    for (keys) |key| {
        if (root.get(key)) |value| return value;
    }
    return null;
}

fn optionalText(root: frontmatter.Node, keys: []const []const u8) ParseError!?[]const u8 {
    const node = lookup(root, keys) orelse return null;
    return node.text() orelse error.InvalidFieldType;
}

/// Claude Code documents `argument-hint: [issue-number]`, which YAML reads as a
/// one-item sequence; render a sequence back to its bracketed text.
fn optionalHint(arena: std.mem.Allocator, root: frontmatter.Node, keys: []const []const u8) ParseError!?[]const u8 {
    const node = lookup(root, keys) orelse return null;
    switch (node) {
        .scalar => |text| return text,
        .sequence => |items| {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (items, 0..) |item, index| {
                if (index != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, item.text() orelse return error.InvalidFieldType);
            }
            try out.append(arena, ']');
            return try out.toOwnedSlice(arena);
        },
        .mapping => return error.InvalidFieldType,
    }
}

fn optionalBool(root: frontmatter.Node, keys: []const []const u8) ParseError!?bool {
    const text = try optionalText(root, keys) orelse return null;
    return frontmatter.parseBool(text) orelse error.InvalidBoolean;
}

/// A list field is either a YAML sequence of scalars or one scalar using the
/// space/comma-separated Claude Code form.
fn optionalList(
    allocator: std.mem.Allocator,
    root: frontmatter.Node,
    keys: []const []const u8,
) ParseError![]const []const u8 {
    const node = lookup(root, keys) orelse return parseStringList(allocator, "");
    switch (node) {
        .scalar => |text| return parseStringList(allocator, text),
        .sequence => |items| {
            var out: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (out.items) |value| allocator.free(value);
                out.deinit(allocator);
            }
            for (items) |item| {
                const text = std.mem.trim(u8, item.text() orelse return error.InvalidFieldType, " \t");
                if (text.len == 0) continue;
                try appendOwnedString(allocator, &out, text);
            }
            return out.toOwnedSlice(allocator);
        },
        .mapping => return error.InvalidFieldType,
    }
}

fn firstBodyLine(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
}

pub fn parseSkillMd(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
) ParseError!Skill {
    return parseSkillMdWithFallback(allocator, md, source_path, "");
}

pub fn parseStringList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |value| allocator.free(value);
        out.deinit(allocator);
    }

    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        value = value[1 .. value.len - 1];
    }
    if (value.len == 0) return try out.toOwnedSlice(allocator);

    var depth: i32 = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= value.len) : (index += 1) {
        if (index == value.len or (value[index] == ',' and depth == 0)) {
            const segment = std.mem.trim(u8, value[start..index], " \t");
            if (segment.len > 0) {
                if (!hasParen(segment)) {
                    var tokens = std.mem.tokenizeAny(u8, segment, " \t");
                    while (tokens.next()) |token| {
                        const trimmed = std.mem.trim(u8, token, " \t");
                        if (trimmed.len > 0) {
                            try appendOwnedString(allocator, &out, trimmed);
                        }
                    }
                } else {
                    try appendOwnedString(allocator, &out, segment);
                }
            }
            start = index + 1;
            continue;
        }
        if (value[index] == '(') depth += 1;
        if (value[index] == ')') depth -= 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn appendOwnedString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try out.append(allocator, owned);
}

fn hasParen(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '(') != null;
}

pub fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn parseModelActivation(value: []const u8) ?ModelActivation {
    if (std.mem.eql(u8, value, "advisory")) return .advisory;
    if (std.mem.eql(u8, value, "required-first") or
        std.mem.eql(u8, value, "required_first")) return .required_first;
    return null;
}

test "parseSkillMdWithFallback releases every partial allocation" {
    const md =
        "---\n" ++
        "description: >\n" ++
        "  allocation fault\n" ++
        "  fixture\n" ++
        "when_to_use: \"when 'quoted'\"\n" ++
        "allowed-tools:\n" ++
        "  - Read\n" ++
        "  - Bash(git *)\n" ++
        "  - Grep\n" ++
        "disallowed-tools: Write\n" ++
        "arguments: target, scope\n" ++
        "context: fork\n" ++
        "agent: general-purpose\n" ++
        "model: fixture-model\n" ++
        "shell: bash\n" ++
        "---\n" ++
        "Review $target in $scope.\n";

    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 1024) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = parseSkillMdWithFallback(
            failing.allocator(),
            md,
            "/fixture/review",
            "review",
        );
        if (result) |skill| {
            skill.deinit(failing.allocator());
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(reached_success);
}

test "parseSkillMd preserves minimal frontmatter defaults" {
    const md =
        "---\n" ++
        "name: test-skill\n" ++
        "description: A test skill\n" ++
        "---\n" ++
        "Body content here.\n";
    const skill = try parseSkillMd(std.testing.allocator, md, "/tmp/fake");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("test-skill", skill.name);
    try std.testing.expectEqualStrings("A test skill", skill.description);
    try std.testing.expect(std.mem.indexOf(u8, skill.body, "Body content") != null);
    try std.testing.expectEqual(@as(usize, 0), skill.allowed_tools.len);
    try std.testing.expect(!skill.disable_model_invocation);
    try std.testing.expectEqual(ExecContext.inline_ctx, skill.context);
}

test "parseSkillMd accepts allowed_tools legacy spelling" {
    const md =
        "---\n" ++
        "name: scoped\n" ++
        "description: desc\n" ++
        "allowed_tools: Read, Grep, Glob\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/tmp/fake");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Read", skill.allowed_tools[0]);
}

test "parseSkillMd preserves parenthesized tool rules" {
    const md =
        "---\n" ++
        "name: gitops\n" ++
        "description: git ops\n" ++
        "allowed-tools: Read, Bash(git *), Grep\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Read", skill.allowed_tools[0]);
    try std.testing.expectEqualStrings("Bash(git *)", skill.allowed_tools[1]);
    try std.testing.expectEqualStrings("Grep", skill.allowed_tools[2]);
}

test "parseSkillMd accepts bracketed lists" {
    const md =
        "---\n" ++
        "name: yl\n" ++
        "description: yaml list\n" ++
        "allowed-tools: [Read, Grep]\n" ++
        "arguments: [issue, branch]\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), skill.allowed_tools.len);
    try std.testing.expectEqual(@as(usize, 2), skill.arguments.len);
    try std.testing.expectEqualStrings("issue", skill.arguments[0]);
}

test "parseSkillMd preserves invocation and execution metadata" {
    const md =
        "---\n" ++
        "name: pr-summary\n" ++
        "description: Summarize PR\n" ++
        "disable-model-invocation: true\n" ++
        "model-activation: required-first\n" ++
        "context: fork\n" ++
        "agent: Explore\n" ++
        "model: claude-haiku-4-5-20251001\n" ++
        "shell: bash\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expect(skill.disable_model_invocation);
    try std.testing.expectEqual(ModelActivation.required_first, skill.model_activation);
    try std.testing.expectEqual(ExecContext.fork, skill.context);
    try std.testing.expectEqualStrings("Explore", skill.agent);
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", skill.model);
    try std.testing.expectEqualStrings("bash", skill.shell);
}

test "parseSkillMd rejects unknown model activation instead of guessing" {
    try std.testing.expectError(
        error.InvalidModelActivation,
        parseSkillMd(
            std.testing.allocator,
            "---\nname: bad\nmodel-activation: sometimes\n---\nbody",
            "/x",
        ),
    );
}

test "parseSkillMdWithFallback uses directory invocation name" {
    const md =
        "---\n" ++
        "description: no name in fm\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMdWithFallback(
        std.testing.allocator,
        md,
        "/tmp/auto",
        "auto-name",
    );
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auto-name", skill.name);
}

test "parseSkillMd rejects nameless body without fallback" {
    try std.testing.expectError(
        error.MissingSkillName,
        parseSkillMd(std.testing.allocator, "just body\n", "/x"),
    );
}

test "parseSkillMd ignores frontmatter comments" {
    const md =
        "---\n" ++
        "# this is a comment\n" ++
        "name: c\n" ++
        "description: d\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("c", skill.name);
}

test "parseStringList accepts whitespace and bracketed forms" {
    const whitespace = try parseStringList(std.testing.allocator, "Read Grep Glob");
    defer freeStringList(std.testing.allocator, whitespace);
    try std.testing.expectEqual(@as(usize, 3), whitespace.len);

    const bracketed = try parseStringList(std.testing.allocator, "[a, b, c]");
    defer freeStringList(std.testing.allocator, bracketed);
    try std.testing.expectEqual(@as(usize, 3), bracketed.len);
    try std.testing.expectEqualStrings("a", bracketed[0]);
}

test "parseStringList accepts empty input" {
    const values = try parseStringList(std.testing.allocator, "");
    defer freeStringList(std.testing.allocator, values);
    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "YAML frontmatter: folded, quoted, CRLF and block lists parse like Claude Code and Codex" {
    const md =
        "\xEF\xBB\xBF---\r\n" ++
        "name: \"pdf\"\r\n" ++
        "description: >\r\n" ++
        "  Use when tasks involve\r\n" ++
        "  PDF files.\r\n" ++
        "when_to_use: 'it''s a PDF'\r\n" ++
        "argument-hint: [file]\r\n" ++
        "user-invocable: No\r\n" ++
        "allowed-tools:\r\n" ++
        "  - Read\r\n" ++
        "  - Bash(pdftoppm *)\r\n" ++
        "metadata:\r\n" ++
        "  name: ignored-nested\r\n" ++
        "license: MIT\r\n" ++
        "---\r\n" ++
        "Body.\r\n";
    const skill = try parseSkillMdWithFallback(std.testing.allocator, md, "/x", "dir");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pdf", skill.name);
    try std.testing.expectEqualStrings("Use when tasks involve PDF files.\n", skill.description);
    try std.testing.expectEqualStrings("it's a PDF", skill.when_to_use);
    try std.testing.expectEqualStrings("[file]", skill.argument_hint);
    try std.testing.expect(!skill.user_invocable);
    try std.testing.expectEqual(@as(usize, 2), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Bash(pdftoppm *)", skill.allowed_tools[1]);
    try std.testing.expectEqualStrings("Body.\r\n", skill.body);
}

test "frontmatter type mismatches and malformed YAML are typed failures" {
    try std.testing.expectError(error.InvalidFrontmatter, parseSkillMd(std.testing.allocator, "---\nname: x\nno close\n", "/x"));
    try std.testing.expectError(error.InvalidFrontmatter, parseSkillMd(std.testing.allocator, "---\nname: &a x\n---\n", "/x"));
    try std.testing.expectError(error.InvalidFieldType, parseSkillMd(std.testing.allocator, "---\nname: [a, b]\n---\n", "/x"));
    try std.testing.expectError(error.InvalidBoolean, parseSkillMd(std.testing.allocator, "---\nname: x\ndisable-model-invocation: maybe\n---\n", "/x"));
    try std.testing.expectError(error.InvalidContext, parseSkillMd(std.testing.allocator, "---\nname: x\ncontext: sideways\n---\n", "/x"));
    try std.testing.expectError(error.InvalidShell, parseSkillMd(std.testing.allocator, "---\nname: x\nshell: zsh\n---\n", "/x"));
}

test "description falls back to the first body line only when asked" {
    const md = "---\nname: x\n---\n\n  # Title line\nmore\n";
    const plain = try parseSkillMd(std.testing.allocator, md, "/x");
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", plain.description);
    const fallback = try parseSkillMdWithOptions(std.testing.allocator, md, "/x", "x", .{ .description_fallback = true });
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("# Title line", fallback.description);
}

test "Codex sidecar: implicit invocation policy, fail-open on malformed YAML" {
    const hidden = (try parseCodexSidecar(std.testing.allocator, "interface:\n  display_name: \"X\"\npolicy:\n  allow_implicit_invocation: false\n")).?;
    try std.testing.expect(!hidden.allow_implicit_invocation);
    const default = (try parseCodexSidecar(std.testing.allocator, "interface:\n  short_description: s\n")).?;
    try std.testing.expect(default.allow_implicit_invocation);
    try std.testing.expect((try parseCodexSidecar(std.testing.allocator, "policy: [unterminated")) == null);
}
