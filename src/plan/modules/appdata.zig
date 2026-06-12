const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划应用/数据路径复制动作，并根据数据类型设置风险等级。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.AppDataInventory,
    target: inventory.AppDataInventory,
) !void {
    for (source.paths) |path| {
        if (!path.present) continue;
        if (dataPathPresent(target.paths, path.path)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "appdata/copy",
            .name = path.path,
            .module = .appdata,
            .action_type = .copy_data_path,
            .risk = if (path.kind == .database_data or path.kind == .docker_data) .high else .medium,
            .requires_confirmation = true,
            .description = "Copy selected app data path after size and service review",
        });
    }
}

// 判断目标清单中指定数据路径是否存在。
fn dataPathPresent(paths: []const inventory.DataPath, needle: []const u8) bool {
    for (paths) |path| {
        if (path.present and std.mem.eql(u8, path.path, needle)) return true;
    }
    return false;
}
