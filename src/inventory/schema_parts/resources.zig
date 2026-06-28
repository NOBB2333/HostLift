// 资源类型枚举，用于整机迁移前的资源地图和选择。
pub const ResourceKind = enum {
    app_data,
    home_state,
    login_state,
    cache,
    unmanaged_executable,
    install_root,
    package_managed,
    ephemeral,
    unknown,
};

// 资源敏感等级；敏感资源默认需要人工确认。
pub const ResourceSensitivity = enum {
    normal,
    sensitive,
    secret,
    ephemeral,
};

// 资源默认迁移建议。
pub const ResourceDefaultAction = enum {
    copy,
    review,
    exclude,
};

// 整机资源记录，聚合路径、容量、来源证据和迁移建议。
pub const ResourceRef = struct {
    path: []const u8,
    present: bool = true,
    directory: bool = false,
    kind: ResourceKind = .unknown,
    logical_size: u64 = 0,
    disk_usage: u64 = 0,
    file_count: u64 = 0,
    owner: ?[]const u8 = null,
    owner_group: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    mtime_unix: ?[]const u8 = null,
    package_owner: ?[]const u8 = null,
    evidence: [][]const u8 = &.{},
    sha256: ?[]const u8 = null,
    file_type: ?[]const u8 = null,
    dynamic_link_summary: ?[]const u8 = null,
    security_summary: ?[]const u8 = null,
    sensitivity: ResourceSensitivity = .normal,
    default_action: ResourceDefaultAction = .review,
};

// 整机资源清单汇总。
pub const ResourceInventory = struct {
    resources: []ResourceRef = &.{},
    truncated: bool = false,
};
