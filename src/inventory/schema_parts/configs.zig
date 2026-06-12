// 配置文件记录。
pub const ConfigFile = struct {
    path: []const u8,
    present: bool,
    size: u64,
};

// 配置文件清单汇总。
pub const ConfigInventory = struct {
    files: []ConfigFile,
};

// 开发工具记录。
pub const DevTool = struct {
    name: []const u8,
    present: bool,
    version: []const u8,
};

// 开发工具配置文件记录。
pub const DevConfig = struct {
    tool: []const u8,
    path: []const u8,
    present: bool,
    size: u64,
};

// 代理变量设置。
pub const ProxySetting = struct {
    name: []const u8,
    present: bool,
};

// 开发环境清单汇总。
pub const DevEnvInventory = struct {
    tools: []DevTool,
    configs: []DevConfig,
    proxy_vars: []ProxySetting,
};

// 用户主目录配置类型枚举。
pub const HomeConfigKind = enum {
    shell,
    git,
    ssh,
    editor,
    systemd_user,
    app,
    unknown,
};

// 用户主目录配置记录。
pub const HomeConfig = struct {
    user: []const u8,
    path: []const u8,
    relative_path: []const u8,
    present: bool,
    directory: bool,
    kind: HomeConfigKind,
    size: u64,
};

// 用户主目录配置清单汇总。
pub const HomeConfigInventory = struct {
    configs: []HomeConfig,
    truncated: bool,
};
