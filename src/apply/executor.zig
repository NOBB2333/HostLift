const std = @import("std");
const module_registry = @import("../modules/registry.zig");
const plan_filter = @import("../plan/filter.zig");
const plan_schema = @import("../plan/schema.zig");
const action_compatibility = @import("../plan/action_compatibility.zig");
const preflight = @import("preflight.zig");

pub const Options = module_registry.ApplyOptions;

// 在任何远程副作用前验证全部所选 action 都有可执行模块 handler；人工步骤必须先被过滤掉。
pub fn ensureSelectedActionsSupported(actions: []const plan_schema.Action, filter: plan_filter.ActionFilter) !void {
    for (actions) |action| {
        if (!filter.matches(action)) continue;
        _ = try module_registry.ensureApplySupported(action);
    }
}

// 在任何远程调用或本地执行证据创建前，重新校验全部所选 action 的目标兼容要求。
pub fn ensureSelectedActionsCompatible(migration_plan: plan_schema.MigrationPlan, filter: plan_filter.ActionFilter) !void {
    for (migration_plan.actions) |action| {
        if (!filter.matches(action)) continue;
        try action_compatibility.ensureAllowed(action, migration_plan.compatibility);
    }
}

// 在任何备份或 mutation 前，对全部所选 action 执行通用依赖和模块专属只读 preflight。
pub fn preflightSelectedActions(
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    filter: plan_filter.ActionFilter,
    completed_action_ids: []const []const u8,
    source_host: ?[]const u8,
    target_host: []const u8,
    options: Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    for (migration_plan.actions) |action| {
        if (!filter.matches(action)) continue;
        if (containsActionId(completed_action_ids, action.id)) continue;
        try runActionPreflight(io, allocator, migration_plan, action, source_host, target_host, options, stdout, stderr);
    }
}

fn containsActionId(action_ids: []const []const u8, action_id: []const u8) bool {
    for (action_ids) |value| {
        if (std.mem.eql(u8, value, action_id)) return true;
    }
    return false;
}

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
    try applyActionMutation(io, allocator, migration_plan, action, source_host, host, options, stdout, stderr);
    try verifyAction(io, allocator, migration_plan, action, source_host, host, options, stdout, stderr);
}

// 执行单个 action 的远程 mutation；调用方必须在随后记录新增路径回滚证据并调用 verifyAction。
pub fn applyActionMutation(
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
    try action_compatibility.ensureAllowed(action, migration_plan.compatibility);
    try runActionPreflight(io, allocator, migration_plan, action, source_host, host, options, stdout, stderr);
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
}

// 验证单个 action 的执行结果；任何不匹配都向上传播，调用方不得把该 action 标记成功。
pub fn verifyAction(
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
    try action_compatibility.ensureAllowed(action, migration_plan.compatibility);
    const module_handler = module_registry.findForAction(action).?;
    if (module_handler.verify) |verify| {
        const result = try verify(.{
            .io = io,
            .allocator = allocator,
            .migration_plan = migration_plan,
            .source_host = source_host,
            .target_host = host,
            .execution = options.execution,
            .transfer_manifest_verify = options.transfer_manifest_verify,
            .transfer_manifest_max_entries = options.transfer_manifest_max_entries,
            .stdout = stdout,
            .stderr = stderr,
        }, action);
        if (!result.ok) return error.VerifyFailed;
    } else {
        try stdout.print("  verify {s}: skipped (no module verifier)\n", .{action.id});
    }
}

fn runActionPreflight(
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    action: plan_schema.Action,
    source_host: ?[]const u8,
    target_host: []const u8,
    options: Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    try preflight.runActionCheck(io, allocator, migration_plan, target_host, action, options);
    const module_handler = module_registry.findForAction(action) orelse return error.UnsupportedApplyModule;
    if (module_handler.preflight) |module_preflight| {
        try module_preflight(.{
            .io = io,
            .allocator = allocator,
            .migration_plan = migration_plan,
            .source_host = source_host,
            .target_host = target_host,
            .options = options,
            .stdout = stdout,
            .stderr = stderr,
        }, action);
    }
}

test "selected action support validation rejects mixed manual plan before apply" {
    const actions = [_]plan_schema.Action{
        .{
            .id = "packages/install/nginx",
            .module = .packages,
            .action_type = .install_package,
            .subject = "nginx",
            .description = "Install package",
            .risk = .low,
            .requires_confirmation = false,
        },
        .{
            .id = "packages/review-held/nginx",
            .module = .packages,
            .action_type = .manual_step,
            .subject = "nginx",
            .description = "Review held package",
            .risk = .high,
            .requires_confirmation = true,
        },
    };

    try std.testing.expectError(
        error.UnsupportedApplyAction,
        ensureSelectedActionsSupported(&actions, .empty),
    );

    var filter: plan_filter.ActionFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendActionPattern(std.testing.allocator, .exclude, "packages/review-held/");
    try ensureSelectedActionsSupported(&actions, filter);
}

test "selected action compatibility validation rejects unsafe action and permits portable filter" {
    const actions = [_]plan_schema.Action{
        .{
            .id = "projects/copy//srv/app",
            .module = .projects,
            .action_type = .copy_project_path,
            .description = "Copy project",
            .risk = .medium,
            .requires_confirmation = true,
        },
        .{
            .id = "resources/copy//opt/tool",
            .module = .resources,
            .action_type = .copy_data_path,
            .description = "Copy install root",
            .risk = .high,
            .requires_confirmation = true,
        },
    };
    const migration_plan = plan_schema.MigrationPlan{
        .schema_version = plan_schema.schema_version_v2,
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{
            .compatible = false,
            .same_distro = true,
            .same_version = true,
            .same_package_manager = true,
            .same_arch = false,
            .reason = "architecture mismatch",
        },
        .actions = @constCast(&actions),
        .created_at = 0,
    };

    try std.testing.expectError(error.ActionCompatibilityMismatch, ensureSelectedActionsCompatible(migration_plan, .empty));

    var filter: plan_filter.ActionFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendActionPattern(std.testing.allocator, .include, "projects/copy/");
    try ensureSelectedActionsCompatible(migration_plan, filter);
}
