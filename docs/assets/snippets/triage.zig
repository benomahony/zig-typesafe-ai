const r = try client.ask("Help! My payouts have been failing for 3 days.", .{
    .is_urgent = tai.noul("Does this convey urgency?"),
    .department = tai.choice("Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
        .sales = "Pricing, upgrades, new accounts",
    }),
    .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
}, .{});

const page_oncall = r.answers.is_urgent > 0.8;
const queue = switch (r.answers.department.choice) {
    .billing => "payments",
    .technical => "engineering",
    .sales => "sales",
};
