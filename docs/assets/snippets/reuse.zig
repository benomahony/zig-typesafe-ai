const triage = .{
    .is_urgent = tai.noul("Does this convey urgency?"),
    .department = tai.choice("Which team?", .{ .billing = null, .technical = null }),
};

const tickets = [_][]const u8{
    "I was double charged, please refund me today.",
    "Minor typo on the pricing page.",
};

var results: [tickets.len]tai.Result(@TypeOf(triage)) = undefined;
for (tickets, &results) |body, *result| {
    result.* = try client.ask(body, triage, .{});
}
