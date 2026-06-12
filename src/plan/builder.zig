const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");
const compatibility = @import("compatibility.zig");
const hash = @import("hash.zig");
const rules = @import("rules.zig");

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
