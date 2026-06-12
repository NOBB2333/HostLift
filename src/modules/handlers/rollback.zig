const handler = @import("../handler.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const path_util = @import("../../util/paths.zig");

// 执行文件型 rollback；文件用 cp -a，目录用 rsync -a --delete。
pub fn restoreFileBackup(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
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
