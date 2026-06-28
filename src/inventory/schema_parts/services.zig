// 服务启用状态枚举。
pub const ServiceState = enum {
    enabled,
    disabled,
    static,
    masked,
    indirect,
    generated,
    transient,
    unknown,
};

// 服务运行状态枚举。
pub const ServiceActiveState = enum {
    active,
    reloading,
    inactive,
    failed,
    activating,
    deactivating,
    maintenance,
    unknown,
};

// systemd 服务单元记录。
pub const ServiceUnit = struct {
    name: []const u8,
    state: ServiceState,
    active_state: ServiceActiveState = .unknown,
    custom: bool,
    path: ?[]const u8 = null,
    dependency_summary: ?[]const u8 = null,
};

// systemd drop-in 配置片段记录。
pub const SystemdDropIn = struct {
    unit: []const u8,
    path: []const u8,
    size: u64 = 0,
    meaningful_lines: u32 = 0,
};

// 服务关联环境文件记录。
pub const ServiceEnvFile = struct {
    unit: []const u8,
    path: []const u8,
    size: u64 = 0,
    meaningful_lines: u32 = 0,
};

// systemd 定时器记录。
pub const SystemdTimer = struct {
    name: []const u8,
    state: ServiceState = .unknown,
    activates: []const u8,
    schedule: []const u8,
    custom: bool = false,
    path: ?[]const u8 = null,
};

// systemd socket 单元记录。
pub const SystemdSocket = struct {
    name: []const u8,
    state: ServiceState,
    activates: ?[]const u8 = null,
    custom: bool = false,
    path: ?[]const u8 = null,
};

// 用户 systemd 单元类型枚举。
pub const UserSystemdUnitKind = enum {
    service,
    timer,
    socket,
    unknown,
};

// 用户 systemd 单元记录。
pub const UserSystemdUnit = struct {
    user: []const u8,
    name: []const u8,
    path: []const u8,
    kind: UserSystemdUnitKind,
    enabled: bool,
};

// XDG 自动启动作用域枚举。
pub const XdgAutostartScope = enum {
    system,
    user,
};

// XDG 自动启动条目记录。
pub const XdgAutostartEntry = struct {
    scope: XdgAutostartScope,
    user: ?[]const u8 = null,
    name: []const u8,
    path: []const u8,
};

// SysV init 脚本记录。
pub const SysvInitScript = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool,
    runlevels: []const u8,
};

// OpenRC 服务记录。
pub const OpenRcService = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool,
    runlevels: []const u8,
};

// 服务清单汇总。
pub const ServiceInventory = struct {
    init_system: []const u8,
    units: []ServiceUnit,
    drop_ins: []SystemdDropIn = &.{},
    env_files: []ServiceEnvFile = &.{},
    timers: []SystemdTimer = &.{},
    sockets: []SystemdSocket = &.{},
    user_units: []UserSystemdUnit = &.{},
    xdg_autostart: []XdgAutostartEntry = &.{},
    sysv_init: []SysvInitScript = &.{},
    openrc: []OpenRcService = &.{},
};

// 定时任务条目记录。
pub const CronEntry = struct {
    source: []const u8,
    owner: ?[]const u8,
    line_count: u32,
    kind: CronSourceKind = .cron,
};

// 定时任务来源类型，区分普通 cron、anacron 和一次性 at 任务线索。
pub const CronSourceKind = enum {
    cron,
    anacron,
    periodic_dir,
    at_spool,
};

// 定时任务清单汇总。
pub const CronInventory = struct {
    entries: []CronEntry,
};
