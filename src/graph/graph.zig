//! In-memory dependency graph.
//!
//! The graph owns its node names, dependency metadata, and lookup table through
//! an arena. It consumes only validated manifests, so every node source is
//! either a complete remote source or a local path.

const std = @import("std");

const parser = @import("../parser.zig");
const validator = @import("../validator.zig");

const Allocator = std.mem.Allocator;

pub const NodeId = u32;

pub const Error = error{
    OutOfMemory,
    RootAlreadySet,
    UnknownNode,
    EdgeConflict,
    NodeConflict,
    TooManyNodes,
};

pub const DependencySource = validator.DependencySource;

/// Source and optional package metadata stored on a dependency node.
pub const Dependency = struct {
    source: DependencySource,
    version: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
};

/// A package in the graph. `name` is used as its displayed label.
pub const Node = struct {
    id: NodeId,
    name: []const u8,
    /// `null` for the synthetic root node.
    dependency: ?Dependency = null,
};

/// A directed package-to-dependency relationship.
pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    lazy: bool,
};

pub const Graph = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    lookup: std.StringHashMapUnmanaged(NodeId) = .empty,
    root: ?NodeId = null,

    /// Creates an empty graph using `allocator` for nodes and graph storage.
    pub fn init(allocator: Allocator) Graph {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Releases graph storage. The graph must not be used after this call.
    pub fn deinit(self: *Graph) void {
        self.lookup.deinit(self.arena.allocator());
        self.arena.deinit();
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds the synthetic root node. The root is intentionally not indexed by
    /// name so that a dependency with the same name cannot be merged into it.
    pub fn addRoot(self: *Graph, name: []const u8) Error!NodeId {
        if (self.root != null) return error.RootAlreadySet;

        const id = try self.nextNodeId();
        const owned_name = try self.arena.allocator().dupe(u8, name);
        try self.nodes.append(self.allocator, .{
            .id = id,
            .name = owned_name,
        });
        self.root = id;
        return id;
    }

    /// Returns the existing node for `name`, or appends a new one.
    ///
    /// The dependency metadata is cloned into the graph arena, so the source
    /// manifest may be deinitialized after this call. A repeated name reuses
    /// its node only when the source metadata agrees.
    pub fn addNode(self: *Graph, name: []const u8, dependency: Dependency) Error!NodeId {
        if (self.lookup.get(name)) |existing| {
            const existing_dependency = self.nodes.items[existing].dependency.?;
            if (!sameSource(existing_dependency.source, dependency.source)) return error.NodeConflict;
            return existing;
        }

        const id = try self.nextNodeId();
        const arena = self.arena.allocator();
        const owned_name = try arena.dupe(u8, name);
        const owned_dependency = try cloneDependency(arena, dependency);

        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.lookup.put(arena, owned_name, id);
        self.nodes.appendAssumeCapacity(.{
            .id = id,
            .name = owned_name,
            .dependency = owned_dependency,
        });

        return id;
    }

    /// Finds a dependency node by name. The synthetic root is not in this index.
    pub fn find(self: *const Graph, name: []const u8) ?NodeId {
        return self.lookup.get(name);
    }

    /// Adds a directed edge. Repeating an identical edge is a no-op; repeating
    /// it with a different lazy setting returns `EdgeConflict`.
    pub fn addEdge(self: *Graph, from: NodeId, to: NodeId, lazy: bool) Error!void {
        if (!self.nodeExists(from) or !self.nodeExists(to)) return error.UnknownNode;

        for (self.edges.items) |edge| {
            if (edge.from == from and edge.to == to) {
                if (edge.lazy == lazy) return;
                return error.EdgeConflict;
            }
        }

        try self.edges.append(self.allocator, .{
            .from = from,
            .to = to,
            .lazy = lazy,
        });
    }

    /// Builds a graph containing only the direct dependencies of a validated
    /// manifest. Use the resolver module to recursively load local packages.
    pub fn fromValidatedManifest(
        allocator: Allocator,
        manifest: *const validator.ValidatedManifest,
    ) !Graph {
        var graph = Graph.init(allocator);
        errdefer graph.deinit();

        const root = try graph.addRoot(manifest.name);

        var iterator = manifest.dependencies.iterator();
        while (iterator.next()) |entry| {
            const dependency = entry.value_ptr.*;
            const node = try graph.addNode(entry.key_ptr.*, .{
                .source = dependency.source,
                .version = dependency.version,
                .paths = dependency.paths,
            });
            try graph.addEdge(root, node, dependency.lazy);
        }

        return graph;
    }

    fn nextNodeId(self: *const Graph) Error!NodeId {
        if (self.nodes.items.len > std.math.maxInt(NodeId)) return error.TooManyNodes;
        return @intCast(self.nodes.items.len);
    }

    fn nodeExists(self: *const Graph, id: NodeId) bool {
        return @as(usize, id) < self.nodes.items.len;
    }
};

fn cloneDependency(allocator: Allocator, dependency: Dependency) Allocator.Error!Dependency {
    return .{
        .source = try cloneSource(allocator, dependency.source),
        .version = if (dependency.version) |value| try allocator.dupe(u8, value) else null,
        .paths = try cloneStrings(allocator, dependency.paths),
    };
}

fn cloneSource(allocator: Allocator, source: DependencySource) Allocator.Error!DependencySource {
    return switch (source) {
        .remote => |remote| .{
            .remote = .{
                .url = try allocator.dupe(u8, remote.url),
                .hash = try allocator.dupe(u8, remote.hash),
            },
        },
        .local => |local| .{
            .local = .{
                .path = try allocator.dupe(u8, local.path),
            },
        },
    };
}

fn cloneStrings(allocator: Allocator, values: []const []const u8) Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| {
        result[i] = try allocator.dupe(u8, value);
    }
    return result;
}

fn sameSource(a: DependencySource, b: DependencySource) bool {
    return switch (a) {
        .remote => |a_remote| switch (b) {
            .remote => |b_remote| std.mem.eql(u8, a_remote.url, b_remote.url) and
                std.mem.eql(u8, a_remote.hash, b_remote.hash),
            .local => false,
        },
        .local => |a_local| switch (b) {
            .remote => false,
            .local => |b_local| std.mem.eql(u8, a_local.path, b_local.path),
        },
    };
}

const fixtures = struct {
    const simple = @embedFile("../fixtures/simple.zon");
};

fn findEdge(graph: *const Graph, from: NodeId, to: NodeId) ?Edge {
    for (graph.edges.items) |edge| {
        if (edge.from == from and edge.to == to) return edge;
    }
    return null;
}

const ValidatedFixture = struct {
    arena: std.heap.ArenaAllocator,
    manifest: validator.ValidatedManifest,

    fn deinit(self: *ValidatedFixture) void {
        self.arena.deinit();
    }
};

fn validateSource(source: []const u8) !ValidatedFixture {
    var result: ValidatedFixture = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .manifest = undefined,
    };
    errdefer result.arena.deinit();

    var parsed = try parser.parse(std.testing.allocator, source);
    defer parsed.deinit();

    var diagnostics: validator.Diagnostics = undefined;
    result.manifest = (try validator.validate(result.arena.allocator(), &parsed, &diagnostics)) orelse
        return error.TestExpectedValid;
    return result;
}

test "builds a graph from a validated manifest" {
    var fixture = try validateSource(fixtures.simple);
    defer fixture.deinit();

    var graph = try Graph.fromValidatedManifest(std.testing.allocator, &fixture.manifest);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 4), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 3), graph.edges.items.len);

    const root = graph.root.?;
    try std.testing.expectEqualStrings("zig_depgraph", graph.nodes.items[root].name);

    const httpz = graph.find("httpz").?;
    const custom = graph.find("custom").?;
    const remote = graph.find("remote").?;

    try std.testing.expectEqualStrings("httpz", graph.nodes.items[httpz].name);
    try std.testing.expectEqualStrings(
        "https://example.com/httpz.tar.gz",
        graph.nodes.items[httpz].dependency.?.source.remote.url,
    );

    try std.testing.expectEqualDeep(Edge{ .from = root, .to = httpz, .lazy = false }, findEdge(&graph, root, httpz).?);
    try std.testing.expectEqualDeep(Edge{ .from = root, .to = custom, .lazy = true }, findEdge(&graph, root, custom).?);
    try std.testing.expectEqualDeep(Edge{ .from = root, .to = remote, .lazy = false }, findEdge(&graph, root, remote).?);
}

test "graph owns dependency metadata" {
    var graph: Graph = undefined;
    {
        var fixture = try validateSource(fixtures.simple);
        defer fixture.deinit();

        graph = try Graph.fromValidatedManifest(std.testing.allocator, &fixture.manifest);
    }
    defer graph.deinit();

    const httpz = graph.find("httpz").?;
    const dependency = graph.nodes.items[httpz].dependency.?;
    try std.testing.expectEqualStrings("https://example.com/httpz.tar.gz", dependency.source.remote.url);
    try std.testing.expectEqualStrings("httpz-0.1.0-abc", dependency.source.remote.hash);
    try std.testing.expectEqualStrings("0.1.0", dependency.version.?);
    try std.testing.expectEqual(@as(usize, 2), dependency.paths.len);
    try std.testing.expectEqualStrings("src", dependency.paths[0]);
}

test "deduplicates repeated nodes and edges" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const root = try graph.addRoot("root");
    const dependency: Dependency = .{ .source = .{ .local = .{ .path = "../httpz" } } };
    const first = try graph.addNode("httpz", dependency);
    const second = try graph.addNode("httpz", dependency);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);

    try graph.addEdge(root, first, false);
    try graph.addEdge(root, first, false);

    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try std.testing.expectError(error.EdgeConflict, graph.addEdge(root, first, true));
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try std.testing.expectEqual(root, graph.nodes.items[root].id);
}

test "rejects a second root and unknown edge endpoints" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const root = try graph.addRoot("root");
    const node = try graph.addNode("httpz", .{ .source = .{ .local = .{ .path = "../httpz" } } });

    try std.testing.expectError(error.RootAlreadySet, graph.addRoot("other"));
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);

    try std.testing.expectError(error.UnknownNode, graph.addEdge(root, 100, false));
    try std.testing.expectError(error.UnknownNode, graph.addEdge(100, node, false));
}

test "rejects conflicting source metadata for the same node name" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode("shared", .{
        .source = .{ .remote = .{
            .url = "https://example.com/shared-a.tar.gz",
            .hash = "hash-a",
        } },
    });

    try std.testing.expectError(error.NodeConflict, graph.addNode("shared", .{
        .source = .{ .remote = .{
            .url = "https://example.com/shared-b.tar.gz",
            .hash = "hash-b",
        } },
    }));

    const same = try graph.addNode("shared", .{
        .source = .{ .remote = .{
            .url = "https://example.com/shared-a.tar.gz",
            .hash = "hash-a",
        } },
        .version = "1.0.0",
    });

    try std.testing.expectEqual(first, same);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
}

test "root name does not collide with a dependency of the same name" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const root = try graph.addRoot("shared");
    const dependency = try graph.addNode("shared", .{
        .source = .{ .remote = .{
            .url = "https://example.com/shared.tar.gz",
            .hash = "hash",
        } },
    });

    try std.testing.expect(root != dependency);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
    try std.testing.expectEqual(dependency, graph.find("shared").?);

    try graph.addEdge(root, dependency, false);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
}
