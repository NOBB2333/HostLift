const std = @import("std");
const common = @import("common.zig");

// 生成 groupadd 命令，必要时保留 gid。
pub fn groupAddCommand(allocator: std.mem.Allocator, group: []const u8, gid: ?u32) !common.Command {
    if (group.len == 0) return error.MissingApplySubject;
    if (gid) |value| {
        const gid_text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        errdefer allocator.free(gid_text);
        const argv = try allocator.alloc([]const u8, 4);
        errdefer allocator.free(argv);
        argv[0] = "groupadd";
        argv[1] = "-g";
        argv[2] = gid_text;
        argv[3] = group;
        const owned = try allocator.alloc([]const u8, 1);
        owned[0] = gid_text;
        return .{ .argv = argv, .owned = owned };
    }
    const argv = try allocator.alloc([]const u8, 2);
    argv[0] = "groupadd";
    argv[1] = group;
    return common.commandWithoutOwned(allocator, argv);
}

// 生成 useradd 命令，保留 uid/gid/home/shell 等基础属性。
pub fn userAddCommand(
    allocator: std.mem.Allocator,
    user: []const u8,
    uid: ?u32,
    gid: ?u32,
    home: ?[]const u8,
    shell: ?[]const u8,
) !common.Command {
    if (user.len == 0) return error.MissingApplySubject;
    if (uid) |uid_value| {
        if (gid == null or home == null or shell == null) return error.IncompleteUserMetadata;
        const gid_value = gid.?;
        const uid_text = try std.fmt.allocPrint(allocator, "{d}", .{uid_value});
        errdefer allocator.free(uid_text);
        const gid_text = try std.fmt.allocPrint(allocator, "{d}", .{gid_value});
        errdefer allocator.free(gid_text);
        const argv = try allocator.alloc([]const u8, 10);
        errdefer allocator.free(argv);
        argv[0] = "useradd";
        argv[1] = "-m";
        argv[2] = "-u";
        argv[3] = uid_text;
        argv[4] = "-g";
        argv[5] = gid_text;
        argv[6] = "-d";
        argv[7] = home.?;
        argv[8] = "-s";
        argv[9] = shell.?;
        const owned = try allocator.alloc([]const u8, 2);
        owned[0] = uid_text;
        owned[1] = gid_text;
        return .{ .argv = argv, .owned = owned };
    }
    const argv = try allocator.alloc([]const u8, 3);
    argv[0] = "useradd";
    argv[1] = "-m";
    argv[2] = user;
    return common.commandWithoutOwned(allocator, argv);
}

// 生成 groupdel 命令，用于保守回滚 HostLift 创建的组。
pub fn groupDeleteCommand(allocator: std.mem.Allocator, group: []const u8) !common.Command {
    if (group.len == 0) return error.MissingApplySubject;
    const argv = try allocator.alloc([]const u8, 2);
    argv[0] = "groupdel";
    argv[1] = group;
    return common.commandWithoutOwned(allocator, argv);
}

// 生成 userdel 命令，用于保守回滚 HostLift 创建的用户；不删除 home。
pub fn userDeleteCommand(allocator: std.mem.Allocator, user: []const u8) !common.Command {
    if (user.len == 0) return error.MissingApplySubject;
    const argv = try allocator.alloc([]const u8, 2);
    argv[0] = "userdel";
    argv[1] = user;
    return common.commandWithoutOwned(allocator, argv);
}
