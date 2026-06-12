const std = @import("std");
const audit_chain = @import("chain.zig");
const audit_event = @import("event.zig");
const audit_log = @import("log.zig");
const plan_schema = @import("../plan/schema.zig");

const Chain = audit_chain.Chain;
const CredentialSource = audit_event.CredentialSource;
const Result = audit_event.Result;

// 写入 plan action 的审计事件。
pub fn writeActionEvent(
    writer: anytype,
    timestamp: i64,
    result: Result,
    operator: []const u8,
    host: []const u8,
    action: plan_schema.Action,
    plan_created_at: i64,
    plan_hash: []const u8,
    policy_hash: ?[]const u8,
    approval_ticket: ?[]const u8,
    credential_source: CredentialSource,
    rollback_manifest_path: []const u8,
    message: []const u8,
) !void {
    try audit_log.writeEvent(writer, .{
        .timestamp = timestamp,
        .phase = .apply,
        .result = result,
        .operator = operator,
        .host = host,
        .action_id = action.id,
        .action_type = @tagName(action.action_type),
        .module = @tagName(action.module),
        .plan_created_at = plan_created_at,
        .plan_hash = plan_hash,
        .policy_hash = policy_hash,
        .approval_ticket = approval_ticket,
        .credential_source = credential_source,
        .rollback_manifest = rollback_manifest_path,
        .message = message,
    });
}

// 写入 plan action 的链式审计事件。
pub fn writeChainedActionEvent(
    allocator: std.mem.Allocator,
    writer: anytype,
    chain: *Chain,
    timestamp: i64,
    result: Result,
    operator: []const u8,
    host: []const u8,
    action: plan_schema.Action,
    plan_created_at: i64,
    plan_hash: []const u8,
    policy_hash: ?[]const u8,
    approval_ticket: ?[]const u8,
    credential_source: CredentialSource,
    rollback_manifest_path: []const u8,
    message: []const u8,
) !void {
    try audit_log.writeChainedEvent(allocator, writer, chain, .{
        .timestamp = timestamp,
        .phase = .apply,
        .result = result,
        .operator = operator,
        .host = host,
        .action_id = action.id,
        .action_type = @tagName(action.action_type),
        .module = @tagName(action.module),
        .plan_created_at = plan_created_at,
        .plan_hash = plan_hash,
        .policy_hash = policy_hash,
        .approval_ticket = approval_ticket,
        .credential_source = credential_source,
        .rollback_manifest = rollback_manifest_path,
        .message = message,
    });
}
