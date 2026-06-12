const std = @import("std");
const apply_actions = @import("../../apply/actions.zig");
const plan = @import("../../plan/schema.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_options = @import("../../remote/options.zig");
const remote_planner = @import("../../remote/planner.zig");

// 声明用户级 systemd unit 启用动作需要的目标机命令。
pub fn applyRequirements() []const []const u8 {
    return &.{ "runuser", "systemctl" };
}

// 执行用户级 systemd unit enable。
pub fn apply(ctx: anytype, action: plan.Action) !void {
    const unit_ref = apply_actions.subject(action);
    if (unit_ref.len == 0) return error.MissingApplySubject;
    var command = try apply_actions.userSystemctlEnableCommand(ctx.allocator, unit_ref);
    defer command.deinit(ctx.allocator);
    const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.options.execution);
    try ctx.stdout.print("  - {s}: enable user unit {s}\n", .{ action.id, unit_ref });
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
}

// 验证用户级 systemd unit 已启用。
pub fn verify(ctx: anytype, action: plan.Action) !void {
    const unit_ref = apply_actions.subject(action);
    if (unit_ref.len == 0) return error.MissingApplySubject;
    try verifyIsEnabled(ctx.io, ctx.allocator, ctx.target_host, ctx.execution, ctx.stdout, action.id, unit_ref, error.VerifyUserSystemdUnitNotEnabled);
}

// 回滚用户级 systemd unit enable。
pub fn rollback(ctx: anytype, action_id: []const u8, subject: []const u8) !void {
    if (subject.len == 0) return error.MissingRollbackSubject;
    var command = try apply_actions.userSystemctlDisableCommand(ctx.allocator, subject);
    defer command.deinit(ctx.allocator);
    const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
    try ctx.stdout.print("  - rollback {s}: disable user unit {s}\n", .{ action_id, subject });
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
}

// 验证用户级 systemd unit enable 已被回滚。
pub fn verifyRollback(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution: remote_options.ExecutionOptions,
    stdout: anytype,
    action_id: []const u8,
    subject: []const u8,
) !void {
    const enabled = isEnabled(io, allocator, host, execution, subject) catch |err| switch (err) {
        error.RemoteCommandFailed => false,
        else => return err,
    };
    if (enabled) return error.RollbackVerifyUserServiceStillEnabled;
    try stdout.print("  verify rollback {s}: user unit disabled {s}\n", .{ action_id, subject });
}

// 远程检查用户级 systemd unit 是否已启用，不匹配则返回错误。
fn verifyIsEnabled(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution: remote_options.ExecutionOptions,
    stdout: anytype,
    action_id: []const u8,
    subject: []const u8,
    mismatch_error: anyerror,
) !void {
    if (!try isEnabled(io, allocator, host, execution, subject)) return mismatch_error;
    try stdout.print("  verify {s}: user unit enabled {s}\n", .{ action_id, subject });
}

// 远程查询用户级 systemd unit 是否处于 enabled 状态。
fn isEnabled(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution: remote_options.ExecutionOptions,
    subject: []const u8,
) !bool {
    var command = try apply_actions.userSystemctlIsEnabledCommand(allocator, subject);
    defer command.deinit(allocator);
    return remote_exec.commandSucceededWithOptions(io, allocator, host, command.argv, execution);
}
