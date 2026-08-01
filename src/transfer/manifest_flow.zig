const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const remote_schema = @import("../remote/schema.zig");
const remote_manifest = @import("../transport/manifest.zig");
const transfer_options = @import("options.zig");

// 判断 transfer 是否需要先构建源路径 manifest。
pub fn needsSourceManifest(parsed: transfer_options.Parsed) bool {
    return parsed.manifest_output_path != null or parsed.verify_remote_manifest;
}

// 校验 transfer manifest 相关选项之间的约束。
pub fn validateOptions(parsed: transfer_options.Parsed) !void {
    const needs_manifest = needsSourceManifest(parsed);
    if (needs_manifest and parsed.source_host != null and !parsed.approve) return error.RemoteSourceManifestRequiresApprove;
    if (needs_manifest and parsed.source_host != null and !parsed.recursive) return error.RemoteSourceManifestRequiresRecursiveTransfer;
    if (parsed.verify_remote_manifest and !parsed.recursive) return error.RemoteManifestVerificationRequiresRecursiveTransfer;
    if (parsed.verify_remote_manifest and !parsed.approve) return error.RemoteManifestVerificationRequiresApprove;
}

// 按 transfer 来源位置构建本地或远程源 manifest。
pub fn buildSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: transfer_options.Parsed,
    source_path: []const u8,
) !?local_manifest.Manifest {
    if (!needsSourceManifest(parsed)) return null;
    if (parsed.source_host) |host| {
        return try remote_manifest.buildRemoteWithOptions(io, allocator, host, source_path, parsed.manifest_max_entries, parsed.execution);
    }
    return try local_manifest.build(io, allocator, source_path, parsed.manifest_max_entries);
}

// 如用户指定 --manifest-output，则写出源 manifest。
pub fn writeSourceIfRequested(
    io: std.Io,
    stdout: anytype,
    parsed: transfer_options.Parsed,
    source_manifest: ?local_manifest.Manifest,
) !void {
    if (parsed.manifest_output_path) |path| {
        const manifest_value = source_manifest orelse return error.MissingTransferSourceManifest;
        try local_manifest.writeFile(io, path, manifest_value, parsed.manifest_force);
        try stdout.print("source manifest written: {s}\n", .{path});
    }
}

// 如用户要求远程校验，则构建目标 manifest 并与源 manifest 对比。
pub fn verifyRemoteIfRequested(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: anytype,
    parsed: transfer_options.Parsed,
    transfer_plan: remote_schema.TransferPlan,
    source_manifest: ?local_manifest.Manifest,
) !void {
    if (!parsed.verify_remote_manifest) return;

    const expected = source_manifest orelse return error.MissingTransferSourceManifest;
    var actual = try remote_manifest.buildRemoteWithOptions(
        io,
        allocator,
        transfer_plan.host,
        transfer_plan.target_path,
        parsed.manifest_max_entries,
        parsed.execution,
    );
    defer actual.deinit(allocator);

    const report = try local_manifest.verify(allocator, expected, actual);
    try local_manifest.writeVerificationSummary(stdout, report);
    if (!report.valid) return error.RemoteManifestVerificationFailed;
}

test "transfer manifest flow detects source manifest needs" {
    try std.testing.expect(!needsSourceManifest(.{}));
    try std.testing.expect(needsSourceManifest(.{ .manifest_output_path = "manifest.json" }));
    try std.testing.expect(needsSourceManifest(.{ .verify_remote_manifest = true }));
}

test "transfer manifest flow validates remote source constraints" {
    try validateOptions(.{});
    try std.testing.expectError(
        error.RemoteSourceManifestRequiresApprove,
        validateOptions(.{ .source_host = "root@192.0.2.11", .manifest_output_path = "manifest.json" }),
    );
    try std.testing.expectError(
        error.RemoteSourceManifestRequiresRecursiveTransfer,
        validateOptions(.{ .source_host = "root@192.0.2.11", .manifest_output_path = "manifest.json", .approve = true }),
    );
}

test "transfer manifest flow validates remote verification constraints" {
    try std.testing.expectError(
        error.RemoteManifestVerificationRequiresRecursiveTransfer,
        validateOptions(.{ .verify_remote_manifest = true, .approve = true }),
    );
    try std.testing.expectError(
        error.RemoteManifestVerificationRequiresApprove,
        validateOptions(.{ .verify_remote_manifest = true, .recursive = true }),
    );
    try validateOptions(.{ .verify_remote_manifest = true, .recursive = true, .approve = true });
}
