const std = @import("std");
const plan = @import("../../plan/schema.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const handler = @import("../handler.zig");

const apply_actions = @import("../../apply/actions.zig");
const command_handler = @import("command.zig");
const file_rollback_handler = @import("rollback.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const transfer_handler = @import("transfer.zig");

// 声明 project 模块 action 在目标机器执行前需要具备的入口命令。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    return switch (action.action_type) {
        .copy_project_path => transfer_handler.applyRequirements(ctx, action),
        else => command_handler.applyRequirements(ctx, action),
    };
}

// 执行 project 模块动作；项目目录复制走传输，其余 Compose 动作走命令型 handler。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    return switch (action.action_type) {
        .copy_project_path => transfer_handler.apply(ctx, action),
        else => command_handler.apply(ctx, action),
    };
}

// 验证 project 模块动作结果。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    return switch (action.action_type) {
        .copy_project_path => transfer_handler.verify(ctx, action),
        else => command_handler.verify(ctx, action),
    };
}

// 回滚 project 模块动作；Compose up 回滚为 docker compose down，文件型项目仍恢复备份。
pub fn rollback(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    if (std.mem.eql(u8, entry.action_type, "start_compose_project")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        var command = try apply_actions.dockerComposeDownCommand(ctx.allocator, entry.subject);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
        try ctx.stdout.print("  - rollback {s}: compose down {s}\n", .{ entry.action_id, entry.subject });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }
    return file_rollback_handler.restoreFileBackup(ctx, entry);
}
