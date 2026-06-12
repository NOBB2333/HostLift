// sudoers 路径类型枚举。
pub const SudoersPathKind = enum {
    file,
    directory,
    missing,
    other,
};

// sudoers 条目记录。
pub const SudoersEntry = struct {
    path: []const u8,
    present: bool,
    kind: SudoersPathKind,
    size: u64,
    mode: ?u32 = null,
    meaningful_lines: u32 = 0,
};

// sudoers 清单汇总。
pub const SudoersInventory = struct {
    entries: []SudoersEntry,
    truncated: bool = false,
};
