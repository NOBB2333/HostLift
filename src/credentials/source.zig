const std = @import("std");
const validation = @import("../security/validation.zig");

// 凭据来源类型枚举：默认 SSH、identity file、ssh-agent、env、vault。
pub const SourceKind = enum {
    default_ssh,
    identity_file,
    ssh_agent,
    env,
    vault,
};

// 凭据来源结构体，包含类型、identity file 和 provider 引用。
pub const Source = struct {
    kind: SourceKind,
    identity_file: ?[]const u8 = null,
    provider_ref: ?[]const u8 = null,
};

// 根据 SSH identity file 选项构造凭据来源元数据。
pub fn fromIdentityFile(identity_file: ?[]const u8) Source {
    return if (identity_file) |path|
        .{ .kind = .identity_file, .identity_file = path }
    else
        .{ .kind = .default_ssh };
}

// 根据 CLI/配置中的 identity file 和 provider 选项构造凭据来源，并拒绝同时指定。
pub fn fromOptions(identity_file: ?[]const u8, provider: ?[]const u8) !Source {
    if (identity_file != null and provider != null) return error.CredentialSourceConflict;
    if (provider) |value| return parseProvider(value);
    return fromIdentityFile(identity_file);
}

// 解析凭据 provider 字符串；未实现 provider 只建立元数据，不读取 secret。
pub fn parseProvider(value: []const u8) !Source {
    if (std.mem.eql(u8, value, "default") or std.mem.eql(u8, value, "default_ssh")) return .{ .kind = .default_ssh };
    if (std.mem.eql(u8, value, "ssh-agent") or std.mem.eql(u8, value, "ssh_agent")) return .{ .kind = .ssh_agent };
    if (std.mem.startsWith(u8, value, "identity-file:")) {
        const path = value["identity-file:".len..];
        if (path.len == 0) return error.InvalidCredentialProvider;
        return .{ .kind = .identity_file, .identity_file = path };
    }
    if (std.mem.startsWith(u8, value, "env:")) {
        const name = value["env:".len..];
        try validateProviderRef(name);
        return .{ .kind = .env, .provider_ref = name };
    }
    if (std.mem.startsWith(u8, value, "vault:")) {
        const path = value["vault:".len..];
        try validateProviderRef(path);
        return .{ .kind = .vault, .provider_ref = path };
    }
    return error.InvalidCredentialProvider;
}

// 校验凭据来源；未实现 provider 显式失败关闭。
pub fn validate(source: Source) !void {
    switch (source.kind) {
        .default_ssh => {
            if (source.identity_file != null or source.provider_ref != null) return error.InvalidCredentialSource;
        },
        .identity_file => {
            const path = source.identity_file orelse return error.InvalidCredentialSource;
            if (source.provider_ref != null) return error.InvalidCredentialSource;
            try validation.validateSshIdentityFile(path);
        },
        .ssh_agent => {
            if (source.identity_file != null or source.provider_ref != null) return error.InvalidCredentialSource;
        },
        .env => {
            if (source.identity_file != null) return error.InvalidCredentialSource;
            _ = source.provider_ref orelse return error.InvalidCredentialSource;
        },
        .vault => {
            if (source.identity_file != null) return error.InvalidCredentialSource;
            _ = source.provider_ref orelse return error.InvalidCredentialSource;
            return error.UnsupportedCredentialProvider;
        },
    }
}

// 把 env provider 解析为可执行的 SSH identity file 路径；不读取私钥内容。
pub fn resolve(allocator: std.mem.Allocator, source: Source) !Source {
    if (source.kind != .env) {
        try validate(source);
        return source;
    }
    const name = source.provider_ref orelse return error.InvalidCredentialSource;
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const raw_value = std.c.getenv(name_z.ptr) orelse return error.MissingCredentialProviderValue;
    return resolveEnvValue(source, std.mem.span(raw_value));
}

// 使用可测试的环境变量值解析 env provider；返回的 identity_file 引用传入 value。
pub fn resolveEnvValue(source: Source, value: []const u8) !Source {
    try validate(source);
    if (source.kind != .env) return source;
    if (value.len == 0) return error.MissingCredentialProviderValue;
    try validation.validateSshIdentityFile(value);
    return .{
        .kind = .env,
        .identity_file = value,
        .provider_ref = source.provider_ref,
    };
}

// 返回审计日志使用的稳定凭据来源名称。
pub fn auditName(source: Source) []const u8 {
    return @tagName(source.kind);
}

// 校验 provider ref 字符串的长度和字符合法性。
fn validateProviderRef(value: []const u8) !void {
    if (value.len == 0 or value.len > 256) return error.InvalidCredentialProvider;
    for (value) |char| {
        const ok = std.ascii.isAlphanumeric(char) or char == '_' or char == '-' or char == '.' or char == '/' or char == ':';
        if (!ok) return error.InvalidCredentialProvider;
    }
}

test "derives default ssh credential source" {
    const source = fromIdentityFile(null);
    try validate(source);
    try std.testing.expectEqual(SourceKind.default_ssh, source.kind);
    try std.testing.expect(source.identity_file == null);
    try std.testing.expectEqualStrings("default_ssh", auditName(source));
}

test "derives identity file credential source without exposing path in audit name" {
    const source = fromIdentityFile("/home/me/.ssh/id_ed25519");
    try validate(source);
    try std.testing.expectEqual(SourceKind.identity_file, source.kind);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", source.identity_file.?);
    try std.testing.expectEqualStrings("identity_file", auditName(source));
}

test "parses supported ssh agent credential provider" {
    const source = try parseProvider("ssh-agent");
    try validate(source);
    try std.testing.expectEqual(SourceKind.ssh_agent, source.kind);
    try std.testing.expect(source.identity_file == null);
    try std.testing.expectEqualStrings("ssh_agent", auditName(source));
}

test "parses unsupported external providers but fails closed during validation" {
    const env_source = try parseProvider("env:HOSTLIFT_SSH_KEY");
    try std.testing.expectEqual(SourceKind.env, env_source.kind);
    try std.testing.expectEqualStrings("HOSTLIFT_SSH_KEY", env_source.provider_ref.?);
    try validate(env_source);

    const vault_source = try parseProvider("vault:secret/hostlift/prod");
    try std.testing.expectEqual(SourceKind.vault, vault_source.kind);
    try std.testing.expectError(error.UnsupportedCredentialProvider, validate(vault_source));
}

test "resolves env provider into identity file metadata without changing audit kind" {
    const env_source = try parseProvider("env:HOSTLIFT_SSH_KEY");
    const resolved = try resolveEnvValue(env_source, "/home/me/.ssh/id_ed25519");

    try std.testing.expectEqual(SourceKind.env, resolved.kind);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", resolved.identity_file.?);
    try std.testing.expectEqualStrings("HOSTLIFT_SSH_KEY", resolved.provider_ref.?);
    try std.testing.expectEqualStrings("env", auditName(resolved));
}

test "derives source from mutually exclusive identity file and provider options" {
    try std.testing.expectEqual(SourceKind.default_ssh, (try fromOptions(null, null)).kind);
    try std.testing.expectEqual(SourceKind.identity_file, (try fromOptions("/home/me/.ssh/id_ed25519", null)).kind);
    try std.testing.expectEqual(SourceKind.ssh_agent, (try fromOptions(null, "ssh-agent")).kind);
    try std.testing.expectError(error.CredentialSourceConflict, fromOptions("/home/me/.ssh/id_ed25519", "ssh-agent"));
}

test "rejects invalid identity file path" {
    try std.testing.expectError(error.InvalidSshIdentityFile, validate(fromIdentityFile("/tmp/key;rm")));
    try std.testing.expectError(error.InvalidCredentialProvider, parseProvider("env:BAD;NAME"));
    try std.testing.expectError(error.InvalidSshIdentityFile, resolveEnvValue(try parseProvider("env:HOSTLIFT_SSH_KEY"), "/tmp/key;rm"));
}

test "rejects mismatched source metadata" {
    try std.testing.expectError(error.InvalidCredentialSource, validate(.{
        .kind = .default_ssh,
        .identity_file = "/home/me/.ssh/id_ed25519",
    }));
    try std.testing.expectError(error.InvalidCredentialSource, validate(.{
        .kind = .identity_file,
        .identity_file = null,
    }));
    try std.testing.expectError(error.InvalidCredentialSource, validate(.{
        .kind = .ssh_agent,
        .provider_ref = "agent",
    }));
}
