const std = @import("std");
const remote_schema = @import("../remote/schema.zig");
const remote_session = @import("../remote/session.zig");
const ssh_argv = @import("../remote/ssh_argv.zig");
const transport_runner = @import("runner.zig");

// 执行 rsync 传输；支持 --partial 保留未完成文件，便于后续重试继续传。
pub fn executePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    stdout: anytype,
    stderr: anytype,
) !void {
    if (transfer_plan.source_host != null) {
        try executeRemoteSourcePlan(io, allocator, transfer_plan, stdout, stderr);
        return;
    }

    const transfer_source = try allocator.dupe(u8, transfer_plan.source_path);
    defer allocator.free(transfer_source);

    const remote_target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ transfer_plan.host, transfer_plan.target_path });
    defer allocator.free(remote_target);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const remote_shell = try remoteShellArg(allocator, transfer_plan.ssh_identity_file);
    defer if (remote_shell) |value| allocator.free(value);
    var bandwidth_limit_buf: [32]u8 = undefined;
    const bandwidth_limit_arg = formatBandwidthLimitKbps(&bandwidth_limit_buf, transfer_plan.bandwidth_limit_kbps);
    try appendArgv(allocator, &argv, transfer_plan, transfer_source, remote_target, remote_shell, bandwidth_limit_arg);
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
}

fn executeRemoteSourcePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    transfer_plan: remote_schema.TransferPlan,
    stdout: anytype,
    stderr: anytype,
) !void {
    const source_host = transfer_plan.source_host.?;
    const remote_target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ transfer_plan.host, transfer_plan.target_path });
    defer allocator.free(remote_target);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const connect_timeout = try std.fmt.allocPrint(allocator, "ConnectTimeout={d}", .{transfer_plan.timeout_seconds});
    defer allocator.free(connect_timeout);

    var bandwidth_limit_buf: [32]u8 = undefined;
    const bandwidth_limit_arg = formatBandwidthLimitKbps(&bandwidth_limit_buf, transfer_plan.bandwidth_limit_kbps);
    try appendRemoteSourceArgv(allocator, &argv, transfer_plan, source_host, remote_target, connect_timeout, bandwidth_limit_arg);

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
}

fn appendRemoteSourceArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    transfer_plan: remote_schema.TransferPlan,
    source_host: []const u8,
    remote_target: []const u8,
    connect_timeout: []const u8,
    bandwidth_limit_arg: ?[]const u8,
) !void {
    try ssh_argv.appendSshPrefix(allocator, argv, transfer_plan.ssh_identity_file, connect_timeout, source_host);
    try appendArgv(allocator, argv, transfer_plan, transfer_plan.source_path, remote_target, "ssh -o BatchMode=yes", bandwidth_limit_arg);
}

// 构造 rsync argv；测试直接覆盖这个边界，避免 shell 拼接风险。
pub fn appendArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    transfer_plan: remote_schema.TransferPlan,
    transfer_source: []const u8,
    remote_target: []const u8,
    remote_shell: ?[]const u8,
    bandwidth_limit_arg: ?[]const u8,
) !void {
    try argv.append(allocator, "rsync");
    try argv.append(allocator, "-a");
    if (remote_shell) |value| try argv.appendSlice(allocator, &.{ "-e", value });
    if (bandwidth_limit_arg) |value| try argv.append(allocator, value);
    if (transfer_plan.partial) try argv.append(allocator, "--partial");
    if (transfer_plan.resumable) try argv.append(allocator, "--append-verify");
    if (!transfer_plan.recursive) try argv.append(allocator, "--no-recursive");
    if (!transfer_plan.preserve_metadata) try argv.append(allocator, "--no-perms");
    try argv.append(allocator, transfer_source);
    try argv.append(allocator, remote_target);
}

// 构造 rsync -e ssh 远程 shell 参数，指定 identity file。
fn remoteShellArg(allocator: std.mem.Allocator, identity_file: ?[]const u8) !?[]const u8 {
    const path = identity_file orelse return null;
    const value = try std.fmt.allocPrint(allocator, "ssh -o BatchMode=yes -i {s}", .{path});
    return value;
}

// 将 kbps 带宽限制转换为 rsync --bwlimit 参数。
fn formatBandwidthLimitKbps(buffer: []u8, value: ?u32) ?[]const u8 {
    const limit = value orelse return null;
    const kb_per_second = @max(@as(u32, 1), (limit / 8) + @as(u32, if (limit % 8 == 0) 0 else 1));
    return std.fmt.bufPrint(buffer, "--bwlimit={d}", .{kb_per_second}) catch unreachable;
}

// 检查 argv 中是否已包含指定参数值。
fn containsArg(argv: []const []const u8, value: []const u8) bool {
    for (argv) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

test "rsync argv includes archive and partial flags" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .rsync,
        .partial = true,
        .timeout_seconds = 600,
        .retries = 2,
        .risk = .high,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendArgv(std.testing.allocator, &argv, plan, "/srv/app", "root@192.0.2.10:/srv/app", null, null);

    try std.testing.expectEqualStrings("rsync", argv.items[0]);
    try std.testing.expectEqualStrings("-a", argv.items[1]);
    try std.testing.expectEqualStrings("--partial", argv.items[2]);
    try std.testing.expectEqualStrings("/srv/app", argv.items[3]);
    try std.testing.expectEqualStrings("root@192.0.2.10:/srv/app", argv.items[4]);
}

test "rsync argv includes append verify for resume" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .rsync,
        .partial = true,
        .resumable = true,
        .risk = .high,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendArgv(std.testing.allocator, &argv, plan, "/srv/app", "root@192.0.2.10:/srv/app", null, null);

    try std.testing.expect(containsArg(argv.items, "--partial"));
    try std.testing.expect(containsArg(argv.items, "--append-verify"));
}

test "rsync argv includes bandwidth limit" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .rsync,
        .bandwidth_limit_kbps = 8192,
        .risk = .high,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    var limit_buf: [32]u8 = undefined;
    const limit_arg = formatBandwidthLimitKbps(&limit_buf, plan.bandwidth_limit_kbps).?;
    try appendArgv(std.testing.allocator, &argv, plan, "/srv/app", "root@192.0.2.10:/srv/app", null, limit_arg);

    try std.testing.expect(containsArg(argv.items, "--bwlimit=1024"));
}

test "rsync argv includes identity file through remote shell" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .rsync,
        .ssh_identity_file = "/home/me/.ssh/id_ed25519",
        .risk = .high,
        .requires_approval = true,
    };
    const remote_shell = try remoteShellArg(std.testing.allocator, plan.ssh_identity_file);
    defer if (remote_shell) |value| std.testing.allocator.free(value);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendArgv(std.testing.allocator, &argv, plan, "/srv/app", "root@192.0.2.10:/srv/app", remote_shell, null);

    try std.testing.expectEqualStrings("-e", argv.items[2]);
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes -i /home/me/.ssh/id_ed25519", argv.items[3]);
}

test "remote source rsync argv sshes to source host and pushes to target" {
    const plan = remote_schema.TransferPlan{
        .schema_version = remote_schema.transfer_plan_schema_version,
        .source_host = "root@192.0.2.11",
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .rsync,
        .partial = true,
        .timeout_seconds = 600,
        .risk = .high,
        .requires_approval = true,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendRemoteSourceArgv(std.testing.allocator, &argv, plan, plan.source_host.?, "root@192.0.2.10:/srv/app", "ConnectTimeout=600", null);

    try std.testing.expectEqualStrings("ssh", argv.items[0]);
    try std.testing.expectEqualStrings("root@192.0.2.11", argv.items[5]);
    try std.testing.expectEqualStrings("--", argv.items[6]);
    try std.testing.expectEqualStrings("rsync", argv.items[7]);
    try std.testing.expect(containsArg(argv.items, "--partial"));
    try std.testing.expect(containsArg(argv.items, "/srv/app"));
    try std.testing.expect(containsArg(argv.items, "root@192.0.2.10:/srv/app"));
}
