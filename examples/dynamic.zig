//! Questions built at runtime: one noul per label read from the command line.
//!
//!     TYPESAFE_API_KEY=... zig build run-dynamic -- "The app crashes when I upload a PDF" bug feature-request billing

const std = @import("std");
const tai = @import("tai");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: dynamic <text> <label>...\n", .{});
        return error.InvalidArguments;
    }

    var client: tai.Client = try .init(init.gpa, init.io, .{ .environ_map = init.environ_map });
    defer client.deinit();

    const labels = args[2..];
    const questions = try arena.alloc(tai.NamedQuestion, labels.len);
    for (labels, questions) |label, *q| q.* = .{
        .name = label,
        .question = .{ .noul = .{
            .instructions = .{ .text = try std.fmt.allocPrint(arena, "Is this text about {s}?", .{label}) },
        } },
    };

    var result = try client.systemOne(.{ .state = .{ .text = args[1] }, .questions = questions }, .{});
    defer result.deinit();

    for (result.value.answers) |named| switch (named.answer) {
        .noul => |n| std.debug.print("{s:<20} {d:.3}\n", .{ named.name, n.noul }),
        else => {},
    };
}
