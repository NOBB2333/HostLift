const std = @import("std");
const apply_actions = @import("actions.zig");
const module_registry = @import("../modules/registry.zig");
const plan_schema = @import("../plan/schema.zig");
const remote_preflight = @import("../remote/preflight.zig");

pub const Check = remote_preflight.Check;

// 根据 apply action 推导目标机器在执行前必须具备的入口命令。
pub fn actionCheck(
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    host: []const u8,
    action: plan_schema.Action,
) !Check {
    return actionCheckWithOptions(allocator, migration_plan, host, action, .{});
}

// 根据 apply action 和执行选项推导目标机器在执行前必须具备的入口命令。
pub fn actionCheckWithOptions(
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    host: []const u8,
    action: plan_schema.Action,
    options: module_registry.ApplyOptions,
) !Check {
    const alternate_commands = try alternateCommandsForAction(allocator, action);
    errdefer freeAlternateCommands(allocator, alternate_commands);
    return .{
        .host = host,
        .commands = try commandsForAction(allocator, migration_plan, action, options),
        .any_commands = alternate_commands,
    };
}

// 对单个 apply action 执行远程依赖预检；缺依赖时失败关闭。
pub fn runActionCheck(
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    host: []const u8,
    action: plan_schema.Action,
    options: module_registry.ApplyOptions,
) !void {
    const check = try actionCheckWithOptions(allocator, migration_plan, host, action, options);
    defer allocator.free(check.commands);
    defer freeAlternateCommands(allocator, check.any_commands);
    try remote_preflight.runCheck(io, allocator, check, options.execution);
}

// 为 SysV init action 生成可选命令组（chkconfig / update-rc.d）。
fn alternateCommandsForAction(allocator: std.mem.Allocator, action: plan_schema.Action) ![]const []const []const u8 {
    if (action.action_type != .enable_sysv_init and action.action_type != .disable_sysv_init) return &.{};
    const group = try allocator.alloc([]const u8, 2);
    errdefer allocator.free(group);
    group[0] = "chkconfig";
    group[1] = "update-rc.d";
    const groups = try allocator.alloc([]const []const u8, 1);
    groups[0] = group;
    return groups;
}

// 释放 actionCheck 为可选命令组分配的内存。
pub fn freeAlternateCommands(allocator: std.mem.Allocator, groups: []const []const []const u8) void {
    if (groups.len == 0) return;
    for (groups) |group| allocator.free(group);
    allocator.free(groups);
}

// 汇总 apply action 在目标机器上必须存在的命令列表。
fn commandsForAction(
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    action: plan_schema.Action,
    options: module_registry.ApplyOptions,
) ![]const []const u8 {
    var commands: std.ArrayList([]const u8) = .empty;
    errdefer commands.deinit(allocator);

    if (try actionNeedsRemoteBackup(allocator, action)) {
        try appendUnique(allocator, &commands, "mkdir");
        try appendUnique(allocator, &commands, "cp");
    }

    const module_handler = module_registry.findForAction(action) orelse return try commands.toOwnedSlice(allocator);
    if (module_handler.applyRequirements) |requirements| {
        for (requirements(.{ .migration_plan = migration_plan, .options = options }, action)) |command| {
            try appendUnique(allocator, &commands, command);
        }
    }
    return try commands.toOwnedSlice(allocator);
}

// 判断 action 是否需要在远端备份目标路径。
fn actionNeedsRemoteBackup(allocator: std.mem.Allocator, action: plan_schema.Action) !bool {
    const target = try apply_actions.backupTargetForAction(allocator, action);
    if (target) |value| allocator.free(value);
    return target != null;
}

// 向列表追加不重复的命令字符串。
fn appendUnique(allocator: std.mem.Allocator, commands: *std.ArrayList([]const u8), command: []const u8) !void {
    for (commands.items) |existing| {
        if (std.mem.eql(u8, existing, command)) return;
    }
    try commands.append(allocator, command);
}
