const std = @import("std");
const handler = @import("../handler.zig");
const plan = @import("../../plan/schema.zig");
const artifacts = @import("../../postgresql/artifacts.zig");
const postgresql_remote = @import("../../remote/postgresql.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const remote_preflight = @import("../../remote/preflight.zig");
const remote_schema = @import("../../remote/schema.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const transfer_command = @import("../../transfer/command.zig");
const remote_file = @import("../../transport/remote_probe.zig");
const validation = @import("../../security/validation.zig");

const min_postgresql_major: u64 = 10;
const artifact_capacity_floor: u64 = 64 * 1024 * 1024;

// 返回 PostgreSQL provider 在目标机需要的固定入口命令。
pub fn applyRequirements(_: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    if (!isAction(action.action_type)) return &.{};
    return &.{ "sudo", "env", "psql", "pg_dumpall", "install", "sha256sum", "stat", "id", "df", "chown", "chmod" };
}

// 在全部 mutation 前验证 root SSH、peer 认证、版本、停写、空目标、容量和 artifact 独占约束。
pub fn preflight(ctx: handler.ApplyPreflightContext, action: plan.Action) !void {
    try validateAction(action, ctx.migration_plan.source_inventory_hash);
    const source_host = ctx.source_host orelse return error.PostgresqlSourceHostRequired;
    try ensureRootHost(ctx, source_host);
    try ensureRootHost(ctx, ctx.target_host);
    try remote_preflight.runCheck(ctx.io, ctx.allocator, .{
        .host = source_host,
        .commands = applyRequirements(.{ .migration_plan = ctx.migration_plan, .options = ctx.options }, action),
    }, ctx.options.execution);
    try ensureCompatibleMajors(ctx, source_host);

    switch (action.action_type) {
        .postgresql_dump => {
            try ensureSourceQuiesced(ctx, source_host);
            const source_dump = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(source_dump);
            try ensureAbsent(ctx, source_host, source_dump);
            const bytes = try queryU64(ctx, source_host, .database_bytes);
            try ensureCapacity(ctx, source_host, "/var/lib", requiredCapacity(bytes));
        },
        .postgresql_target_baseline => {
            try ensureTargetEmpty(ctx);
            const baseline = try artifacts.targetBaselinePath(ctx.allocator, action.subject);
            defer ctx.allocator.free(baseline);
            try ensureAbsent(ctx, ctx.target_host, baseline);
        },
        .postgresql_transfer => {
            const target_dump = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(target_dump);
            try ensureAbsent(ctx, ctx.target_host, target_dump);
            const transfer_plan = try buildTransferPlan(ctx, target_dump, source_host);
            try remote_preflight.runTransferPreflight(ctx.io, ctx.allocator, transfer_plan, ctx.options.execution);
            const bytes = try queryU64(ctx, source_host, .database_bytes);
            try ensureCapacity(ctx, ctx.target_host, "/var/lib", requiredCapacity(bytes));
        },
        .postgresql_restore => {
            try ensureTargetEmpty(ctx);
            const bytes = try queryU64(ctx, source_host, .database_bytes);
            const data_dir = try queryTrimmed(ctx, ctx.target_host, .data_directory);
            defer ctx.allocator.free(data_dir);
            try validation.validatePath(data_dir);
            try ensureCapacity(ctx, ctx.target_host, data_dir, requiredCapacity(bytes));
        },
        .postgresql_verify => {},
        else => unreachable,
    }
}

// 执行固定 PostgreSQL provider 动作；restore 单次执行且不自动重放。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    try validateAction(action, ctx.migration_plan.source_inventory_hash);
    const source_host = ctx.source_host orelse return error.PostgresqlSourceHostRequired;
    switch (action.action_type) {
        .postgresql_dump => {
            const path = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            try createArtifactDirectory(ctx, source_host, action.subject);
            try createPrivateFile(ctx, source_host, path);
            var argv = [_][]const u8{ "sudo", "-n", "-u", "postgres", "env", "LC_ALL=C", "pg_dumpall", "--file", path };
            try execute(ctx, source_host, action.id, &argv);
            return .{ .changed = true };
        },
        .postgresql_target_baseline => {
            const path = try artifacts.targetBaselinePath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            try createArtifactDirectory(ctx, ctx.target_host, action.subject);
            try createPrivateFile(ctx, ctx.target_host, path);
            var argv = [_][]const u8{ "sudo", "-n", "-u", "postgres", "env", "LC_ALL=C", "pg_dumpall", "--file", path };
            try execute(ctx, ctx.target_host, action.id, &argv);
            return .{ .changed = true };
        },
        .postgresql_transfer => {
            const path = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            if (!try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, source_host, path, ctx.options.execution)) return error.PostgresqlSourceDumpMissing;
            const transfer_plan = try buildTransferPlan(ctx, path, source_host);
            try ctx.stdout.print("  - {s}: ", .{action.id});
            try transfer_command.executePlan(ctx.io, ctx.allocator, transfer_plan, ctx.stdout, ctx.stderr);
            var chown_argv = [_][]const u8{ "chown", "postgres:postgres", path };
            try execute(ctx, ctx.target_host, action.id, &chown_argv);
            var chmod_argv = [_][]const u8{ "chmod", "0600", path };
            try execute(ctx, ctx.target_host, action.id, &chmod_argv);
            return .{ .changed = true };
        },
        .postgresql_restore => {
            const path = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            if (!try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, path, ctx.options.execution)) return error.PostgresqlTargetDumpMissing;
            const result = try postgresql_remote.restoreCluster(ctx.io, ctx.allocator, ctx.target_host, path, ctx.options.execution);
            try ctx.stdout.print("  - {s}: PostgreSQL restore completed; allowed_bootstrap_conflicts={d}\n", .{ action.id, result.allowed_bootstrap_conflicts });
            return .{ .changed = true };
        },
        .postgresql_verify => return .{ .changed = false },
        else => unreachable,
    }
}

// 验证 dump/baseline 非空且可哈希、传输两端 SHA-256 一致，并比较恢复后的数据库与角色目录。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    try validateAction(action, ctx.migration_plan.source_inventory_hash);
    const source_host = ctx.source_host orelse return error.PostgresqlSourceHostRequired;
    switch (action.action_type) {
        .postgresql_dump => {
            const path = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            try verifyArtifact(ctx, source_host, path, action.id);
        },
        .postgresql_target_baseline => {
            const path = try artifacts.targetBaselinePath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            try verifyArtifact(ctx, ctx.target_host, path, action.id);
        },
        .postgresql_transfer => {
            const path = try artifacts.sourceDumpPath(ctx.allocator, action.subject);
            defer ctx.allocator.free(path);
            const source_hash = try remote_file.sha256FileWithOptions(ctx.io, ctx.allocator, source_host, path, ctx.execution);
            const target_hash = try remote_file.sha256FileWithOptions(ctx.io, ctx.allocator, ctx.target_host, path, ctx.execution);
            if (!std.mem.eql(u8, &source_hash, &target_hash)) return error.PostgresqlTransferChecksumMismatch;
            try ctx.stdout.print("  verify {s}: PostgreSQL dump SHA-256 matched\n", .{action.id});
        },
        .postgresql_restore => {
            const version = try queryTrimmedVerify(ctx, ctx.target_host, .server_version_num);
            defer ctx.allocator.free(version);
            try ctx.stdout.print("  verify {s}: target PostgreSQL accepted queries\n", .{action.id});
        },
        .postgresql_verify => {
            try compareCatalog(ctx, source_host, .database_catalog, "database", action.id);
            try compareCatalog(ctx, source_host, .role_catalog, "role", action.id);
        },
        else => unreachable,
    }
    return .{ .ok = true, .message = "PostgreSQL provider verification passed" };
}

// PostgreSQL restore 只能根据 baseline evidence 人工重建目标；拒绝伪装成自动完整回滚。
pub fn rollback(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    if (!std.mem.eql(u8, entry.action_type, "postgresql_manual_recovery")) return error.UnsupportedRollbackAction;
    try ctx.stderr.print("  - rollback {s}: manual PostgreSQL recovery required; baseline={s} digest={s}\n", .{ entry.action_id, entry.backup_path, entry.subject });
    return error.ManualRollbackRequired;
}

fn isAction(action_type: plan.ActionType) bool {
    return switch (action_type) {
        .postgresql_dump, .postgresql_target_baseline, .postgresql_transfer, .postgresql_restore, .postgresql_verify => true,
        else => false,
    };
}

fn validateAction(action: plan.Action, source_inventory_hash: [32]u8) !void {
    if (action.module != .appdata or !isAction(action.action_type)) return error.InvalidPostgresqlAction;
    try artifacts.validateRootForInventoryHash(action.subject, source_inventory_hash);
}

fn ensureRootHost(ctx: handler.ApplyPreflightContext, host: []const u8) !void {
    var argv = [_][]const u8{ "id", "-u" };
    const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, host, &argv, ctx.options.execution, 1024);
    defer ctx.allocator.free(output);
    if (!std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), "0")) return error.PostgresqlRootSshRequired;
}

fn ensureCompatibleMajors(ctx: handler.ApplyPreflightContext, source_host: []const u8) !void {
    const source_version = try queryU64(ctx, source_host, .server_version_num);
    const target_version = try queryU64(ctx, ctx.target_host, .server_version_num);
    const source_major = source_version / 10_000;
    const target_major = target_version / 10_000;
    if (source_major < min_postgresql_major or target_major < min_postgresql_major) return error.UnsupportedPostgresqlMajor;
    if (source_major != target_major) return error.PostgresqlMajorMismatch;
    if (try queryU64(ctx, source_host, .postgres_admin_count) != 1) return error.PostgresqlSourceAdminUnsupported;
}

fn ensureSourceQuiesced(ctx: handler.ApplyPreflightContext, source_host: []const u8) !void {
    if (try queryU64(ctx, source_host, .client_count) != 0) return error.PostgresqlSourceClientsConnected;
}

fn ensureTargetEmpty(ctx: handler.ApplyPreflightContext) !void {
    if (try queryU64(ctx, ctx.target_host, .custom_database_count) != 0) return error.PostgresqlTargetNotEmpty;
    if (try queryU64(ctx, ctx.target_host, .custom_role_count) != 0) return error.PostgresqlTargetNotEmpty;
}

fn queryU64(ctx: handler.ApplyPreflightContext, host: []const u8, query: postgresql_remote.Query) !u64 {
    const value = try queryTrimmed(ctx, host, query);
    defer ctx.allocator.free(value);
    return std.fmt.parseUnsigned(u64, value, 10) catch error.InvalidPostgresqlQueryOutput;
}

fn queryTrimmed(ctx: handler.ApplyPreflightContext, host: []const u8, query: postgresql_remote.Query) ![]u8 {
    const output = try postgresql_remote.queryOutput(ctx.io, ctx.allocator, host, query, ctx.options.execution, 1024 * 1024);
    defer ctx.allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPostgresqlQueryOutput;
    return ctx.allocator.dupe(u8, trimmed);
}

fn queryTrimmedVerify(ctx: handler.VerifyContext, host: []const u8, query: postgresql_remote.Query) ![]u8 {
    const output = try postgresql_remote.queryOutput(ctx.io, ctx.allocator, host, query, ctx.execution, 1024 * 1024);
    defer ctx.allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPostgresqlQueryOutput;
    return ctx.allocator.dupe(u8, trimmed);
}

fn ensureAbsent(ctx: handler.ApplyPreflightContext, host: []const u8, path: []const u8) !void {
    if (try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, host, path, ctx.options.execution)) return error.PostgresqlArtifactAlreadyExists;
}

fn requiredCapacity(database_bytes: u64) u64 {
    const doubled = std.math.mul(u64, database_bytes, 2) catch std.math.maxInt(u64);
    return @max(doubled, artifact_capacity_floor);
}

fn ensureCapacity(ctx: handler.ApplyPreflightContext, host: []const u8, path: []const u8, required: u64) !void {
    var argv = [_][]const u8{ "df", "-PB1", path };
    const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, host, &argv, ctx.options.execution, 16 * 1024);
    defer ctx.allocator.free(output);
    const available = parseDfAvailable(output) orelse return error.PostgresqlCapacityUnavailable;
    if (available <= required) return error.PostgresqlCapacityInsufficient;
}

fn parseDfAvailable(output: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next() orelse return null;
    var last: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) last = line;
    }
    var fields = std.mem.tokenizeAny(u8, last orelse return null, " \t");
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    return std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch null;
}

fn buildTransferPlan(ctx: anytype, path: []const u8, source_host: []const u8) !remote_schema.TransferPlan {
    return remote_planner.buildTransferPlanAdvancedWithLimits(
        ctx.target_host,
        source_host,
        path,
        path,
        true,
        false,
        ctx.options.transfer_transport,
        ctx.options.transfer_partial,
        ctx.options.transfer_resume,
        ctx.options.execution,
        ctx.options.transfer_bandwidth_limit_kbps,
    );
}

fn createArtifactDirectory(ctx: handler.ApplyContext, host: []const u8, root: []const u8) !void {
    var argv = [_][]const u8{ "install", "-d", "-m", "0700", "-o", "postgres", "-g", "postgres", root };
    try execute(ctx, host, "postgresql/artifact-directory", &argv);
}

fn createPrivateFile(ctx: handler.ApplyContext, host: []const u8, path: []const u8) !void {
    var argv = [_][]const u8{ "install", "-m", "0600", "-o", "postgres", "-g", "postgres", "/dev/null", path };
    try execute(ctx, host, "postgresql/private-artifact", &argv);
}

fn execute(ctx: handler.ApplyContext, host: []const u8, action_id: []const u8, argv: []const []const u8) !void {
    const command_plan = try remote_planner.buildCommandPlanWithOptions(host, argv, ctx.options.execution);
    try ctx.stdout.print("  - {s}: ", .{action_id});
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
}

fn verifyArtifact(ctx: handler.VerifyContext, host: []const u8, path: []const u8, action_id: []const u8) !void {
    const size = try remote_file.fileSize(ctx.io, ctx.allocator, host, path, ctx.execution);
    if (size == 0) return error.PostgresqlArtifactEmpty;
    const digest = try remote_file.sha256FileWithOptions(ctx.io, ctx.allocator, host, path, ctx.execution);
    const hex = std.fmt.bytesToHex(digest, .lower);
    try ctx.stdout.print("  verify {s}: artifact bytes={d} sha256={s}\n", .{ action_id, size, &hex });
}

fn compareCatalog(ctx: handler.VerifyContext, source_host: []const u8, query: postgresql_remote.Query, label: []const u8, action_id: []const u8) !void {
    const source = try queryTrimmedVerify(ctx, source_host, query);
    defer ctx.allocator.free(source);
    const target = try queryTrimmedVerify(ctx, ctx.target_host, query);
    defer ctx.allocator.free(target);
    if (!std.mem.eql(u8, source, target)) return error.PostgresqlCatalogMismatch;
    try ctx.stdout.print("  verify {s}: PostgreSQL {s} catalog matched\n", .{ action_id, label });
}

test "postgresql capacity parser reads POSIX df available bytes" {
    try std.testing.expectEqual(@as(u64, 999_999), parseDfAvailable(
        "Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/fake 1000000 1 999999 1% /\n",
    ).?);
    try std.testing.expectEqual(artifact_capacity_floor, requiredCapacity(1));
}
