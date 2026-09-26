//! tai: a Zig SDK for the TypeSafe System One API (https://docs.typesafe.ai/api).
//!
//! ```zig
//! const tai = @import("tai");
//!
//! var client: tai.Client = try .init(gpa, io, .{ .environ_map = init.environ_map });
//! defer client.deinit();
//!
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
//! switch (r.answers.department.choice) {
//!     .billing => {}, .technical => {}, .sales => {},
//! }
//! ```

const std = @import("std");

pub const Client = @import("Client.zig");
pub const RetryPolicy = @import("retry.zig").RetryPolicy;

const dsl = @import("dsl.zig");
pub const noul = dsl.noul;
pub const choice = dsl.choice;
pub const score = dsl.score;
pub const Answers = dsl.Answers;
pub const Result = dsl.Result;
pub const ChoiceResult = dsl.ChoiceResult;
pub const ScoreResult = dsl.ScoreResult;

const types = @import("types.zig");
pub const Content = types.Content;
pub const Question = types.Question;
pub const Noul = types.Noul;
pub const Choice = types.Choice;
pub const Score = types.Score;
pub const NamedQuestion = types.NamedQuestion;
pub const Request = types.Request;
pub const Response = types.Response;
pub const Answer = types.Answer;
pub const NamedAnswer = types.NamedAnswer;
pub const NoulAnswer = types.NoulAnswer;
pub const ChoiceAnswer = types.ChoiceAnswer;
pub const ScoreAnswer = types.ScoreAnswer;
pub const Usage = types.Usage;
pub const ModelCard = types.ModelCard;
pub const ModelList = types.ModelList;
pub const ValidationError = types.ValidationError;
pub const validate = types.validate;

test {
    std.testing.refAllDecls(@This());
    _ = types;
    _ = dsl;
    _ = @import("retry.zig");
    _ = @import("tests.zig");
}
