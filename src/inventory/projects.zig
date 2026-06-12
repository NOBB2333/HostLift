const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 在常见部署根目录下识别项目类型和 manifest 文件。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.ProjectInventory {
    const roots = [_][]const u8{
        "/srv",
        "/opt",
        "/var/www",
    };

    var projects: std.ArrayList(schema.ProjectRef) = .empty;
    errdefer {
        for (projects.items) |project| {
            allocator.free(project.root);
            allocator.free(project.manifest_path);
        }
        projects.deinit(allocator);
    }

    var truncated = false;
    for (roots) |root| {
        if (!probe.pathExists(io, root)) continue;
        try appendIfDetected(io, allocator, &projects, root);
        if (projects.items.len >= 256) {
            truncated = true;
            break;
        }
        try appendChildProjects(io, allocator, &projects, root, &truncated);
        if (truncated) break;
    }

    return .{
        .projects = try projects.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

// 在常见父目录下识别直接子项目。
fn appendChildProjects(
    io: std.Io,
    allocator: std.mem.Allocator,
    projects: *std.ArrayList(schema.ProjectRef),
    root: []const u8,
    truncated: *bool,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (projects.items.len >= 256) {
            truncated.* = true;
            return;
        }
        if (entry.kind != .directory) continue;
        const child = std.fs.path.join(allocator, &.{ root, entry.name }) catch continue;
        defer allocator.free(child);
        try appendIfDetected(io, allocator, projects, child);
    }
}

// 如果目录包含项目 manifest，则追加项目记录。
fn appendIfDetected(
    io: std.Io,
    allocator: std.mem.Allocator,
    projects: *std.ArrayList(schema.ProjectRef),
    root: []const u8,
) !void {
    if (hasRoot(projects.items, root)) return;
    const candidates = [_]struct {
        name: []const u8,
        kind: schema.ProjectKind,
    }{
        .{ .name = "docker-compose.yml", .kind = .docker_compose },
        .{ .name = "docker-compose.yaml", .kind = .docker_compose },
        .{ .name = "compose.yml", .kind = .docker_compose },
        .{ .name = "compose.yaml", .kind = .docker_compose },
        .{ .name = "package.json", .kind = .node },
        .{ .name = "pyproject.toml", .kind = .python },
        .{ .name = "requirements.txt", .kind = .python },
        .{ .name = "go.mod", .kind = .go },
        .{ .name = "Cargo.toml", .kind = .rust },
        .{ .name = "build.zig", .kind = .zig },
        .{ .name = "index.html", .kind = .static_site },
    };

    for (candidates) |candidate| {
        if (!probe.pathExistsJoin(io, allocator, root, candidate.name)) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ root, candidate.name });
        errdefer allocator.free(manifest_path);
        try projects.append(allocator, .{
            .root = try allocator.dupe(u8, root),
            .kind = candidate.kind,
            .manifest_path = manifest_path,
        });
        return;
    }
}

// 判断项目列表中是否已经存在某个根目录。
fn hasRoot(projects: []const schema.ProjectRef, root: []const u8) bool {
    for (projects) |project| {
        if (std.mem.eql(u8, project.root, root)) return true;
    }
    return false;
}
