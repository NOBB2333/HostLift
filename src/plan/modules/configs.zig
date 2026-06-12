const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划已知系统配置路径复制动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ConfigInventory,
    target: inventory.ConfigInventory,
) !void {
    for (source.files) |file| {
        if (!file.present) continue;
        if (configPresent(target.files, file.path)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "configs/write",
            .name = file.path,
            .module = .configs,
            .action_type = .write_file,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Copy or merge selected configuration path",
        });
    }
}

// 判断目标清单中指定配置文件是否存在。
fn configPresent(files: []const inventory.ConfigFile, path: []const u8) bool {
    for (files) |file| {
        if (file.present and std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}
