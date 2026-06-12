const std = @import("std");
const plan_schema = @import("../plan/schema.zig");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const remote_planner = @import("../remote/planner.zig");
const path_util = @import("../util/paths.zig");

// 为 home 配置创建目标父目录并设置 owner，避免新机器目录不存在。
pub fn prepareHomeConfigParent(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    action: plan_schema.Action,
    path: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    return prepareHomeConfigParentWithOptions(io, allocator, host, action, path, stdout, stderr, .{});
}

// 为 home 配置创建目标父目录并使用指定远程执行选项设置 owner。
pub fn prepareHomeConfigParentWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    action: plan_schema.Action,
    path: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const owner = action.owner orelse return error.MissingApplySubject;
    const parent = try path_util.parentDirAlloc(allocator, path);
    defer allocator.free(parent);

    var mkdir_argv = [_][]const u8{ "mkdir", "-p", parent };
    const mkdir_plan = try remote_planner.buildCommandPlanWithOptions(host, mkdir_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, mkdir_plan, stdout, stderr);

    var chown_argv = [_][]const u8{ "chown", owner, parent };
    const chown_plan = try remote_planner.buildCommandPlanWithOptions(host, chown_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, chown_plan, stdout, stderr);
}

// 修正 home 配置复制后的 owner；SSH client 配置会额外收紧权限。
pub fn fixHomeConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    action: plan_schema.Action,
    path: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    return fixHomeConfigWithOptions(io, allocator, host, action, path, stdout, stderr, .{});
}

// 使用指定远程执行选项修正 home 配置 owner 和 SSH client 权限。
pub fn fixHomeConfigWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    action: plan_schema.Action,
    path: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const owner = action.owner orelse return error.MissingApplySubject;
    var chown_argv = [_][]const u8{ "chown", "-R", owner, path };
    const chown_plan = try remote_planner.buildCommandPlanWithOptions(host, chown_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, chown_plan, stdout, stderr);

    if (std.mem.endsWith(u8, path, "/.ssh/config")) {
        const ssh_dir = try path_util.parentDirAlloc(allocator, path);
        defer allocator.free(ssh_dir);

        var chown_ssh_argv = [_][]const u8{ "chown", owner, ssh_dir, path };
        const chown_ssh_plan = try remote_planner.buildCommandPlanWithOptions(host, chown_ssh_argv[0..], execution_options);
        try remote_exec.executePlan(io, allocator, chown_ssh_plan, stdout, stderr);

        var chmod_dir_argv = [_][]const u8{ "chmod", "700", ssh_dir };
        const chmod_dir_plan = try remote_planner.buildCommandPlanWithOptions(host, chmod_dir_argv[0..], execution_options);
        try remote_exec.executePlan(io, allocator, chmod_dir_plan, stdout, stderr);

        var chmod_file_argv = [_][]const u8{ "chmod", "600", path };
        const chmod_file_plan = try remote_planner.buildCommandPlanWithOptions(host, chmod_file_argv[0..], execution_options);
        try remote_exec.executePlan(io, allocator, chmod_file_plan, stdout, stderr);
    }
}

// 修正 authorized_keys 复制后的 .ssh 目录、文件权限和 owner。
pub fn fixAuthorizedKeys(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    action: plan_schema.Action,
    authorized_keys_path: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    return fixAuthorizedKeysWithOptions(io, allocator, host, action, authorized_keys_path, stdout, stderr, .{});
}

// 使用指定远程执行选项修正 authorized_keys 的 .ssh 目录、文件权限和 owner。
pub fn fixAuthorizedKeysWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    action: plan_schema.Action,
    authorized_keys_path: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const user = authorizedKeysUser(action) orelse return error.MissingApplySubject;
    const ssh_dir = try path_util.parentDirAlloc(allocator, authorized_keys_path);
    defer allocator.free(ssh_dir);

    var chmod_dir_argv = [_][]const u8{ "chmod", "700", ssh_dir };
    const chmod_dir_plan = try remote_planner.buildCommandPlanWithOptions(host, chmod_dir_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, chmod_dir_plan, stdout, stderr);

    var chmod_file_argv = [_][]const u8{ "chmod", "600", authorized_keys_path };
    const chmod_file_plan = try remote_planner.buildCommandPlanWithOptions(host, chmod_file_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, chmod_file_plan, stdout, stderr);

    var chown_argv = [_][]const u8{ "chown", user, ssh_dir, authorized_keys_path };
    const chown_plan = try remote_planner.buildCommandPlanWithOptions(host, chown_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, chown_plan, stdout, stderr);
}

// 从 authorized_keys action id 中提取用户名。
pub fn authorizedKeysUser(action: plan_schema.Action) ?[]const u8 {
    const prefix = "ssh/authorized-keys/";
    if (!std.mem.startsWith(u8, action.id, prefix)) return null;
    const user = action.id[prefix.len..];
    if (user.len == 0) return null;
    return user;
}

test "authorized keys user is derived from action id" {
    const action = plan_schema.Action{
        .id = "ssh/authorized-keys/deploy",
        .module = .ssh,
        .action_type = .add_authorized_key,
        .subject = "/home/deploy/.ssh/authorized_keys",
        .description = "Copy authorized keys",
        .risk = .medium,
        .requires_confirmation = true,
    };
    try std.testing.expectEqualStrings("deploy", authorizedKeysUser(action).?);

    var invalid = action;
    invalid.id = "ssh/authorized-keys/";
    try std.testing.expect(authorizedKeysUser(invalid) == null);
}
