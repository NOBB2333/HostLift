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
            .description = descriptionForFstab(entry),
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
            .description = descriptionForMount(entry),
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

// 根据 fstab 类型生成操作清单提示。
fn descriptionForFstab(entry: inventory.FstabEntry) []const u8 {
    if (isRemoteFs(entry.fs_type)) return "Review remote mount checklist: network reachability, credentials, mount options and target boot behavior before manual migration";
    if (isManagedStorageFs(entry.fs_type) or looksLikeManagedDevice(entry.device)) return "Review storage mapping checklist: target disks, UUIDs, LVM/ZFS/Btrfs layout and backup consistency before editing fstab";
    return "Review fstab entry, device mapping and application data consistency before manual migration";
}

// 根据当前挂载类型生成操作清单提示。
fn descriptionForMount(entry: inventory.MountEntry) []const u8 {
    if (isRemoteFs(entry.fs_type)) return "Review remote mounted data before migration; confirm NFS/CIFS/autofs credentials and target network path manually";
    if (isManagedStorageFs(entry.fs_type) or looksLikeManagedDevice(entry.source)) return "Review mounted storage before migration; HostLift does not recreate LVM/ZFS/Btrfs/disk topology automatically";
    return "Review source mount point before migration; HostLift does not mount filesystems automatically";
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

// 判断文件系统是否常见于远程挂载。
fn isRemoteFs(fs_type: []const u8) bool {
    return std.mem.eql(u8, fs_type, "nfs") or
        std.mem.eql(u8, fs_type, "nfs4") or
        std.mem.eql(u8, fs_type, "cifs") or
        std.mem.eql(u8, fs_type, "smb3") or
        std.mem.eql(u8, fs_type, "fuse.sshfs");
}

// 判断文件系统类型是否常见于需要专门准备的存储能力。
fn isManagedStorageFs(fs_type: []const u8) bool {
    return std.mem.eql(u8, fs_type, "zfs") or
        std.mem.eql(u8, fs_type, "btrfs");
}

// 判断设备字符串是否看起来来自 LVM/ZFS/Btrfs 或远程源。
fn looksLikeManagedDevice(device: []const u8) bool {
    return std.mem.startsWith(u8, device, "/dev/mapper/") or
        std.mem.startsWith(u8, device, "/dev/zvol/") or
        std.mem.indexOf(u8, device, ":/") != null;
}
