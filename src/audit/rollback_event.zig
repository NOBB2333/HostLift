const std = @import("std");
const audit_chain = @import("chain.zig");
const audit_event = @import("event.zig");
const audit_log = @import("log.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

const Chain = audit_chain.Chain;
const CredentialSource = audit_event.CredentialSource;
const Result = audit_event.Result;

// 写入 rollback entry 的审计事件。
pub fn writeRollbackEvent(
    writer: anytype,
    timestamp: i64,
    result: Result,
    operator: []const u8,
    host: []const u8,
    entry: rollback_manifest.Entry,
    policy_hash: ?[]const u8,
    approval_ticket: ?[]const u8,
    credential_source: CredentialSource,
    rollback_manifest_path: []const u8,
    message: []const u8,
) !void {
    try audit_log.writeEvent(writer, .{
        .timestamp = timestamp,
        .phase = .rollback,
        .result = result,
        .operator = operator,
        .host = host,
        .action_id = entry.action_id,
        .action_type = entry.action_type,
        .module = moduleNameForActionId(entry.action_id),
        .policy_hash = policy_hash,
        .approval_ticket = approval_ticket,
        .credential_source = credential_source,
        .rollback_manifest = rollback_manifest_path,
        .message = message,
    });
}

// 写入 rollback entry 的链式审计事件。
pub fn writeChainedRollbackEvent(
    allocator: std.mem.Allocator,
    writer: anytype,
    chain: *Chain,
    timestamp: i64,
    result: Result,
    operator: []const u8,
    host: []const u8,
    entry: rollback_manifest.Entry,
    policy_hash: ?[]const u8,
    approval_ticket: ?[]const u8,
    credential_source: CredentialSource,
    rollback_manifest_path: []const u8,
    message: []const u8,
) !void {
    try audit_log.writeChainedEvent(allocator, writer, chain, .{
        .timestamp = timestamp,
        .phase = .rollback,
        .result = result,
        .operator = operator,
        .host = host,
        .action_id = entry.action_id,
        .action_type = entry.action_type,
        .module = moduleNameForActionId(entry.action_id),
        .policy_hash = policy_hash,
        .approval_ticket = approval_ticket,
        .credential_source = credential_source,
        .rollback_manifest = rollback_manifest_path,
        .message = message,
    });
}

// 从 action_id 中提取模块名称，用于回滚事件。
fn moduleNameForActionId(action_id: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, action_id, '/') orelse return "unknown";
    return action_id[0..slash];
}
