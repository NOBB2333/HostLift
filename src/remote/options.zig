const std = @import("std");
const defaults = @import("defaults.zig");
const credential_source = @import("../credentials/source.zig");
const session = @import("session.zig");

pub const default_retries: u8 = 0;
pub const max_retries: u8 = 5;
pub const max_timeout_seconds: u32 = 24 * 60 * 60;

// 远程执行选项，包含超时、重试、凭据和取消配置。
pub const ExecutionOptions = struct {
    timeout_seconds: u32 = defaults.default_timeout_seconds,
    retries: u8 = default_retries,
    ssh_identity_file: ?[]const u8 = null,
    credential_provider: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    cancel_file: ?[]const u8 = null,
    operation_state_file: ?[]const u8 = null,
};

// 归一化后的远程执行选项，凭据已解析并校验。
pub const NormalizedExecutionOptions = struct {
    timeout_seconds: u32,
    retries: u8,
    ssh_identity_file: ?[]const u8 = null,
    credential_source: credential_source.SourceKind = .default_ssh,
    operation_id: ?[]const u8 = null,
    cancel_file: ?[]const u8 = null,
    operation_state_file: ?[]const u8 = null,
};

// 校验并归一化远程执行选项，0 秒按默认 timeout 处理。
pub fn normalize(options: ExecutionOptions) !NormalizedExecutionOptions {
    return normalizeWithAllocator(std.heap.smp_allocator, options);
}

// 使用指定 allocator 归一化远程执行选项，env provider 会复制解析出的 identity file 路径。
pub fn normalizeWithAllocator(allocator: std.mem.Allocator, options: ExecutionOptions) !NormalizedExecutionOptions {
    const timeout_seconds = if (options.timeout_seconds == 0)
        defaults.default_timeout_seconds
    else
        options.timeout_seconds;
    if (timeout_seconds > max_timeout_seconds) return error.InvalidRemoteTimeout;
    if (options.retries > max_retries) return error.InvalidRemoteRetries;
    const source = try credential_source.fromOptions(options.ssh_identity_file, options.credential_provider);
    const resolved_source = try credential_source.resolve(allocator, source);
    if (options.operation_id) |value| try session.validateOperationId(value);
    if (options.cancel_file) |value| try session.validateCancelFile(value);
    if (options.operation_state_file) |value| try session.validateOperationStateFile(value);
    return .{
        .timeout_seconds = timeout_seconds,
        .retries = options.retries,
        .ssh_identity_file = resolved_source.identity_file,
        .credential_source = resolved_source.kind,
        .operation_id = options.operation_id,
        .cancel_file = options.cancel_file,
        .operation_state_file = options.operation_state_file,
    };
}

// 将秒级 timeout 转成 std.Io.Timeout，供 std.process.run 使用。
pub fn ioTimeout(timeout_seconds: u32) std.Io.Timeout {
    if (timeout_seconds == 0) return .none;
    return .{
        .duration = .{
            .clock = .boot,
            .raw = .fromNanoseconds(@as(i96, timeout_seconds) * std.time.ns_per_s),
        },
    };
}

test "normalizes zero timeout to default" {
    const options = try normalize(.{ .timeout_seconds = 0, .retries = 2, .ssh_identity_file = "/home/me/.ssh/id_ed25519" });
    try std.testing.expectEqual(defaults.default_timeout_seconds, options.timeout_seconds);
    try std.testing.expectEqual(@as(u8, 2), options.retries);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", options.ssh_identity_file.?);
    try std.testing.expectEqual(credential_source.SourceKind.identity_file, options.credential_source);
}

test "normalizes ssh agent provider without identity file argv" {
    const options = try normalize(.{ .credential_provider = "ssh-agent" });
    try std.testing.expect(options.ssh_identity_file == null);
    try std.testing.expectEqual(credential_source.SourceKind.ssh_agent, options.credential_source);
}

test "normalizes env provider into identity file argv" {
    const source = try credential_source.parseProvider("env:HOSTLIFT_SSH_KEY");
    const resolved = try credential_source.resolveEnvValue(source, "/home/me/.ssh/id_ed25519");
    const identity_file = try std.testing.allocator.dupe(u8, resolved.identity_file.?);
    defer std.testing.allocator.free(identity_file);

    try std.testing.expectEqual(credential_source.SourceKind.env, resolved.kind);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", identity_file);
}

test "rejects excessive timeout and retries" {
    try std.testing.expectError(error.InvalidRemoteTimeout, normalize(.{ .timeout_seconds = max_timeout_seconds + 1 }));
    try std.testing.expectError(error.InvalidRemoteRetries, normalize(.{ .retries = max_retries + 1 }));
    try std.testing.expectError(error.InvalidSshIdentityFile, normalize(.{ .ssh_identity_file = "/tmp/key;rm" }));
    try std.testing.expectError(error.CredentialSourceConflict, normalize(.{ .ssh_identity_file = "/home/me/.ssh/id_ed25519", .credential_provider = "ssh-agent" }));
    try std.testing.expectError(error.MissingCredentialProviderValue, normalize(.{ .credential_provider = "env:HOSTLIFT_SSH_KEY" }));
    try std.testing.expectError(error.InvalidRemoteOperationId, normalize(.{ .operation_id = "bad value" }));
    try std.testing.expectError(error.InvalidRemoteCancelFile, normalize(.{ .cancel_file = "relative" }));
    try std.testing.expectError(error.InvalidOperationStatePath, normalize(.{ .operation_state_file = "relative" }));
}
