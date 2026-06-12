const std = @import("std");
const remote_options = @import("../remote/options.zig");
const remote_schema = @import("../remote/schema.zig");

// transfer 子命令的解析结果，包含源/目标路径和传输选项。
pub const Parsed = struct {
    host: ?[]const u8 = null,
    source_host: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    target_path: ?[]const u8 = null,
    preserve_metadata: bool = false,
    recursive: bool = false,
    approve: bool = false,
    execution: remote_options.ExecutionOptions = .{},
    transport: remote_schema.TransferTransport = .scp,
    partial: bool = false,
    resumable: bool = false,
    bandwidth_limit_kbps: ?u32 = null,
    manifest_output_path: ?[]const u8 = null,
    manifest_force: bool = false,
    manifest_max_entries: usize = 100_000,
    verify_remote_manifest: bool = false,
};

// 解析 transfer 命令参数，只做 argv 到结构化 options 的转换。
pub fn parse(args: []const []const u8) !Parsed {
    var parsed: Parsed = .{};

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--host")) {
            index += 1;
            if (index >= args.len) return error.MissingRemoteHost;
            parsed.host = args[index];
        } else if (std.mem.eql(u8, arg, "--source-host")) {
            index += 1;
            if (index >= args.len) return error.MissingSourceHost;
            parsed.source_host = args[index];
        } else if (std.mem.eql(u8, arg, "--source")) {
            index += 1;
            if (index >= args.len) return error.MissingTransferSource;
            parsed.source_path = args[index];
        } else if (std.mem.eql(u8, arg, "--target")) {
            index += 1;
            if (index >= args.len) return error.MissingTransferTarget;
            parsed.target_path = args[index];
        } else if (std.mem.eql(u8, arg, "--preserve")) {
            parsed.preserve_metadata = true;
        } else if (std.mem.eql(u8, arg, "--recursive")) {
            parsed.recursive = true;
        } else if (std.mem.eql(u8, arg, "--approve")) {
            parsed.approve = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            index += 1;
            if (index >= args.len) return error.MissingTimeout;
            parsed.execution.timeout_seconds = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--retries")) {
            index += 1;
            if (index >= args.len) return error.MissingRetries;
            parsed.execution.retries = try std.fmt.parseUnsigned(u8, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            index += 1;
            if (index >= args.len) return error.MissingIdentityFile;
            parsed.execution.ssh_identity_file = args[index];
        } else if (std.mem.eql(u8, arg, "--credential-provider")) {
            index += 1;
            if (index >= args.len) return error.MissingCredentialProvider;
            parsed.execution.credential_provider = args[index];
        } else if (std.mem.eql(u8, arg, "--operation-id")) {
            index += 1;
            if (index >= args.len) return error.MissingRemoteOperationId;
            parsed.execution.operation_id = args[index];
        } else if (std.mem.eql(u8, arg, "--cancel-file")) {
            index += 1;
            if (index >= args.len) return error.MissingRemoteCancelFile;
            parsed.execution.cancel_file = args[index];
        } else if (std.mem.eql(u8, arg, "--operation-state")) {
            index += 1;
            if (index >= args.len) return error.MissingOperationStatePath;
            parsed.execution.operation_state_file = args[index];
        } else if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            if (index >= args.len) return error.MissingTransport;
            parsed.transport = parseTransport(args[index]) orelse return error.InvalidTransport;
        } else if (std.mem.eql(u8, arg, "--partial")) {
            parsed.partial = true;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            parsed.resumable = true;
        } else if (std.mem.eql(u8, arg, "--bwlimit")) {
            index += 1;
            if (index >= args.len) return error.MissingTransferBandwidthLimit;
            parsed.bandwidth_limit_kbps = try std.fmt.parseUnsigned(u32, args[index], 10);
            if (parsed.bandwidth_limit_kbps.? == 0) return error.InvalidTransferBandwidthLimit;
        } else if (std.mem.eql(u8, arg, "--manifest-output")) {
            index += 1;
            if (index >= args.len) return error.MissingManifestOutputPath;
            parsed.manifest_output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--manifest-max-entries")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxEntries;
            parsed.manifest_max_entries = try std.fmt.parseUnsigned(usize, args[index], 10);
            if (parsed.manifest_max_entries == 0) return error.InvalidMaxEntries;
        } else if (std.mem.eql(u8, arg, "--force")) {
            parsed.manifest_force = true;
        } else if (std.mem.eql(u8, arg, "--verify-remote-manifest")) {
            parsed.verify_remote_manifest = true;
        } else {
            return error.UnknownTransferArgument;
        }
    }

    return parsed;
}

// 解析 transfer 后端名称。
pub fn parseTransport(value: []const u8) ?remote_schema.TransferTransport {
    if (std.mem.eql(u8, value, "scp")) return .scp;
    if (std.mem.eql(u8, value, "rsync")) return .rsync;
    if (std.mem.eql(u8, value, "chunk")) return .chunk;
    return null;
}

test "transfer options parses transport names" {
    try std.testing.expectEqual(remote_schema.TransferTransport.scp, parseTransport("scp").?);
    try std.testing.expectEqual(remote_schema.TransferTransport.rsync, parseTransport("rsync").?);
    try std.testing.expectEqual(remote_schema.TransferTransport.chunk, parseTransport("chunk").?);
    try std.testing.expect(parseTransport("ssh") == null);
}

test "transfer options parser fills execution and manifest settings" {
    const parsed = try parse(&.{
        "--host", "root@192.0.2.10",
        "--source", "/srv/app",
        "--target", "/srv/app",
        "--recursive",
        "--preserve",
        "--approve",
        "--timeout", "120",
        "--retries", "2",
        "--identity-file", "/home/me/.ssh/id_ed25519",
        "--operation-id", "OPS-123/transfer",
        "--cancel-file", "/tmp/hostlift-cancel-OPS-123",
        "--operation-state", "/tmp/hostlift-operation-state.jsonl",
        "--transport", "rsync",
        "--partial",
        "--resume",
        "--bwlimit", "8192",
        "--manifest-output", "manifest.json",
        "--manifest-max-entries", "10",
        "--force",
        "--verify-remote-manifest",
    });

    try std.testing.expectEqualStrings("root@192.0.2.10", parsed.host.?);
    try std.testing.expectEqualStrings("/srv/app", parsed.source_path.?);
    try std.testing.expectEqualStrings("/srv/app", parsed.target_path.?);
    try std.testing.expect(parsed.recursive);
    try std.testing.expect(parsed.preserve_metadata);
    try std.testing.expect(parsed.approve);
    try std.testing.expectEqual(@as(u32, 120), parsed.execution.timeout_seconds);
    try std.testing.expectEqual(@as(u8, 2), parsed.execution.retries);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", parsed.execution.ssh_identity_file.?);
    try std.testing.expectEqualStrings("OPS-123/transfer", parsed.execution.operation_id.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-cancel-OPS-123", parsed.execution.cancel_file.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-operation-state.jsonl", parsed.execution.operation_state_file.?);
    try std.testing.expectEqual(remote_schema.TransferTransport.rsync, parsed.transport);
    try std.testing.expect(parsed.partial);
    try std.testing.expect(parsed.resumable);
    try std.testing.expectEqual(@as(?u32, 8192), parsed.bandwidth_limit_kbps);
    try std.testing.expectEqualStrings("manifest.json", parsed.manifest_output_path.?);
    try std.testing.expectEqual(@as(usize, 10), parsed.manifest_max_entries);
    try std.testing.expect(parsed.manifest_force);
    try std.testing.expect(parsed.verify_remote_manifest);
}

test "transfer options parser rejects invalid values" {
    try std.testing.expectError(error.InvalidTransport, parse(&.{ "--transport", "ftp" }));
    try std.testing.expectError(error.InvalidMaxEntries, parse(&.{ "--manifest-max-entries", "0" }));
    try std.testing.expectError(error.InvalidTransferBandwidthLimit, parse(&.{ "--bwlimit", "0" }));
    try std.testing.expectError(error.MissingTransferSource, parse(&.{"--source"}));
}

test "transfer options parser accepts credential provider option" {
    const parsed = try parse(&.{
        "--host", "root@192.0.2.10",
        "--source", "/srv/app",
        "--target", "/srv/app",
        "--credential-provider", "ssh-agent",
    });

    try std.testing.expectEqualStrings("ssh-agent", parsed.execution.credential_provider.?);
}
