//! Keeps every Zig example in the documentation quoted from a tested region.
//!
//!     snippets write   extract regions and update docs in place
//!     snippets check   fail if anything is stale or untested
//!
//! Regions are marked in test sources with `// docs:start NAME` and
//! `// docs:end NAME`. Each becomes `docs/assets/snippets/NAME.zig`, which
//! Zine pages embed with `[]($code.siteAsset('snippets/NAME.zig').language('zig'))`.
//! Markdown and doc comments that Zine can't reach (the README, `//!` docs)
//! mark a fenced block with `snippet: NAME` on the line before it, and the
//! block is rewritten from the region. Any other ```zig block is an error.
//!
//! Runs from the repository root.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sources = [_][]const u8{
    "tests/e2e.zig",
    "tests/consumer/build.zig",
    "tests/consumer/src/main.zig",
};
const snippets_dir = "docs/assets/snippets";
const content_dir = "docs/content";
const synced_files = [_][]const u8{
    "README.md",
    "src/root.zig",
    "src/Client.zig",
    "src/dsl.zig",
};

const Mode = enum { write, check };

const Snippet = struct {
    name: []const u8,
    source: []const u8,
    line: usize,
    code: []const u8,
    used: bool = false,
};

const Context = struct {
    arena: Allocator,
    io: Io,
    mode: Mode,
    snippets: std.StringArrayHashMapUnmanaged(Snippet) = .empty,
    problems: usize = 0,

    fn problem(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("error: " ++ fmt ++ "\n", args);
        ctx.problems += 1;
    }

    fn read(ctx: *Context, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(4 << 20));
    }

    /// Writes `data` to `path` in write mode, or reports a difference in check mode.
    fn update(ctx: *Context, path: []const u8, data: []const u8) !void {
        const current = ctx.read(path) catch |err| switch (err) {
            error.FileNotFound => "",
            else => |e| return e,
        };
        if (std.mem.eql(u8, current, data)) return;
        switch (ctx.mode) {
            .write => {
                try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
                std.debug.print("updated {s}\n", .{path});
            },
            .check => ctx.problem("{s} is out of date; run `zig build snippets`", .{path}),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const mode = if (args.len == 2) std.meta.stringToEnum(Mode, args[1]) else null;
    var ctx: Context = .{ .arena = arena, .io = init.io, .mode = mode orelse {
        std.debug.print("usage: snippets <write|check>\n", .{});
        std.process.exit(2);
    } };

    for (sources) |path| try extract(&ctx, path);
    try Io.Dir.cwd().createDirPath(ctx.io, snippets_dir);
    try writeSnippetFiles(&ctx);
    try checkContent(&ctx);
    for (synced_files) |path| try syncFile(&ctx, path);

    for (ctx.snippets.values()) |s| {
        if (!s.used) ctx.problem("{s}:{d}: snippet '{s}' is not used by any documentation", .{ s.source, s.line, s.name });
    }
    if (ctx.problems > 0) {
        std.debug.print("{d} problem(s)\n", .{ctx.problems});
        std.process.exit(1);
    }
}

fn extract(ctx: *Context, path: []const u8) !void {
    const text = try ctx.read(path);
    const Open = struct { name: []const u8, line: usize, indent: []const u8, out: std.ArrayList(u8) };
    var open: std.ArrayList(Open) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "// docs:start ")) {
            const name = std.mem.trim(u8, trimmed["// docs:start ".len..], " ");
            const indent = line[0 .. line.len - std.mem.trimStart(u8, line, " ").len];
            try open.append(ctx.arena, .{ .name = name, .line = line_no, .indent = indent, .out = .empty });
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "// docs:end ")) {
            const name = std.mem.trim(u8, trimmed["// docs:end ".len..], " ");
            const index = for (open.items, 0..) |o, i| {
                if (std.mem.eql(u8, o.name, name)) break i;
            } else {
                ctx.problem("{s}:{d}: 'docs:end {s}' without a matching start", .{ path, line_no, name });
                continue;
            };
            const region = open.orderedRemove(index);
            const gop = try ctx.snippets.getOrPut(ctx.arena, name);
            if (gop.found_existing) {
                ctx.problem("{s}:{d}: snippet '{s}' already defined at {s}:{d}", .{ path, region.line, name, gop.value_ptr.source, gop.value_ptr.line });
                continue;
            }
            gop.value_ptr.* = .{ .name = name, .source = path, .line = region.line, .code = region.out.items };
            continue;
        }
        for (open.items) |*o| {
            const body = if (std.mem.startsWith(u8, line, o.indent)) line[o.indent.len..] else std.mem.trimStart(u8, line, " ");
            try o.out.appendSlice(ctx.arena, std.mem.trimEnd(u8, body, " \t\r"));
            try o.out.append(ctx.arena, '\n');
        }
    }
    for (open.items) |o| ctx.problem("{s}:{d}: 'docs:start {s}' is never closed", .{ path, o.line, o.name });
}

fn writeSnippetFiles(ctx: *Context) !void {
    for (ctx.snippets.values()) |s| {
        const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.zig", .{ snippets_dir, s.name });
        try ctx.update(path, s.code);
    }

    var dir = try Io.Dir.cwd().openDir(ctx.io, snippets_dir, .{ .iterate = true });
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = std.mem.cutSuffix(u8, entry.name, ".zig") orelse continue;
        if (ctx.snippets.contains(name)) continue;
        switch (ctx.mode) {
            .write => {
                try dir.deleteFile(ctx.io, entry.name);
                std.debug.print("removed {s}/{s}\n", .{ snippets_dir, entry.name });
            },
            .check => ctx.problem("{s}/{s} has no matching docs:start region", .{ snippets_dir, entry.name }),
        }
    }
}

/// Zine pages must embed snippets rather than contain Zig code.
fn checkContent(ctx: *Context) !void {
    var dir = try Io.Dir.cwd().openDir(ctx.io, content_dir, .{ .iterate = true });
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.arena);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".smd")) continue;
        const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ content_dir, entry.path });
        const text = try ctx.read(path);

        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |line| {
            line_no += 1;
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```zig"))
                ctx.problem("{s}:{d}: Zig code must be quoted from a test: []($code.siteAsset('snippets/NAME.zig').language('zig'))", .{ path, line_no });
        }

        const needle = "siteAsset('snippets/";
        var rest = text;
        while (std.mem.indexOf(u8, rest, needle)) |i| {
            rest = rest[i + needle.len ..];
            const end = std.mem.indexOf(u8, rest, ".zig')") orelse break;
            const name = rest[0..end];
            if (ctx.snippets.getPtr(name)) |s| s.used = true else ctx.problem("{s}: unknown snippet '{s}'", .{ path, name });
        }
    }
}

/// Rewrites each fenced block preceded by a `snippet: NAME` line.
fn syncFile(ctx: *Context, path: []const u8) !void {
    const text = try ctx.read(path);
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var pending: ?*Snippet = null;
    var first = true;

    while (lines.next()) |line| {
        line_no += 1;
        if (!first) try out.append(ctx.arena, '\n');
        first = false;
        try out.appendSlice(ctx.arena, line);

        if (std.mem.indexOf(u8, line, "snippet: ")) |i| {
            const name = std.mem.trim(u8, line[i + "snippet: ".len ..], " ->");
            pending = ctx.snippets.getPtr(name) orelse {
                ctx.problem("{s}:{d}: unknown snippet '{s}'", .{ path, line_no, name });
                continue;
            };
            continue;
        }

        const fence = std.mem.indexOf(u8, line, "```zig") orelse {
            if (std.mem.trim(u8, line, " \t").len != 0) pending = null;
            continue;
        };
        const snippet = pending orelse {
            ctx.problem("{s}:{d}: Zig code must be quoted from a test; add a `snippet: NAME` line above it", .{ path, line_no });
            continue;
        };
        pending = null;
        snippet.used = true;

        // Replace everything up to the closing fence with the snippet. The
        // fence's prefix (e.g. "//! ") is repeated on every line.
        const prefix = line[0..fence];
        while (lines.next()) |body| {
            line_no += 1;
            const is_close = std.mem.startsWith(u8, body, prefix) and
                std.mem.eql(u8, std.mem.trim(u8, body[prefix.len..], " \t"), "```");
            if (!is_close) continue;

            var code_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, snippet.code, "\n"), '\n');
            while (code_lines.next()) |code| {
                try out.append(ctx.arena, '\n');
                if (code.len == 0) {
                    try out.appendSlice(ctx.arena, std.mem.trimEnd(u8, prefix, " "));
                } else {
                    try out.appendSlice(ctx.arena, prefix);
                    try out.appendSlice(ctx.arena, code);
                }
            }
            try out.append(ctx.arena, '\n');
            try out.appendSlice(ctx.arena, body);
            break;
        } else ctx.problem("{s}: unterminated ```zig block", .{path});
    }
    try ctx.update(path, out.items);
}
