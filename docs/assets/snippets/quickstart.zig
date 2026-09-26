const std = @import("std");
const tai = @import("tai");

pub fn main(init: std.process.Init) !void {
    var client: tai.Client = try .init(init.gpa, init.io, .{ .environ_map = init.environ_map });
    defer client.deinit();

    const r = try client.ask("I was charged twice. Please help.", .{
        .billing = tai.noul("Is this about billing?"),
    }, .{});

    std.debug.print("billing: {d:.2} ({s})\n", .{ r.answers.billing, r.model() });
}
