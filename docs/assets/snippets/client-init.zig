var client: tai.Client = try .init(gpa, io, .{
    .api_key = api_key, // default: TYPESAFE_API_KEY from environ_map
    .base_url = "https://api.typesafe.ai", // default: TYPESAFE_BASE_URL, then this
    .model = "jev-latest", // default: TYPESAFE_DEFAULT_MODEL, then this
    .retry = .{ .max_retries = 3, .backoff_max_ms = 10_000 },
    .extra_headers = &.{.{ .name = "x-request-source", .value = "docs" }},
});
defer client.deinit();
