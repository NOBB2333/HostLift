const std = @import("std");
const audit_log = @import("../audit/log.zig");
const audit_sink = @import("../audit/sink.zig");
const plan_schema = @import("../plan/schema.zig");

// apply 操作审计上下文，保存 operator、host、plan 等元数据。
pub const ActionAuditContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operator: []const u8,
    host: []const u8,
    plan_created_at: i64,
    plan_hash: []const u8,
    policy_hash: ?[]const u8,
    approval_ticket: ?[]const u8,
    credential_source: audit_log.CredentialSource,
    rollback_manifest_path: []const u8,
};

// 写入 apply action 审计事件，保持 started/failed/succeeded 的字段一致。
pub fn writeAction(
    sink: *audit_sink.OpenedSink,
    ctx: ActionAuditContext,
    action: plan_schema.Action,
    result: audit_log.Result,
    message: []const u8,
) !void {
    try sink.writeAction(
        ctx.allocator,
        std.Io.Timestamp.now(ctx.io, .real).toSeconds(),
        result,
        ctx.operator,
        ctx.host,
        action,
        ctx.plan_created_at,
        ctx.plan_hash,
        ctx.policy_hash,
        ctx.approval_ticket,
        ctx.credential_source,
        ctx.rollback_manifest_path,
        message,
    );
}

// 写入失败事件并立即刷新，确保出错路径也留下审计证据。
pub fn writeFailureAndFlush(
    sink: *audit_sink.OpenedSink,
    ctx: ActionAuditContext,
    action: plan_schema.Action,
    err: anyerror,
) !void {
    try writeAction(sink, ctx, action, .failed, @errorName(err));
    try sink.flush();
}
