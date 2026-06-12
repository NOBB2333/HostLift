const std = @import("std");

// 判断 init 脚本文件名是否应在服务扫描中忽略。
pub fn ignoreInitScriptName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    if (std.mem.eql(u8, name, "README") or std.mem.eql(u8, name, "skeleton")) return true;
    return std.mem.startsWith(u8, name, ".depend.");
}

test "init script ignore rules hide metadata files" {
    try std.testing.expect(ignoreInitScriptName("README"));
    try std.testing.expect(ignoreInitScriptName(".depend.start"));
    try std.testing.expect(!ignoreInitScriptName("nginx"));
}
