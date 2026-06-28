const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划用户 home 配置复制动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.HomeConfigInventory,
    target: inventory.HomeConfigInventory,
) !void {
    for (source.configs) |config| {
        if (!config.present) continue;
        if (homeConfigPresent(target.configs, config.user, config.path)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "home-configs/copy",
            .name = config.path,
            .subject = config.path,
            .module = .home_configs,
            .action_type = .copy_home_config,
            .owner = config.user,
            .risk = if (config.kind == .ssh) .high else .medium,
            .requires_confirmation = true,
            .description = "Copy selected home configuration path and verify owner/group/mode after migration",
            .recursive = config.directory,
        });
    }
}

// 判断目标清单中指定用户 home 配置是否存在。
fn homeConfigPresent(configs: []const inventory.HomeConfig, user: []const u8, path: []const u8) bool {
    for (configs) |config| {
        if (config.present and std.mem.eql(u8, config.user, user) and std.mem.eql(u8, config.path, path)) return true;
    }
    return false;
}
