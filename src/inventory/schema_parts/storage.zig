// fstab 文件系统挂载条目。
pub const FstabEntry = struct {
    device: []const u8,
    mount_point: []const u8,
    fs_type: []const u8,
    options: []const u8,
    dump: u8 = 0,
    pass: u8 = 0,
};

// 当前挂载点记录。
pub const MountEntry = struct {
    mount_point: []const u8,
    fs_type: []const u8,
    source: []const u8,
    options: []const u8,
};

// 存储清单汇总。
pub const StorageInventory = struct {
    fstab_entries: []FstabEntry,
    mounts: []MountEntry,
    truncated: bool = false,
};
