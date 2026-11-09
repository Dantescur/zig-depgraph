pub const parser = @import("parser.zig");
pub const validator = @import("validator.zig");
pub const graph = @import("graph/graph.zig");
pub const dot = @import("graph/dot.zig");
pub const resolver = @import("resolver.zig");

test {
    _ = parser;
    _ = validator;
    _ = graph;
    _ = dot;
    _ = resolver;
}
