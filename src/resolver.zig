//! Loads a manifest and recursively resolves its local path dependencies.
//! Remote dependencies remain leaf nodes because resolving them requires
//! fetching package contents.

const std = @import("std");
const parser = @import("parser.zig");
const validator = @import("validator.zig");
const graph_mod = @import("graph/graph.zig");

const Allocator = std.mem.Allocator;
const Graph = graph_mod.Graph;
const NodeId = graph_mod.NodeId;

/// Maximum size accepted for each root or dependency manifest.
pub const max_manifest_bytes = 16 * 1024 * 1024;

/// Describes a manifest or graph error encountered while resolving packages.
/// `path`, `dependency`, and `diagnostics` are allocated from the caller's
/// scratch allocator and remain valid for its lifetime.
pub const Failure = struct {
    path: []const u8,
    dependency: ?[]const u8 = null,
    message: []const u8,
    diagnostics: []const validator.ValidationError = &.{},
};

/// The graph on success, or the first actionable failure encountered.
/// The caller owns the graph and must call `Graph.deinit` when done.
pub const Result = union(enum) {
    graph: Graph,
    failure: Failure,
};

const LoadError = Allocator.Error || error{Failed};

/// Loads and validates `manifest_path`, then recursively resolves local path
/// dependencies. Remote dependencies are represented as leaf nodes because
/// this loader does not fetch packages. Local packages are deduplicated by
/// manifest fingerprint, which also closes dependency cycles.
///
/// The returned graph owns its data and must be deinitialized by the caller.
/// Failure details use `scratch`, which must remain alive while they are
/// inspected. On success, the graph does not depend on `scratch`.
pub fn load(
    allocator: Allocator,
    scratch: Allocator,
    io: std.Io,
    manifest_path: []const u8,
) Allocator.Error!Result {
    var context: Context = .{
        .allocator = allocator,
        .scratch = scratch,
        .io = io,
        .graph = Graph.init(allocator),
    };
    var graph_ready = false;
    defer if (!graph_ready) context.graph.deinit();
    defer context.resolved.deinit(allocator);

    context.loadRoot(manifest_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failure = context.failure.? },
    };

    graph_ready = true;
    return .{ .graph = context.graph };
}

const Context = struct {
    allocator: Allocator,
    scratch: Allocator,
    io: std.Io,
    graph: Graph,
    resolved: std.AutoHashMapUnmanaged(u64, NodeId) = .empty,
    failure: ?Failure = null,

    fn loadRoot(self: *Context, manifest_path: []const u8) LoadError!void {
        const manifest = try self.readValidated(manifest_path, null);
        const root = self.graph.addRoot(manifest.name) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.failGraph(manifest_path, null, err);
            return error.Failed;
        };
        try self.resolved.put(self.allocator, manifest.fingerprint, root);
        try self.addDependencies(root, manifest_path, &manifest);
    }

    fn readValidated(self: *Context, path: []const u8, dependency: ?[]const u8) LoadError!validator.ValidatedManifest {
        // Parse every package with the same validation rules used for the root.
        const source = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.scratch,
            .limited(max_manifest_bytes),
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.setFailure(path, dependency, "cannot read manifest", &.{});
            return error.Failed;
        };

        var parsed = parser.parse(self.allocator, source) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.setFailure(path, dependency, "cannot parse manifest", &.{});
            return error.Failed;
        };
        defer parsed.deinit();

        var diagnostics: validator.Diagnostics = undefined;
        const validated = validator.validate(self.scratch, &parsed, &diagnostics) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.setFailure(path, dependency, "cannot validate manifest", &.{});
            return error.Failed;
        };
        if (validated) |manifest| return manifest;
        try self.setFailure(path, dependency, "manifest validation failed", diagnostics.errors);
        return error.Failed;
    }

    fn addDependencies(
        self: *Context,
        parent: NodeId,
        manifest_path: []const u8,
        manifest: *const validator.ValidatedManifest,
    ) LoadError!void {
        const parent_dir = std.fs.path.dirname(manifest_path) orelse ".";
        var iterator = manifest.dependencies.iterator();
        while (iterator.next()) |entry| {
            const alias = entry.key_ptr.*;
            const dependency = entry.value_ptr.*;
            const node = switch (dependency.source) {
                .remote => self.addRemote(alias, dependency, manifest_path) catch |err| return err,
                .local => |local| try self.addLocal(parent_dir, alias, local.path),
            };
            self.graph.addEdge(parent, node, dependency.lazy) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try self.failGraph(manifest_path, alias, err);
                return error.Failed;
            };
        }
    }

    fn addRemote(
        self: *Context,
        alias: []const u8,
        dependency: validator.ValidatedDependency,
        manifest_path: []const u8,
    ) LoadError!NodeId {
        return self.graph.addNode(alias, .{
            .source = dependency.source,
            .version = dependency.version,
            .paths = dependency.paths,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.failGraph(manifest_path, alias, err);
            return error.Failed;
        };
    }

    fn addLocal(
        self: *Context,
        parent_dir: []const u8,
        alias: []const u8,
        local_path: []const u8,
    ) LoadError!NodeId {
        // A dependency's path is relative to the manifest that declares it.
        const package_dir = try std.fs.path.resolveAlloc(self.scratch, &.{ parent_dir, local_path });
        const child_manifest_path = try std.fs.path.join(self.scratch, &.{ package_dir, "build.zig.zon" });
        const manifest = try self.readValidated(child_manifest_path, alias);

        if (self.resolved.get(manifest.fingerprint)) |existing| return existing;

        const node = self.graph.addNode(manifest.name, .{
            .source = .{ .local = .{ .path = package_dir } },
            .version = manifest.version,
            .paths = manifest.paths,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.failGraph(child_manifest_path, alias, err);
            return error.Failed;
        };

        // Insert before walking children so cycles resolve to this node.
        try self.resolved.put(self.allocator, manifest.fingerprint, node);
        try self.addDependencies(node, child_manifest_path, &manifest);
        return node;
    }

    fn failGraph(self: *Context, path: []const u8, dependency: ?[]const u8, err: anyerror) Allocator.Error!void {
        const message = if (err == error.NodeConflict)
            "conflicting dependency identity"
        else if (err == error.EdgeConflict)
            "conflicting dependency edge"
        else
            "cannot build graph";
        try self.setFailure(path, dependency, message, &.{});
    }

    fn setFailure(
        self: *Context,
        path: []const u8,
        dependency: ?[]const u8,
        message: []const u8,
        diagnostics: []const validator.ValidationError,
    ) Allocator.Error!void {
        self.failure = .{
            .path = try self.scratch.dupe(u8, path),
            .dependency = if (dependency) |name| try self.scratch.dupe(u8, name) else null,
            .message = message,
            .diagnostics = diagnostics,
        };
    }
};

test "resolves transitive local dependencies, deduplicates fingerprints, and closes cycles" {
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    var result = try load(std.testing.allocator, scratch_arena.allocator(), std.testing.io, "src/fixtures/transitive/build.zig.zon");
    switch (result) {
        .failure => |failure| {
            std.debug.print("resolver fixture failed at {s}: {s}\n", .{ failure.path, failure.message });
            return error.TestUnexpectedResult;
        },
        .graph => |*graph| {
            defer graph.deinit();
            try std.testing.expectEqual(@as(usize, 5), graph.nodes.items.len);
            try std.testing.expectEqual(@as(usize, 6), graph.edges.items.len);

            const root = graph.root.?;
            const package_a = graph.find("package_a").?;
            const package_b = graph.find("package_b").?;
            const shared = graph.find("shared").?;
            try std.testing.expectEqual(root, graph.nodes.items[root].id);
            try std.testing.expect(findEdge(graph, package_a, root));
            try std.testing.expect(findEdge(graph, root, package_b));
            try std.testing.expectEqual(edgeCountTo(graph, shared), @as(usize, 2));
            try std.testing.expect(graph.find("remote_alias") != null);
        },
    }
}

fn findEdge(graph: *const Graph, from: NodeId, to: NodeId) bool {
    for (graph.edges.items) |edge| {
        if (edge.from == from and edge.to == to) return true;
    }
    return false;
}

fn edgeCountTo(graph: *const Graph, to: NodeId) usize {
    var count: usize = 0;
    for (graph.edges.items) |edge| if (edge.to == to) {
        count += 1;
    };
    return count;
}
