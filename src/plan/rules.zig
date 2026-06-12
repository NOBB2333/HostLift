const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");
const registry = @import("../modules/registry.zig");

// 追加所有兼容主机之间可自动规划的迁移动作。
pub fn appendAll(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ModuleInventory,
    target: inventory.ModuleInventory,
) !void {
    try registry.appendPlanActions(allocator, actions, source, target);
}
