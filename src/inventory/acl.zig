const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描常见迁移路径是否存在扩展 POSIX ACL，不读取或保存 ACL 条目正文。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.AclInventory {
    const getfacl_available = probe.executableExists(io, allocator, "getfacl");
    const candidates = [_][]const u8{
        "/etc",
        "/srv",
        "/opt",
        "/var/www",
        "/var/lib/docker",
        "/home",
    };

    var paths: std.ArrayList(schema.AclPath) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path.path);
        paths.deinit(allocator);
    }

    for (candidates) |candidate| {
        const present = probe.pathExists(io, candidate);
        const directory = if (present) probe.pathIsDirectory(io, candidate) else false;
        try paths.append(allocator, .{
            .path = try allocator.dupe(u8, candidate),
            .present = present,
            .directory = directory,
            .has_extended_acl = if (present and getfacl_available) hasExtendedAcl(io, allocator, candidate) else false,
        });
    }

    return .{
        .getfacl_available = getfacl_available,
        .paths = try paths.toOwnedSlice(allocator),
        .truncated = false,
    };
}

// 释放 ACL 扫描条目中分配的路径。
pub fn freePaths(allocator: std.mem.Allocator, paths: []schema.AclPath) void {
    for (paths) |path| allocator.free(path.path);
    allocator.free(paths);
}

// 使用 getfacl 输出判断是否存在扩展 ACL，但不保存输出正文。
fn hasExtendedAcl(io: std.Io, allocator: std.mem.Allocator, path: []const u8) bool {
    const argv = [_][]const u8{ "getfacl", "-cp", path };
    const output = probe.runCommand(io, allocator, &argv, 64 * 1024) catch return false;
    defer allocator.free(output);
    return aclOutputHasExtendedEntries(output);
}

// 判断 getfacl 输出中是否包含 user/group/mask 扩展 ACL 条目。
fn aclOutputHasExtendedEntries(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "user:") and !std.mem.startsWith(u8, line, "user::")) return true;
        if (std.mem.startsWith(u8, line, "group:") and !std.mem.startsWith(u8, line, "group::")) return true;
        if (std.mem.startsWith(u8, line, "mask::")) return true;
        if (std.mem.startsWith(u8, line, "default:user:") and !std.mem.startsWith(u8, line, "default:user::")) return true;
        if (std.mem.startsWith(u8, line, "default:group:") and !std.mem.startsWith(u8, line, "default:group::")) return true;
        if (std.mem.startsWith(u8, line, "default:mask::")) return true;
    }
    return false;
}

test "ACL parser detects extended entries without storing ACL body" {
    try std.testing.expect(!aclOutputHasExtendedEntries(
        \\user::rwx
        \\group::r-x
        \\other::r-x
    ));
    try std.testing.expect(aclOutputHasExtendedEntries(
        \\user::rwx
        \\user:deploy:r-x
        \\group::r-x
        \\mask::r-x
        \\other::---
    ));
    try std.testing.expect(aclOutputHasExtendedEntries(
        \\default:user::rwx
        \\default:user:ops:r-x
    ));
}
