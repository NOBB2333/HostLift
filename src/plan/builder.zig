const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");
const compatibility = @import("compatibility.zig");
const action_compatibility = @import("action_compatibility.zig");
const hash = @import("hash.zig");
const rules = @import("rules.zig");
const common = @import("modules/common.zig");
const dag = @import("dag.zig");
const postgresql_provider = @import("postgresql_provider.zig");
const reinstall_provider = @import("reinstall_provider.zig");
const reinstall_schema = @import("../reinstall/schema.zig");

pub const Options = struct {
    postgresql_auto: bool = false,
    postgresql_writers_stopped: bool = false,
    reinstall_recipes: ?reinstall_schema.RecipeSet = null,
};

// 从源/目标 inventory 构建迁移计划；这里只生成动作，不执行任何修改。
pub fn build(
    allocator: std.mem.Allocator,
    source: inventory.Inventory,
    target: inventory.Inventory,
    created_at: i64,
) !plan.MigrationPlan {
    return buildWithOptions(allocator, source, target, created_at, .{});
}

// 按显式 provider 选项构建迁移计划；高风险数据库动作只有在调用方确认一致性条件后才生成。
pub fn buildWithOptions(
    allocator: std.mem.Allocator,
    source: inventory.Inventory,
    target: inventory.Inventory,
    created_at: i64,
    options: Options,
) !plan.MigrationPlan {
    var actions: std.ArrayList(plan.Action) = .empty;
    errdefer {
        for (actions.items) |action| plan.deinitAction(allocator, action);
        actions.deinit(allocator);
    }
    const source_inventory_hash = try hash.inventoryHash(allocator, source);
    const target_inventory_hash = try hash.inventoryHash(allocator, target);
    const compat = compatibility.check(source, target);
    try rules.appendAll(allocator, &actions, source.modules, target.modules);
    try appendCriticalScanWarnings(allocator, &actions, "source", source.scan.warnings);
    try appendCriticalScanWarnings(allocator, &actions, "target", target.scan.warnings);
    if (options.postgresql_auto) {
        if (!options.postgresql_writers_stopped) return error.PostgresqlWritersStoppedAcknowledgementRequired;
        try postgresql_provider.enable(allocator, &actions, source_inventory_hash);
    } else if (options.postgresql_writers_stopped) {
        return error.PostgresqlAutoProviderRequired;
    }
    if (options.reinstall_recipes) |recipes| {
        try reinstall_provider.enable(allocator, &actions, recipes, source_inventory_hash, target);
    }
    try action_compatibility.replaceBlockedWithManualReviews(allocator, &actions, compat);
    try dag.enrich(allocator, actions.items);

    return .{
        .schema_version = plan.current_schema_version,
        .source_inventory_hash = source_inventory_hash,
        .target_inventory_hash = target_inventory_hash,
        .package_manager = target.package_manager.kind,
        .compatibility = .{
            .compatible = compat.compatible,
            .same_distro = compat.same_distro,
            .same_version = compat.same_version,
            .same_package_manager = compat.same_package_manager,
            .same_arch = compat.same_arch,
            .reason = try allocator.dupe(u8, compat.reason),
        },
        .actions = try actions.toOwnedSlice(allocator),
        .created_at = created_at,
    };
}

fn appendCriticalScanWarnings(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    scope: []const u8,
    warnings: []const []const u8,
) !void {
    for (warnings) |warning| {
        const module = criticalModuleFromWarning(warning) orelse continue;
        const module_name = moduleNameForId(module);
        const action_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scope, module_name });
        defer allocator.free(action_name);
        try common.appendAction(allocator, actions, .{
            .id_prefix = "scan-warning",
            .name = action_name,
            .subject = warning,
            .module = module,
            .action_type = .manual_step,
            .risk = .critical,
            .requires_confirmation = true,
            .description = "Critical scan failed; rescan or inspect manually before treating missing inventory as safe",
        });
    }
}

fn criticalModuleFromWarning(warning: []const u8) ?plan.ModuleName {
    const prefix = "scan module ";
    if (!std.mem.startsWith(u8, warning, prefix)) return null;
    const rest = warning[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const module_name = rest[0..end];
    if (std.mem.eql(u8, module_name, "users")) return .users;
    if (std.mem.eql(u8, module_name, "ssh")) return .ssh;
    if (std.mem.eql(u8, module_name, "sudoers")) return .sudoers;
    if (std.mem.eql(u8, module_name, "acl")) return .acl;
    if (std.mem.eql(u8, module_name, "storage")) return .storage;
    if (std.mem.eql(u8, module_name, "system_baseline")) return .system_baseline;
    if (std.mem.eql(u8, module_name, "resources")) return .resources;
    if (std.mem.eql(u8, module_name, "security_policy")) return .security_policy;
    return null;
}

fn moduleNameForId(module: plan.ModuleName) []const u8 {
    return switch (module) {
        .system_baseline => "system-baseline",
        .security_policy => "security-policy",
        else => @tagName(module),
    };
}
