const std = @import("std");
const audit_log = @import("../audit/log.zig");
const audit_operator = @import("../audit/operator.zig");
const audit_sink = @import("../audit/sink.zig");
const apply_audit = @import("apply_audit.zig");
const apply_cli_options = @import("apply_options.zig");
const apply_dry_run = @import("apply_dry_run.zig");
const apply_policy = @import("apply_policy.zig");
const approval_receipt_cli = @import("approval_receipt.zig");
const host_authz_cli = @import("host_authz.zig");
const apply_backup = @import("../apply/backup.zig");
const apply_executor = @import("../apply/executor.zig");
const plan_filter = @import("../plan/filter.zig");
const plan_schema = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");
const manifest_hash = @import("../manifest/hash.zig");
const remote_planner = @import("../remote/planner.zig");
const fs_util = @import("../util/fs.zig");
const summary_util = @import("../util/summary.zig");

// 预览或执行迁移计划；真实远程修改必须显式使用 --approve。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var options = try apply_cli_options.parse(allocator, args);
    defer options.deinit(allocator);

    const file_path = options.plan_path orelse return error.MissingPlanPath;
    const plan_bytes = try fs_util.readFileAlloc(io, allocator, file_path, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const plan_hash = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_hash);

    const parsed = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const report = plan_validator.validate(parsed.value);
    try summary_util.writePlanValidationSummary(writer, report);
    if (!report.valid) return error.InvalidMigrationPlan;

    var policy_hash: ?[]const u8 = null;
    defer if (policy_hash) |value| allocator.free(value);

    if (options.dry_run) try apply_policy.evaluateDryRun(io, allocator, parsed.value, plan_hash, options.policy_path, writer);

    const selected_action_count = plan_filter.countSelectedActions(parsed.value.actions, options.filter);
    if (!options.filter.isEmpty()) try writer.print("Selected by filters: {d}\n", .{selected_action_count});

    if (options.dry_run) {
        try apply_dry_run.write(writer, parsed.value, options.filter, selected_action_count);
        return;
    }

    if (selected_action_count == 0) {
        try writer.writeAll("\nNo selected actions to apply.\n");
        return;
    }

    const apply_host = options.host orelse return error.MissingRemoteHost;
    try remote_planner.validateHost(apply_host);
    if (options.source_host) |value| try remote_planner.validateHost(value);
    const audit_operator_name = options.operator orelse audit_operator.detectFromProcessEnv();

    try host_authz_cli.validateOptional(io, allocator, options.host_authz_path, audit_operator_name, apply_host, writer);

    try approval_receipt_cli.validateOptional(io, allocator, options.approval_receipt_path, options.approval_receipt_key_env, .{
        .ticket = options.approval_ticket,
        .operator = audit_operator_name,
        .host = apply_host,
        .plan_hash = plan_hash,
        .purpose = "apply",
        .now = std.Io.Timestamp.now(io, .real).toSeconds(),
    });

    policy_hash = try apply_policy.evaluateApproved(io, allocator, parsed.value, plan_hash, options.policy_path, apply_host, options.approval_ticket, audit_operator_name, writer);

    const backup_root = try std.fmt.allocPrint(allocator, "/var/lib/hostlift/backups/{d}", .{parsed.value.created_at});
    defer allocator.free(backup_root);
    const rollback_manifest_path = try std.fmt.allocPrint(allocator, "/tmp/hostlift-rollback-{d}.jsonl", .{parsed.value.created_at});
    defer allocator.free(rollback_manifest_path);
    var manifest_file = try std.Io.Dir.cwd().createFile(io, rollback_manifest_path, .{ .truncate = true });
    defer manifest_file.close(io);
    var manifest_buffer: [4096]u8 = undefined;
    var manifest_writer = manifest_file.writer(io, &manifest_buffer);

    var audit_buffer: [4096]u8 = undefined;
    var audit_mirror_buffer: [4096]u8 = undefined;
    var sink_result = try audit_sink.openSinkWithMirror(io, allocator, options.audit_log_output_path, options.audit_sink_target, options.audit_mirror_log_path, parsed.value.created_at, &audit_buffer, &audit_mirror_buffer);
    defer sink_result.deinit(allocator);
    const audit_sink_label = sink_result.label;
    const credential_source = try audit_log.credentialSourceForOptions(
        options.apply_options.execution.ssh_identity_file,
        options.apply_options.execution.credential_provider,
    );
    const audit_ctx = apply_audit.ActionAuditContext{
        .allocator = allocator,
        .io = io,
        .operator = audit_operator_name,
        .host = apply_host,
        .plan_created_at = parsed.value.created_at,
        .plan_hash = plan_hash,
        .policy_hash = policy_hash,
        .approval_ticket = options.approval_ticket,
        .credential_source = credential_source,
        .rollback_manifest_path = rollback_manifest_path,
    };

    try writer.print("\nRollback manifest: {s}\nAudit sink: {s}\nRemote backup root: {s}\n", .{ rollback_manifest_path, audit_sink_label, backup_root });
    if (options.audit_mirror_log_path) |path| try writer.print("Audit mirror log: {s}\n", .{path});
    try writer.writeAll("\nApplying supported actions:\n");
    for (parsed.value.actions) |action| {
        if (!options.filter.matches(action)) continue;
        try apply_audit.writeAction(&sink_result.sink, audit_ctx, action, .started, "started");
        apply_backup.prepareRemoteRollbackWithOptions(
            io,
            allocator,
            action,
            apply_host,
            backup_root,
            &manifest_writer.interface,
            writer,
            writer,
            parsed.value.created_at,
            options.apply_options.execution,
        ) catch |err| {
            try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
            return err;
        };
        apply_executor.applyAction(io, allocator, parsed.value, action, options.source_host, apply_host, options.apply_options, writer, writer) catch |err| {
            try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
            return err;
        };
        try apply_audit.writeAction(&sink_result.sink, audit_ctx, action, .succeeded, "succeeded");
    }
    try manifest_writer.flush();
    try sink_result.sink.flush();
    if (sink_result.sink.tailHash()) |tail_hash| try writer.print("Audit tail hash: {s}\n", .{tail_hash});
}
