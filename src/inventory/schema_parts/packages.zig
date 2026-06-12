// 包管理器类型枚举。
pub const PackageManagerKind = enum {
    apt,
    dnf,
    yum,
    pacman,
    zypper,
    unknown,
};

// 软件仓库源引用。
pub const RepositoryRef = struct {
    id: []const u8,
    enabled: bool,
};

// 包管理器检测信息。
pub const PackageManagerInfo = struct {
    kind: PackageManagerKind,
    version: []const u8,
    repos: []RepositoryRef,
};

// 包清单（显式安装和锁定包）。
pub const PackageInventory = struct {
    explicit: [][]const u8,
    held: [][]const u8,
};
