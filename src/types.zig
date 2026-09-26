//! Request and response types for the TypeSafe System One API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

pub const max_choice_options = 255;
pub const min_score_levels = 2;
pub const max_score_levels = 10;

/// A value that the API accepts as `string | object | array`: `state`,
/// `instructions`, and criteria descriptions.
pub const Content = union(enum) {
    /// Plain text, sent as a JSON string.
    text: []const u8,
    /// Structured data, sent as-is.
    json: std.json.Value,
    /// Pre-serialized JSON, written verbatim. Must be a single valid JSON value.
    raw: []const u8,

    /// Serializes any Zig value (structs, slices, ...) with `std.json` into
    /// a `.raw` Content. The returned bytes are owned by `allocator`.
    pub fn fromValue(allocator: Allocator, value: anytype) Allocator.Error!Content {
        return .{ .raw = try Stringify.valueAlloc(allocator, value, .{}) };
    }

    pub fn jsonStringify(self: Content, w: *Stringify) Stringify.Error!void {
        switch (self) {
            .text => |s| try w.write(s),
            .json => |v| try w.write(v),
            .raw => |r| {
                try w.beginWriteRaw();
                try w.writer.writeAll(r);
                w.endWriteRaw();
            },
        }
    }
};

/// A yes/no question. The answer is the probability that the answer is yes.
pub const Noul = struct {
    instructions: Content,
    criteria: ?Criteria = null,

    pub const Criteria = struct {
        /// What a yes (value near 1) means. Sent as `"true"`.
        yes: ?Content = null,
        /// What a no (value near 0) means. Sent as `"false"`.
        no: ?Content = null,
    };
};

/// Picks one option from a set you define.
pub const Choice = struct {
    instructions: Content,
    /// Between 1 and 255 options, sent as the `criteria` map in order.
    options: []const Option,

    pub const Option = struct {
        name: []const u8,
        /// Rubric description for this option; `null` sends JSON `null`.
        description: ?Content = null,
    };
};

/// Rates the state against ordered, descriptive levels.
pub const Score = struct {
    instructions: Content,
    /// Between 2 and 10 ordered level descriptions, sent as `criteria`.
    levels: []const Content,
};

pub const Question = union(enum) {
    noul: Noul,
    choice: Choice,
    score: Score,

    pub fn jsonStringify(self: Question, w: *Stringify) Stringify.Error!void {
        try w.beginObject();
        try w.objectField("type");
        try w.write(@tagName(self));
        switch (self) {
            .noul => |q| {
                try w.objectField("instructions");
                try w.write(q.instructions);
                if (q.criteria) |c| {
                    try w.objectField("criteria");
                    try w.beginObject();
                    if (c.yes) |yes| {
                        try w.objectField("true");
                        try w.write(yes);
                    }
                    if (c.no) |no| {
                        try w.objectField("false");
                        try w.write(no);
                    }
                    try w.endObject();
                }
            },
            .choice => |q| {
                try w.objectField("instructions");
                try w.write(q.instructions);
                try w.objectField("criteria");
                try w.beginObject();
                for (q.options) |option| {
                    try w.objectField(option.name);
                    try w.write(option.description);
                }
                try w.endObject();
            },
            .score => |q| {
                try w.objectField("instructions");
                try w.write(q.instructions);
                try w.objectField("criteria");
                try w.write(q.levels);
            },
        }
        try w.endObject();
    }
};

/// A question paired with the id its answer is returned under.
pub const NamedQuestion = struct {
    name: []const u8,
    question: Question,
};

pub const Request = struct {
    /// The content to evaluate.
    state: Content,
    /// Questions keyed by the name you choose; answers come back under the same names.
    questions: []const NamedQuestion,
    /// Overrides the client's default model for this request.
    model: ?[]const u8 = null,
};

pub const ValidationError = error{
    NoQuestions,
    EmptyQuestionName,
    DuplicateQuestionName,
    NoChoiceOptions,
    TooManyChoiceOptions,
    DuplicateChoiceOption,
    TooFewScoreLevels,
    TooManyScoreLevels,
};

/// Checks the limits the API documents, so bad requests fail before a network round trip.
pub fn validate(request: Request) ValidationError!void {
    if (request.questions.len == 0) return error.NoQuestions;
    for (request.questions, 0..) |named, i| {
        if (named.name.len == 0) return error.EmptyQuestionName;
        for (request.questions[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, named.name)) return error.DuplicateQuestionName;
        }
        switch (named.question) {
            .noul => {},
            .choice => |q| {
                if (q.options.len == 0) return error.NoChoiceOptions;
                if (q.options.len > max_choice_options) return error.TooManyChoiceOptions;
                for (q.options, 0..) |option, j| {
                    for (q.options[0..j]) |prev| {
                        if (std.mem.eql(u8, prev.name, option.name)) return error.DuplicateChoiceOption;
                    }
                }
            },
            .score => |q| {
                if (q.levels.len < min_score_levels) return error.TooFewScoreLevels;
                if (q.levels.len > max_score_levels) return error.TooManyScoreLevels;
            },
        }
    }
}

/// Writes the request body, using `default_model` when the request has no model.
pub fn writeRequest(w: *Stringify, request: Request, default_model: []const u8) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("state");
    try w.write(request.state);
    try w.objectField("model");
    try w.write(request.model orelse default_model);
    try w.objectField("questions");
    try w.beginObject();
    for (request.questions) |named| {
        try w.objectField(named.name);
        try w.write(named.question);
    }
    try w.endObject();
    try w.endObject();
}

pub const NoulAnswer = struct {
    /// Probability that the answer is yes, from 0 to 1.
    noul: f64,
};

pub const ChoiceAnswer = struct {
    /// The highest-probability option.
    choice: []const u8,
    /// Every option with its probability, in the order the API returned them.
    probabilities: []const OptionProbability,
    confidence: f64,

    pub const OptionProbability = struct {
        option: []const u8,
        probability: f64,
    };

    pub fn probabilityOf(self: ChoiceAnswer, option: []const u8) ?f64 {
        for (self.probabilities) |p| {
            if (std.mem.eql(u8, p.option, option)) return p.probability;
        }
        return null;
    }

    /// The chosen option as a member of enum `E`, or null if it is not one.
    pub fn as(self: ChoiceAnswer, comptime E: type) ?E {
        return std.meta.stringToEnum(E, self.choice);
    }
};

pub const ScoreAnswer = struct {
    /// Probability-weighted level; can land between levels.
    score: f64,
    /// One entry per level, ordered by level index.
    levels: []const Level,
    confidence: f64,

    pub const Level = struct {
        /// The level description from the response `legend`. Non-string
        /// descriptions are re-serialized as JSON text.
        description: []const u8,
        probability: f64,
    };

    /// Index of the single most probable level.
    pub fn mostLikelyLevel(self: ScoreAnswer) ?usize {
        if (self.levels.len == 0) return null;
        var best: usize = 0;
        for (self.levels, 0..) |level, i| {
            if (level.probability > self.levels[best].probability) best = i;
        }
        return best;
    }
};

pub const Answer = union(enum) {
    noul: NoulAnswer,
    choice: ChoiceAnswer,
    score: ScoreAnswer,
    /// An answer type this SDK version does not know about.
    unknown: std.json.Value,
};

pub const NamedAnswer = struct {
    name: []const u8,
    answer: Answer,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

pub const Response = struct {
    /// The versioned model id that answered, e.g. `jev-1.13.0`.
    model: []const u8,
    /// Answers in the order the API returned them.
    answers: []const NamedAnswer,
    usage: Usage,

    pub fn get(self: Response, name: []const u8) ?Answer {
        for (self.answers) |named| {
            if (std.mem.eql(u8, named.name, name)) return named.answer;
        }
        return null;
    }

    /// The noul answer named `name`, or null if missing or of another type.
    pub fn noul(self: Response, name: []const u8) ?NoulAnswer {
        const answer = self.get(name) orelse return null;
        return if (answer == .noul) answer.noul else null;
    }

    /// The choice answer named `name`, or null if missing or of another type.
    pub fn choice(self: Response, name: []const u8) ?ChoiceAnswer {
        const answer = self.get(name) orelse return null;
        return if (answer == .choice) answer.choice else null;
    }

    /// The score answer named `name`, or null if missing or of another type.
    pub fn score(self: Response, name: []const u8) ?ScoreAnswer {
        const answer = self.get(name) orelse return null;
        return if (answer == .score) answer.score else null;
    }

    /// Builds a Response from a parsed JSON body. All memory comes from `arena`.
    pub fn fromJson(arena: Allocator, root: std.json.Value) ParseError!Response {
        const obj = try expectObject(root);
        const answers_obj = try expectObject(obj.get("answers") orelse return error.InvalidResponse);
        const answers = try arena.alloc(NamedAnswer, answers_obj.count());
        for (answers_obj.keys(), answers_obj.values(), answers) |name, value, *out| {
            out.* = .{ .name = name, .answer = try parseAnswer(arena, value) };
        }
        var usage: Usage = .{};
        if (obj.get("usage")) |u| {
            const usage_obj = try expectObject(u);
            if (usage_obj.get("input_tokens")) |v| usage.input_tokens = try expectUnsigned(v);
            if (usage_obj.get("output_tokens")) |v| usage.output_tokens = try expectUnsigned(v);
        }
        return .{
            .model = try expectString(obj.get("model") orelse return error.InvalidResponse),
            .answers = answers,
            .usage = usage,
        };
    }
};

pub const ModelCard = struct {
    /// The model id or alias, as accepted by the `model` field.
    name: []const u8,
    description: []const u8,
    release_date: []const u8,
};

pub const ModelList = struct {
    models: []const ModelCard,
};

pub const ParseError = Allocator.Error || error{InvalidResponse};

fn parseAnswer(arena: Allocator, value: std.json.Value) ParseError!Answer {
    const obj = try expectObject(value);
    const kind = try expectString(obj.get("type") orelse return error.InvalidResponse);
    if (std.mem.eql(u8, kind, "noul")) {
        return .{ .noul = .{ .noul = try expectNumber(obj.get("noul") orelse return error.InvalidResponse) } };
    }
    if (std.mem.eql(u8, kind, "choice")) {
        const probs = try expectObject(obj.get("probabilities") orelse return error.InvalidResponse);
        const out = try arena.alloc(ChoiceAnswer.OptionProbability, probs.count());
        for (probs.keys(), probs.values(), out) |option, p, *o| {
            o.* = .{ .option = option, .probability = try expectNumber(p) };
        }
        return .{ .choice = .{
            .choice = try expectString(obj.get("choice") orelse return error.InvalidResponse),
            .probabilities = out,
            .confidence = try expectNumber(obj.get("confidence") orelse return error.InvalidResponse),
        } };
    }
    if (std.mem.eql(u8, kind, "score")) {
        const legend = try expectObject(obj.get("legend") orelse return error.InvalidResponse);
        const probs = try expectObject(obj.get("probabilities") orelse return error.InvalidResponse);
        const levels = try arena.alloc(ScoreAnswer.Level, legend.count());
        @memset(levels, .{ .description = "", .probability = 0 });
        for (legend.keys(), legend.values()) |key, description| {
            const i = try levelIndex(key, levels.len);
            levels[i].description = switch (description) {
                .string => |s| s,
                else => try Stringify.valueAlloc(arena, description, .{}),
            };
        }
        for (probs.keys(), probs.values()) |key, p| {
            levels[try levelIndex(key, levels.len)].probability = try expectNumber(p);
        }
        return .{ .score = .{
            .score = try expectNumber(obj.get("score") orelse return error.InvalidResponse),
            .levels = levels,
            .confidence = try expectNumber(obj.get("confidence") orelse return error.InvalidResponse),
        } };
    }
    return .{ .unknown = value };
}

fn levelIndex(key: []const u8, len: usize) error{InvalidResponse}!usize {
    const i = std.fmt.parseInt(usize, key, 10) catch return error.InvalidResponse;
    if (i >= len) return error.InvalidResponse;
    return i;
}

fn expectObject(v: std.json.Value) error{InvalidResponse}!std.json.ObjectMap {
    return if (v == .object) v.object else error.InvalidResponse;
}

fn expectString(v: std.json.Value) error{InvalidResponse}![]const u8 {
    return if (v == .string) v.string else error.InvalidResponse;
}

fn expectNumber(v: std.json.Value) error{InvalidResponse}!f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.InvalidResponse,
    };
}

fn expectUnsigned(v: std.json.Value) error{InvalidResponse}!u64 {
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else error.InvalidResponse;
}

const testing = std.testing;

fn expectJson(expected: []const u8, request: Request) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Stringify = .{ .writer = &out.writer };
    try writeRequest(&w, request, "jev-latest");
    try testing.expectEqualStrings(expected, out.written());
}

test "serializes every question type" {
    try expectJson(
        \\{"state":"Help! My payouts have been failing for 3 days.","model":"jev-latest","questions":{"is_urgent":{"type":"noul","instructions":"Does this convey urgency?","criteria":{"true":"Explicitly time-sensitive","false":"No urgency expressed"}},"department":{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":"Payments, invoicing, refunds","technical":null}},"frustration":{"type":"score","instructions":"How frustrated is the customer?","criteria":["Calm","Frustrated","Very angry"]}}}
    , .{
        .state = .{ .text = "Help! My payouts have been failing for 3 days." },
        .questions = &.{
            .{ .name = "is_urgent", .question = .{ .noul = .{
                .instructions = .{ .text = "Does this convey urgency?" },
                .criteria = .{
                    .yes = .{ .text = "Explicitly time-sensitive" },
                    .no = .{ .text = "No urgency expressed" },
                },
            } } },
            .{ .name = "department", .question = .{ .choice = .{
                .instructions = .{ .text = "Which team should handle this?" },
                .options = &.{
                    .{ .name = "billing", .description = .{ .text = "Payments, invoicing, refunds" } },
                    .{ .name = "technical" },
                },
            } } },
            .{ .name = "frustration", .question = .{ .score = .{
                .instructions = .{ .text = "How frustrated is the customer?" },
                .levels = &.{ .{ .text = "Calm" }, .{ .text = "Frustrated" }, .{ .text = "Very angry" } },
            } } },
        },
    });
}

test "structured content and model override" {
    const state = try Content.fromValue(testing.allocator, .{ .user = "ada", .messages = [_][]const u8{ "hi", "refund?" } });
    defer testing.allocator.free(state.raw);
    try expectJson(
        \\{"state":{"user":"ada","messages":["hi","refund?"]},"model":"jev-1.13.0","questions":{"q":{"type":"noul","instructions":{"question":"Is `user` asking for a refund?"}}}}
    , .{
        .state = state,
        .model = "jev-1.13.0",
        .questions = &.{.{ .name = "q", .question = .{ .noul = .{
            .instructions = .{ .raw = "{\"question\":\"Is `user` asking for a refund?\"}" },
        } } }},
    });
}

test "validate enforces documented limits" {
    const noul_q: Question = .{ .noul = .{ .instructions = .{ .text = "?" } } };
    try testing.expectError(error.NoQuestions, validate(.{ .state = .{ .text = "" }, .questions = &.{} }));
    try testing.expectError(error.DuplicateQuestionName, validate(.{ .state = .{ .text = "" }, .questions = &.{
        .{ .name = "a", .question = noul_q },
        .{ .name = "a", .question = noul_q },
    } }));
    try testing.expectError(error.TooFewScoreLevels, validate(.{ .state = .{ .text = "" }, .questions = &.{
        .{ .name = "s", .question = .{ .score = .{ .instructions = .{ .text = "?" }, .levels = &.{.{ .text = "only" }} } } },
    } }));
    try testing.expectError(error.DuplicateChoiceOption, validate(.{ .state = .{ .text = "" }, .questions = &.{
        .{ .name = "c", .question = .{ .choice = .{ .instructions = .{ .text = "?" }, .options = &.{ .{ .name = "x" }, .{ .name = "x" } } } } },
    } }));
    try validate(.{ .state = .{ .text = "" }, .questions = &.{.{ .name = "a", .question = noul_q }} });
}

test "parses every answer type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"model":"jev-1.13.0","answers":{
        \\  "is_urgent":{"type":"noul","noul":0.95},
        \\  "department":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"technical":0.12,"sales":0},"confidence":0.81},
        \\  "frustration":{"type":"score","score":1.05,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"0":0.0,"1":0.95,"2":0.05},"confidence":0.92},
        \\  "future":{"type":"ranking","order":[]}
        \\},"usage":{"input_tokens":318,"output_tokens":34}}
    , .{});
    const resp = try Response.fromJson(a, root);

    try testing.expectEqualStrings("jev-1.13.0", resp.model);
    try testing.expectEqual(@as(u64, 318), resp.usage.input_tokens);
    try testing.expectEqual(@as(f64, 0.95), resp.noul("is_urgent").?.noul);

    const dept = resp.choice("department").?;
    try testing.expectEqual(.billing, dept.as(enum { billing, technical, sales }).?);
    try testing.expectEqual(@as(f64, 0.0), dept.probabilityOf("sales").?);

    const frustration = resp.score("frustration").?;
    try testing.expectEqual(@as(usize, 3), frustration.levels.len);
    try testing.expectEqualStrings("Very angry", frustration.levels[2].description);
    try testing.expectEqual(@as(usize, 1), frustration.mostLikelyLevel().?);

    try testing.expect(resp.get("future").? == .unknown);
    try testing.expect(resp.noul("department") == null);
    try testing.expect(resp.get("missing") == null);
}

test "rejects malformed answers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"model":"m","answers":{"s":{"type":"score","score":1,"legend":{"0":"a"},"probabilities":{"7":1},"confidence":1}}}
    , .{});
    try testing.expectError(error.InvalidResponse, Response.fromJson(a, root));
}
