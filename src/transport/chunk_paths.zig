const std = @import("std");
const security_validation = @import("../security/validation.zig");

// 拼接本地根目录和 manifest 相对路径，并拒绝逃逸路径。
pub fn joinLocalRelative(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ![]const u8 {
    try validateRelativePath(relative);
    if (std.mem.eql(u8, relative, ".")) return allocator.dupe(u8, root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), relative });
}

// 拼接远端 staging 根目录和 manifest 相对路径，并拒绝逃逸路径。
pub fn joinRemoteRelative(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ![]const u8 {
    try validateRelativePath(relative);
    if (std.mem.eql(u8, relative, ".")) return allocator.dupe(u8, root);
    const result = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), relative });
    errdefer allocator.free(result);
    try security_validation.validatePath(result);
    return result;
}

// 校验相对路径不为空、不以 / 开头、不包含 . 或 .. 逃逸。
fn validateRelativePath(relative: []const u8) !void {
    if (relative.len == 0) return error.InvalidTransferPath;
    if (std.mem.eql(u8, relative, ".")) return;
    if (std.mem.startsWith(u8, relative, "/")) return error.InvalidTransferPath;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidTransferPath;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidTransferPath;
    }
    try security_validation.validatePath(relative);
}

test "chunk relative path joins reject traversal" {
    const joined = try joinRemoteRelative(std.testing.allocator, "/tmp/staging", "config/app.conf");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("/tmp/staging/config/app.conf", joined);

    try std.testing.expectError(error.InvalidTransferPath, joinRemoteRelative(std.testing.allocator, "/tmp/staging", "../etc/passwd"));
    try std.testing.expectError(error.InvalidTransferPath, joinLocalRelative(std.testing.allocator, "/srv/app", "/etc/passwd"));
}
