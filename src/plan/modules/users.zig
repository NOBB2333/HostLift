const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划非系统用户和组创建动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.UserInventory,
    target: inventory.UserInventory,
) !void {
    for (source.groups) |group| {
        if (group.system) continue;
        if (findGroupByName(target.groups, group.name)) |existing| {
            if (existing.gid != group.gid) {
                try appendGroupConflict(allocator, actions, group.name, "Review existing target group with different GID before migration");
            }
            continue;
        }
        if (findGroupByGid(target.groups, group.gid)) |existing| {
            try appendGroupConflict(allocator, actions, existing.name, "Review GID conflict before creating source group");
            continue;
        }
        try common.appendAction(allocator, actions, .{
            .id_prefix = "users/create-group",
            .name = group.name,
            .module = .users,
            .action_type = .create_group,
            .gid = group.gid,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Create non-system group if there is no GID conflict",
        });
    }

    for (source.users) |user| {
        if (user.system) continue;
        if (findUserByName(target.users, user.name)) |existing| {
            if (userDiffers(user, existing)) {
                try appendUserConflict(allocator, actions, user.name, "Review existing target user with different UID, GID, home or shell before migration");
            }
            continue;
        }
        if (findUserByUid(target.users, user.uid)) |existing| {
            try appendUserConflict(allocator, actions, existing.name, "Review UID conflict before creating source user");
            continue;
        }
        try common.appendAction(allocator, actions, .{
            .id_prefix = "users/create-user",
            .name = user.name,
            .module = .users,
            .action_type = .create_user,
            .uid = user.uid,
            .gid = user.gid,
            .home = user.home,
            .shell = user.shell,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Create non-system user if there is no UID conflict",
        });
    }
}

// 查找指定用户名。
fn findUserByName(users: []const inventory.UserAccount, name: []const u8) ?inventory.UserAccount {
    for (users) |user| {
        if (std.mem.eql(u8, user.name, name)) return user;
    }
    return null;
}

// 查找指定 UID 的用户。
fn findUserByUid(users: []const inventory.UserAccount, uid: u32) ?inventory.UserAccount {
    for (users) |user| {
        if (user.uid == uid) return user;
    }
    return null;
}

// 查找指定组名。
fn findGroupByName(groups: []const inventory.GroupAccount, name: []const u8) ?inventory.GroupAccount {
    for (groups) |group| {
        if (std.mem.eql(u8, group.name, name)) return group;
    }
    return null;
}

// 查找指定 GID 的用户组。
fn findGroupByGid(groups: []const inventory.GroupAccount, gid: u32) ?inventory.GroupAccount {
    for (groups) |group| {
        if (group.gid == gid) return group;
    }
    return null;
}

// 判断源用户与目标用户的 UID、GID、home 或 shell 是否存在差异。
fn userDiffers(source: inventory.UserAccount, target: inventory.UserAccount) bool {
    return source.uid != target.uid or
        source.gid != target.gid or
        !std.mem.eql(u8, source.home, target.home) or
        !std.mem.eql(u8, source.shell, target.shell);
}

// 追加用户冲突的人工审查步骤。
fn appendUserConflict(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    name: []const u8,
    description: []const u8,
) !void {
    try manual_common.appendManualStep(allocator, actions, .{
        .id_prefix = "users/review-user-conflict",
        .name = name,
        .subject = name,
        .module = .users,
        .risk = .high,
        .description = description,
    });
}

// 追加用户组冲突的人工审查步骤。
fn appendGroupConflict(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    name: []const u8,
    description: []const u8,
) !void {
    try manual_common.appendManualStep(allocator, actions, .{
        .id_prefix = "users/review-group-conflict",
        .name = name,
        .subject = name,
        .module = .users,
        .risk = .high,
        .description = description,
    });
}

test "user planning emits manual step on UID conflict instead of create user" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| {
            std.testing.allocator.free(action.id);
            std.testing.allocator.free(action.subject);
            if (action.home) |home| std.testing.allocator.free(home);
            if (action.shell) |shell| std.testing.allocator.free(shell);
            std.testing.allocator.free(action.description);
        }
        actions.deinit(std.testing.allocator);
    }

    var source_users = [_]inventory.UserAccount{.{
        .name = "deploy",
        .uid = 1001,
        .gid = 1001,
        .home = "/home/deploy",
        .shell = "/bin/bash",
        .system = false,
    }};
    var target_users = [_]inventory.UserAccount{.{
        .name = "existing",
        .uid = 1001,
        .gid = 1001,
        .home = "/home/existing",
        .shell = "/bin/bash",
        .system = false,
    }};

    try appendActions(std.testing.allocator, &actions, .{
        .users = source_users[0..],
        .groups = &.{},
    }, .{
        .users = target_users[0..],
        .groups = &.{},
    });

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqual(plan.ActionType.manual_step, actions.items[0].action_type);
    try std.testing.expectEqual(plan.RiskLevel.high, actions.items[0].risk);
}
