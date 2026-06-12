const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 检测常见开发工具是否存在及其版本。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.DevTool {
    const candidates = [_]struct {
        name: []const u8,
        argv: []const []const u8,
    }{
        .{ .name = "python3", .argv = &.{ "python3", "--version" } },
        .{ .name = "python", .argv = &.{ "python", "--version" } },
        .{ .name = "pip3", .argv = &.{ "pip3", "--version" } },
        .{ .name = "pip", .argv = &.{ "pip", "--version" } },
        .{ .name = "node", .argv = &.{ "node", "--version" } },
        .{ .name = "npm", .argv = &.{ "npm", "--version" } },
        .{ .name = "pnpm", .argv = &.{ "pnpm", "--version" } },
        .{ .name = "yarn", .argv = &.{ "yarn", "--version" } },
        .{ .name = "git", .argv = &.{ "git", "--version" } },
        .{ .name = "docker", .argv = &.{ "docker", "--version" } },
    };

    var tools: std.ArrayList(schema.DevTool) = .empty;
    errdefer {
        for (tools.items) |tool| {
            allocator.free(tool.name);
            allocator.free(tool.version);
        }
        tools.deinit(allocator);
    }

    for (candidates) |candidate| {
        const present = probe.executableExists(io, allocator, candidate.name);
        const version = if (present)
            probe.runFirstLine(io, allocator, candidate.argv) catch try allocator.dupe(u8, "unknown")
        else
            try allocator.dupe(u8, "not-installed");

        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, candidate.name),
            .present = present,
            .version = version,
        });
    }

    return tools.toOwnedSlice(allocator);
}
