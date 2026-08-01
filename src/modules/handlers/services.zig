const std = @import("std");
const plan = @import("../../plan/schema.zig");
const handler = @import("../handler.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");

const apply_actions = @import("../../apply/actions.zig");
const command_handler = @import("command.zig");
const file_rollback_handler = @import("rollback.zig");
const file_transfer_handler = @import("transfer.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const remote_schema = @import("../../remote/schema.zig");
const services_openrc = @import("services_openrc.zig");
const services_sysv = @import("services_sysv.zig");
const services_user_systemd = @import("services_user_systemd.zig");
const transfer_command = @import("../../transfer/command.zig");

// 声明 service 模块 action 在目标机器执行前需要具备的入口命令。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    return switch (action.action_type) {
        .enable_systemd_unit, .install_systemd_unit => &.{"systemctl"},
        .enable_user_systemd_unit => services_user_systemd.applyRequirements(),
        .enable_openrc_service, .disable_openrc_service => &.{"rc-update"},
        .enable_sysv_init, .disable_sysv_init => &.{"ls"},
        .write_file, .copy_home_config => file_transfer_handler.applyRequirements(ctx, action),
        else => command_handler.applyRequirements(ctx, action),
    };
}

// 对 service 中的 unit/init 文件动作执行只读传输 preflight，其余动作由通用命令检查覆盖。
pub fn preflight(ctx: handler.ApplyPreflightContext, action: plan.Action) !void {
    if (action.action_type == .install_systemd_unit) {
        const transfer = try systemdUnitTransfer(ctx, action);
        defer ctx.allocator.free(transfer.target_path);
        try file_transfer_handler.preflightTransferPlan(ctx, action, transfer.plan);
        return;
    }
    if (action.action_type == .write_file or action.action_type == .copy_home_config) {
        try file_transfer_handler.preflight(ctx, action);
    }
}

// 执行 service 模块动作；unit 安装走传输加 daemon-reload，其余走命令型 handler。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    if (action.action_type == .install_systemd_unit) {
        const transfer = try systemdUnitTransfer(ctx, action);
        defer ctx.allocator.free(transfer.target_path);
        try ctx.stdout.print("  - {s}: ", .{action.id});
        try transfer_command.executePlan(ctx.io, ctx.allocator, transfer.plan, ctx.stdout, ctx.stderr);

        var reload_argv = [_][]const u8{ "systemctl", "daemon-reload" };
        const reload_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, reload_argv[0..], ctx.options.execution);
        try remote_exec.executePlan(ctx.io, ctx.allocator, reload_plan, ctx.stdout, ctx.stderr);
        return .{ .changed = true };
    }
    if (action.action_type == .write_file or action.action_type == .copy_home_config) {
        return file_transfer_handler.apply(ctx, action);
    }
    if (action.action_type == .enable_user_systemd_unit) {
        try services_user_systemd.apply(ctx, action);
        return .{ .changed = true };
    }
    if (action.action_type == .enable_openrc_service or action.action_type == .disable_openrc_service) {
        try services_openrc.apply(ctx, action);
        return .{ .changed = true };
    }
    if (action.action_type == .enable_sysv_init or action.action_type == .disable_sysv_init) {
        try services_sysv.apply(ctx, action);
        return .{ .changed = true };
    }
    return command_handler.apply(ctx, action);
}

const SystemdUnitTransfer = struct {
    target_path: []const u8,
    plan: remote_schema.TransferPlan,
};

fn systemdUnitTransfer(ctx: anytype, action: plan.Action) !SystemdUnitTransfer {
    const source_path = apply_actions.subject(action);
    if (source_path.len == 0) return error.MissingApplySubject;
    const target_path = try apply_actions.systemdTargetPath(ctx.allocator, action, source_path);
    errdefer ctx.allocator.free(target_path);
    return .{
        .target_path = target_path,
        .plan = try remote_planner.buildTransferPlanAdvancedWithLimits(
            ctx.target_host,
            ctx.source_host,
            source_path,
            target_path,
            true,
            false,
            ctx.options.transfer_transport,
            ctx.options.transfer_partial,
            ctx.options.transfer_resume,
            ctx.options.execution,
            ctx.options.transfer_bandwidth_limit_kbps,
        ),
    };
}

// 验证 service 模块动作结果。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    if (action.action_type == .install_systemd_unit) {
        const source_path = apply_actions.subject(action);
        if (source_path.len == 0) return error.MissingApplySubject;
        const target_path = try apply_actions.systemdTargetPath(ctx.allocator, action, source_path);
        defer ctx.allocator.free(target_path);
        const exists = try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, target_path, ctx.execution);
        if (!exists) return error.VerifyTargetMissing;
        try ctx.stdout.print("  verify {s}: unit exists {s}\n", .{ action.id, target_path });
        return .{ .ok = true };
    }
    if (action.action_type == .write_file or action.action_type == .copy_home_config) {
        return file_transfer_handler.verify(ctx, action);
    }
    if (action.action_type == .enable_user_systemd_unit) {
        try services_user_systemd.verify(ctx, action);
        return .{ .ok = true };
    }
    if (action.action_type == .enable_openrc_service or action.action_type == .disable_openrc_service) {
        try services_openrc.verify(ctx, action);
        return .{ .ok = true };
    }
    if (action.action_type == .enable_sysv_init or action.action_type == .disable_sysv_init) {
        try services_sysv.verify(ctx, action);
        return .{ .ok = true };
    }
    return command_handler.verify(ctx, action);
}

// 回滚 service 模块动作；enable 回滚为 disable，文件型 unit 仍恢复备份。
pub fn rollback(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    if (std.mem.eql(u8, entry.action_type, "enable_systemd_unit")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        var command = try apply_actions.systemctlDisableCommand(ctx.allocator, entry.subject);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
        try ctx.stdout.print("  - rollback {s}: disable {s}\n", .{ entry.action_id, entry.subject });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }
    if (std.mem.eql(u8, entry.action_type, "enable_user_systemd_unit")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        try services_user_systemd.rollback(ctx, entry.action_id, entry.subject);
        return .{ .restored = true };
    }
    if (std.mem.eql(u8, entry.action_type, "enable_openrc_service") or std.mem.eql(u8, entry.action_type, "disable_openrc_service")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        try services_openrc.rollback(ctx, entry.action_type, entry.action_id, entry.subject);
        return .{ .restored = true };
    }
    if (std.mem.eql(u8, entry.action_type, "enable_sysv_init") or std.mem.eql(u8, entry.action_type, "disable_sysv_init")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        try services_sysv.rollback(ctx, entry.action_type, entry.action_id, entry.subject);
        return .{ .restored = true };
    }
    return file_rollback_handler.restoreFileBackup(ctx, entry);
}
