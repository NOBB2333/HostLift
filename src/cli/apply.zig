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
const apply_run_state = @import("../apply/run_state.zig");
const plan_filter = @import("../plan/filter.zig");
const plan_schema = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");
const manifest_hash = @import("../manifest/hash.zig");
const remote_planner = @import("../remote/planner.zig");
const rollback_manifest_schema = @import("../rollback/manifest.zig");
const fs_util = @import("../util/fs.zig");
const summary_util = @import("../util/summary.zig");

const RollbackManifestFile = struct {
    path: []u8,
    file: std.Io.File,

    fn deinit(self: *RollbackManifestFile, io: std.Io, allocator: std.mem.Allocator) void {
        self.file.unlock(io);
        self.file.close(io);
        allocator.free(self.path);
    }
};

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
        try apply_dry_run.write(writer, parsed.value, options.filter, selected_action_count, options.apply_options);
        return;
    }

    if (selected_action_count == 0) {
        try writer.writeAll("\nNo selected actions to apply.\n");
        return;
    }

    try apply_executor.ensureSelectedActionsSupported(parsed.value.actions, options.filter);
    try apply_executor.ensureSelectedActionsCompatible(parsed.value, options.filter);
    try plan_validator.validateSelection(parsed.value.actions, options.filter);
    if (options.resume_run_state_path == null) {
        try ensureRollbackManifestAvailable(io, options.rollback_manifest_path);
        try apply_run_state.ensureNewPathAvailable(io, options.run_state_path);
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

    const selection_hash = try apply_run_state.selectionHashAlloc(allocator, parsed.value.actions, options.filter);
    defer allocator.free(selection_hash);
    const run_expected = apply_run_state.Expected{
        .plan_hash = plan_hash,
        .host = apply_host,
        .selection_hash = selection_hash,
    };
    var run_buffer: [4096]u8 = undefined;
    var run_session: ?apply_run_state.Session = null;
    defer if (run_session) |*session| session.deinit();
    if (options.resume_run_state_path) |resume_path| {
        run_session = try apply_run_state.openForResume(
            io,
            allocator,
            resume_path,
            run_expected,
            parsed.value.actions,
            options.filter,
            &run_buffer,
        );
        if (options.rollback_manifest_path) |requested_manifest| {
            if (!std.mem.eql(u8, requested_manifest, run_session.?.rollback_manifest_path)) return error.RunStateRollbackManifestMismatch;
        }
    }

    var completed_action_ids_storage: ?[][]const u8 = null;
    defer if (completed_action_ids_storage) |ids| allocator.free(ids);
    if (run_session) |session| completed_action_ids_storage = try session.completedActionIdsAlloc(allocator);
    const completed_action_ids: []const []const u8 = if (completed_action_ids_storage) |ids| ids else &.{};

    try writer.writeAll("\nPreflighting selected actions:\n");
    try apply_executor.preflightSelectedActions(
        io,
        allocator,
        parsed.value,
        options.filter,
        completed_action_ids,
        options.source_host,
        apply_host,
        options.apply_options,
        writer,
        writer,
    );

    var rollback_manifest = if (run_session) |session|
        try openRollbackManifestForResume(io, allocator, session.rollback_manifest_path, apply_host, parsed.value.actions, options.filter)
    else
        try createRollbackManifestFile(io, allocator, options.rollback_manifest_path, parsed.value.created_at);
    defer rollback_manifest.deinit(io, allocator);
    const rollback_manifest_path = rollback_manifest.path;
    var manifest_buffer: [4096]u8 = undefined;
    var manifest_writer = rollback_manifest.file.writer(io, &manifest_buffer);
    const manifest_stat = try rollback_manifest.file.stat(io);
    try manifest_writer.seekTo(manifest_stat.size);

    if (run_session == null) {
        run_session = try apply_run_state.create(
            io,
            allocator,
            options.run_state_path,
            run_expected,
            rollback_manifest_path,
            std.Io.Timestamp.now(io, .real).toSeconds(),
            &run_buffer,
        );
    }
    const migration_run = &run_session.?;
    const backup_root = try std.fmt.allocPrint(allocator, "/var/lib/hostlift/backups/{d}-{s}", .{ parsed.value.created_at, migration_run.run_id });
    defer allocator.free(backup_root);

    try writer.print("\nMigration run: {s}\nRun state: {s}\nRollback manifest: {s}\nRemote backup root: {s}\n", .{ migration_run.run_id, migration_run.path, rollback_manifest_path, backup_root });

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

    try writer.print("Audit sink: {s}\n", .{audit_sink_label});
    if (options.audit_mirror_log_path) |path| try writer.print("Audit mirror log: {s}\n", .{path});
    try writer.writeAll("\nApplying supported actions:\n");
    for (parsed.value.actions) |action| {
        if (!options.filter.matches(action)) continue;
        if (migration_run.isCompleted(action.id)) {
            try writer.print("  - {s}: skipped (proven succeeded in run state)\n", .{action.id});
            try migration_run.appendAction(action.id, .skipped, null);
            continue;
        }
        for (plan_schema.dependencies(action)) |dependency_id| {
            if (!migration_run.isCompleted(dependency_id)) return error.ActionDependencyNotSatisfied;
        }
        try migration_run.appendAction(action.id, .started, null);
        try apply_audit.writeAction(&sink_result.sink, audit_ctx, action, .started, "started");
        if (migration_run.isRollbackPrepared(action.id)) {
            try writer.print("  rollback preparation {s}: reused from run state\n", .{action.id});
        } else {
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
                try migration_run.appendAction(action.id, .failed, @errorName(err));
                try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
                return err;
            };
            manifest_writer.flush() catch |err| {
                try migration_run.appendAction(action.id, .failed, @errorName(err));
                try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
                return err;
            };
            try migration_run.appendAction(action.id, .rollback_prepared, null);
        }
        apply_executor.applyActionMutation(io, allocator, parsed.value, action, options.source_host, apply_host, options.apply_options, writer, writer) catch |err| {
            if (action.action_type == .reinstall_download or action.action_type == .reinstall_execute) {
                _ = apply_backup.writeCreatedPathRollbackEntriesWithOptions(
                    io,
                    allocator,
                    action,
                    apply_host,
                    &manifest_writer.interface,
                    parsed.value.created_at,
                    options.apply_options.execution,
                ) catch |evidence_err| {
                    manifest_writer.flush() catch {};
                    try migration_run.appendAction(action.id, .failed, @errorName(evidence_err));
                    try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, evidence_err);
                    return evidence_err;
                };
                manifest_writer.flush() catch |evidence_err| {
                    try migration_run.appendAction(action.id, .failed, @errorName(evidence_err));
                    try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, evidence_err);
                    return evidence_err;
                };
            }
            try migration_run.appendAction(action.id, .failed, @errorName(err));
            try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
            return err;
        };
        _ = apply_backup.writeCreatedPathRollbackEntriesWithOptions(
            io,
            allocator,
            action,
            apply_host,
            &manifest_writer.interface,
            parsed.value.created_at,
            options.apply_options.execution,
        ) catch |err| {
            manifest_writer.flush() catch {};
            try migration_run.appendAction(action.id, .failed, @errorName(err));
            try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
            return err;
        };
        manifest_writer.flush() catch |err| {
            try migration_run.appendAction(action.id, .failed, @errorName(err));
            try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
            return err;
        };
        apply_executor.verifyAction(io, allocator, parsed.value, action, options.source_host, apply_host, options.apply_options, writer, writer) catch |err| {
            try migration_run.appendAction(action.id, .failed, @errorName(err));
            try apply_audit.writeFailureAndFlush(&sink_result.sink, audit_ctx, action, err);
            return err;
        };
        try migration_run.appendAction(action.id, .succeeded, null);
        try apply_audit.writeAction(&sink_result.sink, audit_ctx, action, .succeeded, "succeeded");
    }
    try manifest_writer.flush();
    try sink_result.sink.flush();
    if (sink_result.sink.tailHash()) |tail_hash| try writer.print("Audit tail hash: {s}\n", .{tail_hash});
}

fn createRollbackManifestFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    requested_path: ?[]const u8,
    plan_created_at: i64,
) !RollbackManifestFile {
    if (requested_path) |value| {
        const path = try allocator.dupe(u8, value);
        errdefer allocator.free(path);
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.RollbackManifestAlreadyExists,
            else => return err,
        };
        errdefer file.close(io);
        try file.lock(io, .exclusive);
        return .{ .path = path, .file = file };
    }

    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        var random_bytes: [8]u8 = undefined;
        try io.randomSecure(&random_bytes);
        const nonce = std.mem.readInt(u64, &random_bytes, .little);
        const path = try defaultRollbackManifestPath(allocator, plan_created_at, nonce);
        const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        errdefer file.close(io);
        try file.lock(io, .exclusive);
        return .{ .path = path, .file = file };
    }
    return error.RollbackManifestNameCollision;
}

fn openRollbackManifestForResume(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_value: []const u8,
    host: []const u8,
    actions: []const plan_schema.Action,
    filter: plan_filter.ActionFilter,
) !RollbackManifestFile {
    const path = try allocator.dupe(u8, path_value);
    errdefer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return error.RollbackManifestNotFound,
        else => return err,
    };
    errdefer file.close(io);
    try file.lock(io, .exclusive);
    errdefer file.unlock(io);

    var reader = file.readerStreaming(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.RollbackManifestTooLarge,
        else => return err,
    };
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(rollback_manifest_schema.Entry, allocator, line, .{ .ignore_unknown_fields = true }) catch return error.InvalidRollbackManifestEntry;
        defer parsed.deinit();
        try rollback_manifest_schema.validateEntry(parsed.value);
        if (!std.mem.eql(u8, parsed.value.host, host)) return error.RollbackManifestHostMismatch;
        if (!selectedActionExists(actions, filter, parsed.value.action_id)) return error.RollbackManifestActionMismatch;
    }
    return .{ .path = path, .file = file };
}

fn selectedActionExists(actions: []const plan_schema.Action, filter: plan_filter.ActionFilter, action_id: []const u8) bool {
    for (actions) |action| {
        if (filter.matches(action) and std.mem.eql(u8, action.id, action_id)) return true;
    }
    return false;
}

fn ensureRollbackManifestAvailable(io: std.Io, requested_path: ?[]const u8) !void {
    const path = requested_path orelse return;
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.RollbackManifestAlreadyExists;
}

fn defaultRollbackManifestPath(allocator: std.mem.Allocator, plan_created_at: i64, nonce: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/hostlift-rollback-{d}-{x}.jsonl", .{ plan_created_at, nonce });
}

test "explicit rollback manifest refuses to overwrite existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/rollback.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var first = try createRollbackManifestFile(std.testing.io, std.testing.allocator, path, 123);
    first.deinit(std.testing.io, std.testing.allocator);
    try std.testing.expectError(
        error.RollbackManifestAlreadyExists,
        createRollbackManifestFile(std.testing.io, std.testing.allocator, path, 123),
    );
}

test "explicit rollback manifest collision is detected before remote preflight" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/rollback.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    file.close(std.testing.io);
    try std.testing.expectError(
        error.RollbackManifestAlreadyExists,
        ensureRollbackManifestAvailable(std.testing.io, path),
    );
}

test "default rollback manifest path includes a per-run nonce" {
    const first = try defaultRollbackManifestPath(std.testing.allocator, 123, 0x1111);
    defer std.testing.allocator.free(first);
    const second = try defaultRollbackManifestPath(std.testing.allocator, 123, 0x2222);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("/tmp/hostlift-rollback-123-1111.jsonl", first);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}
