const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描 SELinux 和 AppArmor 的启用状态与配置目录事实，不读取策略正文。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.SecurityPolicyInventory {
    return .{
        .selinux = scanSelinux(io, allocator),
        .apparmor = scanAppArmor(io, allocator),
    };
}

// 根据只读系统路径推断 SELinux 状态。
fn scanSelinux(io: std.Io, allocator: std.mem.Allocator) schema.SelinuxInventory {
    const selinux_fs_present = probe.pathExists(io, "/sys/fs/selinux");
    const config_present = probe.pathExists(io, "/etc/selinux/config");
    const status = selinuxStatus(io, allocator);
    return .{
        .present = selinux_fs_present or config_present,
        .status = status,
        .config_present = config_present,
        .policy_dirs = countDirectoryEntries(io, allocator, "/etc/selinux"),
    };
}

// 根据只读系统路径推断 AppArmor 状态。
fn scanAppArmor(io: std.Io, allocator: std.mem.Allocator) schema.AppArmorInventory {
    const module_present = probe.pathExists(io, "/sys/module/apparmor");
    const config_dirs = countExistingPaths(io, &.{
        "/etc/apparmor",
        "/etc/apparmor.d",
    });
    return .{
        .present = module_present or config_dirs > 0,
        .status = appArmorStatus(io, allocator),
        .profiles_loaded = appArmorProfilesLoaded(io, allocator),
        .config_dirs = config_dirs,
    };
}

// 读取 SELinux enforcing/permissive 状态。
fn selinuxStatus(io: std.Io, allocator: std.mem.Allocator) schema.PolicyStatus {
    const enforce = probe.readTrimmedFile(io, allocator, "/sys/fs/selinux/enforce") catch {
        if (probe.pathExists(io, "/sys/fs/selinux")) return .enabled;
        return .unknown;
    };
    defer allocator.free(enforce);
    return parseSelinuxEnforce(enforce);
}

// 读取 AppArmor enabled 参数。
fn appArmorStatus(io: std.Io, allocator: std.mem.Allocator) schema.PolicyStatus {
    const enabled = probe.readTrimmedFile(io, allocator, "/sys/module/apparmor/parameters/enabled") catch {
        if (probe.pathExists(io, "/sys/module/apparmor")) return .enabled;
        return .unknown;
    };
    defer allocator.free(enabled);
    return parseAppArmorEnabled(enabled);
}

// 统计已加载 AppArmor profile 数量，不读取 profile 正文。
fn appArmorProfilesLoaded(io: std.Io, allocator: std.mem.Allocator) u32 {
    const contents = probe.readWholeFile(io, allocator, "/sys/kernel/security/apparmor/profiles") catch return 0;
    defer allocator.free(contents);
    return probe.countMeaningfulLines(contents);
}

// 统计目录中的直接子项数量；失败时返回 0。
fn countDirectoryEntries(io: std.Io, allocator: std.mem.Allocator, path: []const u8) u32 {
    _ = allocator;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |_| {
        count += 1;
    }
    return count;
}

// 统计存在的路径数量。
fn countExistingPaths(io: std.Io, paths: []const []const u8) u32 {
    var count: u32 = 0;
    for (paths) |path| {
        if (probe.pathExists(io, path)) count += 1;
    }
    return count;
}

// 解析 SELinux enforce 文件内容。
fn parseSelinuxEnforce(value: []const u8) schema.PolicyStatus {
    if (std.mem.eql(u8, value, "1")) return .enforcing;
    if (std.mem.eql(u8, value, "0")) return .permissive;
    return .unknown;
}

// 解析 AppArmor enabled 参数内容。
fn parseAppArmorEnabled(value: []const u8) schema.PolicyStatus {
    if (std.ascii.eqlIgnoreCase(value, "Y") or std.ascii.eqlIgnoreCase(value, "yes") or std.mem.eql(u8, value, "1")) return .enabled;
    if (std.ascii.eqlIgnoreCase(value, "N") or std.ascii.eqlIgnoreCase(value, "no") or std.mem.eql(u8, value, "0")) return .disabled;
    return .unknown;
}

test "security policy status parsers are conservative" {
    try std.testing.expectEqual(schema.PolicyStatus.enforcing, parseSelinuxEnforce("1"));
    try std.testing.expectEqual(schema.PolicyStatus.permissive, parseSelinuxEnforce("0"));
    try std.testing.expectEqual(schema.PolicyStatus.unknown, parseSelinuxEnforce("unexpected"));
    try std.testing.expectEqual(schema.PolicyStatus.enabled, parseAppArmorEnabled("Y"));
    try std.testing.expectEqual(schema.PolicyStatus.enabled, parseAppArmorEnabled("yes"));
    try std.testing.expectEqual(schema.PolicyStatus.disabled, parseAppArmorEnabled("N"));
    try std.testing.expectEqual(schema.PolicyStatus.unknown, parseAppArmorEnabled("maybe"));
}
