# tai

A Zig SDK for the [TypeSafe System One API](https://docs.typesafe.ai/api).
Ask typed questions and get answers the compiler understands.

<!-- snippet: triage -->
```zig
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
```

- **Typed DSL**: question sets are struct literals. Choice options become
  enums, score levels become fixed arrays or enums, and the result owns no
  heap memory.
- **Runtime API**: `Client.systemOne` covers questions that aren't known
  until runtime.
- **Same behaviour as the official SDKs**: the same environment variables
  (`TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`), and
  retries with exponential backoff that honour `Retry-After` for 408, 429 and
  5xx (including 529 Overloaded).
- **Errors with detail**: precise error sets, plus an optional `Diagnostics`
  value with the HTTP status, response body and attempt count.
- **Standard library only**: built on `std.http.Client` and `std.Io`, so
  calls can be cancelled.

## Install

Requires Zig `0.17.0-dev.947` or later.

```sh
zig fetch --save git+https://github.com/benomahony/zig-typesafe-ai
```

Then, in `build.zig`:

<!-- snippet: install-build -->
```zig
const tai = b.dependency("tai", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("tai", tai.module("tai"));
```

## Quick start

<!-- snippet: quickstart -->
```zig
const std = @import("std");
const tai = @import("tai");

pub fn main(init: std.process.Init) !void {
    var client: tai.Client = try .init(init.gpa, init.io, .{ .environ_map = init.environ_map });
    defer client.deinit();

    const r = try client.ask("I was charged twice. Please help.", .{
        .billing = tai.noul("Is this about billing?"),
    }, .{});

    std.debug.print("billing: {d:.2} ({s})\n", .{ r.answers.billing, r.model() });
}
```

## Documentation

The guide lives in [`docs/`](docs/) and is built with [Zine](https://zine-ssg.io).

```sh
cd docs && zine            # dev server on http://localhost:1990
zig build docs             # generated API reference in zig-out/docs/api
```

## Development

```sh
zig build test --summary all   # unit tests + mock-server tests, no network needed
zig build examples             # build examples/
TYPESAFE_API_KEY=... zig build run-triage -- "My invoice is wrong"
```
