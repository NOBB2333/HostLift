const std = @import("std");

// 追加标准 ssh argv 前缀；所有调用都使用 argv 数组，避免 shell 拼接。
pub fn appendSshPrefix(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    identity_file: ?[]const u8,
    connect_timeout: ?[]const u8,
    host: []const u8,
) !void {
    try argv.appendSlice(allocator, &.{ "ssh", "-o", "BatchMode=yes" });
    if (identity_file) |path| try argv.appendSlice(allocator, &.{ "-i", path });
    if (connect_timeout) |value| try argv.appendSlice(allocator, &.{ "-o", value });
    try argv.appendSlice(allocator, &.{ host, "--" });
}

test "ssh argv prefix includes identity file before host" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendSshPrefix(std.testing.allocator, &argv, "/home/me/.ssh/id_ed25519", "ConnectTimeout=30", "root@192.0.2.10");

    try std.testing.expectEqualStrings("ssh", argv.items[0]);
    try std.testing.expectEqualStrings("-i", argv.items[3]);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", argv.items[4]);
    try std.testing.expectEqualStrings("root@192.0.2.10", argv.items[7]);
    try std.testing.expectEqualStrings("--", argv.items[8]);
}
