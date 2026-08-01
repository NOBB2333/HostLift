const std = @import("std");
const handler = @import("../handler.zig");
const plan = @import("../../plan/schema.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const reinstall = @import("reinstall.zig");
const rollback_handler = @import("rollback.zig");
const transfer = @import("transfer.zig");

// 按 action 类型返回资源复制或可信重装的执行依赖。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    if (isReinstall(action.action_type)) return reinstall.applyRequirements(ctx, action);
    return transfer.applyRequirements(ctx, action);
}

// 按 action 类型执行资源模块只读 preflight。
pub fn preflight(ctx: handler.ApplyPreflightContext, action: plan.Action) !void {
    if (isReinstall(action.action_type)) return reinstall.preflight(ctx, action);
    return transfer.preflight(ctx, action);
}

// 按 action 类型执行资源复制或可信重装 mutation。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    if (isReinstall(action.action_type)) return reinstall.apply(ctx, action);
    return transfer.apply(ctx, action);
}

// 按 action 类型验证资源复制或可信重装结果。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    if (isReinstall(action.action_type)) return reinstall.verify(ctx, action);
    return transfer.verify(ctx, action);
}

// 资源模块的文件备份和新建路径都复用通用 rollback handler。
pub fn rollback(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    return rollback_handler.restoreFileBackup(ctx, entry);
}

fn isReinstall(action_type: plan.ActionType) bool {
    return switch (action_type) {
        .reinstall_download, .reinstall_execute, .reinstall_verify => true,
        else => false,
    };
}
