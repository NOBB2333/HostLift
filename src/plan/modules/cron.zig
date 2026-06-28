const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划 cron 来源复制/合并动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.CronInventory,
    target: inventory.CronInventory,
) !void {
    for (source.entries) |entry| {
        if (hasCronEntry(target.entries, entry)) continue;
        if (entry.kind == .anacron or entry.kind == .at_spool) {
            try manual_common.appendManualStep(allocator, actions, .{
                .id_prefix = if (entry.kind == .anacron) "cron/review-anacron" else "cron/review-at",
                .name = entry.source,
                .subject = entry.source,
                .module = .cron,
                .risk = .high,
                .description = if (entry.kind == .anacron)
                    "Review anacron job before migration; HostLift does not automatically replay periodic catch-up jobs"
                else
                    "Review one-shot at job spool before migration; HostLift does not replay scheduled one-time commands",
            });
            continue;
        }
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

test "cron plan reviews anacron and at spool instead of installing" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| {
            std.testing.allocator.free(action.id);
            std.testing.allocator.free(action.subject);
            std.testing.allocator.free(action.description);
        }
        actions.deinit(std.testing.allocator);
    }

    var source_entries = [_]inventory.CronEntry{
        .{ .source = "/etc/anacrontab", .owner = null, .line_count = 1, .kind = .anacron },
        .{ .source = "/var/spool/at/a0001", .owner = "root", .line_count = 1, .kind = .at_spool },
    };

    try appendActions(std.testing.allocator, &actions, .{ .entries = source_entries[0..] }, .{ .entries = &.{} });

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    try std.testing.expectEqualStrings("cron/review-anacron//etc/anacrontab", actions.items[0].id);
    try std.testing.expectEqualStrings("cron/review-at//var/spool/at/a0001", actions.items[1].id);
    try std.testing.expectEqual(plan.ActionType.manual_step, actions.items[0].action_type);
}
