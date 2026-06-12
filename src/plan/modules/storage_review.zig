const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const manual_common = @import("manual_common.zig");

// 规划 fstab 和挂载点事实差异的人工审查动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.StorageInventory,
    target: inventory.StorageInventory,
) !void {
    for (source.fstab_entries) |entry| {
        if (findFstabEntry(target.fstab_entries, entry.mount_point)) |existing| {
            if (!fstabDiffers(entry, existing)) continue;
        }
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "storage/review-fstab",
            .name = entry.mount_point,
            .subject = entry.mount_point,
            .module = .storage,
            .risk = .critical,
            .description = "Review fstab entry, device mapping and application data consistency before manual migration",
        });
    }
    for (source.mounts) |entry| {
        if (isVirtualFs(entry.fs_type)) continue;
        if (findMountEntry(target.mounts, entry.mount_point)) |_| continue;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "storage/review-mount",
            .name = entry.mount_point,
            .subject = entry.mount_point,
            .module = .storage,
            .risk = .high,
            .description = "Review source mount point before migration; HostLift does not mount filesystems automatically",
        });
    }
    if (source.truncated) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "storage/review-truncated",
            .name = "mountinfo-limit",
            .subject = "/proc/self/mountinfo",
            .module = .storage,
            .risk = .high,
            .description = "Review truncated mount scan results before migration",
        });
    }
}

// 查找 fstab mount point。
fn findFstabEntry(entries: []const inventory.FstabEntry, mount_point: []const u8) ?inventory.FstabEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.mount_point, mount_point)) return entry;
    }
    return null;
}

// 判断 fstab 条目是否不同。
fn fstabDiffers(source: inventory.FstabEntry, target: inventory.FstabEntry) bool {
    return !std.mem.eql(u8, source.device, target.device) or
        !std.mem.eql(u8, source.fs_type, target.fs_type) or
        !std.mem.eql(u8, source.options, target.options) or
        source.dump != target.dump or
        source.pass != target.pass;
}

// 查找当前挂载点。
fn findMountEntry(entries: []const inventory.MountEntry, mount_point: []const u8) ?inventory.MountEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.mount_point, mount_point)) return entry;
    }
    return null;
}

// 判断文件系统类型是否属于无需迁移的虚拟文件系统。
fn isVirtualFs(fs_type: []const u8) bool {
    const virtual_types = [_][]const u8{
        "proc",
        "sysfs",
        "devtmpfs",
        "devpts",
        "tmpfs",
        "cgroup",
        "cgroup2",
        "pstore",
        "securityfs",
        "debugfs",
        "tracefs",
        "configfs",
        "fusectl",
        "mqueue",
        "hugetlbfs",
        "overlay",
        "nsfs",
        "autofs",
        "binfmt_misc",
    };
    for (virtual_types) |candidate| {
        if (std.mem.eql(u8, fs_type, candidate)) return true;
    }
    return false;
}
