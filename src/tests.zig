//! Client tests against a local mock HTTP server.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const tai = @import("root.zig");

const Reply = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    headers: []const std.http.Header = &.{},
};

const Seen = struct {
    method: std.http.Method = .GET,
    target: [64]u8 = undefined,
    target_len: usize = 0,
    authorization: [64]u8 = undefined,
    authorization_len: usize = 0,
    custom_header: bool = false,
    body: [2048]u8 = undefined,
    body_len: usize = 0,

    fn targetSlice(s: *const Seen) []const u8 {
        return s.target[0..s.target_len];
    }
    fn authorizationSlice(s: *const Seen) []const u8 {
        return s.authorization[0..s.authorization_len];
    }
    fn bodySlice(s: *const Seen) []const u8 {
        return s.body[0..s.body_len];
    }
};

/// Serves `replies` in order, one per request, recording what it saw.
const MockServer = struct {
    listener: Io.net.Server,
    replies: []const Reply,
    seen: [8]Seen = @splat(.{}),
    served: usize = 0,

    fn init(io: Io, replies: []const Reply) !MockServer {
        const address: Io.net.IpAddress = try .parse("127.0.0.1", 0);
        return .{ .listener = try address.listen(io, .{ .reuse_address = true }), .replies = replies };
    }

    fn deinit(self: *MockServer, io: Io) void {
        self.listener.deinit(io);
    }

    fn baseUrl(self: *const MockServer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.listener.socket.address.getPort()});
    }

    fn run(self: *MockServer, io: Io) void {
        self.serve(io) catch |err| std.debug.panic("mock server: {t}", .{err});
    }

    fn serve(self: *MockServer, io: Io) !void {
        while (self.served < self.replies.len) {
            const stream = try self.listener.accept(io);
            defer stream.close(io);
            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var in = stream.reader(io, &in_buf);
            var out = stream.writer(io, &out_buf);
            var server: std.http.Server = .init(&in.interface, &out.interface);

            while (self.served < self.replies.len) {
                var request = server.receiveHead() catch break;
                const seen = &self.seen[self.served];
                seen.method = request.head.method;
                seen.target_len = copy(&seen.target, request.head.target);
                var it = request.iterateHeaders();
                while (it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "authorization")) seen.authorization_len = copy(&seen.authorization, h.value);
                    if (std.ascii.eqlIgnoreCase(h.name, "x-custom")) seen.custom_header = true;
                }
                if (request.head.content_length) |len| {
                    const reader = request.readerExpectNone(&.{});
                    try reader.readSliceAll(seen.body[0..len]);
                    seen.body_len = len;
                }
                const reply = self.replies[self.served];
                self.served += 1;
                try request.respond(reply.body, .{
                    .status = reply.status,
                    .extra_headers = reply.headers,
                    .keep_alive = self.served < self.replies.len,
                });
            }
        }
    }

    fn copy(dest: []u8, src: []const u8) usize {
        const n = @min(dest.len, src.len);
        @memcpy(dest[0..n], src[0..n]);
        return n;
    }
};

const fast_retry: tai.RetryPolicy = .{ .backoff_initial_ms = 1, .backoff_max_ms = 2 };

const answers_body =
    \\{"model":"jev-1.13.0","answers":{
    \\  "is_urgent":{"type":"noul","noul":0.95},
    \\  "department":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"technical":0.12,"sales":0.0},"confidence":0.81},
    \\  "frustration":{"type":"score","score":1.05,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"0":0.0,"1":0.95,"2":0.05},"confidence":0.92}
    \\},"usage":{"input_tokens":304,"output_tokens":18}}
;

fn withServer(replies: []const Reply, options: tai.Client.Options, comptime body: fn (*tai.Client, *MockServer) anyerror!void) !void {
    const io = testing.io;
    var mock: MockServer = try .init(io, replies);
    defer mock.deinit(io);
    var future = try io.concurrent(MockServer.run, .{ &mock, io });
    defer future.cancel(io);

    var url_buf: [64]u8 = undefined;
    var opts = options;
    opts.base_url = try mock.baseUrl(&url_buf);
    if (opts.api_key == null) opts.api_key = "test-key";
    var client: tai.Client = try .init(testing.allocator, io, opts);
    defer client.deinit();
    try body(&client, &mock);
    future.await(io);
}

test "ask sends the DSL request and returns typed answers" {
    try withServer(&.{.{ .body = answers_body }}, .{ .extra_headers = &.{.{ .name = "x-custom", .value = "1" }} }, struct {
        fn run(client: *tai.Client, mock: *MockServer) !void {
            const r = try client.ask("Help! My payouts have been failing for 3 days.", .{
                .is_urgent = tai.noul("Does this convey urgency?"),
                .department = tai.choice("Which team should handle this?", .{
                    .billing = "Payments, invoicing, refunds",
                    .technical = "Bugs, outages, integrations",
                    .sales = "Pricing, upgrades, new accounts",
                }),
                .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
            }, .{});

            try testing.expectEqual(@as(f64, 0.95), r.answers.is_urgent);
            try testing.expectEqual(.billing, r.answers.department.choice);
            try testing.expectEqual(@as(usize, 1), r.answers.frustration.level());
            try testing.expectEqualStrings("jev-1.13.0", r.model());
            try testing.expectEqual(@as(u64, 304), r.usage.input_tokens);

            const seen = &mock.seen[0];
            try testing.expectEqual(std.http.Method.POST, seen.method);
            try testing.expectEqualStrings("/v1/systemone", seen.targetSlice());
            try testing.expectEqualStrings("Bearer test-key", seen.authorizationSlice());
            try testing.expect(seen.custom_header);
            try testing.expect(std.mem.indexOf(u8, seen.bodySlice(), "\"model\":\"jev-latest\"") != null);
            try testing.expect(std.mem.indexOf(u8, seen.bodySlice(), "\"sales\":\"Pricing, upgrades, new accounts\"") != null);
        }
    }.run);
}

test "retries 429 and 529, honoring retry-after-ms" {
    const replies: []const Reply = &.{
        .{ .status = .too_many_requests, .body = "{\"detail\":\"slow down\"}", .headers = &.{.{ .name = "retry-after-ms", .value = "1" }} },
        .{ .status = @enumFromInt(529), .body = "{\"detail\":\"overloaded\"}" },
        .{ .body = answers_body },
    };
    try withServer(replies, .{ .retry = fast_retry }, struct {
        fn run(client: *tai.Client, mock: *MockServer) !void {
            var diag: tai.Client.Diagnostics = .{};
            defer diag.deinit();
            const r = try client.ask("x", .{ .is_urgent = tai.noul("?") }, .{ .diagnostics = &diag });
            try testing.expectEqual(@as(f64, 0.95), r.answers.is_urgent);
            try testing.expectEqual(@as(u32, 3), diag.attempts);
            try testing.expectEqual(@as(usize, 3), mock.served);
        }
    }.run);
}

test "non-retryable status surfaces an error with diagnostics" {
    const detail = "{\"detail\":[{\"loc\":[\"body\",\"questions\"],\"msg\":\"field required\"}]}";
    try withServer(&.{.{ .status = .unprocessable_entity, .body = detail }}, .{ .retry = fast_retry }, struct {
        fn run(client: *tai.Client, _: *MockServer) !void {
            var diag: tai.Client.Diagnostics = .{};
            defer diag.deinit();
            try testing.expectError(error.UnprocessableEntity, client.ask("x", .{ .q = tai.noul("?") }, .{ .diagnostics = &diag }));
            try testing.expectEqual(std.http.Status.unprocessable_entity, diag.status.?);
            try testing.expectEqualStrings(detail, diag.body);
            try testing.expectEqual(@as(u32, 1), diag.attempts);
        }
    }.run);
}

test "gives up after max_retries" {
    const replies: []const Reply = &.{
        .{ .status = .service_unavailable },
        .{ .status = .service_unavailable },
    };
    try withServer(replies, .{ .retry = .{ .max_retries = 1, .backoff_initial_ms = 1, .backoff_max_ms = 1 } }, struct {
        fn run(client: *tai.Client, _: *MockServer) !void {
            try testing.expectError(error.ServerError, client.ask("x", .{ .q = tai.noul("?") }, .{}));
        }
    }.run);
}

test "systemOne with runtime-built questions" {
    try withServer(&.{.{ .body = answers_body }}, .{ .model = "jev-1.13.0" }, struct {
        fn run(client: *tai.Client, mock: *MockServer) !void {
            var questions: [1]tai.NamedQuestion = undefined;
            questions[0] = .{ .name = "is_urgent", .question = .{ .noul = .{ .instructions = .{ .text = "Urgent?" } } } };
            var parsed = try client.systemOne(.{ .state = .{ .text = "hi" }, .questions = &questions }, .{});
            defer parsed.deinit();
            try testing.expectEqual(@as(f64, 0.95), parsed.value.noul("is_urgent").?.noul);
            try testing.expectEqual(.billing, parsed.value.choice("department").?.as(enum { billing, technical, sales }).?);
            try testing.expect(std.mem.indexOf(u8, mock.seen[0].bodySlice(), "\"model\":\"jev-1.13.0\"") != null);
        }
    }.run);
}

test "listModels" {
    const body =
        \\{"models":[{"name":"jev-latest","description":"Flagship","release_date":"2026-05-01","extra":1}]}
    ;
    try withServer(&.{.{ .body = body }}, .{}, struct {
        fn run(client: *tai.Client, mock: *MockServer) !void {
            var models = try client.listModels(.{});
            defer models.deinit();
            try testing.expectEqual(@as(usize, 1), models.value.models.len);
            try testing.expectEqualStrings("jev-latest", models.value.models[0].name);
            try testing.expectEqual(std.http.Method.GET, mock.seen[0].method);
            try testing.expectEqualStrings("/v1/models", mock.seen[0].targetSlice());
        }
    }.run);
}

test "connection failure is reported after retries" {
    const io = testing.io;
    // Bind then close a socket so the port is very likely refused.
    var mock: MockServer = try .init(io, &.{});
    var url_buf: [64]u8 = undefined;
    const url = try mock.baseUrl(&url_buf);
    mock.deinit(io);

    var client: tai.Client = try .init(testing.allocator, io, .{ .api_key = "k", .base_url = url, .retry = fast_retry });
    defer client.deinit();
    var diag: tai.Client.Diagnostics = .{};
    defer diag.deinit();
    try testing.expectError(error.ConnectionFailed, client.ask("x", .{ .q = tai.noul("?") }, .{ .diagnostics = &diag }));
    try testing.expectEqual(@as(u32, 3), diag.attempts);
    try testing.expect(diag.transport_error != null);
}

test "init reads the environment and requires an API key" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try testing.expectError(error.MissingApiKey, tai.Client.init(testing.allocator, testing.io, .{ .environ_map = &map }));

    try map.put("TYPESAFE_API_KEY", "from-env");
    try map.put("TYPESAFE_BASE_URL", "https://example.test///");
    try map.put("TYPESAFE_DEFAULT_MODEL", "   ");
    var client: tai.Client = try .init(testing.allocator, testing.io, .{ .environ_map = &map });
    defer client.deinit();
    try testing.expectEqualStrings("https://example.test", client.base_url);
    try testing.expectEqualStrings("jev-latest", client.model);
    try testing.expectEqualStrings("Bearer from-env", client.authorization);
}

test "systemOne validates before sending" {
    var client: tai.Client = try .init(testing.allocator, testing.io, .{ .api_key = "k", .base_url = "http://127.0.0.1:1" });
    defer client.deinit();
    try testing.expectError(error.NoQuestions, client.systemOne(.{ .state = .{ .text = "" }, .questions = &.{} }, .{}));
}

test "a stalled call can be canceled" {
    const io = testing.io;
    // A listener that accepts nothing: the request connects but never gets a response.
    var mock: MockServer = try .init(io, &.{});
    defer mock.deinit(io);
    var url_buf: [64]u8 = undefined;
    var client: tai.Client = try .init(testing.allocator, io, .{ .api_key = "k", .base_url = try mock.baseUrl(&url_buf) });
    defer client.deinit();

    const call = struct {
        fn run(c: *tai.Client) tai.Client.Error!f64 {
            const r = try c.ask("x", .{ .q = tai.noul("?") }, .{ .retry = .none });
            return r.answers.q;
        }
    }.run;
    var future = try io.concurrent(call, .{&client});
    try io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
}
