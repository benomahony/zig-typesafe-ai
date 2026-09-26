//! Retry policy, backoff, and `Retry-After` handling. Defaults match the
//! official Python and JavaScript SDKs.

const std = @import("std");

pub const RetryPolicy = struct {
    /// Retries after the initial attempt; `0` disables retries.
    max_retries: u32 = 2,
    /// First backoff delay, doubled each retry up to `backoff_max_ms`.
    backoff_initial_ms: u64 = 500,
    backoff_max_ms: u64 = 5_000,
    /// Fraction of each backoff delay randomly subtracted, from 0 to 1.
    backoff_jitter: f64 = 0.25,
    /// Honor `Retry-After` and `retry-after-ms` response headers up to `max_retry_after_ms`.
    respect_retry_after: bool = true,
    /// Server-requested delays longer than this fall back to backoff.
    max_retry_after_ms: u64 = 60_000,
    /// Retry when the server cannot be reached or the connection drops.
    retry_connection_errors: bool = true,
    /// HTTP statuses to retry.
    retry_status: *const fn (status: u10) bool = defaultRetryStatus,

    pub const none: RetryPolicy = .{ .max_retries = 0 };

    /// Retries 408, 429, and every 5xx (including 529 Overloaded).
    pub fn defaultRetryStatus(status: u10) bool {
        return status == 408 or status == 429 or (status >= 500 and status <= 599);
    }

    /// Delay before retry number `retry` (0-based). `unit` is a random value in [0, 1).
    pub fn backoffMs(self: RetryPolicy, retry: u32, unit: f64) u64 {
        if (self.backoff_initial_ms == 0 or self.backoff_max_ms == 0) return 0;
        const shift: u6 = @intCast(@min(retry, 32));
        const base = std.math.mul(u64, self.backoff_initial_ms, @as(u64, 1) << shift) catch self.backoff_max_ms;
        const capped: f64 = @floatFromInt(@min(base, self.backoff_max_ms));
        const jitter = std.math.clamp(self.backoff_jitter, 0, 1);
        return @intFromFloat(capped * (1 - jitter * unit));
    }

    /// The delay to wait before the next attempt, preferring a server-requested delay.
    pub fn delayMs(self: RetryPolicy, retry: u32, unit: f64, retry_after_ms: ?u64) u64 {
        if (self.respect_retry_after) {
            if (retry_after_ms) |ms| if (ms <= self.max_retry_after_ms) return ms;
        }
        return self.backoffMs(retry, unit);
    }
};

/// Parses `retry-after-ms` (milliseconds) or `Retry-After` (seconds) header values.
/// HTTP-date values are ignored so backoff applies instead.
pub fn parseRetryAfter(name: []const u8, value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const scale: f64 = if (std.ascii.eqlIgnoreCase(name, "retry-after-ms"))
        1
    else if (std.ascii.eqlIgnoreCase(name, "retry-after"))
        1000
    else
        return null;
    const n = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!std.math.isFinite(n) or n < 0) return null;
    return @intFromFloat(@ceil(n * scale));
}

const testing = std.testing;

test "backoff doubles, caps, and applies jitter" {
    const p: RetryPolicy = .{};
    try testing.expectEqual(@as(u64, 500), p.backoffMs(0, 0));
    try testing.expectEqual(@as(u64, 1000), p.backoffMs(1, 0));
    try testing.expectEqual(@as(u64, 5000), p.backoffMs(10, 0));
    try testing.expectEqual(@as(u64, 5000), p.backoffMs(100, 0));
    try testing.expectEqual(@as(u64, 375), p.backoffMs(0, 1));
    try testing.expectEqual(@as(u64, 0), (RetryPolicy{ .backoff_initial_ms = 0 }).backoffMs(3, 0));
}

test "retry-after takes precedence within limit" {
    const p: RetryPolicy = .{};
    try testing.expectEqual(@as(u64, 2000), p.delayMs(0, 0, 2000));
    try testing.expectEqual(@as(u64, 500), p.delayMs(0, 0, 120_000));
    try testing.expectEqual(@as(u64, 500), (RetryPolicy{ .respect_retry_after = false }).delayMs(0, 0, 2000));
}

test "parses retry-after headers" {
    try testing.expectEqual(@as(?u64, 3000), parseRetryAfter("Retry-After", "3"));
    try testing.expectEqual(@as(?u64, 1500), parseRetryAfter("retry-after", " 1.5 "));
    try testing.expectEqual(@as(?u64, 250), parseRetryAfter("retry-after-ms", "250"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("x-other", "3"));
}

test "default retryable statuses" {
    for ([_]u10{ 408, 429, 500, 503, 529 }) |s| try testing.expect(RetryPolicy.defaultRetryStatus(s));
    for ([_]u10{ 400, 401, 403, 404, 422 }) |s| try testing.expect(!RetryPolicy.defaultRetryStatus(s));
}
