const by_index = try client.ask(message, .{
    .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
}, .{});

const level: usize = by_index.answers.frustration.level(); // 0, 1 or 2
