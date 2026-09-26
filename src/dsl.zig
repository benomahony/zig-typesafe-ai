//! The typed question DSL.
//!
//! Declare questions as a struct literal and get back a struct with one field
//! per question, typed by the question:
//!
// snippet: triage
//! ```zig
//! const r = try client.ask("Help! My payouts have been failing for 3 days.", .{
//!     .is_urgent = tai.noul("Does this convey urgency?"),
//!     .department = tai.choice("Which team should handle this?", .{
//!         .billing = "Payments, invoicing, refunds",
//!         .technical = "Bugs, outages, integrations",
//!         .sales = "Pricing, upgrades, new accounts",
//!     }),
//!     .frustration = tai.score("How frustrated is the customer?", .{ "Calm", "Frustrated", "Very angry" }),
//! }, .{});
//!
//! const page_oncall = r.answers.is_urgent > 0.8;
//! const queue = switch (r.answers.department.choice) {
//!     .billing => "payments",
//!     .technical => "engineering",
//!     .sales => "sales",
//! };
//! ```
//!
//! Choice options and score levels are known at compile time, so option
//! names are checked by the compiler and the result needs no allocation.
//! Instructions, descriptions, and state can be any value `std.json` can
//! serialize, known at compile time or not.

const std = @import("std");
const Stringify = std.json.Stringify;
const types = @import("types.zig");

/// A yes/no question. Answers with the probability of yes, as `f64`.
pub fn noul(instructions: anytype) Noul(@TypeOf(instructions)) {
    return .{ .instructions = instructions };
}

/// Picks one option. `options` is either an enum type, or a struct literal
/// mapping each option name to its description (or `null`).
pub fn choice(instructions: anytype, options: anytype) Choice(@TypeOf(instructions), OptionsType(options)) {
    return .{ .instructions = instructions, .options = if (@TypeOf(options) == type) {} else options };
}

/// Rates the state against ordered levels. `levels` is either a tuple of level
/// descriptions (answers with a level index), a struct literal mapping level
/// names to descriptions, or an enum type whose tag names are the
/// descriptions (both answer with an enum).
pub fn score(instructions: anytype, levels: anytype) Score(@TypeOf(instructions), OptionsType(levels)) {
    return .{ .instructions = instructions, .levels = if (@TypeOf(levels) == type) {} else levels };
}

fn OptionsType(options: anytype) type {
    return if (@TypeOf(options) == type) Tags(options) else @TypeOf(options);
}

/// Marks an enum type passed in place of a struct literal of descriptions.
fn Tags(comptime E: type) type {
    if (@typeInfo(E) != .@"enum") @compileError("expected an enum type or a struct literal, found " ++ @typeName(E));
    return struct {
        pub const Enum = E;
    };
}

fn isTags(comptime O: type) bool {
    return @typeInfo(O) == .@"struct" and @typeInfo(O).@"struct".field_names.len == 0 and @hasDecl(O, "Enum");
}

/// The enum with one tag per field of `O`, in declaration order.
fn EnumOf(comptime O: type) type {
    if (isTags(O)) return O.Enum;
    const info = @typeInfo(O);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("expected a struct literal like .{ .name = \"description\" }, found " ++ @typeName(O));
    return std.meta.FieldEnum(O);
}

fn tagNames(comptime O: type) []const [:0]const u8 {
    return std.meta.fieldNames(if (isTags(O)) O.Enum else O);
}

pub fn Noul(comptime I: type) type {
    return struct {
        instructions: I,
        yes: ?[]const u8 = null,
        no: ?[]const u8 = null,

        const Self = @This();
        pub const is_tai_question = true;
        pub const Answer = f64;

        /// Describes what a yes (near 1) and a no (near 0) mean.
        pub fn criteria(self: Self, yes: []const u8, no: []const u8) Self {
            var q = self;
            q.yes = yes;
            q.no = no;
            return q;
        }

        pub fn jsonStringify(self: Self, w: *Stringify) Stringify.Error!void {
            try w.beginObject();
            try w.objectField("type");
            try w.write("noul");
            try w.objectField("instructions");
            try w.write(self.instructions);
            if (self.yes != null or self.no != null) {
                try w.objectField("criteria");
                try w.beginObject();
                if (self.yes) |yes| {
                    try w.objectField("true");
                    try w.write(yes);
                }
                if (self.no) |no| {
                    try w.objectField("false");
                    try w.write(no);
                }
                try w.endObject();
            }
            try w.endObject();
        }

        pub fn fromAnswer(answer: types.Answer) error{InvalidResponse}!Answer {
            return if (answer == .noul) answer.noul.noul else error.InvalidResponse;
        }
    };
}

pub fn Choice(comptime I: type, comptime O: type) type {
    const names = tagNames(O);
    if (names.len == 0) @compileError("a choice needs at least one option");
    if (names.len > types.max_choice_options) @compileError("a choice accepts at most 255 options");

    return struct {
        instructions: I,
        options: if (isTags(O)) void else O,

        const Self = @This();
        pub const is_tai_question = true;
        pub const Option = EnumOf(O);
        pub const Answer = ChoiceResult(Option);

        pub fn jsonStringify(self: Self, w: *Stringify) Stringify.Error!void {
            try w.beginObject();
            try w.objectField("type");
            try w.write("choice");
            try w.objectField("instructions");
            try w.write(self.instructions);
            try w.objectField("criteria");
            try w.beginObject();
            inline for (comptime names) |name| {
                try w.objectField(name);
                if (comptime isTags(O)) try w.write(null) else try w.write(@field(self.options, name));
            }
            try w.endObject();
            try w.endObject();
        }

        pub fn fromAnswer(answer: types.Answer) error{InvalidResponse}!Answer {
            if (answer != .choice) return error.InvalidResponse;
            const a = answer.choice;
            var probabilities: std.EnumArray(Option, f64) = .initFill(0);
            for (a.probabilities) |p| {
                const option = std.meta.stringToEnum(Option, p.option) orelse return error.InvalidResponse;
                probabilities.set(option, p.probability);
            }
            return .{
                .choice = std.meta.stringToEnum(Option, a.choice) orelse return error.InvalidResponse,
                .probabilities = probabilities,
                .confidence = a.confidence,
            };
        }
    };
}

pub fn ChoiceResult(comptime E: type) type {
    return struct {
        /// The highest-probability option.
        choice: E,
        probabilities: std.EnumArray(E, f64),
        confidence: f64,

        pub fn probability(self: @This(), option: E) f64 {
            return self.probabilities.get(option);
        }
    };
}

pub fn Score(comptime I: type, comptime L: type) type {
    const is_tuple = @typeInfo(L) == .@"struct" and @typeInfo(L).@"struct".is_tuple;
    const count = if (is_tuple) @typeInfo(L).@"struct".field_names.len else tagNames(L).len;
    if (count < types.min_score_levels) @compileError("a score needs at least 2 levels");
    if (count > types.max_score_levels) @compileError("a score accepts at most 10 levels");

    return struct {
        instructions: I,
        levels: if (isTags(L)) void else L,

        const Self = @This();
        pub const is_tai_question = true;
        pub const Level = if (is_tuple) usize else EnumOf(L);
        pub const Answer = ScoreResult(Level, count);

        pub fn jsonStringify(self: Self, w: *Stringify) Stringify.Error!void {
            try w.beginObject();
            try w.objectField("type");
            try w.write("score");
            try w.objectField("instructions");
            try w.write(self.instructions);
            try w.objectField("criteria");
            try w.beginArray();
            if (is_tuple) {
                inline for (0..count) |i| try w.write(self.levels[i]);
            } else {
                inline for (comptime tagNames(L)) |name| {
                    if (comptime isTags(L)) try w.write(name) else try w.write(@field(self.levels, name));
                }
            }
            try w.endArray();
            try w.endObject();
        }

        pub fn fromAnswer(answer: types.Answer) error{InvalidResponse}!Answer {
            if (answer != .score) return error.InvalidResponse;
            const a = answer.score;
            if (a.levels.len != count) return error.InvalidResponse;
            var probabilities: [count]f64 = undefined;
            for (a.levels, &probabilities) |level, *p| p.* = level.probability;
            return .{ .score = a.score, .probabilities = probabilities, .confidence = a.confidence };
        }
    };
}

pub fn ScoreResult(comptime L: type, comptime count: usize) type {
    return struct {
        /// Probability-weighted level index; can land between levels.
        score: f64,
        /// Probability of each level, by level index.
        probabilities: [count]f64,
        confidence: f64,

        const Self = @This();

        /// The single most probable level.
        pub fn level(self: Self) L {
            const i = std.mem.indexOfMax(f64, &self.probabilities);
            return if (L == usize) i else @enumFromInt(i);
        }

        pub fn probability(self: Self, l: L) f64 {
            return self.probabilities[if (L == usize) l else @intFromEnum(l)];
        }
    };
}

/// The typed answers for a question struct `Q`: one field per question.
pub fn Answers(comptime Q: type) type {
    const info = @typeInfo(Q);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("questions must be a struct literal like .{ .name = tai.noul(\"...\") }, found " ++ @typeName(Q));
    const names = info.@"struct".field_names;
    if (names.len == 0) @compileError("ask at least one question");
    var answer_types: [names.len]type = undefined;
    for (info.@"struct".field_types, &answer_types, names) |T, *A, name| {
        if (!@hasDecl(T, "is_tai_question"))
            @compileError("question '" ++ name ++ "' must be built with tai.noul, tai.choice, or tai.score");
        A.* = T.Answer;
    }
    return @Struct(.auto, null, names, &answer_types, &@splat(.{}));
}

/// The result of `Client.ask`. Owns no heap memory.
pub fn Result(comptime Q: type) type {
    return struct {
        answers: Answers(Q),
        usage: types.Usage,
        model_buf: [max_model_len]u8,
        model_len: u8,

        const Self = @This();

        /// The versioned model id that answered, e.g. `jev-1.13.0`.
        pub fn model(self: *const Self) []const u8 {
            return self.model_buf[0..self.model_len];
        }

        pub fn fromResponse(response: types.Response) error{InvalidResponse}!Self {
            var self: Self = undefined;
            inline for (@typeInfo(Q).@"struct".field_names, @typeInfo(Q).@"struct".field_types) |name, T| {
                const answer = response.get(name) orelse return error.InvalidResponse;
                @field(self.answers, name) = try T.fromAnswer(answer);
            }
            self.usage = response.usage;
            const len = @min(response.model.len, max_model_len);
            @memcpy(self.model_buf[0..len], response.model[0..len]);
            self.model_len = @intCast(len);
            return self;
        }
    };
}

pub const max_model_len = 64;

/// Writes the request body for a DSL question struct.
pub fn writeRequest(w: *Stringify, state: anytype, questions: anytype, model: []const u8) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("state");
    try w.write(state);
    try w.objectField("model");
    try w.write(model);
    try w.objectField("questions");
    try w.write(questions);
    try w.endObject();
}

const testing = std.testing;

fn expectBody(expected: []const u8, state: anytype, questions: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Stringify = .{ .writer = &out.writer };
    try writeRequest(&w, state, questions, "jev-latest");
    try testing.expectEqualStrings(expected, out.written());
}

const Severity = enum { low, medium, high };

test "DSL serializes the documented request shape" {
    const runtime_instructions: []const u8 = "Which team should handle this?";
    try expectBody(
        \\{"state":"Help!","model":"jev-latest","questions":{"is_urgent":{"type":"noul","instructions":"Does this convey urgency?","criteria":{"true":"Explicitly time-sensitive","false":"No urgency expressed"}},"department":{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":"Payments, invoicing, refunds","sales":null}},"frustration":{"type":"score","instructions":"How frustrated?","criteria":["Calm","Frustrated","Very angry"]}}}
    , "Help!", .{
        .is_urgent = noul("Does this convey urgency?").criteria("Explicitly time-sensitive", "No urgency expressed"),
        .department = choice(runtime_instructions, .{ .billing = "Payments, invoicing, refunds", .sales = null }),
        .frustration = score("How frustrated?", .{ "Calm", "Frustrated", "Very angry" }),
    });
}

test "DSL accepts enums and structured values" {
    try expectBody(
        \\{"state":{"user":"ada","open_tickets":3},"model":"jev-latest","questions":{"severity":{"type":"score","instructions":{"question":"How severe is `ticket`?","ticket":{"id":42}},"criteria":["low","medium","high"]},"sev":{"type":"choice","instructions":"Pick one","criteria":{"low":null,"medium":null,"high":null}}}}
    , .{ .user = "ada", .open_tickets = 3 }, .{
        .severity = score(.{ .question = "How severe is `ticket`?", .ticket = .{ .id = 42 } }, Severity),
        .sev = choice("Pick one", Severity),
    });
}

test "DSL result types follow the questions" {
    const Q = @TypeOf(.{
        .a = noul("?"),
        .b = choice("?", .{ .x = "X", .y = null }),
        .c = score("?", .{ "lo", "hi" }),
        .d = score("?", .{ .calm = "Calm", .angry = "Angry" }),
        .e = choice("?", Severity),
    });
    const A = Answers(Q);
    try testing.expect(@FieldType(A, "a") == f64);
    const B = @FieldType(@FieldType(A, "b"), "choice");
    try testing.expectEqual(@as(usize, 2), std.meta.fieldNames(B).len);
    try testing.expectEqualStrings("y", @tagName(B.y));
    const D = @TypeOf(@as(@FieldType(A, "d"), undefined).level());
    try testing.expectEqualStrings("angry", @tagName(D.angry));
    try testing.expect(@TypeOf(@as(@FieldType(A, "c"), undefined).level()) == usize);
    try testing.expect(@FieldType(@FieldType(A, "e"), "choice") == Severity);
}

test "DSL converts a parsed response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"model":"jev-1.13.0","answers":{
        \\  "is_urgent":{"type":"noul","noul":0.95},
        \\  "department":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"technical":0.12},"confidence":0.81},
        \\  "frustration":{"type":"score","score":1.05,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"0":0.0,"1":0.95,"2":0.05},"confidence":0.92}
        \\},"usage":{"input_tokens":318,"output_tokens":34}}
    , .{});
    const response = try types.Response.fromJson(a, root);

    const questions = .{
        .is_urgent = noul("Does this convey urgency?"),
        .department = choice("Which team?", .{ .billing = null, .technical = null }),
        .frustration = score("How frustrated?", .{ .calm = "Calm", .frustrated = "Frustrated", .angry = "Very angry" }),
    };
    const r = try Result(@TypeOf(questions)).fromResponse(response);
    try testing.expectEqual(@as(f64, 0.95), r.answers.is_urgent);
    try testing.expectEqual(.billing, r.answers.department.choice);
    try testing.expectEqual(@as(f64, 0.12), r.answers.department.probability(.technical));
    try testing.expectEqual(.frustrated, r.answers.frustration.level());
    try testing.expectEqualStrings("jev-1.13.0", r.model());
    try testing.expectEqual(@as(u64, 34), r.usage.output_tokens);

    const wrong = .{ .department = choice("?", .{ .sales = null }) };
    try testing.expectError(error.InvalidResponse, Result(@TypeOf(wrong)).fromResponse(response));
    const missing = .{ .nope = noul("?") };
    try testing.expectError(error.InvalidResponse, Result(@TypeOf(missing)).fromResponse(response));
}
