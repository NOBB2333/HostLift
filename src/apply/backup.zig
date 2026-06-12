const std = @import("std");
const apply_actions = @import("actions.zig");
const rollback_entries = @import("rollback_entries.zig");
const plan_schema = @import("../plan/schema.zig");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const remote_planner = @import("../remote/planner.zig");
const rollback_manifest = @import("../rollback/manifest.zig");
const path_util = @import("../util/paths.zig");

// 在文件型 action 执行前准备远程备份，并写入本地 rollback 记录。
pub fn prepareRemoteRollback(
    io: std.Io,
    allocator: std.mem.Allocator,
    action: plan_schema.Action,
    host: []const u8,
    backup_root: []const u8,
    manifest_writer: anytype,
    stdout: anytype,
    stderr: anytype,
    created_at: i64,
) !void {
    return prepareRemoteRollbackWithOptions(io, allocator, action, host, backup_root, manifest_writer, stdout, stderr, created_at, .{});
}

// 在文件型 action 执行前准备远程备份，并使用指定远程执行选项。
pub fn prepareRemoteRollbackWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    action: plan_schema.Action,
    host: []const u8,
    backup_root: []const u8,
    manifest_writer: anytype,
    stdout: anytype,
    stderr: anytype,
    created_at: i64,
    execution_options: remote_options.ExecutionOptions,
) !void {
    if (try rollback_entries.writeCommandRollbackEntry(manifest_writer, action, host, created_at)) return;

    if (action.action_type == .copy_data_path or action.action_type == .copy_project_path) {
        const action_subject = apply_actions.subject(action);
        if (action_subject.len == 0) return error.MissingApplySubject;
        if (try remote_exec.pathExistsWithOptions(io, allocator, host, action_subject, execution_options)) return error.TargetDataPathAlreadyExists;
        return;
    }

    const target_path = try apply_actions.backupTargetForAction(allocator, action);
    if (target_path == null) return;
    defer allocator.free(target_path.?);

    const backup_path = try remotePathIfPresentWithOptions(io, allocator, host, target_path.?, backup_root, stdout, stderr, execution_options);
    if (backup_path) |value| {
        defer allocator.free(value);
        try rollback_manifest.writeEntry(manifest_writer, .{
            .created_at = created_at,
            .host = host,
            .action_id = action.id,
            .action_type = @tagName(action.action_type),
            .original_path = target_path.?,
            .backup_path = value,
        });
    }
}

// 如果远程目标已存在，则复制到 HostLift backup root 并返回备份路径。
pub fn remotePathIfPresent(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    target_path: []const u8,
    backup_root: []const u8,
    stdout: anytype,
    stderr: anytype,
) !?[]const u8 {
    return remotePathIfPresentWithOptions(io, allocator, host, target_path, backup_root, stdout, stderr, .{});
}

// 如果远程目标已存在，则按指定执行选项复制到 backup root 并返回备份路径。
pub fn remotePathIfPresentWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    target_path: []const u8,
    backup_root: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !?[]const u8 {
    if (!try remote_exec.pathExistsWithOptions(io, allocator, host, target_path, execution_options)) return null;

    const backup_path = try pathForTarget(allocator, backup_root, target_path);
    errdefer allocator.free(backup_path);
    const backup_parent = try path_util.parentDirAlloc(allocator, backup_path);
    defer allocator.free(backup_parent);

    var mkdir_argv = [_][]const u8{ "mkdir", "-p", backup_parent };
    const mkdir_plan = try remote_planner.buildCommandPlanWithOptions(host, mkdir_argv[0..], execution_options);
    try stdout.print("  backup {s} -> {s}\n", .{ target_path, backup_path });
    try remote_exec.executePlan(io, allocator, mkdir_plan, stdout, stderr);

    var cp_argv = [_][]const u8{ "cp", "-a", target_path, backup_path };
    const cp_plan = try remote_planner.buildCommandPlanWithOptions(host, cp_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, cp_plan, stdout, stderr);

    return backup_path;
}

// 根据远程目标路径生成备份路径。
pub fn pathForTarget(allocator: std.mem.Allocator, backup_root: []const u8, target_path: []const u8) ![]const u8 {
    try remote_planner.validatePath(backup_root);
    try remote_planner.validatePath(target_path);
    if (!std.mem.startsWith(u8, backup_root, "/") or !std.mem.startsWith(u8, target_path, "/")) return error.InvalidTransferPath;
    if (target_path.len <= 1) return error.InvalidTransferPath;
    const normalized_root = std.mem.trimEnd(u8, backup_root, "/");
    const normalized_target = std.mem.trimStart(u8, target_path, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ normalized_root, normalized_target });
}

test "rollback backup paths preserve absolute target layout under backup root" {
    const backup_path = try pathForTarget(std.testing.allocator, "/var/lib/hostlift/backups/123", "/etc/nginx/nginx.conf");
    defer std.testing.allocator.free(backup_path);
    try std.testing.expectEqualStrings("/var/lib/hostlift/backups/123/etc/nginx/nginx.conf", backup_path);

    const parent = try path_util.parentDirAlloc(std.testing.allocator, backup_path);
    defer std.testing.allocator.free(parent);
    try std.testing.expectEqualStrings("/var/lib/hostlift/backups/123/etc/nginx", parent);

    try std.testing.expectError(error.InvalidTransferPath, pathForTarget(std.testing.allocator, "/var/lib/hostlift/backups/123", "/"));
    try std.testing.expectError(error.InvalidTransferPath, pathForTarget(std.testing.allocator, "relative", "/etc/hosts"));
}
