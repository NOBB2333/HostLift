const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const manifest_hash = @import("../manifest/hash.zig");
const remote_schema = @import("../remote/schema.zig");
const remote_session = @import("../remote/session.zig");
const ssh_argv = @import("../remote/ssh_argv.zig");
const path_util = @import("../util/paths.zig");
const chunk_index = @import("chunk_index.zig");
const chunk_paths = @import("chunk_paths.zig");
const chunk_upload = @import("chunk_upload.zig");
const remote_manifest = @import("manifest.zig");
const transport_runner = @import("runner.zig");

const max_chunk_manifest_entries = 200_000;

// 执行 chunk 传输；当前以整文件 chunk 做增量上传，再用远端 rsync 合并落盘。
pub fn executePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    stdout: anytype,
    stderr: anytype,
) !void {
    if (transfer_plan.source_host != null) return error.ChunkRemoteToRemoteUnsupported;
    if (!transfer_plan.recursive) return error.ChunkTransferRequiresRecursive;
    const chunk_size = transfer_plan.chunk_size_bytes orelse return error.InvalidChunkSize;

    const staging_path = try stagingPathAlloc(allocator, transfer_plan);
    defer allocator.free(staging_path);
    const control = try remote_session.controlWithState(transfer_plan.operation_id, transfer_plan.cancel_file, transfer_plan.operation_state_file);

    try runRemoteCommand(io, allocator, transfer_plan, control, &.{ "mkdir", "-p", staging_path, transfer_plan.target_path }, stdout, stderr);

    var source_manifest = try local_manifest.build(io, allocator, transfer_plan.source_path, max_chunk_manifest_entries);
    defer source_manifest.deinit(allocator);
    var target_manifest = buildTargetManifestOrEmpty(io, allocator, transfer_plan) catch |err| switch (err) {
        error.RemoteManifestFailed, error.FileNotFound => try emptyManifest(allocator, transfer_plan.target_path),
        else => return err,
    };
    defer target_manifest.deinit(allocator);

    var source_index = try chunk_index.buildFromManifest(allocator, source_manifest, chunk_size);
    defer source_index.deinit(allocator);
    var target_index = try chunk_index.buildFromManifest(allocator, target_manifest, chunk_size);
    defer target_index.deinit(allocator);
    const missing = try chunk_index.missingChunks(allocator, source_index.index, target_index.index);
    defer allocator.free(missing);

    try createStagingDirectories(io, allocator, transfer_plan, control, staging_path, source_manifest, missing, stdout, stderr);
    try uploadMissingChunks(io, allocator, transfer_plan, control, staging_path, missing, stdout, stderr);

    const staged_source = try std.fmt.allocPrint(allocator, "{s}/", .{staging_path});
    defer allocator.free(staged_source);
    try runRemoteCommand(io, allocator, transfer_plan, control, &.{ "rsync", "-a", staged_source, transfer_plan.target_path }, stdout, stderr);
    try stdout.print("chunk transfer staged: {s} missing_or_changed={d}\n", .{ staging_path, missing.len });
}

// 构造 chunk 上传使用的 scp argv。
pub fn appendUploadArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    transfer_plan: remote_schema.TransferPlan,
    source_path: []const u8,
    remote_target: []const u8,
    bandwidth_limit_arg: ?[]const u8,
) !void {
    try chunk_upload.appendDirectoryUploadArgv(allocator, argv, transfer_plan, source_path, remote_target, bandwidth_limit_arg);
}

// 构建远端目标 manifest，失败时返回空 manifest 而非报错。
fn buildTargetManifestOrEmpty(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
) !local_manifest.Manifest {
    return remote_manifest.buildRemoteWithOptions(io, allocator, transfer_plan.host, transfer_plan.target_path, max_chunk_manifest_entries, .{
        .timeout_seconds = transfer_plan.timeout_seconds,
        .retries = transfer_plan.retries,
        .ssh_identity_file = transfer_plan.ssh_identity_file,
        .operation_id = transfer_plan.operation_id,
        .cancel_file = transfer_plan.cancel_file,
        .operation_state_file = transfer_plan.operation_state_file,
    });
}

// 构造一个空的 manifest，用于远端目标不存在时的增量对比基准。
fn emptyManifest(allocator: std.mem.Allocator, root_path: []const u8) !local_manifest.Manifest {
    return .{
        .root = try allocator.dupe(u8, root_path),
        .entries = try allocator.alloc(local_manifest.Entry, 0),
        .file_count = 0,
        .dir_count = 0,
        .total_bytes = 0,
        .truncated = false,
    };
}

// 在远端 staging 目录下创建缺失的子目录结构。
fn createStagingDirectories(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    control: remote_session.Control,
    staging_path: []const u8,
    source_manifest: local_manifest.Manifest,
    missing: []const chunk_index.ChunkRef,
    stdout: anytype,
    stderr: anytype,
) !void {
    for (source_manifest.entries) |entry| {
        if (!std.mem.eql(u8, entry.kind, "directory")) continue;
        const remote_dir = try chunk_paths.joinRemoteRelative(allocator, staging_path, entry.path);
        defer allocator.free(remote_dir);
        try runRemoteCommand(io, allocator, transfer_plan, control, &.{ "mkdir", "-p", remote_dir }, stdout, stderr);
    }

    for (missing) |chunk| {
        const parent = try path_util.parentDirAlloc(allocator, chunk.path);
        defer allocator.free(parent);
        if (std.mem.eql(u8, parent, ".")) continue;
        const remote_parent = try chunk_paths.joinRemoteRelative(allocator, staging_path, parent);
        defer allocator.free(remote_parent);
        try runRemoteCommand(io, allocator, transfer_plan, control, &.{ "mkdir", "-p", remote_parent }, stdout, stderr);
    }
}

// 逐 chunk 上传本地缺失或变更的文件到远端 staging 目录。
fn uploadMissingChunks(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    control: remote_session.Control,
    staging_path: []const u8,
    missing: []const chunk_index.ChunkRef,
    stdout: anytype,
    stderr: anytype,
) !void {
    var bandwidth_limit_buf: [16]u8 = undefined;
    const bandwidth_limit = formatScpBandwidthLimitKbps(&bandwidth_limit_buf, transfer_plan.bandwidth_limit_kbps);
    for (missing) |chunk| {
        const local_source = try chunk_paths.joinLocalRelative(allocator, transfer_plan.source_path, chunk.path);
        defer allocator.free(local_source);
        const remote_file_path = try chunk_paths.joinRemoteRelative(allocator, staging_path, chunk.path);
        defer allocator.free(remote_file_path);
        const remote_target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ transfer_plan.host, remote_file_path });
        defer allocator.free(remote_target);

        var scp_argv: std.ArrayList([]const u8) = .empty;
        defer scp_argv.deinit(allocator);
        try chunk_upload.appendFileUploadArgv(allocator, &scp_argv, transfer_plan, local_source, remote_target, bandwidth_limit);
        try transport_runner.runWithSession(io, allocator, scp_argv.items, transfer_plan.timeout_seconds, transfer_plan.retries, control, stdout, stderr);
    }
}

// 通过 SSH 在远程主机上执行单条命令。
fn runRemoteCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    control: remote_session.Control,
    command: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &argv, transfer_plan.ssh_identity_file, null, transfer_plan.host);
    try argv.appendSlice(allocator, command);
    try transport_runner.runWithSession(io, allocator, argv.items, transfer_plan.timeout_seconds, transfer_plan.retries, control, stdout, stderr);
}


// 根据传输计划的 host/source/target 生成确定性 staging 路径。
fn stagingPathAlloc(allocator: std.mem.Allocator, transfer_plan: remote_schema.TransferPlan) ![]const u8 {
    const key = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ transfer_plan.host, transfer_plan.source_path, transfer_plan.target_path });
    defer allocator.free(key);
    const hash = try manifest_hash.sha256BytesHexAlloc(allocator, key);
    defer allocator.free(hash);
    return std.fmt.allocPrint(allocator, "/tmp/hostlift-chunk-{s}", .{hash[0..16]});
}

// 将带宽限制值（kbps）格式化为 scp -l 参数字符串。
fn formatScpBandwidthLimitKbps(buffer: []u8, value: ?u32) ?[]const u8 {
    const limit = value orelse return null;
    return std.fmt.bufPrint(buffer, "{d}", .{limit}) catch unreachable;
}


test "chunk staging path is deterministic and under tmp" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .chunk,
        .risk = .high,
        .requires_approval = true,
    };
    const path = try stagingPathAlloc(std.testing.allocator, plan);
    defer std.testing.allocator.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/hostlift-chunk-"));
    try std.testing.expectEqual(@as(usize, "/tmp/hostlift-chunk-".len + 16), path.len);
}
