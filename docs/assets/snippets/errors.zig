var diag: tai.Client.Diagnostics = .{};
defer diag.deinit();

const outcome = client.ask("Is this spam?", .{ .spam = tai.noul("Is this spam?") }, .{ .diagnostics = &diag });
const problem: []const u8 = if (outcome) |_| "" else |err| switch (err) {
    // diag.status is 401; diag.body is the server's JSON explanation.
    error.Unauthorized => diag.body,
    error.RateLimited, error.Overloaded => "busy, try again later",
    else => return err,
};
