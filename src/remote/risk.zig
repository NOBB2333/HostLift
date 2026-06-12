const std = @import("std");
const plan = @import("../plan/schema.zig");

// 根据命令名给远程命令做粗粒度风险分级。
pub fn classifyCommand(argv: []const []const u8) plan.RiskLevel {
    const command = argv[0];
    if (std.mem.eql(u8, command, "rm") or
        std.mem.eql(u8, command, "mkfs") or
        std.mem.eql(u8, command, "dd") or
        std.mem.eql(u8, command, "shutdown") or
        std.mem.eql(u8, command, "reboot") or
        std.mem.eql(u8, command, "poweroff"))
    {
        return .critical;
    }
    if (std.mem.eql(u8, command, "systemctl") or
        std.mem.eql(u8, command, "runuser") or
        std.mem.eql(u8, command, "chkconfig") or
        std.mem.eql(u8, command, "update-rc.d") or
        std.mem.eql(u8, command, "rc-update") or
        std.mem.eql(u8, command, "apt") or
        std.mem.eql(u8, command, "apt-get") or
        std.mem.eql(u8, command, "dnf") or
        std.mem.eql(u8, command, "yum") or
        std.mem.eql(u8, command, "pacman") or
        std.mem.eql(u8, command, "zypper") or
        std.mem.eql(u8, command, "rsync") or
        std.mem.eql(u8, command, "ufw") or
        std.mem.eql(u8, command, "firewall-cmd") or
        std.mem.eql(u8, command, "firewall-offline-cmd") or
        std.mem.eql(u8, command, "nft") or
        std.mem.eql(u8, command, "iptables-restore") or
        std.mem.eql(u8, command, "docker") or
        std.mem.eql(u8, command, "chmod") or
        std.mem.eql(u8, command, "chown") or
        std.mem.eql(u8, command, "pip") or
        std.mem.eql(u8, command, "npm"))
    {
        return .medium;
    }
    return .low;
}

test "classifies destructive commands as critical" {
    var argv = [_][]const u8{ "rm", "-rf", "/tmp/app" };
    try std.testing.expectEqual(plan.RiskLevel.critical, classifyCommand(argv[0..]));
}

test "classifies package and service commands as medium" {
    var package_argv = [_][]const u8{ "apt-get", "install", "nginx" };
    var service_argv = [_][]const u8{ "systemctl", "restart", "nginx" };
    try std.testing.expectEqual(plan.RiskLevel.medium, classifyCommand(package_argv[0..]));
    try std.testing.expectEqual(plan.RiskLevel.medium, classifyCommand(service_argv[0..]));
}

test "classifies ordinary commands as low" {
    var argv = [_][]const u8{ "whoami" };
    try std.testing.expectEqual(plan.RiskLevel.low, classifyCommand(argv[0..]));
}
