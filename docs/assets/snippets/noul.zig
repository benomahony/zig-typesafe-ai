const r = try client.ask("I was charged twice for my March invoice.", .{
    .is_billing = tai.noul("Is this about billing?"),
    .is_urgent = tai.noul("Does this convey urgency?")
        .criteria("Explicitly time-sensitive", "No urgency expressed"),
}, .{});

const route_to_billing = r.answers.is_billing > 0.5;
