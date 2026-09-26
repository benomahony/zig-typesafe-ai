const Severity = enum { low, medium, high, critical };

const r = try client.ask("Production database is down for all customers.", .{
    .severity = tai.choice("How severe is this incident?", Severity),
}, .{});

const severity: Severity = r.answers.severity.choice;
