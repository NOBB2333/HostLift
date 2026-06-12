const std = @import("std");
const plan = @import("../../plan/schema.zig");
const handler = @import("../handler.zig");

const apply_actions = @import("../../apply/actions.zig");
const apply_permissions = @import("../../apply/permissions.zig");
const firewall_backend = @import("../../firewall/backend.zig");
const firewall_reload = @import("../../firewall/reload.zig");
const remote_planner = @import("../../remote/planner.zig");
const remote_manifest = @import("../../transport/manifest.zig");
const transfer_command = @import("../../transfer/command.zig");

// 声明文件型 action 在目标机器执行前需要具备的入口命令。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    return switch (action.action_type) {
        .add_authorized_key => &.{ "chmod", "chown" },
        .copy_home_config => &.{ "mkdir", "chown", "chmod" },
        .apply_firewall_config => firewallRequirements(ctx, action),
        else => &.{},
    };
}

// 执行文件型迁移动作，统一走 transfer plan、权限修复和可选防火墙 reload。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    const action_subject = apply_actions.subject(action);
    if (action_subject.len == 0) return error.MissingApplySubject;
    const recursive = action.action_type == .copy_data_path or
        action.action_type == .copy_project_path or
        action.action_type == .apply_firewall_config or
        action.recursive;
    const transfer_plan = try remote_planner.buildTransferPlanAdvancedWithLimits(
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

// 验证文件型 action 的目标路径存在；单文件且有源主机时比对 SHA-256。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    const action_subject = apply_actions.subject(action);
    if (action_subject.len == 0) return error.MissingApplySubject;
    const exists = try @import("../../remote/exec.zig").pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, action_subject, ctx.execution);
    if (!exists) return error.VerifyTargetMissing;
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
