const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");
const compatibility = @import("compatibility.zig");
const hash = @import("hash.zig");
const rules = @import("rules.zig");
const common = @import("modules/common.zig");

// 从源/目标 inventory 构建迁移计划；这里只生成动作，不执行任何修改。
pub fn build(
    allocator: std.mem.Allocator,
    source: inventory.Inventory,
    target: inventory.Inventory,
    created_at: i64,
) !plan.MigrationPlan {
    var actions: std.ArrayList(plan.Action) = .empty;
    errdefer {
        for (actions.items) |action| {
            allocator.free(action.id);
            allocator.free(action.description);
        }
        actions.deinit(allocator);
    }

    const compat = compatibility.check(source, target);
    if (compat.compatible) {
        try rules.appendAll(allocator, &actions, source.modules, target.modules);
    }
    try appendCriticalScanWarnings(allocator, &actions, "source", source.scan.warnings);
    try appendCriticalScanWarnings(allocator, &actions, "target", target.scan.warnings);

    return .{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = try hash.inventoryHash(allocator, source),
        .target_inventory_hash = try hash.inventoryHash(allocator, target),
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
