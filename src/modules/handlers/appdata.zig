const std = @import("std");
const handler = @import("../handler.zig");
const plan = @import("../../plan/schema.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const postgresql = @import("postgresql.zig");
const rollback_handler = @import("rollback.zig");
const transfer = @import("transfer.zig");

// 按 action 类型分发 appdata 的通用文件迁移或 PostgreSQL provider 依赖。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    if (isPostgresql(action.action_type)) return postgresql.applyRequirements(ctx, action);
    return transfer.applyRequirements(ctx, action);
}

// 按 action 类型分发 appdata 的只读 preflight。
pub fn preflight(ctx: handler.ApplyPreflightContext, action: plan.Action) !void {
    if (isPostgresql(action.action_type)) return postgresql.preflight(ctx, action);
    return transfer.preflight(ctx, action);
}

// 按 action 类型分发 appdata mutation。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    if (isPostgresql(action.action_type)) return postgresql.apply(ctx, action);
    return transfer.apply(ctx, action);
}

// 按 action 类型分发 appdata verify。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    if (isPostgresql(action.action_type)) return postgresql.verify(ctx, action);
    return transfer.verify(ctx, action);
}

// PostgreSQL recovery evidence 失败关闭为人工恢复，普通 appdata 文件继续使用备份恢复。
pub fn rollback(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    if (std.mem.eql(u8, entry.action_type, "postgresql_manual_recovery")) return postgresql.rollback(ctx, entry);
    return rollback_handler.restoreFileBackup(ctx, entry);
}

fn isPostgresql(action_type: plan.ActionType) bool {
    return switch (action_type) {
        .postgresql_dump, .postgresql_target_baseline, .postgresql_transfer, .postgresql_restore, .postgresql_verify => true,
        else => false,
    };
}
