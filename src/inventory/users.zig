const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 从 passwd/group 数据源扫描用户和组。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.UserInventory {
    return .{
        .users = try parsePasswd(io, allocator),
        .groups = try parseGroup(io, allocator),
    };
}

// 释放 parsePasswd 返回的用户数组。
pub fn freeUsers(allocator: std.mem.Allocator, users: []schema.UserAccount) void {
    for (users) |user| {
        allocator.free(user.name);
        allocator.free(user.home);
        allocator.free(user.shell);
    }
    allocator.free(users);
}

// 解析 /etc/passwd 为用户清单；读取失败要上抛，避免误判为无用户。
pub fn parsePasswd(io: std.Io, allocator: std.mem.Allocator) ![]schema.UserAccount {
    const contents = try probe.readWholeFile(io, allocator, "/etc/passwd");
    defer allocator.free(contents);
    return parsePasswdContents(allocator, contents);
}

// 解析 /etc/group 为用户组清单；读取失败要上抛，避免误判为无用户组。
pub fn parseGroup(io: std.Io, allocator: std.mem.Allocator) ![]schema.GroupAccount {
    const contents = try probe.readWholeFile(io, allocator, "/etc/group");
    defer allocator.free(contents);
    return parseGroupContents(allocator, contents);
}

// 从 passwd 文本解析用户记录，便于单元测试覆盖边界。
pub fn parsePasswdContents(allocator: std.mem.Allocator, contents: []const u8) ![]schema.UserAccount {
    var users: std.ArrayList(schema.UserAccount) = .empty;
    errdefer {
        for (users.items) |user| {
            allocator.free(user.name);
            allocator.free(user.home);
            allocator.free(user.shell);
        }
        users.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, line, ':');
        const name = parts.next() orelse continue;
        _ = parts.next() orelse continue;
        const uid_text = parts.next() orelse continue;
        const gid_text = parts.next() orelse continue;
        _ = parts.next() orelse continue;
        const home = parts.next() orelse "";
        const shell = parts.next() orelse "";
        const uid = std.fmt.parseUnsigned(u32, uid_text, 10) catch continue;
        const gid = std.fmt.parseUnsigned(u32, gid_text, 10) catch continue;

        try users.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .uid = uid,
            .gid = gid,
            .home = try allocator.dupe(u8, home),
            .shell = try allocator.dupe(u8, shell),
            .system = uid < 1000,
        });
    }

    return users.toOwnedSlice(allocator);
}

// 从 group 文本解析用户组记录，便于单元测试覆盖边界。
pub fn parseGroupContents(allocator: std.mem.Allocator, contents: []const u8) ![]schema.GroupAccount {
    var groups: std.ArrayList(schema.GroupAccount) = .empty;
    errdefer {
        for (groups.items) |group| allocator.free(group.name);
        groups.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, line, ':');
        const name = parts.next() orelse continue;
        _ = parts.next() orelse continue;
        const gid_text = parts.next() orelse continue;
        const gid = std.fmt.parseUnsigned(u32, gid_text, 10) catch continue;

        try groups.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .gid = gid,
            .system = gid < 1000,
        });
    }

    return groups.toOwnedSlice(allocator);
}

test "passwd parser extracts user metadata and skips invalid records" {
    const parsed = try parsePasswdContents(
        std.testing.allocator,
        "root:x:0:0:root:/root:/bin/bash\nbad:x:not-a-uid:0::/bad:/bin/sh\ndeploy:x:1001:1001::/home/deploy:/bin/bash\n",
    );
    defer freeUsers(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("root", parsed[0].name);
    try std.testing.expect(parsed[0].system);
    try std.testing.expectEqualStrings("deploy", parsed[1].name);
    try std.testing.expect(!parsed[1].system);
}

test "group parser extracts gid and system flag" {
    const parsed = try parseGroupContents(
        std.testing.allocator,
        "root:x:0:\ninvalid:x:nope:\ndeploy:x:1001:\n",
    );
    defer {
        for (parsed) |group| std.testing.allocator.free(group.name);
        std.testing.allocator.free(parsed);
    }

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("root", parsed[0].name);
    try std.testing.expect(parsed[0].system);
    try std.testing.expectEqualStrings("deploy", parsed[1].name);
    try std.testing.expect(!parsed[1].system);
}
