const questions = try arena.alloc(tai.NamedQuestion, labels.len);
for (labels, questions) |label, *q| q.* = .{
    .name = label,
    .question = .{ .noul = .{
        .instructions = .{ .text = try std.fmt.allocPrint(arena, "Is this about {s}?", .{label}) },
    } },
};

var result = try client.systemOne(.{
    .state = .{ .text = document },
    .questions = questions,
}, .{});
defer result.deinit();

var matches: std.ArrayList([]const u8) = .empty;
for (result.value.answers) |named| switch (named.answer) {
    .noul => |n| if (n.noul > 0.5) try matches.append(arena, named.name),
    else => {},
};
