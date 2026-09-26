var models = try client.listModels(.{});
defer models.deinit();

var has_latest = false;
for (models.value.models) |m| {
    if (std.mem.eql(u8, m.name, "jev-latest")) has_latest = true;
}
