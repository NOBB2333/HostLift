const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

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
        if (isMergeSensitiveConfig(file.path)) {
            try manual_common.appendManualStep(allocator, actions, .{
                .id_prefix = "configs/merge-review",
                .name = file.path,
                .subject = file.path,
                .module = .configs,
                .risk = .high,
                .description = "Review merge strategy before applying this configuration; target-specific defaults may need to be preserved",
            });
        }
        try common.appendAction(allocator, actions, .{
            .id_prefix = "configs/write",
            .name = file.path,
            .module = .configs,
            .action_type = .write_file,
            .risk = if (isMergeSensitiveConfig(file.path)) .high else .medium,
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

// 判断配置路径是否通常需要人工 diff/merge。
fn isMergeSensitiveConfig(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/etc/hosts")) return true;
    if (std.mem.eql(u8, path, "/etc/resolv.conf")) return true;
    if (std.mem.eql(u8, path, "/etc/nsswitch.conf")) return true;
    if (std.mem.startsWith(u8, path, "/etc/nginx/")) return true;
    if (std.mem.startsWith(u8, path, "/etc/ssh/")) return true;
    if (std.mem.startsWith(u8, path, "/etc/systemd/")) return true;
    if (std.mem.startsWith(u8, path, "/etc/NetworkManager/")) return true;
    return false;
}
