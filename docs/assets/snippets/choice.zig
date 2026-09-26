const r = try client.ask("The app crashes every time I upload a PDF.", .{
    .department = tai.choice("Which team should handle this?", .{
        .billing = "Payments, invoicing, refunds",
        .technical = "Bugs, outages, integrations",
        .sales = null,
    }),
}, .{});

const department = r.answers.department;
const assignee = switch (department.choice) {
    .billing => "finance-oncall",
    .technical => "eng-oncall",
    .sales => "account-manager",
};
const unsure = department.confidence < 0.5 or department.probability(.sales) > 0.2;
