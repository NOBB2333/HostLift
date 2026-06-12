const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划 XDG autostart 条目的文件型迁移动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_entries: []const inventory.XdgAutostartEntry,
    target_entries: []const inventory.XdgAutostartEntry,
) !void {
    for (source_entries) |entry| {
        if (hasEquivalentXdgAutostart(target_entries, entry)) continue;
        const review_name = try xdgAutostartReviewName(allocator, entry);
        defer allocator.free(review_name);
        try common.appendAction(allocator, actions, .{
            .id_prefix = "services/install-xdg-autostart",
            .name = review_name,
            .subject = entry.path,
            .module = .services,
            .action_type = if (entry.scope == .user) .copy_home_config else .write_file,
            .owner = entry.user,
            .risk = .high,
            .requires_confirmation = true,
            .description = "Install XDG autostart entry from source",
        });
    }
}

// 判断目标是否存在与源等价的 XDG autostart 条目。
fn hasEquivalentXdgAutostart(entries: []const inventory.XdgAutostartEntry, source: inventory.XdgAutostartEntry) bool {
    for (entries) |entry| {
        if (entry.scope != source.scope) continue;
        if (!optionalStringEqual(entry.user, source.user)) continue;
        if (!std.mem.eql(u8, entry.name, source.name)) continue;
        return true;
    }
    return false;
}

// 生成 XDG autostart 条目的审查名称，格式为 "user:name" 或 "system:name"。
fn xdgAutostartReviewName(allocator: std.mem.Allocator, entry: inventory.XdgAutostartEntry) ![]const u8 {
    if (entry.user) |user| return std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, entry.name });
    return std.fmt.allocPrint(allocator, "system:{s}", .{entry.name});
}

// 比较两个可选字符串是否相等，两者均为 null 视为相等。
fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}
