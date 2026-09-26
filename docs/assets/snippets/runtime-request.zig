const options = try arena.alloc(tai.Choice.Option, team_names.len);
for (team_names, options) |name, *option| option.* = .{ .name = name };

const request: tai.Request = .{
    .state = .{ .text = "Stripe webhooks are failing with 500s." },
    .questions = &.{
        .{ .name = "team", .question = .{ .choice = .{
            .instructions = .{ .text = "Which team owns this?" },
            .options = options,
        } } },
        .{ .name = "impact", .question = .{ .score = .{
            .instructions = .{ .text = "How much customer impact?" },
            .levels = &.{ .{ .text = "None" }, .{ .text = "Some" }, .{ .text = "Severe" } },
        } } },
    },
};
try tai.validate(request); // systemOne also validates before sending
