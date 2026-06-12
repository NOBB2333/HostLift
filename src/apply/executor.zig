const std = @import("std");
const module_registry = @import("../modules/registry.zig");
const plan_schema = @import("../plan/schema.zig");
const preflight = @import("preflight.zig");

pub const Options = module_registry.ApplyOptions;

// 将单个 plan action 映射为远程命令或 scp 传输，并在需要时修复权限/触发验证。
pub fn applyAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    action: plan_schema.Action,
    source_host: ?[]const u8,
    host: []const u8,
    options: Options,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = try module_registry.ensureApplySupported(action);
    try preflight.runActionCheck(io, allocator, migration_plan, host, action, options);
    const module_handler = module_registry.findForAction(action).?;
    const apply = module_handler.apply orelse return error.UnsupportedApplyAction;
    _ = try apply(.{
        .io = io,
        .allocator = allocator,
        .migration_plan = migration_plan,
        .source_host = source_host,
        .target_host = host,
        .options = options,
        .stdout = stdout,
        .stderr = stderr,
    }, action);
    if (module_handler.verify) |verify| {
        const result = try verify(.{
            .io = io,
            .allocator = allocator,
            .migration_plan = migration_plan,
            .source_host = source_host,
            .target_host = host,
            .execution = options.execution,
            .stdout = stdout,
            .stderr = stderr,
        }, action);
        if (!result.ok) return error.VerifyFailed;
    } else {
        try stdout.print("  verify {s}: skipped (no module verifier)\n", .{action.id});
    }
}
