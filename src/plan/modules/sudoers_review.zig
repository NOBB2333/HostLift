const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const manual_common = @import("manual_common.zig");

// 规划 sudoers 元数据差异的人工审查动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.SudoersInventory,
    target: inventory.SudoersInventory,
) !void {
    for (source.entries) |entry| {
        if (!entry.present) continue;
        const target_entry = findSudoersEntry(target.entries, entry.path);
        if (target_entry) |existing| {
            if (!sudoersMetadataDiffers(entry, existing)) continue;
        }
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "sudoers/review",
            .name = entry.path,
            .subject = entry.path,
            .module = .sudoers,
            .risk = .critical,
            .description = "Review sudoers metadata before manual migration; HostLift does not serialize sudoers rule content",
        });
    }
    if (source.truncated) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "sudoers/review-truncated",
            .name = "scanner-limit",
            .subject = "/etc/sudoers.d",
            .module = .sudoers,
            .risk = .critical,
            .description = "Review truncated sudoers scan results before migration",
        });
    }
}

// 查找指定 sudoers 路径。
fn findSudoersEntry(entries: []const inventory.SudoersEntry, path: []const u8) ?inventory.SudoersEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

// 判断 sudoers 安全相关元数据是否变化。
fn sudoersMetadataDiffers(source: inventory.SudoersEntry, target: inventory.SudoersEntry) bool {
    return source.present != target.present or
        source.kind != target.kind or
        source.size != target.size or
        source.mode != target.mode or
        source.meaningful_lines != target.meaningful_lines;
}
