const std = @import("std");

// 计算路径的父目录；没有父级时返回当前目录。
pub fn parentDirAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return allocator.dupe(u8, ".");
    if (slash == 0) return allocator.dupe(u8, "/");
    return allocator.dupe(u8, path[0..slash]);
}

// 返回带结尾斜杠的路径副本。
pub fn trailingSlashAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, "/")) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}/", .{path});
}

test "parent dir handles absolute relative and root paths" {
    const absolute = try parentDirAlloc(std.testing.allocator, "/etc/nginx/nginx.conf");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/etc/nginx", absolute);

    const relative = try parentDirAlloc(std.testing.allocator, "nginx.conf");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings(".", relative);

    const root_child = try parentDirAlloc(std.testing.allocator, "/hosts");
    defer std.testing.allocator.free(root_child);
    try std.testing.expectEqualStrings("/", root_child);
}

test "trailing slash helper adds slash only when needed" {
    const added = try trailingSlashAlloc(std.testing.allocator, "/var/lib/hostlift/backups/123/etc/ufw");
    defer std.testing.allocator.free(added);
    try std.testing.expectEqualStrings("/var/lib/hostlift/backups/123/etc/ufw/", added);

    const unchanged = try trailingSlashAlloc(std.testing.allocator, "/etc/ufw/");
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("/etc/ufw/", unchanged);
}
