const std = @import("std");
const apply_actions = @import("../../apply/actions.zig");
const plan = @import("../../plan/schema.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_options = @import("../../remote/options.zig");
const remote_planner = @import("../../remote/planner.zig");

// 执行 OpenRC runlevel 收敛动作。
pub fn apply(ctx: anytype, action: plan.Action) !void {
    const parsed = try apply_actions.parseOpenRcRef(apply_actions.subject(action));
    const enable = action.action_type == .enable_openrc_service;
    var iterator = std.mem.splitScalar(u8, parsed.runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) return error.InvalidOpenRcServiceRef;
        var command = if (enable)
            try apply_actions.openRcAddCommand(ctx.allocator, parsed.service, runlevel)
        else
            try apply_actions.openRcDeleteCommand(ctx.allocator, parsed.service, runlevel);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.options.execution);
        try ctx.stdout.print("  - {s}: rc-update {s} {s} {s}\n", .{ action.id, if (enable) "add" else "del", parsed.service, runlevel });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
    }
}

// 验证 OpenRC runlevel 收敛结果。
pub fn verify(ctx: anytype, action: plan.Action) !void {
    const parsed = try apply_actions.parseOpenRcRef(apply_actions.subject(action));
    if (action.action_type == .enable_openrc_service) {
        try verifyRunlevels(ctx.io, ctx.allocator, ctx.target_host, parsed, true, ctx.execution, ctx.stdout, action.id, error.VerifyOpenRcRunlevelMissing);
        return;
    }
    try verifyRunlevels(ctx.io, ctx.allocator, ctx.target_host, parsed, false, ctx.execution, ctx.stdout, action.id, error.VerifyOpenRcRunlevelStillEnabled);
}

// 回滚 OpenRC runlevel 收敛动作。
pub fn rollback(ctx: anytype, action_type: []const u8, action_id: []const u8, subject: []const u8) !void {
    const parsed = try apply_actions.parseOpenRcRef(subject);
    const restore_enabled = std.mem.eql(u8, action_type, "disable_openrc_service");
    var iterator = std.mem.splitScalar(u8, parsed.runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) return error.InvalidOpenRcServiceRef;
        var command = if (restore_enabled)
            try apply_actions.openRcAddCommand(ctx.allocator, parsed.service, runlevel)
        else
            try apply_actions.openRcDeleteCommand(ctx.allocator, parsed.service, runlevel);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
        try ctx.stdout.print("  - rollback {s}: rc-update {s} {s} {s}\n", .{ action_id, if (restore_enabled) "add" else "del", parsed.service, runlevel });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
    }
}

// 验证 OpenRC rollback 后的 runlevel 状态。
pub fn verifyRollback(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution: remote_options.ExecutionOptions,
    stdout: anytype,
    action_id: []const u8,
    action_type: []const u8,
    subject: []const u8,
) !void {
    const parsed = try apply_actions.parseOpenRcRef(subject);
    if (std.mem.eql(u8, action_type, "enable_openrc_service")) {
        try verifyRunlevels(io, allocator, host, parsed, false, execution, stdout, action_id, error.RollbackVerifyOpenRcStillEnabled);
        return;
    }
    try verifyRunlevels(io, allocator, host, parsed, true, execution, stdout, action_id, error.RollbackVerifyOpenRcRunlevelMissing);
}

// 逐 runlevel 检查 OpenRC 服务链接是否存在或缺失。
fn verifyRunlevels(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    parsed: apply_actions.OpenRcRef,
    expected_enabled: bool,
    execution: remote_options.ExecutionOptions,
    stdout: anytype,
    action_id: []const u8,
    mismatch_error: anyerror,
) !void {
    var iterator = std.mem.splitScalar(u8, parsed.runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) return error.InvalidOpenRcServiceRef;
        const path = try runlevelPath(allocator, runlevel, parsed.service);
        defer allocator.free(path);
        const exists = try remote_exec.pathExistsWithOptions(io, allocator, host, path, execution);
        if (exists != expected_enabled) return mismatch_error;
        try stdout.print("  verify {s}: OpenRC runlevel link {s} {s}\n", .{ action_id, if (expected_enabled) "exists" else "absent", path });
    }
}

// 生成 OpenRC runlevel 目录下服务链接的绝对路径。
fn runlevelPath(allocator: std.mem.Allocator, runlevel: []const u8, service: []const u8) ![]const u8 {
    if (runlevel.len == 0 or service.len == 0) return error.InvalidOpenRcServiceRef;
    return std.fmt.allocPrint(allocator, "/etc/runlevels/{s}/{s}", .{ runlevel, service });
}

test "OpenRC runlevel path uses runlevel and service" {
    const path = try runlevelPath(std.testing.allocator, "default", "nginx");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/etc/runlevels/default/nginx", path);
}
