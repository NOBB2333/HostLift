const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划缺失包安装和 hold/lock 审查动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.PackageInventory,
    target: inventory.PackageInventory,
) !void {
    for (source.explicit) |pkg| {
        if (common.containsString(target.explicit, pkg)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "packages/install",
            .name = pkg,
            .module = .packages,
            .action_type = .install_package,
            .risk = .low,
            .requires_confirmation = false,
            .description = "Install explicit package on target",
        });
    }

    for (source.held) |pkg| {
        if (common.containsString(target.held, pkg)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "packages/review-held",
            .name = pkg,
            .module = .packages,
            .action_type = .manual_step,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Review package hold or lock state",
        });
    }
}
