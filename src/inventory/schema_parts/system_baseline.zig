// 系统路径类型枚举。
pub const SystemPathKind = enum {
    locale,
    timezone,
    storage,
    remote_mount,
    kernel_module,
    limits,
    pam,
    ntp,
    sysctl,
    identity,
    logrotate,
    profile,
    tmpfiles,
    dns,
    nss,
    network,
    security,
    system_env,
    runtime_env,
    script_app,
};

// 系统路径事实记录。
pub const SystemPathFact = struct {
    path: []const u8,
    present: bool,
    directory: bool,
    kind: SystemPathKind,
    size: u64 = 0,
    meaningful_lines: u32 = 0,
};

// 命令可用性事实记录。
pub const CommandFact = struct {
    name: []const u8,
    present: bool,
    line_count: u32 = 0,
};

// hosts 文件条目记录。
pub const HostsEntry = struct {
    address: []const u8,
    names: []const u8,
};

// 系统配置事实记录。
pub const SystemConfigFact = struct {
    kind: SystemPathKind,
    source: []const u8,
    key: []const u8,
    value: []const u8,
};

// 脚本安装类型枚举。
pub const ScriptInstallKind = enum {
    user_binary,
    runtime_manager,
    package_manager,
    config_state,
    install_root,
    unknown,
};

// 脚本安装候选记录。
pub const ScriptInstallCandidate = struct {
    name: []const u8,
    path: []const u8,
    kind: ScriptInstallKind,
    present: bool,
    evidence: ?[]const u8 = null,
    source_hint: ?[]const u8 = null,
    version_hint: ?[]const u8 = null,
    checksum_hint: ?[]const u8 = null,
    config_hint: ?[]const u8 = null,
    reinstall_hint: []const u8,
};

// 系统基线清单汇总。
pub const SystemBaselineInventory = struct {
    paths: []SystemPathFact = &.{},
    commands: []CommandFact = &.{},
    config_facts: []SystemConfigFact = &.{},
    hosts_entries: []HostsEntry = &.{},
    script_apps: []ScriptInstallCandidate = &.{},
    at_jobs_present: bool = false,
    at_jobs_count: u32 = 0,
    truncated: bool = false,
};
