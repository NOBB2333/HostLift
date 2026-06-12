const std = @import("std");
const common = @import("docker_common.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 在常见部署目录下扫描 Compose 文件路径。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !common.ScanResult(schema.ComposeFile) {
    const roots = [_][]const u8{ "/srv", "/opt", "/var/www" };
    var files: std.ArrayList(schema.ComposeFile) = .empty;
    errdefer {
        free(allocator, files.items);
        files.deinit(allocator);
    }

    var truncated = false;
    for (roots) |root| {
        if (files.items.len >= 256) {
            truncated = true;
            break;
        }
        try appendComposeFileIfPresent(io, allocator, &files, root);
        var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (files.items.len >= 256) {
                truncated = true;
                break;
            }
            if (entry.kind != .directory) continue;
            const child = std.fs.path.join(allocator, &.{ root, entry.name }) catch continue;
            defer allocator.free(child);
            try appendComposeFileIfPresent(io, allocator, &files, child);
        }
    }

    return .{ .items = try files.toOwnedSlice(allocator), .truncated = truncated };
}

// 释放 Compose 文件记录列表。
pub fn free(allocator: std.mem.Allocator, files: []schema.ComposeFile) void {
    for (files) |file| {
        allocator.free(file.project_root);
        allocator.free(file.path);
    }
}

// 检查目录下是否存在常见名称的 Compose 文件并追加到列表。
fn appendComposeFileIfPresent(
    io: std.Io,
    allocator: std.mem.Allocator,
    files: *std.ArrayList(schema.ComposeFile),
    project_root: []const u8,
) !void {
    if (composeRootExists(files.items, project_root)) return;
    const names = [_][]const u8{
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    };
    for (names) |name| {
        if (!probe.pathExistsJoin(io, allocator, project_root, name)) continue;
        const path = try std.fs.path.join(allocator, &.{ project_root, name });
        errdefer allocator.free(path);
        try files.append(allocator, .{
            .project_root = try allocator.dupe(u8, project_root),
            .path = path,
        });
        return;
    }
}

// 检查指定 project root 是否已在 Compose 文件列表中。
fn composeRootExists(files: []const schema.ComposeFile, project_root: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file.project_root, project_root)) return true;
    }
    return false;
}
