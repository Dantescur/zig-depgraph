//! Semantic validation and normalization of parsed manifests.
//!
//! The parser is intentionally permissive: it extracts whatever metadata is
//! present and leaves semantic rules to this module. Validation produces a
//! normalized manifest whose dependency sources are guaranteed to be either a
//! complete remote source or a local path.

const std = @import("std");

const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;

pub const ErrorKind = enum {
    missing_field,
    invalid_version,
    invalid_minimum_zig_version,
    missing_source,
    incomplete_remote_source,
    local_source_with_remote,
    invalid_dependency_version,
};

pub const ValidationError = struct {
    kind: ErrorKind,
    field: []const u8,
    dependency: ?[]const u8 = null,
    message: []const u8,
};

pub const Diagnostics = struct {
    errors: []const ValidationError = &.{},
};

pub const DependencySource = union(enum) {
    remote: struct {
        url: []const u8,
        hash: []const u8,
    },
    local: struct {
        path: []const u8,
    },
};

pub const ValidatedDependency = struct {
    name: []const u8,
    source: DependencySource,
    lazy: bool = false,
    version: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
};

pub const ValidatedManifest = struct {
    name: []const u8,
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: ?[]const u8 = null,
    paths: []const []const u8,
    dependencies: std.StringArrayHashMapUnmanaged(ValidatedDependency) = .empty,
};

/// Validates `manifest` and, when successful, returns a normalized manifest
/// allocated from `allocator`. The normalized manifest does not borrow from
/// `manifest`, so the parsed manifest may be deinitialized afterwards.
///
/// If validation fails, returns `null` and populates `diagnostics`. Both the
/// normalized manifest and diagnostics live in `allocator`, whose lifetime is
/// controlled by the caller.
pub fn validate(
    allocator: Allocator,
    manifest: *const parser.Manifest,
    diagnostics: *Diagnostics,
) Allocator.Error!?ValidatedManifest {
    diagnostics.* = .{};

    var errors: std.ArrayList(ValidationError) = .empty;
    errdefer errors.deinit(allocator);

    if (manifest.name == null) {
        try addError(allocator, &errors, .missing_field, "name", null, "manifest is missing the required 'name' field");
    }

    if (manifest.version) |version| {
        if (std.SemanticVersion.parse(version)) |_| {} else |_| {
            try addError(allocator, &errors, .invalid_version, "version", null, "'version' is not a valid semantic version");
        }
    } else {
        try addError(allocator, &errors, .missing_field, "version", null, "manifest is missing the required 'version' field");
    }

    if (manifest.fingerprint == null) {
        try addError(allocator, &errors, .missing_field, "fingerprint", null, "manifest is missing the required 'fingerprint' field");
    }

    if (manifest.paths.len == 0) {
        try addError(allocator, &errors, .missing_field, "paths", null, "manifest must declare at least one path");
    }

    if (manifest.minimum_zig_version) |version| {
        if (std.SemanticVersion.parse(version)) |_| {} else |_| {
            try addError(allocator, &errors, .invalid_minimum_zig_version, "minimum_zig_version", null, "'minimum_zig_version' is not a valid semantic version");
        }
    }

    var iterator = manifest.dependencies.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const dependency = entry.value_ptr.*;

        try validateDependencySource(allocator, &errors, name, dependency);

        if (dependency.version) |version| {
            if (std.SemanticVersion.parse(version)) |_| {} else |_| {
                try addError(allocator, &errors, .invalid_dependency_version, "version", name, "dependency 'version' is not a valid semantic version");
            }
        }
    }

    diagnostics.* = .{ .errors = try errors.toOwnedSlice(allocator) };
    if (diagnostics.errors.len > 0) return null;

    return try normalize(allocator, manifest);
}

fn validateDependencySource(
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
    name: []const u8,
    dependency: parser.Dependency,
) Allocator.Error!void {
    if (dependency.path != null) {
        if (dependency.url != null or dependency.hash != null) {
            try addError(
                allocator,
                errors,
                .local_source_with_remote,
                "source",
                name,
                "a local dependency cannot also specify 'url' or 'hash'",
            );
        }
        return;
    }

    if (dependency.url == null and dependency.hash == null) {
        try addError(
            allocator,
            errors,
            .missing_source,
            "source",
            name,
            "dependency must specify either 'path' or both 'url' and 'hash'",
        );
    } else if (dependency.url == null) {
        try addError(
            allocator,
            errors,
            .incomplete_remote_source,
            "url",
            name,
            "a remote dependency requires 'url'",
        );
    } else if (dependency.hash == null) {
        try addError(
            allocator,
            errors,
            .incomplete_remote_source,
            "hash",
            name,
            "a remote dependency requires 'hash'",
        );
    }
}

fn addError(
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
    kind: ErrorKind,
    field: []const u8,
    dependency: ?[]const u8,
    message: []const u8,
) Allocator.Error!void {
    try errors.append(allocator, .{
        .kind = kind,
        .field = field,
        .dependency = if (dependency) |name| try allocator.dupe(u8, name) else null,
        .message = message,
    });
}

fn normalize(allocator: Allocator, manifest: *const parser.Manifest) Allocator.Error!ValidatedManifest {
    var dependencies: std.StringArrayHashMapUnmanaged(ValidatedDependency) = .empty;

    var iterator = manifest.dependencies.iterator();
    while (iterator.next()) |entry| {
        const dependency = entry.value_ptr.*;
        const name = try allocator.dupe(u8, entry.key_ptr.*);

        const source: DependencySource = if (dependency.path) |path| .{
            .local = .{ .path = try allocator.dupe(u8, path) },
        } else .{
            .remote = .{
                .url = try allocator.dupe(u8, dependency.url.?),
                .hash = try allocator.dupe(u8, dependency.hash.?),
            },
        };

        try dependencies.put(allocator, name, .{
            .name = name,
            .source = source,
            .lazy = dependency.lazy,
            .version = if (dependency.version) |version| try allocator.dupe(u8, version) else null,
            .paths = try cloneStrings(allocator, dependency.paths),
        });
    }

    return .{
        .name = try allocator.dupe(u8, manifest.name.?),
        .version = try allocator.dupe(u8, manifest.version.?),
        .fingerprint = manifest.fingerprint.?,
        .minimum_zig_version = if (manifest.minimum_zig_version) |version| try allocator.dupe(u8, version) else null,
        .paths = try cloneStrings(allocator, manifest.paths),
        .dependencies = dependencies,
    };
}

fn cloneStrings(allocator: Allocator, values: []const []const u8) Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| {
        result[i] = try allocator.dupe(u8, value);
    }
    return result;
}

const fixtures = struct {
    const simple = @embedFile("fixtures/simple.zon");
    const no_dependencies = @embedFile("fixtures/no_dependencies.zon");
    const invalid_sources = @embedFile("fixtures/invalid_sources.zon");
};

test "normalizes a valid manifest" {
    var manifest = try parser.parse(std.testing.allocator, fixtures.simple);
    defer manifest.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = undefined;
    const maybe_validated = try validate(arena.allocator(), &manifest, &diagnostics);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.errors.len);
    const validated = maybe_validated orelse return error.TestExpectedValid;

    try std.testing.expectEqualStrings("zig_depgraph", validated.name);
    try std.testing.expectEqualStrings("0.1.0", validated.version);
    try std.testing.expectEqual(@as(u64, 0x498ba4ead7efad7f), validated.fingerprint);
    try std.testing.expectEqualStrings("0.17.1", validated.minimum_zig_version.?);
    try std.testing.expectEqual(@as(usize, 3), validated.paths.len);

    const httpz = validated.dependencies.get("httpz").?;
    try std.testing.expectEqualStrings("https://example.com/httpz.tar.gz", httpz.source.remote.url);
    try std.testing.expectEqualStrings("httpz-0.1.0-abc", httpz.source.remote.hash);
    try std.testing.expectEqualStrings("0.1.0", httpz.version.?);
    try std.testing.expectEqual(@as(usize, 2), httpz.paths.len);

    const custom = validated.dependencies.get("custom").?;
    try std.testing.expectEqualStrings("../custom", custom.source.local.path);
    try std.testing.expect(custom.lazy);
}

test "normalized manifest does not borrow from the parsed manifest" {
    var manifest = try parser.parse(std.testing.allocator, fixtures.simple);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = undefined;
    const validated = (try validate(arena.allocator(), &manifest, &diagnostics)).?;

    manifest.deinit();

    try std.testing.expectEqualStrings("zig_depgraph", validated.name);
    const httpz = validated.dependencies.get("httpz").?;
    try std.testing.expectEqualStrings("https://example.com/httpz.tar.gz", httpz.source.remote.url);
}

test "reports invalid dependency sources" {
    var manifest = try parser.parse(std.testing.allocator, fixtures.invalid_sources);
    defer manifest.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = undefined;
    const maybe_validated = try validate(arena.allocator(), &manifest, &diagnostics);

    try std.testing.expect(maybe_validated == null);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.errors.len);

    for (diagnostics.errors) |validation_error| {
        const dependency = validation_error.dependency.?;
        if (std.mem.eql(u8, dependency, "url_only")) {
            try std.testing.expectEqual(ErrorKind.incomplete_remote_source, validation_error.kind);
            try std.testing.expectEqualStrings("hash", validation_error.field);
        } else if (std.mem.eql(u8, dependency, "path_and_url")) {
            try std.testing.expectEqual(ErrorKind.local_source_with_remote, validation_error.kind);
            try std.testing.expectEqualStrings("source", validation_error.field);
        } else if (std.mem.eql(u8, dependency, "no_source")) {
            try std.testing.expectEqual(ErrorKind.missing_source, validation_error.kind);
            try std.testing.expectEqualStrings("source", validation_error.field);
        } else {
            return error.UnexpectedDependency;
        }
    }
}

test "reports missing required manifest fields" {
    var manifest = try parser.parse(std.testing.allocator, fixtures.no_dependencies);
    defer manifest.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = undefined;
    const maybe_validated = try validate(arena.allocator(), &manifest, &diagnostics);

    try std.testing.expect(maybe_validated == null);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.errors.len);
    try std.testing.expectEqual(ErrorKind.missing_field, diagnostics.errors[0].kind);
    try std.testing.expectEqualStrings("version", diagnostics.errors[0].field);
    try std.testing.expectEqual(ErrorKind.missing_field, diagnostics.errors[1].kind);
    try std.testing.expectEqualStrings("fingerprint", diagnostics.errors[1].field);
}

test "reports invalid semantic versions" {
    const source =
        \\.{
        \\    .name = .bad_versions,
        \\    .version = "not-a-version",
        \\    .fingerprint = 1,
        \\    .minimum_zig_version = "also-bad",
        \\    .paths = .{
        \\        "build.zig",
        \\    },
        \\    .dependencies = .{
        \\        .remote = .{
        \\            .url = "https://example.com/remote.tar.gz",
        \\            .hash = "hash",
        \\            .version = "bad-too",
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parser.parse(std.testing.allocator, source);
    defer manifest.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = undefined;
    const maybe_validated = try validate(arena.allocator(), &manifest, &diagnostics);

    try std.testing.expect(maybe_validated == null);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.errors.len);
    try std.testing.expectEqual(ErrorKind.invalid_version, diagnostics.errors[0].kind);
    try std.testing.expectEqual(ErrorKind.invalid_minimum_zig_version, diagnostics.errors[1].kind);
    try std.testing.expectEqual(ErrorKind.invalid_dependency_version, diagnostics.errors[2].kind);
    try std.testing.expectEqualStrings("remote", diagnostics.errors[2].dependency.?);
}
