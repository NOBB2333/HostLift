const std = @import("std");
const audit_log = @import("log.zig");
const manifest_hash = @import("../manifest/hash.zig");

// 审计事件 JSON 字段集版本，用于兼容旧日志哈希计算。
pub const FieldSet = enum {
    legacy,
    credential_source,
    policy_hash,
};

// 写入一条审计事件 JSONL，可选择历史字段集以兼容旧日志。
pub fn writeEventJson(writer: anytype, event: audit_log.Event, prev_event_hash: ?[64]u8, event_hash: ?[64]u8, field_set: FieldSet) !void {
    const prev_event_hash_text: ?[]const u8 = if (prev_event_hash) |hash| &hash else null;
    const event_hash_text: ?[]const u8 = if (event_hash) |hash| &hash else null;
    switch (field_set) {
        .policy_hash => {
            const JsonEvent = struct {
                schema_version: []const u8 = audit_log.schema_version,
                timestamp: i64,
                phase: []const u8,
                result: []const u8,
                operator: []const u8,
                host: []const u8,
                action_id: []const u8,
                action_type: []const u8,
                module: []const u8,
                plan_created_at: ?i64,
                plan_hash: ?[]const u8,
                policy_hash: ?[]const u8,
                approval_ticket: ?[]const u8,
                credential_source: []const u8,
                rollback_manifest: ?[]const u8,
                prev_event_hash: ?[]const u8,
                event_hash: ?[]const u8,
                message: []const u8,
            };
            try std.json.Stringify.value(JsonEvent{
                .timestamp = event.timestamp,
                .phase = @tagName(event.phase),
                .result = @tagName(event.result),
                .operator = event.operator,
                .host = event.host,
                .action_id = event.action_id,
                .action_type = event.action_type,
                .module = event.module,
                .plan_created_at = event.plan_created_at,
                .plan_hash = event.plan_hash,
                .policy_hash = event.policy_hash,
                .approval_ticket = event.approval_ticket,
                .credential_source = @tagName(event.credential_source),
                .rollback_manifest = event.rollback_manifest,
                .prev_event_hash = prev_event_hash_text,
                .event_hash = event_hash_text,
                .message = event.message,
            }, .{}, writer);
        },
        .credential_source => {
            const CredentialJsonEvent = struct {
                schema_version: []const u8 = audit_log.schema_version,
                timestamp: i64,
                phase: []const u8,
                result: []const u8,
                operator: []const u8,
                host: []const u8,
                action_id: []const u8,
                action_type: []const u8,
                module: []const u8,
                plan_created_at: ?i64,
                plan_hash: ?[]const u8,
                approval_ticket: ?[]const u8,
                credential_source: []const u8,
                rollback_manifest: ?[]const u8,
                prev_event_hash: ?[]const u8,
                event_hash: ?[]const u8,
                message: []const u8,
            };
            try std.json.Stringify.value(CredentialJsonEvent{
                .timestamp = event.timestamp,
                .phase = @tagName(event.phase),
                .result = @tagName(event.result),
                .operator = event.operator,
                .host = event.host,
                .action_id = event.action_id,
                .action_type = event.action_type,
                .module = event.module,
                .plan_created_at = event.plan_created_at,
                .plan_hash = event.plan_hash,
                .approval_ticket = event.approval_ticket,
                .credential_source = @tagName(event.credential_source),
                .rollback_manifest = event.rollback_manifest,
                .prev_event_hash = prev_event_hash_text,
                .event_hash = event_hash_text,
                .message = event.message,
            }, .{}, writer);
        },
        .legacy => {
            const LegacyJsonEvent = struct {
                schema_version: []const u8 = audit_log.schema_version,
                timestamp: i64,
                phase: []const u8,
                result: []const u8,
                operator: []const u8,
                host: []const u8,
                action_id: []const u8,
                action_type: []const u8,
                module: []const u8,
                plan_created_at: ?i64,
                plan_hash: ?[]const u8,
                approval_ticket: ?[]const u8,
                rollback_manifest: ?[]const u8,
                prev_event_hash: ?[]const u8,
                event_hash: ?[]const u8,
                message: []const u8,
            };
            try std.json.Stringify.value(LegacyJsonEvent{
                .timestamp = event.timestamp,
                .phase = @tagName(event.phase),
                .result = @tagName(event.result),
                .operator = event.operator,
                .host = event.host,
                .action_id = event.action_id,
                .action_type = event.action_type,
                .module = event.module,
                .plan_created_at = event.plan_created_at,
                .plan_hash = event.plan_hash,
                .approval_ticket = event.approval_ticket,
                .rollback_manifest = event.rollback_manifest,
                .prev_event_hash = prev_event_hash_text,
                .event_hash = event_hash_text,
                .message = event.message,
            }, .{}, writer);
        },
    }
    try writer.writeByte('\n');
}

// 计算审计事件在指定前序 hash 下的规范事件哈希。
pub fn hashEvent(allocator: std.mem.Allocator, event: audit_log.Event, prev_event_hash: ?[64]u8, field_set: FieldSet) ![64]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    try writeEventJson(&writer.writer, event, prev_event_hash, null, field_set);
    buffer = writer.toArrayList();

    const hash_text = try manifest_hash.sha256BytesHexAlloc(allocator, buffer.items);
    defer allocator.free(hash_text);
    var result: [64]u8 = undefined;
    @memcpy(&result, hash_text);
    return result;
}
