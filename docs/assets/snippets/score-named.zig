const by_name = try client.ask(message, .{
    .frustration = tai.score("How frustrated is the customer?", .{
        .calm = "Calm",
        .frustrated = "Frustrated",
        .angry = "Very angry",
    }),
}, .{});

const frustration = by_name.answers.frustration;
const offer_refund = frustration.level() == .angry or frustration.probability(.angry) > 0.4;
