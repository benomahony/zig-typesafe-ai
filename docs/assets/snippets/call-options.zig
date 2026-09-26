var diag: tai.Client.Diagnostics = .{};
defer diag.deinit();

const r = try client.ask("Refund request for order #1234.", .{
    .refund = tai.noul("Is this a refund request?"),
}, .{
    .model = "jev-latest", // or pin a versioned id such as the one r.model() reports
    .retry = .none, // or a custom tai.RetryPolicy
    .diagnostics = &diag,
});
