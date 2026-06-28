const handler = @import("../handler.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const path_util = @import("../../util/paths.zig");
const std = @import("std");

// 执行文件型 rollback；文件用 cp -a，目录用 rsync -a --delete。
pub fn restoreFileBackup(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    if (std.mem.eql(u8, entry.action_type, "delete_created_path")) {
        const expected = parseCreatedPathBaseline(entry.subject) orelse return error.RollbackBaselineUnavailable;
        const current = try remoteCreatedPathBaseline(ctx, entry.original_path);
        if (!baselineMatches(expected, current)) return error.RollbackCreatedPathChanged;
        try ctx.stdout.print(
            "  - rollback {s}: delete entire HostLift-created path {s}; baseline={d}B files={d} mtime={d}\n",
            .{ entry.action_id, entry.original_path, expected.bytes, expected.file_count, expected.mtime_unix },
        );
        var rm_argv = [_][]const u8{ "rm", "-rf", "--", entry.original_path };
        const rm_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, rm_argv[0..], ctx.execution);
        try remote_exec.executePlan(ctx.io, ctx.allocator, rm_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }
    if (!try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, entry.backup_path, ctx.execution)) return error.RollbackBackupMissing;
    try ctx.stdout.print("  - rollback {s}: {s} -> {s}\n", .{ entry.action_id, entry.backup_path, entry.original_path });

    if (try remote_exec.pathIsDirectoryWithOptions(ctx.io, ctx.allocator, ctx.target_host, entry.backup_path, ctx.execution)) {
        var mkdir_argv = [_][]const u8{ "mkdir", "-p", entry.original_path };
        const mkdir_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, mkdir_argv[0..], ctx.execution);
        try remote_exec.executePlan(ctx.io, ctx.allocator, mkdir_plan, ctx.stdout, ctx.stderr);

        const backup_source = try path_util.trailingSlashAlloc(ctx.allocator, entry.backup_path);
        defer ctx.allocator.free(backup_source);
        const original_target = try path_util.trailingSlashAlloc(ctx.allocator, entry.original_path);
        defer ctx.allocator.free(original_target);
        var rsync_argv = [_][]const u8{ "rsync", "-a", "--delete", backup_source, original_target };
        const rsync_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, rsync_argv[0..], ctx.execution);
        try remote_exec.executePlan(ctx.io, ctx.allocator, rsync_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }

    const original_parent = try path_util.parentDirAlloc(ctx.allocator, entry.original_path);
    defer ctx.allocator.free(original_parent);
    var mkdir_argv = [_][]const u8{ "mkdir", "-p", original_parent };
    const mkdir_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, mkdir_argv[0..], ctx.execution);
    try remote_exec.executePlan(ctx.io, ctx.allocator, mkdir_plan, ctx.stdout, ctx.stderr);

    var cp_argv = [_][]const u8{ "cp", "-a", entry.backup_path, entry.original_path };
    const cp_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, cp_argv[0..], ctx.execution);
    try remote_exec.executePlan(ctx.io, ctx.allocator, cp_plan, ctx.stdout, ctx.stderr);
    return .{ .restored = true };
}

const CreatedPathBaseline = struct {
    bytes: u64,
    file_count: u64,
    mtime_unix: u64,
};

fn remoteCreatedPathBaseline(ctx: handler.RollbackContext, path: []const u8) !CreatedPathBaseline {
    return .{
        .bytes = try remoteApparentBytes(ctx, path),
        .file_count = try remoteEntryCount(ctx, path),
        .mtime_unix = try remoteMtimeUnix(ctx, path),
    };
}

fn remoteApparentBytes(ctx: handler.RollbackContext, path: []const u8) !u64 {
    var du_bytes_argv = [_][]const u8{ "du", "-sb", path };
    if (remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, du_bytes_argv[0..], ctx.execution, 16 * 1024)) |output| {
        defer ctx.allocator.free(output);
        return parseDuBytes(output) orelse error.RollbackBaselineUnavailable;
    } else |_| {}
    var du_kib_argv = [_][]const u8{ "du", "-sk", path };
    const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, du_kib_argv[0..], ctx.execution, 16 * 1024);
    defer ctx.allocator.free(output);
    return (parseDuBytes(output) orelse return error.RollbackBaselineUnavailable) * 1024;
}

const max_rollback_baseline_entries: usize = 64 * 1024 * 1024;

fn remoteEntryCount(ctx: handler.RollbackContext, path: []const u8) !u64 {
    var find_argv = [_][]const u8{ "find", path, "-xdev", "-printf", "." };
    const output = remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, find_argv[0..], ctx.execution, max_rollback_baseline_entries) catch |err| switch (err) {
        error.StreamTooLong => return error.RollbackBaselineUnavailable,
        else => return err,
    };
    defer ctx.allocator.free(output);
    return @intCast(output.len);
}

fn remoteMtimeUnix(ctx: handler.RollbackContext, path: []const u8) !u64 {
    var stat_argv = [_][]const u8{ "stat", "-c", "%Y", path };
    const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, stat_argv[0..], ctx.execution, 16 * 1024);
    defer ctx.allocator.free(output);
    return parseFirstU64(output) orelse error.RollbackBaselineUnavailable;
}

fn parseCreatedPathBaseline(value: []const u8) ?CreatedPathBaseline {
    if (!std.mem.startsWith(u8, value, "stat:v1:")) return null;
    var fields = std.mem.splitScalar(u8, value["stat:v1:".len..], ':');
    const baseline = CreatedPathBaseline{
        .bytes = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null,
        .file_count = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null,
        .mtime_unix = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null,
    };
    if (fields.next() != null) return null;
    return baseline;
}

fn baselineMatches(expected: CreatedPathBaseline, current: CreatedPathBaseline) bool {
    return expected.bytes == current.bytes and
        expected.file_count == current.file_count and
        expected.mtime_unix == current.mtime_unix;
}

fn parseDuBytes(output: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, output, " \t\r\n");
    return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
}

fn parseFirstU64(output: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, output, " \t\r\n");
    return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
}

test "rollback delete-created baseline parser accepts current format" {
    const baseline = parseCreatedPathBaseline("stat:v1:4096:12:1710000000").?;
    try std.testing.expectEqual(@as(u64, 4096), baseline.bytes);
    try std.testing.expectEqual(@as(u64, 12), baseline.file_count);
    try std.testing.expectEqual(@as(u64, 1710000000), baseline.mtime_unix);
    try std.testing.expectEqual(@as(u64, 4096), parseDuBytes("4096\t/srv/app\n").?);
    try std.testing.expectEqual(@as(u64, 1710000000), parseFirstU64("1710000000\n").?);
    try std.testing.expect(parseCreatedPathBaseline("missing") == null);
    try std.testing.expect(baselineMatches(baseline, baseline));
    try std.testing.expect(!baselineMatches(baseline, .{ .bytes = 4096, .file_count = 13, .mtime_unix = 1710000000 }));
}
