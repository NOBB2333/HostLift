const std = @import("std");
const audit_codec = @import("codec.zig");
const audit_event = @import("event.zig");

// 审计事件哈希链状态，用于防篡改校验。
pub const Chain = struct {
    previous_event_hash: ?[64]u8 = null,
};

// 返回当前审计链尾 hash；没有事件时返回 null。
pub fn tailHash(chain: Chain) ?[64]u8 {
    return chain.previous_event_hash;
}

// 写入一条带 hash chain 的审计事件，并更新链状态。
pub fn writeChainedEvent(
    allocator: std.mem.Allocator,
    writer: anytype,
    chain: *Chain,
    event: audit_event.Event,
) !void {
    const event_hash = try hashEvent(allocator, event, chain.previous_event_hash);
    try audit_codec.writeEventJson(writer, event, chain.previous_event_hash, event_hash, .policy_hash);
    chain.previous_event_hash = event_hash;
}

// 计算审计事件在指定前序 hash 下的规范事件哈希。
pub fn hashEvent(allocator: std.mem.Allocator, event: audit_event.Event, prev_event_hash: ?[64]u8) ![64]u8 {
    return audit_codec.hashEvent(allocator, event, prev_event_hash, .policy_hash);
}

// 按缺少 policy_hash 的审计 schema 计算哈希，用于验证历史日志。
pub fn hashEventWithoutPolicyHash(allocator: std.mem.Allocator, event: audit_event.Event, prev_event_hash: ?[64]u8) ![64]u8 {
    return audit_codec.hashEvent(allocator, event, prev_event_hash, .credential_source);
}

// 按旧版审计 schema 计算哈希，用于验证缺少 credential_source 和 policy_hash 的历史日志。
pub fn hashLegacyEvent(allocator: std.mem.Allocator, event: audit_event.Event, prev_event_hash: ?[64]u8) ![64]u8 {
    return audit_codec.hashEvent(allocator, event, prev_event_hash, .legacy);
}
