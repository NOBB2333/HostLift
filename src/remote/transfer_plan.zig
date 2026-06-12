const std = @import("std");
const schema = @import("schema.zig");
const defaults = @import("defaults.zig");
const remote_options = @import("options.zig");
const transfer_rules = @import("transfer_rules.zig");
const validation = @import("../security/validation.zig");

pub const default_chunk_size_bytes: u64 = transfer_rules.default_chunk_size_bytes;

// 生成文件传输计划，支持本地到远程和远程到远程两种来源。
pub fn buildTransferPlan(
    host: []const u8,
    source_host: ?[]const u8,
    source_path: []const u8,
    target_path: []const u8,
    preserve_metadata: bool,
    recursive: bool,
) !schema.TransferPlan {
    return buildTransferPlanWithOptions(host, source_host, source_path, target_path, preserve_metadata, recursive, .{});
}

// 生成带执行选项的文件传输计划，支持本地到远程和远程到远程两种来源。
pub fn buildTransferPlanWithOptions(
    host: []const u8,
    source_host: ?[]const u8,
    source_path: []const u8,
    target_path: []const u8,
    preserve_metadata: bool,
    recursive: bool,
    options: remote_options.ExecutionOptions,
) !schema.TransferPlan {
    return buildTransferPlanAdvanced(host, source_host, source_path, target_path, preserve_metadata, recursive, .scp, false, options);
}

// 生成可选择传输后端的文件传输计划。
pub fn buildTransferPlanAdvanced(
    host: []const u8,
    source_host: ?[]const u8,
    source_path: []const u8,
    target_path: []const u8,
    preserve_metadata: bool,
    recursive: bool,
    transport: schema.TransferTransport,
    partial: bool,
    options: remote_options.ExecutionOptions,
) !schema.TransferPlan {
    return buildTransferPlanAdvancedWithResume(host, source_host, source_path, target_path, preserve_metadata, recursive, transport, partial, false, options);
}

// 生成支持 rsync 续传语义的文件传输计划。
pub fn buildTransferPlanAdvancedWithResume(
    host: []const u8,
    source_host: ?[]const u8,
    source_path: []const u8,
    target_path: []const u8,
    preserve_metadata: bool,
    recursive: bool,
    transport: schema.TransferTransport,
    partial: bool,
    resumable: bool,
    options: remote_options.ExecutionOptions,
) !schema.TransferPlan {
    return buildTransferPlanAdvancedWithLimits(host, source_host, source_path, target_path, preserve_metadata, recursive, transport, partial, resumable, options, null);
}

// 生成带续传和带宽限制的文件传输计划。
pub fn buildTransferPlanAdvancedWithLimits(
    host: []const u8,
    source_host: ?[]const u8,
    source_path: []const u8,
    target_path: []const u8,
    preserve_metadata: bool,
    recursive: bool,
    transport: schema.TransferTransport,
    partial: bool,
    resumable: bool,
    options: remote_options.ExecutionOptions,
    bandwidth_limit_kbps: ?u32,
) !schema.TransferPlan {
    try validation.validateHost(host);
    if (source_host) |value| try validation.validateHost(value);
    try validation.validatePath(source_path);
    try validation.validatePath(target_path);
    try transfer_rules.validate(.{
        .source_host = source_host,
        .recursive = recursive,
        .transport = transport,
        .partial = partial,
        .resumable = resumable,
        .bandwidth_limit_kbps = bandwidth_limit_kbps,
    });
    const normalized_options = try remote_options.normalize(options);

    return .{
        .schema_version = schema.transfer_plan_schema_version,
        .source_host = source_host,
        .host = host,
        .source_path = source_path,
        .target_path = target_path,
        .recursive = recursive,
        .preserve_metadata = preserve_metadata,
        .verify_checksum = !recursive,
        .transport = transport,
        .partial = transfer_rules.effectivePartial(partial, resumable),
        .resumable = resumable,
        .bandwidth_limit_kbps = bandwidth_limit_kbps,
        .chunk_size_bytes = transfer_rules.chunkSize(transport),
        .timeout_seconds = normalized_options.timeout_seconds,
        .retries = normalized_options.retries,
        .ssh_identity_file = normalized_options.ssh_identity_file,
        .credential_source = normalized_options.credential_source,
        .operation_id = normalized_options.operation_id,
        .cancel_file = normalized_options.cancel_file,
        .operation_state_file = normalized_options.operation_state_file,
        .risk = if (recursive) .high else .medium,
        .requires_approval = true,
    };
}

test "transfer plan rejects unsafe target paths" {
    try std.testing.expectError(
        error.InvalidTransferPath,
        buildTransferPlan("root@192.0.2.10", null, "/tmp/app.tar", "/tmp/app.tar;rm", true, false),
    );
    try std.testing.expectError(
        error.InvalidTransferPath,
        buildTransferPlan("root@192.0.2.10", null, "/tmp/app.tar", "/tmp/app*.tar", true, false),
    );
}

test "transfer plan enables checksum verification and rejects whitespace paths" {
    const transfer_plan = try buildTransferPlan("root@192.0.2.10", null, "/tmp/app.tar", "/opt/app.tar", true, false);
    try std.testing.expect(transfer_plan.verify_checksum);
    try std.testing.expectEqual(defaults.default_timeout_seconds, transfer_plan.timeout_seconds);
    try std.testing.expectError(
        error.InvalidTransferPath,
        buildTransferPlan("root@192.0.2.10", null, "/tmp/app archive.tar", "/opt/app.tar", true, false),
    );
}

test "transfer plan accepts retry options" {
    const transfer_plan = try buildTransferPlanWithOptions("root@192.0.2.10", null, "/tmp/app.tar", "/opt/app.tar", true, false, .{
        .timeout_seconds = 120,
        .retries = 2,
        .ssh_identity_file = "/home/me/.ssh/id_ed25519",
    });
    try std.testing.expectEqual(@as(u32, 120), transfer_plan.timeout_seconds);
    try std.testing.expectEqual(@as(u8, 2), transfer_plan.retries);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", transfer_plan.ssh_identity_file.?);
}

test "transfer plan carries ssh agent credential source" {
    const transfer_plan = try buildTransferPlanWithOptions("root@192.0.2.10", null, "/tmp/app.tar", "/opt/app.tar", true, false, .{
        .credential_provider = "ssh-agent",
    });
    try std.testing.expect(transfer_plan.ssh_identity_file == null);
    try std.testing.expectEqual(@import("../credentials/source.zig").SourceKind.ssh_agent, transfer_plan.credential_source);
}

test "transfer plan carries operation metadata" {
    const transfer_plan = try buildTransferPlanAdvanced(
        "root@192.0.2.10",
        null,
        "/srv/app",
        "/srv/app",
        false,
        true,
        .scp,
        false,
        .{
            .operation_id = "OPS-123/transfer",
            .cancel_file = "/tmp/hostlift-cancel-OPS-123",
            .operation_state_file = "/tmp/hostlift-operation-state.jsonl",
        },
    );

    try std.testing.expectEqualStrings("OPS-123/transfer", transfer_plan.operation_id.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-cancel-OPS-123", transfer_plan.cancel_file.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-operation-state.jsonl", transfer_plan.operation_state_file.?);
}

test "transfer plan supports rsync partial transport" {
    const transfer_plan = try buildTransferPlanAdvanced(
        "root@192.0.2.10",
        null,
        "/srv/app",
        "/srv/app",
        true,
        true,
        .rsync,
        true,
        .{ .timeout_seconds = 600, .retries = 2 },
    );
    try std.testing.expectEqual(schema.TransferTransport.rsync, transfer_plan.transport);
    try std.testing.expect(transfer_plan.partial);
    try std.testing.expectEqual(@as(u32, 600), transfer_plan.timeout_seconds);
    try std.testing.expectEqual(@as(u8, 2), transfer_plan.retries);
}

test "transfer plan supports rsync resume transport" {
    const transfer_plan = try buildTransferPlanAdvancedWithResume(
        "root@192.0.2.10",
        null,
        "/srv/app",
        "/srv/app",
        true,
        true,
        .rsync,
        false,
        true,
        .{ .timeout_seconds = 600, .retries = 2 },
    );
    try std.testing.expectEqual(schema.TransferTransport.rsync, transfer_plan.transport);
    try std.testing.expect(transfer_plan.partial);
    try std.testing.expect(transfer_plan.resumable);
}

test "transfer plan carries bandwidth limit" {
    const transfer_plan = try buildTransferPlanAdvancedWithLimits(
        "root@192.0.2.10",
        null,
        "/srv/app",
        "/srv/app",
        true,
        true,
        .rsync,
        false,
        true,
        .{ .timeout_seconds = 600, .retries = 2 },
        8192,
    );
    try std.testing.expectEqual(@as(?u32, 8192), transfer_plan.bandwidth_limit_kbps);
}

test "transfer plan supports chunk transport contract" {
    const transfer_plan = try buildTransferPlanAdvancedWithLimits(
        "root@192.0.2.10",
        null,
        "/srv/app",
        "/srv/app",
        true,
        true,
        .chunk,
        false,
        false,
        .{ .timeout_seconds = 600, .retries = 2 },
        null,
    );
    try std.testing.expectEqual(schema.TransferTransport.chunk, transfer_plan.transport);
    try std.testing.expectEqual(@as(?u64, default_chunk_size_bytes), transfer_plan.chunk_size_bytes);
    try std.testing.expectEqual(@import("../plan/schema.zig").RiskLevel.high, transfer_plan.risk);
}

test "chunk transport currently requires recursive local source" {
    try std.testing.expectError(
        error.ChunkTransferRequiresRecursive,
        buildTransferPlanAdvancedWithLimits("root@192.0.2.10", null, "/tmp/app.tar", "/opt/app.tar", true, false, .chunk, false, false, .{}, null),
    );
    try std.testing.expectError(
        error.ChunkRemoteToRemoteUnsupported,
        buildTransferPlanAdvancedWithLimits("root@192.0.2.10", "root@192.0.2.11", "/srv/app", "/srv/app", true, true, .chunk, false, false, .{}, null),
    );
}

test "remote source transfer validates source host and disables checksum for recursive plans" {
    const transfer_plan = try buildTransferPlan("root@192.0.2.10", "root@192.0.2.11", "/srv/app", "/srv/app", true, true);
    try std.testing.expectEqualStrings("root@192.0.2.11", transfer_plan.source_host.?);
    try std.testing.expect(transfer_plan.recursive);
    try std.testing.expect(!transfer_plan.verify_checksum);
    try std.testing.expectEqual(@import("../plan/schema.zig").RiskLevel.high, transfer_plan.risk);
}
