const ticket = .{
    .customer = .{ .plan = "pro", .months_subscribed = 18 },
    .message = "I'm cancelling unless the CSV export bug is fixed this week.",
};

const r = try client.ask(ticket, .{
    .churn_risk = tai.noul("Is `customer` likely to cancel based on `message`?"),
    .same_issue = tai.noul(.{
        .question = "Is `message` about the same issue as `previous`?",
        .previous = "CSV export produces an empty file.",
    }),
}, .{});
