//! Parses a `build.zig.zon`-style manifest from ZON source.
//!
//! The parser goes through `std.zig.Ast` and `std.zig.ZonGen` to obtain a
//! `Zoir` (Zig Object Intermediate Representation), which lets us discover
//! arbitrary dependency names instead of forcing the manifest into a fixed
//! Zig struct. `Zoir` is an implementation detail and never escapes this file.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;

pub const Error = error{
    OutOfMemory,
    InvalidZon,
    InvalidManifest,
};

pub const Dependency = struct {
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    lazy: bool = false,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    fingerprint: ?u64 = null,
    minimum_zig_version: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    dependencies: std.StringArrayHashMapUnmanaged(Dependency) = .empty,

    /// Frees every allocation owned by this manifest.
    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn dependency(self: *const Manifest, name: []const u8) ?Dependency {
        return self.dependencies.get(name);
    }
};

/// Parses `source` as a ZON manifest.
///
/// The returned manifest owns all of its data. Call `Manifest.deinit` when it
/// is no longer needed.
pub fn parse(allocator: Allocator, source: []const u8) Error!Manifest {
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);

    var ast = try Ast.parse(allocator, source_z, .{ .mode = .zon });
    defer ast.deinit(allocator);

    var zoir = try ZonGen.generate(allocator, ast, .{});
    defer zoir.deinit(allocator);

    if (zoir.hasCompileErrors()) return error.InvalidZon;

    var manifest: Manifest = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer manifest.deinit();

    const root = Zoir.Node.Index.root.get(&zoir);
    const fields = switch (root) {
        .struct_literal => |literal| literal,
        else => return error.InvalidManifest,
    };

    const arena = manifest.arena.allocator();

    for (fields.names, 0..) |field_name_nts, i| {
        const field_name = field_name_nts.get(&zoir);
        const value = fields.vals.at(@intCast(i)).get(&zoir);

        if (std.mem.eql(u8, field_name, "name")) {
            manifest.name = try dupeString(arena, value, &zoir);
        } else if (std.mem.eql(u8, field_name, "version")) {
            manifest.version = try dupeString(arena, value, &zoir);
        } else if (std.mem.eql(u8, field_name, "fingerprint")) {
            manifest.fingerprint = try extractU64(value);
        } else if (std.mem.eql(u8, field_name, "minimum_zig_version")) {
            manifest.minimum_zig_version = try dupeString(arena, value, &zoir);
        } else if (std.mem.eql(u8, field_name, "paths")) {
            manifest.paths = try extractStringArray(arena, value, &zoir);
        } else if (std.mem.eql(u8, field_name, "dependencies")) {
            try extractDependencies(&manifest, value, &zoir);
        }
    }

    return manifest;
}

fn extractDependencies(manifest: *Manifest, node: Zoir.Node, zoir: *const Zoir) Error!void {
    const fields = switch (node) {
        .struct_literal => |literal| literal,
        .empty_literal => return,
        else => return error.InvalidManifest,
    };

    const arena = manifest.arena.allocator();

    for (fields.names, 0..) |field_name_nts, i| {
        const dependency_name = try arena.dupe(u8, field_name_nts.get(zoir));
        const value = fields.vals.at(@intCast(i)).get(zoir);
        const dependency = try extractDependency(arena, value, zoir);
        try manifest.dependencies.put(arena, dependency_name, dependency);
    }
}

fn extractDependency(arena: Allocator, node: Zoir.Node, zoir: *const Zoir) Error!Dependency {
    var dependency: Dependency = .{};

    const fields = switch (node) {
        .struct_literal => |literal| literal,
        .empty_literal => return dependency,
        else => return error.InvalidManifest,
    };

    for (fields.names, 0..) |field_name_nts, i| {
        const field_name = field_name_nts.get(zoir);
        const value = fields.vals.at(@intCast(i)).get(zoir);

        if (std.mem.eql(u8, field_name, "url")) {
            dependency.url = try dupeString(arena, value, zoir);
        } else if (std.mem.eql(u8, field_name, "hash")) {
            dependency.hash = try dupeString(arena, value, zoir);
        } else if (std.mem.eql(u8, field_name, "path")) {
            dependency.path = try dupeString(arena, value, zoir);
        } else if (std.mem.eql(u8, field_name, "version")) {
            dependency.version = try dupeString(arena, value, zoir);
        } else if (std.mem.eql(u8, field_name, "paths")) {
            dependency.paths = try extractStringArray(arena, value, zoir);
        } else if (std.mem.eql(u8, field_name, "lazy")) {
            dependency.lazy = switch (value) {
                .true => true,
                .false => false,
                else => return error.InvalidManifest,
            };
        }
    }

    return dependency;
}

fn dupeString(arena: Allocator, node: Zoir.Node, zoir: *const Zoir) Error![]const u8 {
    const string = switch (node) {
        .string_literal => |literal| literal,
        .enum_literal => |literal| literal.get(zoir),
        else => return error.InvalidManifest,
    };
    return try arena.dupe(u8, string);
}

fn dupeStringLiteral(arena: Allocator, node: Zoir.Node) Error![]const u8 {
    const string = switch (node) {
        .string_literal => |literal| literal,
        else => return error.InvalidManifest,
    };
    return try arena.dupe(u8, string);
}

fn extractU64(node: Zoir.Node) Error!u64 {
    return switch (node) {
        .int_literal => |literal| switch (literal) {
            .small => |value| if (value < 0) error.InvalidManifest else @intCast(value),
            .big => |value| value.toInt(u64) catch error.InvalidManifest,
        },
        else => error.InvalidManifest,
    };
}

fn extractStringArray(
    arena: Allocator,
    node: Zoir.Node,
    zoir: *const Zoir,
) Error![]const []const u8 {
    const elements = switch (node) {
        .array_literal => |range| range,
        .empty_literal => return &.{},
        else => return error.InvalidManifest,
    };

    const result = try arena.alloc([]const u8, elements.len);
    for (result, 0..) |*slot, i| {
        slot.* = try dupeStringLiteral(arena, elements.at(@intCast(i)).get(zoir));
    }
    return result;
}

const fixtures = struct {
    const simple = @embedFile("fixtures/simple.zon");
    const no_dependencies = @embedFile("fixtures/no_dependencies.zon");
    const arbitrary_names = @embedFile("fixtures/arbitrary_names.zon");
};

test "parses manifest metadata and dependencies" {
    var manifest = try parse(std.testing.allocator, fixtures.simple);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("zig_depgraph", manifest.name.?);
    try std.testing.expectEqualStrings("0.1.0", manifest.version.?);
    try std.testing.expectEqual(@as(u64, 0x498ba4ead7efad7f), manifest.fingerprint.?);
    try std.testing.expectEqualStrings("0.17.1", manifest.minimum_zig_version.?);
    try std.testing.expectEqual(@as(usize, 3), manifest.paths.len);
    try std.testing.expectEqualStrings("build.zig", manifest.paths[0]);
    try std.testing.expectEqualStrings("src", manifest.paths[2]);
    try std.testing.expectEqual(@as(usize, 3), manifest.dependencies.count());

    const httpz = manifest.dependency("httpz").?;
    try std.testing.expectEqualStrings("https://example.com/httpz.tar.gz", httpz.url.?);
    try std.testing.expectEqualStrings("httpz-0.1.0-abc", httpz.hash.?);
    try std.testing.expect(httpz.path == null);
    try std.testing.expectEqualStrings("0.1.0", httpz.version.?);
    try std.testing.expectEqual(@as(usize, 2), httpz.paths.len);
    try std.testing.expectEqualStrings("src", httpz.paths[0]);
    try std.testing.expect(!httpz.lazy);

    const custom = manifest.dependency("custom").?;
    try std.testing.expectEqualStrings("../custom", custom.path.?);
    try std.testing.expect(custom.url == null);
    try std.testing.expect(custom.hash == null);
    try std.testing.expect(custom.lazy);
}

test "parses manifest without dependencies" {
    var manifest = try parse(std.testing.allocator, fixtures.no_dependencies);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("lonely", manifest.name.?);
    try std.testing.expect(manifest.version == null);
    try std.testing.expectEqual(@as(usize, 0), manifest.dependencies.count());
}

test "parses arbitrary dependency names" {
    var manifest = try parse(std.testing.allocator, fixtures.arbitrary_names);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("weird-names", manifest.name.?);
    try std.testing.expectEqual(@as(usize, 2), manifest.dependencies.count());

    const custom = manifest.dependency("my_custom_package").?;
    try std.testing.expectEqualStrings("../custom", custom.path.?);

    const dashed = manifest.dependency("dashed-name").?;
    try std.testing.expectEqualStrings("https://example.com/dashed.tar.gz", dashed.url.?);
}

test "rejects invalid ZON" {
    try std.testing.expectError(error.InvalidZon, parse(std.testing.allocator, ".{ .name = "));
}

test "rejects non-struct roots" {
    try std.testing.expectError(error.InvalidManifest, parse(std.testing.allocator, "123"));
}

test "rejects fields with the wrong type" {
    try std.testing.expectError(
        error.InvalidManifest,
        parse(std.testing.allocator, ".{ .dependencies = .{ .bad = .{ .url = 1 } } }"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        parse(std.testing.allocator, ".{ .dependencies = .{ .bad = .{ .lazy = \"yes\" } } }"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        parse(std.testing.allocator, ".{ .paths = .{ 1 } }"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        parse(std.testing.allocator, ".{ .fingerprint = \"nope\" }"),
    );
}
