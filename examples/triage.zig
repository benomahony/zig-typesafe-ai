//! Support-ticket triage with the typed DSL.
//!
//!     TYPESAFE_API_KEY=... zig build run-triage -- "Help! My payouts have been failing for 3 days."

const std = @import("std");
const tai = @import("tai");

const Severity = enum { low, medium, high, critical };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const message = if (args.len > 1) args[1] else "Help! My payouts have been failing for 3 days.";

    var client: tai.Client = try .init(init.gpa, init.io, .{ .environ_map = init.environ_map });
    defer client.deinit();

    var diag: tai.Client.Diagnostics = .{};
    defer diag.deinit();

    const r = client.ask(.{ .channel = "email", .message = message }, .{
        .is_urgent = tai.noul("Does `message` convey urgency?")
            .criteria("Explicitly time-sensitive", "No urgency expressed"),
        .department = tai.choice("Which team should handle `message`?", .{
            .billing = "Payments, invoicing, refunds",
            .technical = "Bugs, outages, integrations",
            .sales = "Pricing, upgrades, new accounts",
        }),
        .severity = tai.choice("How severe is the issue in `message`?", Severity),
        .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
    }, .{ .diagnostics = &diag }) catch |err| {
        std.log.err("{t} (HTTP {?d}): {s}", .{ err, if (diag.status) |s| @intFromEnum(s) else null, diag.body });
        return err;
    };
    const a = r.answers;

    const team = switch (a.department.choice) {
        .billing => "billing@",
        .technical => "oncall@",
        .sales => "sales@",
    };
    const escalate = a.is_urgent > 0.8 and a.department.confidence > 0.6;

    std.debug.print(
        \\model:       {s}
        \\urgent:      {d:.2}
        \\department:  {t} (confidence {d:.2}) -> {s}
        \\severity:    {t}
        \\frustration: {d:.2} (level {d})
        \\escalate:    {}
        \\tokens:      {d} in / {d} out
        \\
    , .{
        r.model(),
        a.is_urgent,
        a.department.choice,
        a.department.confidence,
        team,
        a.severity.choice,
        a.frustration.score,
        a.frustration.level(),
        escalate,
        r.usage.input_tokens,
        r.usage.output_tokens,
    });
}
