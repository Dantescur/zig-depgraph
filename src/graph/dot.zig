//! Graphviz DOT serialization for dependency graphs.
//!
//! Node identifiers are generated from `NodeId` (`n0`, `n1`, ...); dependency
//! names are only used as escaped labels.

const std = @import("std");

const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;

pub const Options = struct {
    graph_name: []const u8 = "dependencies",
};

pub fn write(graph: *const Graph, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return writeWithOptions(graph, writer, .{});
}

pub fn writeWithOptions(
    graph: *const Graph,
    writer: *std.Io.Writer,
    options: Options,
) std.Io.Writer.Error!void {
    try writer.writeAll("digraph \"");
    try writeEscaped(writer, options.graph_name);
    try writer.writeAll("\" {\n");

    for (graph.nodes.items) |node| {
        try writer.print("    n{d} [label=\"", .{node.id});
        try writeEscaped(writer, node.name);
        try writer.writeAll("\"];\n");
    }

    for (graph.edges.items) |edge| {
        try writer.print("    n{d} -> n{d}", .{ edge.from, edge.to });
        if (edge.lazy) try writer.writeAll(" [style=dashed]");
        try writer.writeAll(";\n");
    }

    try writer.writeAll("}\n");
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(byte),
    };
}

fn render(graph: *const Graph) ![]u8 {
    return renderWithOptions(graph, .{});
}

fn renderWithOptions(graph: *const Graph, options: Options) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try writeWithOptions(graph, &allocating.writer, options);
    return try std.testing.allocator.dupe(u8, allocating.written());
}

test "renders nodes, edges, and lazy edges" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const root = try graph.addRoot("root");
    const httpz = try graph.addNode("httpz", .{
        .source = .{ .remote = .{
            .url = "https://example.com/httpz.tar.gz",
            .hash = "httpz-0.1.0-abc",
        } },
    });
    const custom = try graph.addNode("my_custom_package", .{
        .source = .{ .local = .{ .path = "../custom" } },
    });

    try graph.addEdge(root, httpz, false);
    try graph.addEdge(root, custom, true);

    const dot = try render(&graph);
    defer std.testing.allocator.free(dot);

    try std.testing.expectEqualStrings(
        \\digraph "dependencies" {
        \\    n0 [label="root"];
        \\    n1 [label="httpz"];
        \\    n2 [label="my_custom_package"];
        \\    n0 -> n1;
        \\    n0 -> n2 [style=dashed];
        \\}
        \\
    , dot);
}

test "escapes quotes, backslashes, and newlines in labels" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode("a\"b\\c\nd", .{ .source = .{ .local = .{ .path = "../escaped" } } });

    const dot = try render(&graph);
    defer std.testing.allocator.free(dot);

    try std.testing.expectEqualStrings(
        "digraph \"dependencies\" {\n    n0 [label=\"a\\\"b\\\\c\\nd\"];\n}\n",
        dot,
    );
}

test "renders an empty graph" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const dot = try render(&graph);
    defer std.testing.allocator.free(dot);

    try std.testing.expectEqualStrings("digraph \"dependencies\" {\n}\n", dot);
}

test "quotes and escapes the graph name" {
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    const dot = try renderWithOptions(&graph, .{
        .graph_name = "my \"dependency\" graph",
    });
    defer std.testing.allocator.free(dot);

    try std.testing.expectEqualStrings(
        "digraph \"my \\\"dependency\\\" graph\" {\n}\n",
        dot,
    );
}
