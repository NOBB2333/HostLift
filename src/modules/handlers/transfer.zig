const std = @import("std");
const plan = @import("../../plan/schema.zig");
const handler = @import("../handler.zig");

const apply_actions = @import("../../apply/actions.zig");
const apply_permissions = @import("../../apply/permissions.zig");
const firewall_backend = @import("../../firewall/backend.zig");
const firewall_reload = @import("../../firewall/reload.zig");
const local_manifest = @import("../../manifest/local.zig");
const manifest_verify = @import("../../manifest/verify.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const remote_preflight = @import("../../remote/preflight.zig");
const remote_schema = @import("../../remote/schema.zig");
const remote_manifest = @import("../../transport/manifest.zig");
const transfer_command = @import("../../transfer/command.zig");
const path_util = @import("../../util/paths.zig");

// 声明文件型 action 在目标机器执行前需要具备的入口命令。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    return switch (action.action_type) {
        .add_authorized_key => &.{ "chmod", "chown" },
        .copy_home_config => &.{ "mkdir", "chown", "chmod" },
        .copy_data_path, .copy_project_path => if (ctx.options.transfer_manifest_verify)
            &.{ "find", "stat", "sha256sum", "readlink" }
        else
            &.{},
        .apply_firewall_config => firewallRequirements(ctx, action),
        else => &.{},
    };
}

// 对文件型 action 执行只读 preflight，覆盖源路径、目标冲突、传输依赖和递归容量。
pub fn preflight(ctx: handler.ApplyPreflightContext, action: plan.Action) !void {
    const transfer_plan = try buildTransferPlan(ctx, action);
    try preflightTransferPlan(ctx, action, transfer_plan);
}

// 对已构造的传输计划执行模块级只读 preflight；供 systemd unit 等改写目标路径的 action 复用。
pub fn preflightTransferPlan(ctx: handler.ApplyPreflightContext, action: plan.Action, transfer_plan: remote_schema.TransferPlan) !void {
    try ensureSourcePathExists(ctx, transfer_plan);
    try ensureNewDataTargetAbsent(ctx, action, transfer_plan);
    try remote_preflight.runTransferPreflight(ctx.io, ctx.allocator, transfer_plan, ctx.options.execution);
    try preflightCapacity(ctx, action, transfer_plan);
    try preflightRecursiveManifest(ctx, action, transfer_plan);
}

fn preflightRecursiveManifest(ctx: handler.ApplyPreflightContext, action: plan.Action, transfer_plan: remote_schema.TransferPlan) !void {
    if (!shouldVerifyRecursiveManifest(action, ctx.options.transfer_manifest_verify)) return;
    if (ctx.options.transfer_manifest_max_entries == 0) return error.InvalidManifestEntryLimit;

    if (transfer_plan.source_host) |source_host| {
        try remote_preflight.runCheck(ctx.io, ctx.allocator, .{
            .host = source_host,
            .commands = &.{ "find", "stat", "sha256sum", "readlink" },
        }, ctx.options.execution);
    }

    var source_manifest = try buildSourceManifest(
        ctx.io,
        ctx.allocator,
        transfer_plan.source_host,
        transfer_plan.source_path,
        ctx.options.transfer_manifest_max_entries,
        ctx.options.execution,
    );
    defer source_manifest.deinit(ctx.allocator);
    try manifest_verify.ensureCompleteContent(source_manifest);
    try ctx.stdout.print("content manifest preflight {s}: entries={d} bytes={d}\n", .{
        action.id,
        source_manifest.entries.len,
        source_manifest.total_bytes,
    });
}

fn buildSourceManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_host: ?[]const u8,
    source_path: []const u8,
    max_entries: usize,
    execution: @import("../../remote/options.zig").ExecutionOptions,
) !local_manifest.Manifest {
    if (source_host) |host| {
        return remote_manifest.buildRemoteWithOptions(io, allocator, host, source_path, max_entries, execution);
    }
    return local_manifest.build(io, allocator, source_path, max_entries);
}

// 执行文件型迁移动作，统一走 transfer plan、权限修复和可选防火墙 reload。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    const transfer_plan = try buildTransferPlan(ctx, action);
    const action_subject = apply_actions.subject(action);
    try ctx.stdout.print("  - {s}: ", .{action.id});
    if (action.action_type == .copy_home_config) {
        try apply_permissions.prepareHomeConfigParentWithOptions(ctx.io, ctx.allocator, ctx.target_host, action, action_subject, ctx.stdout, ctx.stderr, ctx.options.execution);
    }
    try transfer_command.executePlan(ctx.io, ctx.allocator, transfer_plan, ctx.stdout, ctx.stderr);
    if (action.action_type == .add_authorized_key) {
        try apply_permissions.fixAuthorizedKeysWithOptions(ctx.io, ctx.allocator, ctx.target_host, action, action_subject, ctx.stdout, ctx.stderr, ctx.options.execution);
    }
    if (action.action_type == .copy_home_config) {
        try apply_permissions.fixHomeConfigWithOptions(ctx.io, ctx.allocator, ctx.target_host, action, action_subject, ctx.stdout, ctx.stderr, ctx.options.execution);
    }
    if (action.action_type == .apply_firewall_config and ctx.options.firewall_reload) {
        try firewall_reload.reloadConfigWithOptions(ctx.io, ctx.allocator, ctx.target_host, action_subject, ctx.options.ssh_port, ctx.stdout, ctx.stderr, ctx.options.execution, .{
            .enabled = ctx.options.firewall_recovery_window_seconds > 0,
            .window_seconds = if (ctx.options.firewall_recovery_window_seconds == 0) 90 else ctx.options.firewall_recovery_window_seconds,
        });
    }
    return .{ .changed = true };
}

fn buildTransferPlan(ctx: anytype, action: plan.Action) !remote_schema.TransferPlan {
    const action_subject = apply_actions.subject(action);
    if (action_subject.len == 0) return error.MissingApplySubject;
    const recursive = action.action_type == .copy_data_path or
        action.action_type == .copy_project_path or
        action.action_type == .apply_firewall_config or
        action.recursive;
    return remote_planner.buildTransferPlanAdvancedWithLimits(
        ctx.target_host,
        ctx.source_host,
        action_subject,
        action_subject,
        true,
        recursive,
        ctx.options.transfer_transport,
        ctx.options.transfer_partial,
        ctx.options.transfer_resume,
        ctx.options.execution,
        ctx.options.transfer_bandwidth_limit_kbps,
    );
}

fn ensureSourcePathExists(ctx: handler.ApplyPreflightContext, transfer_plan: remote_schema.TransferPlan) !void {
    if (transfer_plan.source_host) |source_host| {
        if (!try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, source_host, transfer_plan.source_path, ctx.options.execution)) return error.TransferSourceMissing;
        return;
    }
    std.Io.Dir.accessAbsolute(ctx.io, transfer_plan.source_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.TransferSourceMissing,
        else => return err,
    };
}

fn ensureNewDataTargetAbsent(ctx: handler.ApplyPreflightContext, action: plan.Action, transfer_plan: remote_schema.TransferPlan) !void {
    if (action.action_type != .copy_data_path and action.action_type != .copy_project_path) return;
    if (try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, transfer_plan.target_path, ctx.options.execution)) return error.TargetDataPathAlreadyExists;
}

fn preflightCapacity(ctx: handler.ApplyPreflightContext, action: plan.Action, transfer_plan: remote_schema.TransferPlan) !void {
    if (!shouldCheckCapacity(action, transfer_plan)) return;
    const required_bytes = try sourceApparentBytes(ctx, transfer_plan);
    if (required_bytes == 0) return;
    const target_parent = try path_util.parentDirAlloc(ctx.allocator, transfer_plan.target_path);
    defer ctx.allocator.free(target_parent);
    const capacity = try remoteCapacity(ctx, target_parent);
    if (capacity.available_bytes <= required_bytes) return error.TargetCapacityInsufficient;
    if (capacity.available_inodes == 0) return error.TargetInodeCapacityUnavailable;
    const required_inodes = try sourceEntryCount(ctx, action, transfer_plan, capacity.available_inodes);
    if (required_inodes.count > 0 and required_inodes.count >= capacity.available_inodes) return error.TargetInodeCapacityInsufficient;
    try ctx.stdout.print("capacity preflight {s}: need={d}B available={d}B files={s}{d} iavail={d}\n", .{
        action.id,
        required_bytes,
        capacity.available_bytes,
        if (required_inodes.overflow) ">" else "",
        required_inodes.count,
        capacity.available_inodes,
    });
}

fn shouldCheckCapacity(action: plan.Action, transfer_plan: remote_schema.TransferPlan) bool {
    if (!transfer_plan.recursive) return false;
    return action.action_type == .copy_data_path or action.action_type == .copy_project_path;
}

const RemoteCapacity = struct {
    available_bytes: u64,
    available_inodes: u64,
};

const SourceEntryCount = struct {
    count: u64 = 0,
    overflow: bool = false,
};

fn remoteCapacity(ctx: handler.ApplyPreflightContext, path: []const u8) !RemoteCapacity {
    var df_bytes_argv = [_][]const u8{ "df", "-PB1", path };
    const bytes_output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, df_bytes_argv[0..], ctx.options.execution, 16 * 1024);
    defer ctx.allocator.free(bytes_output);
    var df_inode_argv = [_][]const u8{ "df", "-Pi", path };
    const inode_output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, df_inode_argv[0..], ctx.options.execution, 16 * 1024);
    defer ctx.allocator.free(inode_output);
    return .{
        .available_bytes = parseDfAvailable(bytes_output) orelse return error.TargetCapacityUnavailable,
        .available_inodes = parseDfAvailable(inode_output) orelse return error.TargetInodeCapacityUnavailable,
    };
}

fn sourceApparentBytes(ctx: handler.ApplyPreflightContext, transfer_plan: remote_schema.TransferPlan) !u64 {
    if (transfer_plan.source_host) |source_host| {
        return remoteApparentBytes(ctx.io, ctx.allocator, source_host, transfer_plan.source_path, ctx.options.execution);
    }
    return localApparentBytes(ctx.io, ctx.allocator, transfer_plan.source_path);
}

fn sourceEntryCount(ctx: handler.ApplyPreflightContext, action: plan.Action, transfer_plan: remote_schema.TransferPlan, available_inodes: u64) !SourceEntryCount {
    var result = SourceEntryCount{ .count = action.file_count };
    if (result.count >= available_inodes and result.count > 0) return result;

    const limit = inodeProbeLimit(available_inodes);
    const probed = if (transfer_plan.source_host) |source_host|
        try remoteEntryCount(ctx.io, ctx.allocator, source_host, transfer_plan.source_path, ctx.options.execution, limit)
    else
        try localEntryCount(ctx.io, ctx.allocator, transfer_plan.source_path, limit);
    if (probed.count > result.count) result.count = probed.count;
    result.overflow = probed.overflow;
    return result;
}

const max_inode_probe_entries: usize = 64 * 1024 * 1024;

fn inodeProbeLimit(available_inodes: u64) usize {
    const wanted = std.math.add(u64, available_inodes, 1) catch std.math.maxInt(u64);
    const capped = @min(wanted, max_inode_probe_entries);
    return @intCast(@min(capped, std.math.maxInt(usize)));
}

fn remoteEntryCount(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    execution: @import("../../remote/options.zig").ExecutionOptions,
    limit: usize,
) !SourceEntryCount {
    var argv = [_][]const u8{ "find", path, "-xdev", "-printf", "." };
    const output = remote_exec.commandOutputWithOptions(io, allocator, host, argv[0..], execution, limit) catch |err| switch (err) {
        error.StreamTooLong => return .{ .count = limit, .overflow = true },
        else => return err,
    };
    defer allocator.free(output);
    return .{ .count = output.len };
}

fn localEntryCount(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) !SourceEntryCount {
    const argv = [_][]const u8{ "find", path, "-xdev", "-printf", "." };
    const output = runLocalCommand(io, allocator, argv[0..], limit) catch |err| switch (err) {
        error.StreamTooLong => return .{ .count = limit, .overflow = true },
        else => return err,
    };
    defer allocator.free(output);
    return .{ .count = output.len };
}

fn remoteApparentBytes(io: std.Io, allocator: std.mem.Allocator, host: []const u8, path: []const u8, execution: @import("../../remote/options.zig").ExecutionOptions) !u64 {
    var du_bytes_argv = [_][]const u8{ "du", "-sb", path };
    if (remote_exec.commandOutputWithOptions(io, allocator, host, du_bytes_argv[0..], execution, 16 * 1024)) |output| {
        defer allocator.free(output);
        return parseDuBytes(output) orelse error.SourceSizeUnavailable;
    } else |_| {}
    var du_kib_argv = [_][]const u8{ "du", "-sk", path };
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, du_kib_argv[0..], execution, 16 * 1024);
    defer allocator.free(output);
    return (parseDuBytes(output) orelse return error.SourceSizeUnavailable) * 1024;
}

fn localApparentBytes(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
    const du_bytes_argv = [_][]const u8{ "du", "-sb", path };
    if (runLocalCommand(io, allocator, du_bytes_argv[0..], 16 * 1024)) |output| {
        defer allocator.free(output);
        return parseDuBytes(output) orelse error.SourceSizeUnavailable;
    } else |_| {}
    const du_kib_argv = [_][]const u8{ "du", "-sk", path };
    const output = try runLocalCommand(io, allocator, du_kib_argv[0..], 16 * 1024);
    defer allocator.free(output);
    return (parseDuBytes(output) orelse return error.SourceSizeUnavailable) * 1024;
}

fn runLocalCommand(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, limit: usize) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.CommandFailed;
        },
    }
    return result.stdout;
}

fn parseDuBytes(output: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, output, " \t\r\n");
    return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
}

fn parseDfAvailable(output: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next() orelse return null;
    var last: ?[]const u8 = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len > 0) last = line;
    }
    const line = last orelse return null;
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
}

// 根据防火墙后端和恢复窗口返回目标机所需的前置命令。
fn firewallRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    if (!ctx.options.firewall_reload) return &.{};
    const action_subject = apply_actions.subject(action);
    const backend = firewall_backend.inferFromPath(action_subject) catch return &.{ "grep", "true" };
    const recovery_enabled = ctx.options.firewall_recovery_window_seconds > 0;
    return switch (backend) {
        .ufw => if (recovery_enabled)
            &.{ "grep", "ufw", "chmod", "systemd-run", "/bin/sh", "true", "systemctl", "rm" }
        else
            &.{ "grep", "ufw", "true" },
        .firewalld => if (recovery_enabled)
            &.{ "grep", "firewall-offline-cmd", "firewall-cmd", "chmod", "systemd-run", "/bin/sh", "true", "systemctl", "rm" }
        else
            &.{ "grep", "firewall-offline-cmd", "firewall-cmd", "true" },
        .nftables => if (recovery_enabled)
            &.{ "grep", "nft", "chmod", "systemd-run", "/bin/sh", "true", "systemctl", "rm" }
        else
            &.{ "grep", "nft", "true" },
        .iptables => if (recovery_enabled)
            &.{ "grep", "iptables-restore", "chmod", "systemd-run", "/bin/sh", "true", "systemctl", "rm" }
        else
            &.{ "grep", "iptables-restore", "true" },
    };
}

// 验证文件型 action 的目标路径；递归数据/项目默认逐项比对内容，单文件在有源主机时比对 SHA-256。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    const action_subject = apply_actions.subject(action);
    if (action_subject.len == 0) return error.MissingApplySubject;
    const exists = try @import("../../remote/exec.zig").pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, action_subject, ctx.execution);
    if (!exists) return error.VerifyTargetMissing;
    if (shouldVerifyRecursiveManifest(action, ctx.transfer_manifest_verify)) {
        if (ctx.transfer_manifest_max_entries == 0) return error.InvalidManifestEntryLimit;
        var source_manifest = try buildSourceManifest(
            ctx.io,
            ctx.allocator,
            ctx.source_host,
            action_subject,
            ctx.transfer_manifest_max_entries,
            ctx.execution,
        );
        defer source_manifest.deinit(ctx.allocator);
        try manifest_verify.ensureCompleteContent(source_manifest);

        var target_manifest = try remote_manifest.buildRemoteWithOptions(
            ctx.io,
            ctx.allocator,
            ctx.target_host,
            action_subject,
            ctx.transfer_manifest_max_entries,
            ctx.execution,
        );
        defer target_manifest.deinit(ctx.allocator);
        try manifest_verify.ensureCompleteContent(target_manifest);

        const report = try manifest_verify.verify(ctx.allocator, source_manifest, target_manifest);
        if (!report.valid) {
            try ctx.stderr.print("  verify {s}: manifest mismatch missing={d} changed={d} extra={d} source_truncated={} target_truncated={}\n", .{
                action.id,
                report.missing,
                report.changed,
                report.extra,
                report.expected_truncated,
                report.actual_truncated,
            });
            return error.VerifyManifestMismatch;
        }
        try ctx.stdout.print("  verify {s}: content manifest matched entries={d} bytes={d}\n", .{
            action.id,
            report.checked,
            source_manifest.total_bytes,
        });
        return .{ .ok = true, .message = "content manifest matched" };
    }
    if (shouldVerifyChecksum(action)) {
        if (ctx.source_host) |source_host| {
            const source_hash = try remote_manifest.sha256FileWithOptions(ctx.io, ctx.allocator, source_host, action_subject, ctx.execution);
            const target_hash = try remote_manifest.sha256FileWithOptions(ctx.io, ctx.allocator, ctx.target_host, action_subject, ctx.execution);
            if (!std.mem.eql(u8, &source_hash, &target_hash)) return error.VerifyChecksumMismatch;
            try ctx.stdout.print("  verify {s}: checksum matched {s}\n", .{ action.id, action_subject });
            return .{ .ok = true, .message = "checksum matched" };
        }
    }
    try ctx.stdout.print("  verify {s}: target exists {s}\n", .{ action.id, action_subject });
    return .{ .ok = true };
}

fn shouldVerifyRecursiveManifest(action: plan.Action, enabled: bool) bool {
    if (!enabled) return false;
    return action.action_type == .copy_data_path or action.action_type == .copy_project_path;
}

// 判断文件型 action 是否应做 SHA-256 校验。
fn shouldVerifyChecksum(action: plan.Action) bool {
    if (action.recursive) return false;
    return switch (action.action_type) {
        .write_file,
        .install_cron_entry,
        .add_authorized_key,
        .install_systemd_unit,
        .copy_home_config,
        .apply_firewall_config,
        => true,
        else => false,
    };
}

test "transfer verifier checksum eligibility is single-file only" {
    try std.testing.expect(shouldVerifyChecksum(.{
        .id = "configs/write//etc/hosts",
        .module = .configs,
        .action_type = .write_file,
        .subject = "/etc/hosts",
        .description = "copy hosts",
        .risk = .medium,
        .requires_confirmation = false,
    }));
    try std.testing.expect(!shouldVerifyChecksum(.{
        .id = "projects/copy//srv/app",
        .module = .projects,
        .action_type = .copy_project_path,
        .subject = "/srv/app",
        .description = "copy project",
        .risk = .high,
        .requires_confirmation = true,
        .recursive = true,
    }));
}

test "recursive data and project copies default to content manifest verification" {
    try std.testing.expect(shouldVerifyRecursiveManifest(.{
        .id = "appdata/copy//srv/data",
        .module = .appdata,
        .action_type = .copy_data_path,
        .subject = "/srv/data",
        .description = "copy data",
        .risk = .high,
        .requires_confirmation = true,
    }, true));
    try std.testing.expect(shouldVerifyRecursiveManifest(.{
        .id = "projects/copy//srv/app",
        .module = .projects,
        .action_type = .copy_project_path,
        .subject = "/srv/app",
        .description = "copy project",
        .risk = .high,
        .requires_confirmation = true,
    }, true));
    try std.testing.expect(!shouldVerifyRecursiveManifest(.{
        .id = "appdata/copy//srv/data",
        .module = .appdata,
        .action_type = .copy_data_path,
        .subject = "/srv/data",
        .description = "copy data",
        .risk = .high,
        .requires_confirmation = true,
    }, false));
}

test "transfer preflight parses du and df output" {
    try std.testing.expectEqual(@as(u64, 4096), parseDuBytes("4096\t/srv/app\n").?);
    try std.testing.expectEqual(@as(u64, 5368709120), parseDfAvailable(
        \\Filesystem     1B-blocks       Used  Available Capacity Mounted on
        \\/dev/vda1    10737418240 5368709120 5368709120      50% /srv
    ).?);
    try std.testing.expectEqual(@as(usize, 101), inodeProbeLimit(100));
    try std.testing.expectEqual(@as(usize, max_inode_probe_entries), inodeProbeLimit(std.math.maxInt(u64)));
}
