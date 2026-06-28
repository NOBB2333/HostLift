const std = @import("std");
const audit_log = @import("../audit/log.zig");
const audit_operator = @import("../audit/operator.zig");
const audit_sink = @import("../audit/sink.zig");
const action_policy = @import("../policy/action.zig");
const approval_receipt_cli = @import("../cli/approval_receipt.zig");
const host_authz_cli = @import("../cli/host_authz.zig");
const policy_source = @import("../policy/source.zig");
const dispatcher = @import("dispatcher.zig");
const manifest = @import("manifest.zig");
const rollback_options = @import("options.zig");
const remote_planner = @import("../remote/planner.zig");
const fs_util = @import("../util/fs.zig");

// 根据 rollback manifest 预览或恢复远程备份。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    const options = try rollback_options.parse(args);

    const file_path = options.manifest_path orelse return error.MissingRollbackManifest;
    const manifest_bytes = try fs_util.readInputFileAlloc(io, allocator, file_path, 16 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    const apply_host = if (options.approve) options.host orelse return error.MissingRemoteHost else options.host;
    if (apply_host) |value| try remote_planner.validateHost(value);
    const audit_operator_name = options.operator orelse audit_operator.detectFromProcessEnv();
    var policy_hash: ?[]const u8 = null;
    defer if (policy_hash) |value| allocator.free(value);

    if (options.approve) {
        try host_authz_cli.validateOptional(io, allocator, options.host_authz_path, audit_operator_name, apply_host.?, stdout);
        try approval_receipt_cli.validateOptional(io, allocator, options.approval_receipt_path, options.approval_receipt_key_env, .{
            .ticket = options.approval_ticket,
            .operator = audit_operator_name,
            .host = apply_host.?,
            .purpose = "rollback",
            .now = std.Io.Timestamp.now(io, .real).toSeconds(),
        });
        if (options.policy_path) |path| {
            var policy = try policy_source.readWithHash(io, allocator, path);
            defer policy.deinit(allocator);
            policy_hash = try allocator.dupe(u8, policy.hash);
            const policy_report = action_policy.evaluateExecution(policy.value(), apply_host.?, options.approval_ticket, audit_operator_name);
            try stdout.print(
                "Policy: valid={} approval_ticket_required={} approval_ticket_present={} approval_ticket_allowed={} approval_scope_allowed={} target_host_allowed={} operator_allowed={}\n",
                .{
                    policy_report.valid,
                    policy_report.requires_approval_ticket,
                    policy_report.approval_ticket_present,
                    policy_report.approval_ticket_allowed,
                    policy_report.approval_scope_allowed,
                    policy_report.target_host_allowed,
                    policy_report.operator_allowed,
                },
            );
            if (!policy_report.valid) return error.PolicyDeniedRollback;
        }
    }

    var audit_buffer: [4096]u8 = undefined;
    var audit_mirror_buffer: [4096]u8 = undefined;
    var sink_storage: ?audit_sink.OpenResult = null;
    const credential_source = try audit_log.credentialSourceForOptions(
        options.execution_options.ssh_identity_file,
        options.execution_options.credential_provider,
    );
    if (options.approve) {
        sink_storage = try audit_sink.openSinkWithMirror(
            io,
            allocator,
            options.audit_log_output_path,
            options.audit_sink_target,
            options.audit_mirror_log_path,
            std.Io.Timestamp.now(io, .real).toSeconds(),
            &audit_buffer,
            &audit_mirror_buffer,
        );
        try stdout.print("Audit sink: {s}\n", .{sink_storage.?.label});
        if (options.audit_mirror_log_path) |path| try stdout.print("Audit mirror log: {s}\n", .{path});
    }
    defer if (sink_storage) |*opened| opened.deinit(allocator);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(manifest.Entry, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try manifest.validateEntry(parsed.value);
        if (apply_host) |value| {
            if (!std.mem.eql(u8, value, parsed.value.host)) return error.RollbackManifestHostMismatch;
        }

        count += 1;
        if (options.dry_run) {
            try printDryRunEntry(stdout, parsed.value);
        } else {
            const sink = &sink_storage.?.sink;
            try sink.writeRollback(
                allocator,
                std.Io.Timestamp.now(io, .real).toSeconds(),
                .started,
                audit_operator_name,
                apply_host.?,
                parsed.value,
                policy_hash,
                options.approval_ticket,
                credential_source,
                file_path,
                "started",
            );
            dispatcher.executeEntry(io, allocator, parsed.value, apply_host.?, options.execution_options, stdout, stderr) catch |err| {
                try sink.writeRollback(
                    allocator,
                    std.Io.Timestamp.now(io, .real).toSeconds(),
                    .failed,
                    audit_operator_name,
                    apply_host.?,
                    parsed.value,
                    policy_hash,
                    options.approval_ticket,
                    credential_source,
                    file_path,
                    @errorName(err),
                );
                try sink.flush();
                return err;
            };
            try sink.writeRollback(
                allocator,
                std.Io.Timestamp.now(io, .real).toSeconds(),
                .succeeded,
                audit_operator_name,
                apply_host.?,
                parsed.value,
                policy_hash,
                options.approval_ticket,
                credential_source,
                file_path,
                "succeeded",
            );
        }
    }

    if (count == 0) {
        try stdout.writeAll("No rollback entries found.\n");
    } else if (options.dry_run) {
        try stdout.print("Rollback dry-run entries: {d}\n", .{count});
    } else {
        if (sink_storage) |*opened| try opened.sink.flush();
        try stdout.print("Rollback entries applied: {d}\n", .{count});
        if (sink_storage) |opened| {
            if (opened.sink.tailHash()) |tail_hash| try stdout.print("Audit tail hash: {s}\n", .{tail_hash});
        }
    }
}

// 输出单条 rollback entry 的 dry-run 预览格式。
fn printDryRunEntry(stdout: anytype, entry: manifest.Entry) !void {
    if (std.mem.eql(u8, entry.action_type, "delete_created_path")) {
        try stdout.print(
            "  - rollback {s}: delete entire HostLift-created path {s} on {s} if baseline still matches {s}; changed paths fail closed\n",
            .{ entry.action_id, entry.original_path, entry.host, entry.subject },
        );
        return;
    }
    if (entry.subject.len > 0 and entry.original_path.len == 0 and entry.backup_path.len == 0) {
        try stdout.print(
            "  - rollback {s}: {s} on {s}\n",
            .{ entry.action_id, entry.subject, entry.host },
        );
        return;
    }
    try stdout.print(
        "  - rollback {s}: {s} -> {s} on {s}\n",
        .{ entry.action_id, entry.backup_path, entry.original_path, entry.host },
    );
}
