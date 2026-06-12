const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const remote_schema = @import("../remote/schema.zig");
const remote_session = @import("../remote/session.zig");
const remote_manifest = @import("manifest.zig");
const transport_runner = @import("runner.zig");

// 执行 scp 传输；单文件传输会在成功后做 SHA-256 校验。
pub fn executePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    stdout: anytype,
    stderr: anytype,
) !void {
    const transfer_source = if (transfer_plan.source_host) |source_host|
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ source_host, transfer_plan.source_path })
    else
        try allocator.dupe(u8, transfer_plan.source_path);
    defer allocator.free(transfer_source);

    const remote_target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ transfer_plan.host, transfer_plan.target_path });
    defer allocator.free(remote_target);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var bandwidth_limit_buf: [16]u8 = undefined;
    const bandwidth_limit_arg = formatBandwidthLimitKbps(&bandwidth_limit_buf, transfer_plan.bandwidth_limit_kbps);
    try appendArgv(allocator, &argv, transfer_plan, transfer_source, remote_target, bandwidth_limit_arg);

    try transport_runner.runWithSession(
        io,
        allocator,
        argv.items,
        transfer_plan.timeout_seconds,
        transfer_plan.retries,
        try remote_session.controlWithState(transfer_plan.operation_id, transfer_plan.cancel_file, transfer_plan.operation_state_file),
        stdout,
        stderr,
    );

    if (transfer_plan.verify_checksum) {
        const local_hash = if (transfer_plan.source_host) |source_host|
            try remote_manifest.sha256FileWithOptions(io, allocator, source_host, transfer_plan.source_path, .{ .ssh_identity_file = transfer_plan.ssh_identity_file })
        else
            try local_manifest.sha256File(io, transfer_plan.source_path);
        const remote_hash = try remote_manifest.sha256FileWithOptions(io, allocator, transfer_plan.host, transfer_plan.target_path, .{ .ssh_identity_file = transfer_plan.ssh_identity_file });
        if (!std.mem.eql(u8, local_hash[0..], remote_hash[0..])) return error.RemoteTransferChecksumMismatch;
        const hash_text = local_manifest.hexSha256(local_hash);
        try stdout.print("sha256 verified: {s}\n", .{&hash_text});
    }
}

test "scp argv includes identity file" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/tmp/app.tar",
        .target_path = "/opt/app.tar",
        .preserve_metadata = true,
        .verify_checksum = false,
        .ssh_identity_file = "/home/me/.ssh/id_ed25519",
        .risk = .medium,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendArgv(std.testing.allocator, &argv, plan, "/tmp/app.tar", "root@192.0.2.10:/opt/app.tar", null);

    try std.testing.expectEqualStrings("scp", argv.items[0]);
    try std.testing.expectEqualStrings("-i", argv.items[1]);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", argv.items[2]);
}

test "scp argv includes bandwidth limit" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/tmp/app.tar",
        .target_path = "/opt/app.tar",
        .preserve_metadata = true,
        .verify_checksum = false,
        .bandwidth_limit_kbps = 8192,
        .risk = .medium,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    var limit_buf: [16]u8 = undefined;
    const limit_arg = formatBandwidthLimitKbps(&limit_buf, plan.bandwidth_limit_kbps).?;
    try appendArgv(std.testing.allocator, &argv, plan, "/tmp/app.tar", "root@192.0.2.10:/opt/app.tar", limit_arg);

    try std.testing.expectEqualStrings("-l", argv.items[1]);
    try std.testing.expectEqualStrings("8192", argv.items[2]);
}

// 拼接 scp argv，支持 identity file、带宽限制、递归和元数据保留。
fn appendArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    transfer_plan: remote_schema.TransferPlan,
    transfer_source: []const u8,
    remote_target: []const u8,
    bandwidth_limit_arg: ?[]const u8,
) !void {
    try argv.append(allocator, "scp");
    if (transfer_plan.ssh_identity_file) |path| try argv.appendSlice(allocator, &.{ "-i", path });
    if (bandwidth_limit_arg) |value| try argv.appendSlice(allocator, &.{ "-l", value });
    if (transfer_plan.source_host != null) try argv.append(allocator, "-3");
    if (transfer_plan.recursive) try argv.append(allocator, "-r");
    if (transfer_plan.preserve_metadata) try argv.append(allocator, "-p");
    try argv.append(allocator, transfer_source);
    try argv.append(allocator, remote_target);
}

// 将带宽限制值（kbps）格式化为 scp -l 参数字符串。
fn formatBandwidthLimitKbps(buffer: []u8, value: ?u32) ?[]const u8 {
    const limit = value orelse return null;
    return std.fmt.bufPrint(buffer, "{d}", .{limit}) catch unreachable;
}
