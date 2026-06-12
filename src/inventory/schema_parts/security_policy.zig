// 安全策略状态枚举。
pub const PolicyStatus = enum {
    enabled,
    disabled,
    permissive,
    enforcing,
    unknown,
};

// SELinux 清单记录。
pub const SelinuxInventory = struct {
    present: bool,
    status: PolicyStatus,
    config_present: bool,
    policy_dirs: u32 = 0,
};

// AppArmor 清单记录。
pub const AppArmorInventory = struct {
    present: bool,
    status: PolicyStatus,
    profiles_loaded: u32 = 0,
    config_dirs: u32 = 0,
};

// 安全策略清单汇总。
pub const SecurityPolicyInventory = struct {
    selinux: SelinuxInventory = .{
        .present = false,
        .status = .unknown,
        .config_present = false,
        .policy_dirs = 0,
    },
    apparmor: AppArmorInventory = .{
        .present = false,
        .status = .unknown,
        .profiles_loaded = 0,
        .config_dirs = 0,
    },
};
