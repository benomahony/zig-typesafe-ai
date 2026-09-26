//! Client for the TypeSafe System One API.
//!
// snippet: client-init
//! ```zig
//! var client: tai.Client = try .init(gpa, io, .{
//!     .api_key = api_key, // default: TYPESAFE_API_KEY from environ_map
//!     .base_url = "https://api.typesafe.ai", // default: TYPESAFE_BASE_URL, then this
//!     .model = "jev-latest", // default: TYPESAFE_DEFAULT_MODEL, then this
//!     .retry = .{ .max_retries = 3, .backoff_max_ms = 10_000 },
//!     .extra_headers = &.{.{ .name = "x-request-source", .value = "docs" }},
//! });
//! defer client.deinit();
//! ```
//!
//! Requests are safe to issue from multiple threads; the connection pool is shared.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stringify = std.json.Stringify;

const types = @import("types.zig");
const dsl = @import("dsl.zig");
const retry_mod = @import("retry.zig");
const RetryPolicy = retry_mod.RetryPolicy;

pub const version = "0.1.0";

pub const default_base_url = "https://api.typesafe.ai";
pub const default_model = "jev-latest";

/// Environment variable names, shared with the official SDKs.
pub const env = struct {
    pub const api_key = "TYPESAFE_API_KEY";
    pub const base_url = "TYPESAFE_BASE_URL";
    pub const default_model = "TYPESAFE_DEFAULT_MODEL";
};

gpa: Allocator,
io: Io,
http: std.http.Client,
/// API root with trailing slashes removed.
base_url: []const u8,
/// Model used when a request does not set one.
model: []const u8,
retry: RetryPolicy,
extra_headers: []const std.http.Header,
authorization: []const u8,

pub const Options = struct {
    /// Falls back to `TYPESAFE_API_KEY` in `environ_map`.
    api_key: ?[]const u8 = null,
    /// Falls back to `TYPESAFE_BASE_URL`, then `https://api.typesafe.ai`.
    base_url: ?[]const u8 = null,
    /// Falls back to `TYPESAFE_DEFAULT_MODEL`, then `jev-latest`.
    model: ?[]const u8 = null,
    retry: RetryPolicy = .{},
    /// Sent with every request. Must outlive the client.
    extra_headers: []const std.http.Header = &.{},
    /// Environment to read fallbacks from, e.g. `init.environ_map` in `main`.
    /// Empty or whitespace-only values are ignored.
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const InitError = Allocator.Error || error{MissingApiKey};

/// Non-2xx responses, after retries. `Diagnostics` holds the status and body.
pub const ApiError = error{
    BadRequest,
    Unauthorized,
    PermissionDenied,
    NotFound,
    RequestTimeout,
    UnprocessableEntity,
    RateLimited,
    Overloaded,
    ServerError,
    UnexpectedStatus,
};

pub const Error = ApiError || types.ValidationError || Allocator.Error || error{
    /// The server could not be reached, or the connection dropped. See `Diagnostics.transport_error`.
    ConnectionFailed,
    /// `base_url` is not an http(s) URL with a host.
    InvalidBaseUrl,
    /// The response body did not match the documented shape.
    InvalidResponse,
    Canceled,
};

/// Extra detail about a failed (or successful) call. Pass a pointer in
/// `CallOptions.diagnostics` and call `deinit` when done.
pub const Diagnostics = struct {
    allocator: ?Allocator = null,
    /// HTTP status of the last response, if any.
    status: ?std.http.Status = null,
    /// Body of the last non-2xx response, typically JSON describing the problem.
    body: []const u8 = "",
    /// Attempts made, including the first.
    attempts: u32 = 0,
    /// Underlying transport error behind `error.ConnectionFailed`.
    transport_error: ?anyerror = null,

    pub fn deinit(self: *Diagnostics) void {
        if (self.allocator) |a| a.free(self.body);
        self.* = .{};
    }

    fn setBody(self: *Diagnostics, gpa: Allocator, body: []const u8) Allocator.Error!void {
        if (self.allocator) |a| a.free(self.body);
        self.body = "";
        self.body = try gpa.dupe(u8, body);
        self.allocator = gpa;
    }
};

pub const CallOptions = struct {
    diagnostics: ?*Diagnostics = null,
    /// Overrides the client's retry policy for this call.
    retry: ?RetryPolicy = null,
    /// Overrides the client's model for this call (`Client.ask` only; `Request` has its own field).
    model: ?[]const u8 = null,
};

pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    const api_key = options.api_key orelse envValue(options.environ_map, env.api_key) orelse
        return error.MissingApiKey;
    const base_url = std.mem.trimEnd(u8, options.base_url orelse
        envValue(options.environ_map, env.base_url) orelse default_base_url, "/");
    const model = options.model orelse envValue(options.environ_map, env.default_model) orelse default_model;

    const owned_base_url = try gpa.dupe(u8, base_url);
    errdefer gpa.free(owned_base_url);
    const owned_model = try gpa.dupe(u8, model);
    errdefer gpa.free(owned_model);
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});

    return .{
        .gpa = gpa,
        .io = io,
        .http = .{ .allocator = gpa, .io = io },
        .base_url = owned_base_url,
        .model = owned_model,
        .retry = options.retry,
        .extra_headers = options.extra_headers,
        .authorization = authorization,
    };
}

pub fn deinit(self: *Client) void {
    self.http.deinit();
    self.gpa.free(self.base_url);
    self.gpa.free(self.model);
    std.crypto.secureZero(u8, @constCast(self.authorization));
    self.gpa.free(self.authorization);
    self.* = undefined;
}

fn envValue(map: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, (map orelse return null).get(name) orelse return null, " \t\r\n");
    return if (value.len == 0) null else value;
}

/// Asks typed questions about `state` using the DSL. See `tai.noul`,
/// `tai.choice`, and `tai.score`. `state` can be a string or any value
/// `std.json` can serialize.
pub fn ask(self: *Client, state: anytype, questions: anytype, call: CallOptions) Error!dsl.Result(@TypeOf(questions)) {
    var payload: Io.Writer.Allocating = .init(self.gpa);
    defer payload.deinit();
    var w: Stringify = .{ .writer = &payload.writer };
    dsl.writeRequest(&w, state, questions, call.model orelse self.model) catch return error.OutOfMemory;

    var parsed = try self.post("/v1/systemone", payload.written(), call);
    defer parsed.deinit();
    return dsl.Result(@TypeOf(questions)).fromResponse(parsed.value);
}

/// Sends a request built at runtime. Use this when the set of questions is
/// not known at compile time; otherwise prefer `ask`.
pub fn systemOne(self: *Client, request: types.Request, call: CallOptions) Error!std.json.Parsed(types.Response) {
    try types.validate(request);
    var payload: Io.Writer.Allocating = .init(self.gpa);
    defer payload.deinit();
    var w: Stringify = .{ .writer = &payload.writer };
    types.writeRequest(&w, request, self.model) catch return error.OutOfMemory;
    return self.post("/v1/systemone", payload.written(), call);
}

/// Lists the model names the account can send in the `model` field.
pub fn listModels(self: *Client, call: CallOptions) Error!std.json.Parsed(types.ModelList) {
    const body = try self.send(.GET, "/v1/models", null, call);
    defer self.gpa.free(body);
    return std.json.parseFromSlice(types.ModelList, self.gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn post(self: *Client, path: []const u8, payload: []const u8, call: CallOptions) Error!std.json.Parsed(types.Response) {
    const body = try self.send(.POST, path, payload, call);
    defer self.gpa.free(body);

    const arena = try self.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(self.gpa);
    errdefer {
        arena.deinit();
        self.gpa.destroy(arena);
    }
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    return .{ .arena = arena, .value = try types.Response.fromJson(a, root) };
}

/// Sends a request with retries and returns the 2xx body, owned by `gpa`.
fn send(self: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8, call: CallOptions) Error![]u8 {
    const policy = call.retry orelse self.retry;
    const url = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ self.base_url, path });
    defer self.gpa.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;

    var retries: u32 = 0;
    while (true) : (retries += 1) {
        if (call.diagnostics) |d| d.attempts = retries + 1;
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();

        var transport_err: ?anyerror = null;
        const outcome = self.attempt(method, uri, payload, &body.writer, &transport_err) catch |err| switch (err) {
            error.ConnectionFailed => |e| {
                if (call.diagnostics) |d| d.transport_error = transport_err;
                if (policy.retry_connection_errors and retries < policy.max_retries) {
                    try self.sleepMs(policy.delayMs(retries, self.randomUnit(), null));
                    continue;
                }
                return e;
            },
            else => |e| return e,
        };

        const code = @intFromEnum(outcome.status);
        if (call.diagnostics) |d| d.status = outcome.status;
        if (code >= 200 and code < 300) return body.toOwnedSlice();

        if (call.diagnostics) |d| try d.setBody(self.gpa, body.written());
        if (policy.retry_status(code) and retries < policy.max_retries) {
            try self.sleepMs(policy.delayMs(retries, self.randomUnit(), outcome.retry_after_ms));
            continue;
        }
        return statusError(code);
    }
}

fn statusError(code: u10) ApiError {
    return switch (code) {
        400 => error.BadRequest,
        401 => error.Unauthorized,
        403 => error.PermissionDenied,
        404 => error.NotFound,
        408 => error.RequestTimeout,
        422 => error.UnprocessableEntity,
        429 => error.RateLimited,
        529 => error.Overloaded,
        500...528, 530...599 => error.ServerError,
        else => error.UnexpectedStatus,
    };
}

const Outcome = struct {
    status: std.http.Status,
    retry_after_ms: ?u64,
};

const AttemptError = error{ ConnectionFailed, InvalidBaseUrl, OutOfMemory, Canceled };

/// One HTTP round trip. Streams the response body into `body`.
fn attempt(
    self: *Client,
    method: std.http.Method,
    uri: std.Uri,
    payload: ?[]const u8,
    body: *Io.Writer,
    transport_err: *?anyerror,
) AttemptError!Outcome {
    var headers_buf: [max_extra_headers + 1]std.http.Header = undefined;
    headers_buf[0] = .{ .name = "accept", .value = "application/json" };
    const n = @min(self.extra_headers.len, max_extra_headers);
    @memcpy(headers_buf[1..][0..n], self.extra_headers[0..n]);

    var req = self.http.request(method, uri, .{
        .redirect_behavior = .unhandled,
        // Redirects are never followed, so the key cannot leak to another host.
        .headers = .{
            .authorization = .{ .override = self.authorization },
            .user_agent = .{ .override = "tai-zig/" ++ version },
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
        },
        .extra_headers = headers_buf[0 .. n + 1],
    }) catch |err| return transportError(transport_err, err);
    defer req.deinit();

    if (payload) |bytes| {
        req.transfer_encoding = .{ .content_length = bytes.len };
        var request_body = req.sendBodyUnflushed(&.{}) catch |err| return transportError(transport_err, streamError(&req, err));
        request_body.writer.writeAll(bytes) catch |err| return transportError(transport_err, streamError(&req, err));
        request_body.end() catch |err| return transportError(transport_err, streamError(&req, err));
        req.connection.?.flush() catch |err| return transportError(transport_err, streamError(&req, err));
    } else {
        req.sendBodiless() catch |err| return transportError(transport_err, streamError(&req, err));
    }

    var response = req.receiveHead(&.{}) catch |err| return transportError(transport_err, streamError(&req, err));

    // Header strings are invalidated once the body reader is created.
    var retry_after_ms: ?u64 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        const ms = retry_mod.parseRetryAfter(header.name, header.value) orelse continue;
        // `retry-after-ms` is more precise than `Retry-After`.
        if (retry_after_ms == null or std.ascii.eqlIgnoreCase(header.name, "retry-after-ms")) retry_after_ms = ms;
    }
    const status = response.head.status;

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try self.gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try self.gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return transportError(transport_err, error.UnsupportedCompressionMethod),
    };
    defer self.gpa.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(body) catch |err| switch (err) {
        error.ReadFailed => return transportError(transport_err, streamError(&req, response.bodyErr() orelse error.ReadFailed)),
        error.WriteFailed => return error.OutOfMemory,
    };

    return .{ .status = status, .retry_after_ms = retry_after_ms };
}

const max_extra_headers = 32;

/// Replaces the generic `ReadFailed`/`WriteFailed` with the connection's
/// underlying error, so that cancellation surfaces as `error.Canceled`.
fn streamError(req: *std.http.Client.Request, err: anyerror) anyerror {
    const connection = req.connection orelse return err;
    return switch (err) {
        error.ReadFailed => connection.getReadError() orelse err,
        error.WriteFailed => connection.stream_writer.err orelse err,
        else => err,
    };
}

fn transportError(out: *?anyerror, err: anyerror) AttemptError {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => return error.InvalidBaseUrl,
        else => {
            out.* = err;
            return error.ConnectionFailed;
        },
    }
}

fn sleepMs(self: *Client, ms: u64) error{Canceled}!void {
    if (ms == 0) return;
    try self.io.sleep(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), .awake);
}

fn randomUnit(self: *Client) f64 {
    var buf: [8]u8 = undefined;
    self.io.random(&buf);
    return @as(f64, @floatFromInt(std.mem.readInt(u64, &buf, .little) >> 11)) / (1 << 53);
}
