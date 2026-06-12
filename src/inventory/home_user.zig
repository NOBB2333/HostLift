const std = @import("std");
const schema = @import("schema.zig");

// 判断用户 home 是否值得参与用户级配置、服务和敏感路径扫描。
pub fn shouldScanHome(user: schema.UserAccount) bool {
    if (user.home.len == 0 or std.mem.eql(u8, user.home, "/nonexistent")) return false;
    return !user.system or std.mem.eql(u8, user.name, "root");
}

test "home scan rule keeps root and non-system users" {
    try std.testing.expect(shouldScanHome(.{ .name = "root", .uid = 0, .gid = 0, .home = "/root", .shell = "/bin/bash", .system = true }));
    try std.testing.expect(shouldScanHome(.{ .name = "deploy", .uid = 1001, .gid = 1001, .home = "/home/deploy", .shell = "/bin/bash", .system = false }));
    try std.testing.expect(!shouldScanHome(.{ .name = "daemon", .uid = 1, .gid = 1, .home = "/usr/sbin", .shell = "/usr/sbin/nologin", .system = true }));
    try std.testing.expect(!shouldScanHome(.{ .name = "nobody", .uid = 65534, .gid = 65534, .home = "/nonexistent", .shell = "/usr/sbin/nologin", .system = true }));
}
