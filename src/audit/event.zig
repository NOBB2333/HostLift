const credentials = @import("../credentials/source.zig");

pub const schema_version = "hostlift.audit.v1";

// 审计事件生命周期阶段。
pub const Phase = enum {
    apply,
    rollback,
};

// 审计事件执行结果。
pub const Result = enum {
    started,
    succeeded,
    failed,
};

pub const CredentialSource = credentials.SourceKind;

// 审计事件核心数据结构。
pub const Event = struct {
    timestamp: i64,
    phase: Phase,
    result: Result,
    operator: []const u8 = "unknown",
    host: []const u8,
    action_id: []const u8,
    action_type: []const u8,
    module: []const u8,
    plan_created_at: ?i64 = null,
    plan_hash: ?[]const u8 = null,
    policy_hash: ?[]const u8 = null,
    approval_ticket: ?[]const u8 = null,
    credential_source: CredentialSource = .default_ssh,
    rollback_manifest: ?[]const u8 = null,
    message: []const u8 = "",
};

// 根据是否显式指定 SSH 私钥判断审计中的凭据来源。
pub fn credentialSourceForIdentity(identity_file: ?[]const u8) CredentialSource {
    return credentials.fromIdentityFile(identity_file).kind;
}

// 根据远程执行凭据配置判断审计中的凭据来源。
pub fn credentialSourceForOptions(identity_file: ?[]const u8, provider: ?[]const u8) !CredentialSource {
    const source = try credentials.fromOptions(identity_file, provider);
    try credentials.validate(source);
    return source.kind;
}
