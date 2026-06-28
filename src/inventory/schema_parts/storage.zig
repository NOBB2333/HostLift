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
    total_bytes: u64 = 0,
    available_bytes: u64 = 0,
    total_inodes: u64 = 0,
    available_inodes: u64 = 0,
};

// 存储清单汇总。
pub const StorageInventory = struct {
    fstab_entries: []FstabEntry,
    mounts: []MountEntry,
    memory_total_bytes: u64 = 0,
    memory_available_bytes: u64 = 0,
    swap_total_bytes: u64 = 0,
    swap_free_bytes: u64 = 0,
    truncated: bool = false,
};
