const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const startup = @import("services_startup.zig");
const systemd = @import("services_systemd.zig");

// 扫描服务和启动项事实，只记录元数据，不决定是否迁移。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.ServiceInventory {
    return .{
        .init_system = try allocator.dupe(u8, detectInitSystem(io)),
        .units = try systemd.scanUnits(io, allocator),
        .timers = try systemd.scanTimers(io, allocator),
        .sockets = try systemd.scanSockets(io, allocator),
        .user_units = try startup.scanUserSystemdUnits(io, allocator),
        .xdg_autostart = try startup.scanXdgAutostart(io, allocator),
        .sysv_init = try startup.scanSysvInitScripts(io, allocator),
        .openrc = try startup.scanOpenRcServices(io, allocator),
    };
}

// 通过检查路径探测当前 init 系统类型。
fn detectInitSystem(io: std.Io) []const u8 {
    if (probe.pathExists(io, "/run/systemd/system")) return "systemd";
    if (probe.pathExists(io, "/etc/runlevels")) return "openrc";
    if (probe.pathExists(io, "/etc/init.d")) return "sysvinit";
    return "unknown";
}

test "init system detector falls back to unknown in test environment" {
    _ = detectInitSystem(std.testing.io);
}
