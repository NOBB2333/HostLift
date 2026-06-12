const std = @import("std");
const audit_log = @import("log.zig");

const credential_source_field = "\"credential_source\"";
const policy_hash_field = "\"policy_hash\"";

// 单行审计事件解析结果，携带字段集标记。
pub const Parsed = struct {
    value: std.json.Parsed(Event),
    has_credential_source: bool,
    has_policy_hash: bool,

    // 释放单行审计事件解析时分配的字符串。
    pub fn deinit(self: Parsed) void {
        self.value.deinit();
    }
};

// 反序列化后的审计事件 JSON 结构。
pub const Event = struct {
    schema_version: []const u8,
    timestamp: i64,
    phase: []const u8,
    result: []const u8,
    operator: []const u8,
    host: []const u8,
    action_id: []const u8,
    action_type: []const u8,
    module: []const u8,
    plan_created_at: ?i64 = null,
    plan_hash: ?[]const u8 = null,
    policy_hash: ?[]const u8 = null,
    approval_ticket: ?[]const u8 = null,
    credential_source: []const u8 = "default_ssh",
    rollback_manifest: ?[]const u8 = null,
    prev_event_hash: ?[]const u8 = null,
    event_hash: ?[]const u8 = null,
    message: []const u8 = "",
};

// 解析单行审计 JSON，并记录该行属于当前或历史字段集。
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Parsed {
    return .{
        .value = try std.json.parseFromSlice(Event, allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }),
        .has_credential_source = std.mem.indexOf(u8, line, credential_source_field) != null,
        .has_policy_hash = std.mem.indexOf(u8, line, policy_hash_field) != null,
    };
}

// 根据日志行实际字段集重算事件 hash；兼容旧审计日志。
pub fn hashEvent(allocator: std.mem.Allocator, event: Event, has_credential_source: bool, has_policy_hash: bool) ![64]u8 {
    const normalized_event = audit_log.Event{
        .timestamp = event.timestamp,
        .phase = parsePhase(event.phase) orelse return error.InvalidAuditPhase,
        .result = parseResult(event.result) orelse return error.InvalidAuditResult,
        .operator = event.operator,
        .host = event.host,
        .action_id = event.action_id,
        .action_type = event.action_type,
        .module = event.module,
        .plan_created_at = event.plan_created_at,
        .plan_hash = event.plan_hash,
        .policy_hash = event.policy_hash,
        .approval_ticket = event.approval_ticket,
        .credential_source = parseCredentialSource(event.credential_source) orelse return error.InvalidAuditCredentialSource,
        .rollback_manifest = event.rollback_manifest,
        .message = event.message,
    };
    const previous_hash = if (event.prev_event_hash) |hash| try parseHash(hash) else null;
    if (has_credential_source and has_policy_hash) return audit_log.hashEvent(allocator, normalized_event, previous_hash);
    if (has_credential_source) return audit_log.hashEventWithoutPolicyHash(allocator, normalized_event, previous_hash);
    return audit_log.hashLegacyEvent(allocator, normalized_event, previous_hash);
}

// 检查可选前序 hash 是否与预期链尾一致。
pub fn matchesOptionalHash(value: ?[]const u8, expected: ?[64]u8) bool {
    if (expected) |hash| {
        const actual = value orelse return false;
        return std.mem.eql(u8, actual, &hash);
    }
    return value == null;
}

// 检查必填事件 hash 是否等于重算结果。
pub fn matchesRequiredHash(value: ?[]const u8, expected: [64]u8) bool {
    const actual = value orelse return false;
    return std.mem.eql(u8, actual, &expected);
}

// 将 JSON 字符串解析为审计阶段枚举。
fn parsePhase(value: []const u8) ?audit_log.Phase {
    if (std.mem.eql(u8, value, "apply")) return .apply;
    if (std.mem.eql(u8, value, "rollback")) return .rollback;
    return null;
}

// 将 JSON 字符串解析为审计结果枚举。
fn parseResult(value: []const u8) ?audit_log.Result {
    if (std.mem.eql(u8, value, "started")) return .started;
    if (std.mem.eql(u8, value, "succeeded")) return .succeeded;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    return null;
}

// 将 JSON 字符串解析为凭据来源枚举。
fn parseCredentialSource(value: []const u8) ?audit_log.CredentialSource {
    if (std.mem.eql(u8, value, "default_ssh")) return .default_ssh;
    if (std.mem.eql(u8, value, "identity_file")) return .identity_file;
    if (std.mem.eql(u8, value, "ssh_agent")) return .ssh_agent;
    if (std.mem.eql(u8, value, "env")) return .env;
    if (std.mem.eql(u8, value, "vault")) return .vault;
    return null;
}

// 将十六进制文本解析为 64 字节哈希值。
fn parseHash(value: []const u8) ![64]u8 {
    if (value.len != 64) return error.InvalidAuditHash;
    var result: [64]u8 = undefined;
    @memcpy(&result, value);
    return result;
}
