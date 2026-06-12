const std = @import("std");

// apply 动作的命令结构体，持有 argv 和需要释放的 owned 字符串。
pub const Command = struct {
    argv: []const []const u8,
    owned: []const []const u8,

    // 释放 apply 命令 argv 中复制出来的字符串。
    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        for (self.owned) |item| allocator.free(item);
        allocator.free(self.owned);
        allocator.free(self.argv);
    }
};

// 构造不持有额外字符串的命令对象。
pub fn commandWithoutOwned(allocator: std.mem.Allocator, argv: []const []const u8) !Command {
    return .{ .argv = argv, .owned = try allocator.alloc([]const u8, 0) };
}
