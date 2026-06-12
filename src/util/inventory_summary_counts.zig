const std = @import("std");
const inventory = @import("../inventory/schema.zig");

// 服务计数汇总：enabled、disabled、static、masked、active 和 custom。
pub const ServiceCounts = struct {
    enabled: usize = 0,
    disabled: usize = 0,
    static_like: usize = 0,
    masked: usize = 0,
    active_like: usize = 0,
    custom: usize = 0,
};

// 统计 service 的启用、禁用和自定义数量。
pub fn countServices(units: []const inventory.ServiceUnit) ServiceCounts {
    var counts: ServiceCounts = .{};
    for (units) |unit| {
        if (unit.custom) counts.custom += 1;
        switch (unit.active_state) {
            .active, .reloading, .activating => counts.active_like += 1,
            .inactive, .failed, .deactivating, .maintenance, .unknown => {},
        }
        switch (unit.state) {
            .enabled => counts.enabled += 1,
            .disabled => counts.disabled += 1,
            .static, .generated, .indirect, .transient => counts.static_like += 1,
            .masked => counts.masked += 1,
            .unknown => {},
        }
    }
    return counts;
}

// 统计非系统用户数量。
pub fn countNonSystemUsers(users: []const inventory.UserAccount) usize {
    var count: usize = 0;
    for (users) |user| {
        if (!isNoiseUser(user)) count += 1;
    }
    return count;
}

// 统计非系统用户组数量。
pub fn countNonSystemGroups(groups: []const inventory.GroupAccount) usize {
    var count: usize = 0;
    for (groups) |group| {
        if (!isNoiseGroup(group)) count += 1;
    }
    return count;
}

// 统计存在的配置文件数量。
pub fn countPresentConfigs(files: []const inventory.ConfigFile) usize {
    var count: usize = 0;
    for (files) |file| {
        if (file.present) count += 1;
    }
    return count;
}

// 统计存在的 sudoers 路径数量。
pub fn countPresentSudoersEntries(entries: []const inventory.SudoersEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.present) count += 1;
    }
    return count;
}

// 统计发现扩展 ACL 的路径数量。
pub fn countExtendedAclPaths(paths: []const inventory.AclPath) usize {
    var count: usize = 0;
    for (paths) |path| {
        if (path.has_extended_acl) count += 1;
    }
    return count;
}

// 统计已检测到的开发工具数量。
pub fn countPresentDevTools(tools: []const inventory.DevTool) usize {
    var count: usize = 0;
    for (tools) |tool| {
        if (tool.present) count += 1;
    }
    return count;
}

// 统计存在的开发配置路径数量。
pub fn countPresentDevConfigs(configs: []const inventory.DevConfig) usize {
    var count: usize = 0;
    for (configs) |config| {
        if (config.present) count += 1;
    }
    return count;
}

// 统计存在的 home 配置路径数量。
pub fn countPresentHomeConfigs(configs: []const inventory.HomeConfig) usize {
    var count: usize = 0;
    for (configs) |config| {
        if (config.present) count += 1;
    }
    return count;
}

// 统计存在的代理环境变量数量。
pub fn countPresentProxyVars(vars: []const inventory.ProxySetting) usize {
    var count: usize = 0;
    for (vars) |proxy| {
        if (proxy.present) count += 1;
    }
    return count;
}

// 统计存在的应用/数据路径数量。
pub fn countPresentDataPaths(paths: []const inventory.DataPath) usize {
    var count: usize = 0;
    for (paths) |path| {
        if (path.present) count += 1;
    }
    return count;
}

// 统计可用的容器运行时数量。
pub fn countAvailableContainerRuntimes(runtimes: []const inventory.ContainerRuntime) usize {
    var count: usize = 0;
    for (runtimes) |runtime| {
        if (runtime.available) count += 1;
    }
    return count;
}

// 统计存在的防火墙配置路径数量。
pub fn countPresentFirewallConfigs(configs: []const inventory.FirewallConfig) usize {
    var count: usize = 0;
    for (configs) |config| {
        if (config.present) count += 1;
    }
    return count;
}

// 统计存在的系统基线路径数量。
pub fn countPresentSystemBaselinePaths(paths: []const inventory.SystemPathFact) usize {
    var count: usize = 0;
    for (paths) |path| {
        if (path.present) count += 1;
    }
    return count;
}

// 统计存在的脚本安装应用候选数量。
pub fn countPresentScriptApps(apps: []const inventory.ScriptInstallCandidate) usize {
    var count: usize = 0;
    for (apps) |app| {
        if (app.present) count += 1;
    }
    return count;
}

// 统计非虚拟文件系统挂载数量。
pub fn countPhysicalOrRemoteMounts(mounts: []const inventory.MountEntry) usize {
    var count: usize = 0;
    for (mounts) |mount| {
        if (!isVirtualFs(mount.fs_type)) count += 1;
    }
    return count;
}

// 判断用户是否属于摘要中应隐藏的系统/噪声用户。
pub fn isNoiseUser(user: inventory.UserAccount) bool {
    if (user.system) return true;
    if (std.mem.eql(u8, user.name, "nobody")) return true;
    if (std.mem.startsWith(u8, user.name, "snapd-range-")) return true;
    if (std.mem.eql(u8, user.name, "snap_daemon")) return true;
    return false;
}

// 判断用户组是否属于摘要中应隐藏的系统/噪声组。
pub fn isNoiseGroup(group: inventory.GroupAccount) bool {
    if (group.system) return true;
    if (std.mem.eql(u8, group.name, "nogroup")) return true;
    if (std.mem.startsWith(u8, group.name, "snapd-range-")) return true;
    if (std.mem.eql(u8, group.name, "snap_daemon")) return true;
    return false;
}

// 判断文件系统类型是否属于摘要中默认弱化的虚拟/内核文件系统。
fn isVirtualFs(fs_type: []const u8) bool {
    const virtual_types = [_][]const u8{
        "proc",
        "sysfs",
        "devtmpfs",
        "devpts",
        "tmpfs",
        "cgroup",
        "cgroup2",
        "pstore",
        "securityfs",
        "debugfs",
        "tracefs",
        "configfs",
        "fusectl",
        "mqueue",
        "hugetlbfs",
        "overlay",
        "nsfs",
        "autofs",
        "binfmt_misc",
    };
    for (virtual_types) |candidate| {
        if (std.mem.eql(u8, fs_type, candidate)) return true;
    }
    return false;
}
