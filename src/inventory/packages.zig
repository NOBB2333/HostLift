const std = @import("std");
const package_manager = @import("package_manager.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 检测目标机器可用的系统包管理器。
pub fn detectManager(io: std.Io, allocator: std.mem.Allocator) !schema.PackageManagerInfo {
    var kind: schema.PackageManagerKind = .unknown;
    for (package_manager.candidates()) |candidate| {
        if (probe.executableExists(io, allocator, candidate.executable)) {
            kind = candidate.kind;
            break;
        }
    }

    return .{
        .kind = kind,
        .version = try detectManagerVersion(io, allocator, kind),
        .repos = try scanRepositories(io, allocator, kind),
    };
}

// 扫描显式安装包和 hold/lock 状态。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.PackageInventory {
    return .{
        .explicit = try scanExplicit(io, allocator),
        .held = try scanHeld(io, allocator),
    };
}

// 读取包管理器版本字符串。
fn detectManagerVersion(
    io: std.Io,
    allocator: std.mem.Allocator,
    kind: schema.PackageManagerKind,
) ![]const u8 {
    const command = package_manager.versionCommand(kind) orelse return allocator.dupe(u8, "unknown");
    return probe.runFirstLine(io, allocator, command) catch allocator.dupe(u8, "unknown");
}

// 扫描包管理器仓库配置文件引用。
fn scanRepositories(
    io: std.Io,
    allocator: std.mem.Allocator,
    kind: schema.PackageManagerKind,
) ![]schema.RepositoryRef {
    var repos: std.ArrayList(schema.RepositoryRef) = .empty;
    errdefer {
        for (repos.items) |repo| allocator.free(repo.id);
        repos.deinit(allocator);
    }

    for (package_manager.repositorySources(kind)) |source| {
        switch (source) {
            .file => |path| try appendRepositoryFile(io, allocator, &repos, path),
            .dir => |path| try appendRepositoryDir(io, allocator, &repos, path),
        }
    }

    return repos.toOwnedSlice(allocator);
}

// 扫描用户显式安装的软件包列表。
fn scanExplicit(io: std.Io, allocator: std.mem.Allocator) ![][]const u8 {
    for (package_manager.candidates()) |candidate| {
        const command = package_manager.explicitPackagesCommand(candidate.kind) orelse continue;
        if (probe.executableExists(io, allocator, command.executable)) {
            return probe.runLines(io, allocator, command.argv, 1024 * 1024);
        }
    }
    return allocator.alloc([]const u8, 0);
}

// 扫描被 hold/pin 住的软件包列表。
fn scanHeld(io: std.Io, allocator: std.mem.Allocator) ![][]const u8 {
    for (package_manager.candidates()) |candidate| {
        const command = package_manager.heldPackagesCommand(candidate.kind) orelse continue;
        if (probe.executableExists(io, allocator, command.executable)) {
            return probe.runLines(io, allocator, command.argv, 256 * 1024);
        }
    }
    return allocator.alloc([]const u8, 0);
}

// 扫描仓库配置目录中的普通文件。
fn appendRepositoryDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    repos: *std.ArrayList(schema.RepositoryRef),
    path: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendRepositoryFile(io, allocator, repos, child_path);
    }
}

// 追加单个仓库配置文件引用。
fn appendRepositoryFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    repos: *std.ArrayList(schema.RepositoryRef),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    if (probe.countMeaningfulLines(contents) == 0) return;

    try repos.append(allocator, .{
        .id = try allocator.dupe(u8, path),
        .enabled = true,
    });
}
