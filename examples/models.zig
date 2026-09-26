//! Lists the models available to your account.
//!
//!     TYPESAFE_API_KEY=... zig build run-models

const std = @import("std");
const tai = @import("tai");

pub fn main(init: std.process.Init) !void {
    var client: tai.Client = try .init(init.gpa, init.io, .{ .environ_map = init.environ_map });
    defer client.deinit();

    var diag: tai.Client.Diagnostics = .{};
    defer diag.deinit();
    var models = client.listModels(.{ .diagnostics = &diag }) catch |err| {
        std.log.err("{t} (HTTP {?d}): {s}", .{ err, if (diag.status) |s| @intFromEnum(s) else null, diag.body });
        return err;
    };
    defer models.deinit();

    for (models.value.models) |m| std.debug.print("{s:<14} {s}  {s}\n", .{ m.name, m.release_date, m.description });
}
