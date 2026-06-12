// POSIX 扩展 ACL 路径检测结果。
pub const AclPath = struct {
    path: []const u8,
    present: bool,
    directory: bool,
    has_extended_acl: bool,
};

// ACL 清单汇总。
pub const AclInventory = struct {
    getfacl_available: bool,
    paths: []AclPath,
    truncated: bool = false,
};
