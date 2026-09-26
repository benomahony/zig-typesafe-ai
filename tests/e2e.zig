//! End-to-end tests against the live TypeSafe API.
//!
//!     TYPESAFE_API_KEY=... zig build e2e
//!
//! Every code example in the documentation is quoted from a region of this
//! file (or `tests/consumer/`) between `// docs:start NAME` and
//! `// docs:end NAME`; run `zig build snippets` after editing one.
//!
//! Assertions check structure and ranges, plus a few unambiguous cases, so
//! that a new model version does not break them.

const std = @import("std");
const testing = std.testing;
const tai = @import("tai");

fn apiKey(buf: []u8) ![]const u8 {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const key = env.get(tai.Client.env.api_key) orelse {
        std.debug.print("\nset TYPESAFE_API_KEY to run the e2e tests\n", .{});
        return error.MissingApiKey;
    };
    if (key.len > buf.len) return error.ApiKeyTooLong;
    @memcpy(buf[0..key.len], key);
    return buf[0..key.len];
}

fn liveClient() !tai.Client {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    if (env.get(tai.Client.env.api_key) == null) {
        std.debug.print("\nset TYPESAFE_API_KEY to run the e2e tests\n", .{});
        return error.MissingApiKey;
    }
    return tai.Client.init(testing.allocator, testing.io, .{ .environ_map = &env });
}

fn expectProbability(p: f64) !void {
    try testing.expect(p >= 0 and p <= 1);
}

fn expectDistribution(probabilities: []const f64) !void {
    var sum: f64 = 0;
    for (probabilities) |p| {
        try expectProbability(p);
        sum += p;
    }
    try testing.expectApproxEqAbs(@as(f64, 1), sum, 0.02);
}

test "triage" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start triage
    const r = try client.ask("Help! My payouts have been failing for 3 days.", .{
        .is_urgent = tai.noul("Does this convey urgency?"),
        .department = tai.choice("Which team should handle this?", .{
            .billing = "Payments, invoicing, refunds",
            .technical = "Bugs, outages, integrations",
            .sales = "Pricing, upgrades, new accounts",
        }),
        .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
    }, .{});

    const page_oncall = r.answers.is_urgent > 0.8;
    const queue = switch (r.answers.department.choice) {
        .billing => "payments",
        .technical => "engineering",
        .sales => "sales",
    };
    // docs:end triage

    try expectProbability(r.answers.is_urgent);
    try testing.expect(r.answers.is_urgent > 0.5);
    try testing.expect(page_oncall == (r.answers.is_urgent > 0.8));
    try testing.expect(queue.len > 0);
    try testing.expect(r.answers.department.choice != .sales);
    try expectDistribution(&r.answers.department.probabilities.values);
    try expectProbability(r.answers.department.confidence);
    try expectDistribution(&r.answers.frustration.probabilities);
    try testing.expect(r.answers.frustration.score >= 0 and r.answers.frustration.score <= 2);
    try testing.expect(r.model().len > 0);
    try testing.expect(r.usage.input_tokens > 0);
}

test "noul" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start noul
    const r = try client.ask("I was charged twice for my March invoice.", .{
        .is_billing = tai.noul("Is this about billing?"),
        .is_urgent = tai.noul("Does this convey urgency?")
            .criteria("Explicitly time-sensitive", "No urgency expressed"),
    }, .{});

    const route_to_billing = r.answers.is_billing > 0.5;
    // docs:end noul

    try testing.expect(route_to_billing);
    try expectProbability(r.answers.is_urgent);
}

test "choice" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start choice
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
    // docs:end choice

    try testing.expectEqual(.technical, department.choice);
    try testing.expectEqualStrings("eng-oncall", assignee);
    _ = unsure;
    try expectDistribution(&department.probabilities.values);
}

test "choice from an enum" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start choice-enum
    const Severity = enum { low, medium, high, critical };

    const r = try client.ask("Production database is down for all customers.", .{
        .severity = tai.choice("How severe is this incident?", Severity),
    }, .{});

    const severity: Severity = r.answers.severity.choice;
    // docs:end choice-enum

    try testing.expect(severity == .high or severity == .critical);
}

test "score" {
    var client = try liveClient();
    defer client.deinit();
    const message = "This is the third time I've asked. Fix it now or I'm leaving.";

    // docs:start score-levels
    const by_index = try client.ask(message, .{
        .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
    }, .{});

    const level: usize = by_index.answers.frustration.level(); // 0, 1 or 2
    // docs:end score-levels

    // docs:start score-named
    const by_name = try client.ask(message, .{
        .frustration = tai.score("How frustrated is the customer?", .{
            .calm = "Calm",
            .frustrated = "Frustrated",
            .angry = "Very angry",
        }),
    }, .{});

    const frustration = by_name.answers.frustration;
    const offer_refund = frustration.level() == .angry or frustration.probability(.angry) > 0.4;
    // docs:end score-named

    try testing.expect(level >= 1);
    try testing.expect(frustration.level() != .calm);
    _ = offer_refund;
    try expectDistribution(&frustration.probabilities);
    try expectProbability(frustration.confidence);
}

test "structured state" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start structured-state
    const ticket = .{
        .customer = .{ .plan = "pro", .months_subscribed = 18 },
        .message = "I'm cancelling unless the CSV export bug is fixed this week.",
    };

    const r = try client.ask(ticket, .{
        .churn_risk = tai.noul("Is `customer` likely to cancel based on `message`?"),
        .same_issue = tai.noul(.{
            .question = "Is `message` about the same issue as `previous`?",
            .previous = "CSV export produces an empty file.",
        }),
    }, .{});
    // docs:end structured-state

    try testing.expect(r.answers.churn_risk > 0.5);
    try expectProbability(r.answers.same_issue);
}

test "reuse a question set" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start reuse
    const triage = .{
        .is_urgent = tai.noul("Does this convey urgency?"),
        .department = tai.choice("Which team?", .{ .billing = null, .technical = null }),
    };

    const tickets = [_][]const u8{
        "I was double charged, please refund me today.",
        "Minor typo on the pricing page.",
    };

    var results: [tickets.len]tai.Result(@TypeOf(triage)) = undefined;
    for (tickets, &results) |body, *result| {
        result.* = try client.ask(body, triage, .{});
    }
    // docs:end reuse

    try testing.expectEqual(.billing, results[0].answers.department.choice);
    try testing.expect(results[0].answers.is_urgent > results[1].answers.is_urgent);
}

test "per-call options" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start call-options
    var diag: tai.Client.Diagnostics = .{};
    defer diag.deinit();

    const r = try client.ask("Refund request for order #1234.", .{
        .refund = tai.noul("Is this a refund request?"),
    }, .{
        .model = "jev-latest", // or pin a versioned id such as the one r.model() reports
        .retry = .none, // or a custom tai.RetryPolicy
        .diagnostics = &diag,
    });
    // docs:end call-options

    try testing.expect(r.answers.refund > 0.5);
    try testing.expectEqual(@as(u32, 1), diag.attempts);
    try testing.expectEqual(std.http.Status.ok, diag.status.?);
}

test "client options" {
    var key_buf: [256]u8 = undefined;
    const api_key = try apiKey(&key_buf);
    const gpa = testing.allocator;
    const io = testing.io;

    // docs:start client-init
    var client: tai.Client = try .init(gpa, io, .{
        .api_key = api_key, // default: TYPESAFE_API_KEY from environ_map
        .base_url = "https://api.typesafe.ai", // default: TYPESAFE_BASE_URL, then this
        .model = "jev-latest", // default: TYPESAFE_DEFAULT_MODEL, then this
        .retry = .{ .max_retries = 3, .backoff_max_ms = 10_000 },
        .extra_headers = &.{.{ .name = "x-request-source", .value = "docs" }},
    });
    defer client.deinit();
    // docs:end client-init

    const r = try client.ask("hello", .{ .greeting = tai.noul("Is this a greeting?") }, .{});
    try testing.expect(r.answers.greeting > 0.5);
}

test "errors and diagnostics" {
    var client: tai.Client = try .init(testing.allocator, testing.io, .{ .api_key = "not-a-real-key" });
    defer client.deinit();

    // docs:start errors
    var diag: tai.Client.Diagnostics = .{};
    defer diag.deinit();

    const outcome = client.ask("Is this spam?", .{ .spam = tai.noul("Is this spam?") }, .{ .diagnostics = &diag });
    const problem: []const u8 = if (outcome) |_| "" else |err| switch (err) {
        // diag.status is 401; diag.body is the server's JSON explanation.
        error.Unauthorized => diag.body,
        error.RateLimited, error.Overloaded => "busy, try again later",
        else => return err,
    };
    // docs:end errors

    try testing.expectError(error.Unauthorized, outcome);
    try testing.expectEqual(std.http.Status.unauthorized, diag.status.?);
    try testing.expect(std.mem.indexOf(u8, problem, "authentication") != null);
}

test "list models" {
    var client = try liveClient();
    defer client.deinit();

    // docs:start list-models
    var models = try client.listModels(.{});
    defer models.deinit();

    var has_latest = false;
    for (models.value.models) |m| {
        if (std.mem.eql(u8, m.name, "jev-latest")) has_latest = true;
    }
    // docs:end list-models

    try testing.expect(has_latest);
    for (models.value.models) |m| {
        try testing.expect(m.description.len > 0);
        try testing.expect(m.release_date.len > 0);
    }
}

test "runtime questions" {
    var client = try liveClient();
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const labels: []const []const u8 = &.{ "billing", "a software bug", "gardening" };
    const document = "The invoice PDF shows the wrong amount and the download button throws an error.";

    // docs:start runtime
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
    // docs:end runtime

    try testing.expectEqual(labels.len, result.value.answers.len);
    try testing.expect(result.value.noul("billing").?.noul > 0.5);
    try testing.expect(result.value.noul("gardening").?.noul < 0.5);
    try testing.expect(matches.items.len >= 1);
}

test "runtime choice and score" {
    var client = try liveClient();
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const team_names: []const []const u8 = &.{ "payments", "platform", "growth" };

    // docs:start runtime-request
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
    // docs:end runtime-request

    var result = try client.systemOne(request, .{});
    defer result.deinit();

    // docs:start runtime-response
    const response = result.value;
    const team = response.choice("team").?; // null if missing or not a choice
    const owner = team.choice; // one of team_names
    const p_payments = team.probabilityOf("payments") orelse 0;

    const impact = response.score("impact").?;
    const worst = impact.levels[impact.mostLikelyLevel().?].description; // "None", "Some" or "Severe"
    // docs:end runtime-response

    try testing.expect(p_payments >= 0 and p_payments <= 1);
    var known = false;
    for (team_names) |name| known = known or std.mem.eql(u8, name, owner);
    try testing.expect(known);
    try testing.expectEqual(@as(usize, 3), impact.levels.len);
    try testing.expect(worst.len > 0);
    try testing.expect(response.usage.input_tokens > 0);
}
