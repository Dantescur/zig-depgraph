const std = @import("std");
const depgraph = @import("zig_depgraph");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "graph")) {
        usage();
        std.process.exit(1);
    }

    var manifest_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (output_path != null) {
                usage();
                std.process.exit(1);
            }
            i += 1;
            if (i >= args.len) {
                usage();
                std.process.exit(1);
            }
            output_path = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            usage();
            std.process.exit(1);
        } else if (manifest_path == null) {
            manifest_path = arg;
        } else {
            usage();
            std.process.exit(1);
        }
    }

    const path = manifest_path orelse {
        usage();
        std.process.exit(1);
    };

    // Accept either a package directory or its build.zig.zon file.
    const resolved_path = resolveManifestPath(arena, init.io, path) catch |err| {
        std.debug.print("error: cannot access {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    const result = depgraph.resolver.load(init.gpa, arena, init.io, resolved_path) catch |err| {
        std.debug.print("error: cannot resolve dependencies: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    var graph = switch (result) {
        .graph => |loaded| loaded,
        .failure => |failure| {
            if (failure.dependency) |dependency| {
                std.debug.print("error: dependency '{s}' {s} at {s}\n", .{ dependency, failure.message, failure.path });
            } else {
                std.debug.print("error: {s} at {s}\n", .{ failure.message, failure.path });
            }
            for (failure.diagnostics) |diagnostic| {
                if (diagnostic.dependency) |dependency| {
                    std.debug.print("error: dependency '{s}': {s}\n", .{ dependency, diagnostic.message });
                } else {
                    std.debug.print("error: {s}\n", .{diagnostic.message});
                }
            }
            std.process.exit(1);
        },
    };
    defer graph.deinit();

    if (output_path) |output| {
        var file = std.Io.Dir.cwd().createFile(init.io, output, .{}) catch |err| {
            std.debug.print("error: cannot create {s}: {s}\n", .{ output, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close(init.io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(init.io, &buffer);
        depgraph.dot.write(&graph, &file_writer.interface) catch |err| {
            std.debug.print("error: cannot write {s}: {s}\n", .{ output, @errorName(err) });
            std.process.exit(1);
        };
        file_writer.flush() catch |err| {
            std.debug.print("error: cannot flush {s}: {s}\n", .{ output, @errorName(err) });
            std.process.exit(1);
        };
    } else {
        var buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
        depgraph.dot.write(&graph, &stdout_writer.interface) catch |err| {
            std.debug.print("error: cannot write stdout: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        stdout_writer.flush() catch |err| {
            std.debug.print("error: cannot flush stdout: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }
}

fn resolveManifestPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind == .directory) {
        return try std.fs.path.join(allocator, &.{ path, "build.zig.zon" });
    }
    return path;
}

fn usage() void {
    std.debug.print(
        \\usage: zig-depgraph graph <path> [--output <file>]
        \\
        \\  <path>      build.zig.zon file or project directory
        \\  -o, --output  write DOT to <file> instead of stdout
        \\
    , .{});
}
