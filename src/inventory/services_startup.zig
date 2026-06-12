const std = @import("std");
const openrc = @import("services_openrc.zig");
const schema = @import("schema.zig");
const sysv = @import("services_sysv.zig");
const user_units = @import("services_user_units.zig");
const xdg = @import("services_xdg.zig");

// 扫描用户级 systemd unit 文件名、路径、类型和启用状态。
pub fn scanUserSystemdUnits(io: std.Io, allocator: std.mem.Allocator) ![]schema.UserSystemdUnit {
    return user_units.scan(io, allocator);
}

// 扫描系统级和用户级 XDG autostart desktop 入口。
pub fn scanXdgAutostart(io: std.Io, allocator: std.mem.Allocator) ![]schema.XdgAutostartEntry {
    return xdg.scan(io, allocator);
}

// 扫描 SysV init 脚本和 runlevel 启用摘要。
pub fn scanSysvInitScripts(io: std.Io, allocator: std.mem.Allocator) ![]schema.SysvInitScript {
    return sysv.scan(io, allocator);
}

// 扫描 OpenRC service 和 runlevel 启用摘要。
pub fn scanOpenRcServices(io: std.Io, allocator: std.mem.Allocator) ![]schema.OpenRcService {
    return openrc.scan(io, allocator);
}
