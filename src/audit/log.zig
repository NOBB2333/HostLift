const std = @import("std");
const action_event = @import("action_event.zig");
const audit_codec = @import("codec.zig");
const audit_chain = @import("chain.zig");
const audit_event = @import("event.zig");
const rollback_event = @import("rollback_event.zig");

pub const schema_version = audit_event.schema_version;
pub const Phase = audit_event.Phase;
pub const Result = audit_event.Result;
pub const CredentialSource = audit_event.CredentialSource;
pub const Event = audit_event.Event;
pub const Chain = audit_chain.Chain;

// 根据批次时间生成本地审计日志路径。
pub fn pathForBatch(allocator: std.mem.Allocator, created_at: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/hostlift-audit-{d}.jsonl", .{created_at});
}

// 返回当前审计链尾 hash；没有事件时返回 null。
pub fn chainTailHash(chain: Chain) ?[64]u8 {
    return audit_chain.tailHash(chain);
}

// 根据是否显式指定 SSH 私钥判断审计中的凭据来源。
pub fn credentialSourceForIdentity(identity_file: ?[]const u8) CredentialSource {
    return audit_event.credentialSourceForIdentity(identity_file);
}

// 根据远程执行凭据配置判断审计中的凭据来源。
pub fn credentialSourceForOptions(identity_file: ?[]const u8, provider: ?[]const u8) !CredentialSource {
    return audit_event.credentialSourceForOptions(identity_file, provider);
}

// 写入一条审计事件，供 apply/rollback approved 模式追踪执行结果。
pub fn writeEvent(writer: anytype, event: Event) !void {
    try audit_codec.writeEventJson(writer, event, null, null, .policy_hash);
}

// 写入一条带 hash chain 的审计事件，并更新链状态。
pub fn writeChainedEvent(allocator: std.mem.Allocator, writer: anytype, chain: *Chain, event: Event) !void {
    try audit_chain.writeChainedEvent(allocator, writer, chain, event);
}

// 计算审计事件在指定前序 hash 下的规范事件哈希。
pub fn hashEvent(allocator: std.mem.Allocator, event: Event, prev_event_hash: ?[64]u8) ![64]u8 {
    return audit_chain.hashEvent(allocator, event, prev_event_hash);
}

// 按缺少 policy_hash 的审计 schema 计算哈希，用于验证历史日志。
pub fn hashEventWithoutPolicyHash(allocator: std.mem.Allocator, event: Event, prev_event_hash: ?[64]u8) ![64]u8 {
    return audit_chain.hashEventWithoutPolicyHash(allocator, event, prev_event_hash);
}

// 按旧版审计 schema 计算哈希，用于验证缺少 credential_source 和 policy_hash 的历史日志。
pub fn hashLegacyEvent(allocator: std.mem.Allocator, event: Event, prev_event_hash: ?[64]u8) ![64]u8 {
    return audit_chain.hashLegacyEvent(allocator, event, prev_event_hash);
}

pub const writeActionEvent = action_event.writeActionEvent;
pub const writeChainedActionEvent = action_event.writeChainedActionEvent;
pub const writeRollbackEvent = rollback_event.writeRollbackEvent;
pub const writeChainedRollbackEvent = rollback_event.writeChainedRollbackEvent;
