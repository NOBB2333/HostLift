const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");

// 规划 cron 来源复制/合并动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.CronInventory,
    target: inventory.CronInventory,
) !void {
    for (source.entries) |entry| {
        if (hasCronEntry(target.entries, entry)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "cron/install",
            .name = entry.source,
            .module = .cron,
            .action_type = .install_cron_entry,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Install or merge cron source after review",
        });
    }
}

// 判断目标清单中是否已有相同 cron 来源。
fn hasCronEntry(entries: []const inventory.CronEntry, needle: inventory.CronEntry) bool {
    for (entries) |entry| {
        const same_owner = if (entry.owner) |owner|
            if (needle.owner) |needle_owner| std.mem.eql(u8, owner, needle_owner) else false
        else
            needle.owner == null;
        if (same_owner and std.mem.eql(u8, entry.source, needle.source)) return true;
    }
    return false;
}
