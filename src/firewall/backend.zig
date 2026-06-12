const std = @import("std");
const remote_planner = @import("../remote/planner.zig");

// 防火墙后端类型枚举。
pub const Backend = enum {
    ufw,
    firewalld,
    nftables,
    iptables,
};

// 防火墙命令 argv 容器，含长度信息。
pub const Argv = struct {
    items: [4][]const u8,
    len: usize,

    // 返回当前防火墙命令的 argv 切片。
    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }
};

// 根据防火墙配置路径推断对应 backend。
pub fn inferFromPath(path: []const u8) !Backend {
    if (std.mem.startsWith(u8, path, "/etc/ufw") or std.mem.eql(u8, path, "/etc/default/ufw")) return .ufw;
    if (std.mem.startsWith(u8, path, "/etc/firewalld")) return .firewalld;
    if (std.mem.eql(u8, path, "/etc/nftables.conf")) return .nftables;
    if (std.mem.startsWith(u8, path, "/etc/iptables") or std.mem.startsWith(u8, path, "/etc/sysconfig/iptables")) return .iptables;
    return error.UnsupportedFirewallBackend;
}

// 根据 backend 生成远程恢复脚本内容。
pub fn recoveryScriptAlloc(allocator: std.mem.Allocator, backend: Backend, config_path: []const u8) ![]const u8 {
    try remote_planner.validatePath(config_path);
    return switch (backend) {
        .ufw => std.fmt.allocPrint(
            allocator,
            "ufw reload\n",
            .{},
        ),
        .firewalld => std.fmt.allocPrint(
            allocator,
            "firewall-cmd --reload\n",
            .{},
        ),
        .nftables => std.fmt.allocPrint(
            allocator,
            "nft -f {s}\n",
            .{config_path},
        ),
        .iptables => std.fmt.allocPrint(
            allocator,
            "iptables-restore {s}\n",
            .{config_path},
        ),
    };
}

// 构造 systemd-run 延迟恢复命令 argv。
pub fn appendSystemdRunRecoveryArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    unit_name: []const u8,
    script_path: []const u8,
    window_seconds: u32,
) !void {
    try remote_planner.validateCommandToken(unit_name);
    try remote_planner.validatePath(script_path);
    if (window_seconds < 10 or window_seconds > 3600) return error.InvalidFirewallRecoveryWindow;
    const on_active = try std.fmt.allocPrint(allocator, "--on-active={d}", .{window_seconds});
    errdefer allocator.free(on_active);
    const unit_arg = try std.fmt.allocPrint(allocator, "--unit={s}", .{unit_name});
    errdefer allocator.free(unit_arg);
    try argv.append(allocator, "systemd-run");
    try argv.append(allocator, on_active);
    try argv.append(allocator, unit_arg);
    try argv.append(allocator, "/bin/sh");
    try argv.append(allocator, script_path);
}

// 返回 backend-specific 配置校验命令 argv。
pub fn validationArgv(backend: Backend, config_path: []const u8) Argv {
    return switch (backend) {
        .ufw => .{ .items = .{ "ufw", "--dry-run", "reload", "" }, .len = 3 },
        .firewalld => .{ .items = .{ "firewall-offline-cmd", "--check-config", "", "" }, .len = 2 },
        .nftables => .{ .items = .{ "nft", "-c", "-f", config_path }, .len = 4 },
        .iptables => .{ .items = .{ "iptables-restore", "--test", config_path, "" }, .len = 3 },
    };
}

// 返回 backend-specific reload 命令 argv。
pub fn reloadArgv(backend: Backend, config_path: []const u8) Argv {
    return switch (backend) {
        .ufw => .{ .items = .{ "ufw", "reload", "", "" }, .len = 2 },
        .firewalld => .{ .items = .{ "firewall-cmd", "--reload", "", "" }, .len = 2 },
        .nftables => .{ .items = .{ "nft", "-f", config_path, "" }, .len = 3 },
        .iptables => .{ .items = .{ "iptables-restore", config_path, "", "" }, .len = 2 },
    };
}

test "firewall backend inference follows persistent config paths" {
    try std.testing.expectEqual(Backend.ufw, try inferFromPath("/etc/ufw"));
    try std.testing.expectEqual(Backend.ufw, try inferFromPath("/etc/default/ufw"));
    try std.testing.expectEqual(Backend.firewalld, try inferFromPath("/etc/firewalld"));
    try std.testing.expectEqual(Backend.nftables, try inferFromPath("/etc/nftables.conf"));
    try std.testing.expectEqual(Backend.iptables, try inferFromPath("/etc/iptables/rules.v4"));
    try std.testing.expectError(error.UnsupportedFirewallBackend, inferFromPath("/etc/hosts"));
}

test "recovery script uses backend-specific reload command" {
    const nft_script = try recoveryScriptAlloc(std.testing.allocator, .nftables, "/etc/nftables.conf");
    defer std.testing.allocator.free(nft_script);
    try std.testing.expect(std.mem.indexOf(u8, nft_script, "nft -f /etc/nftables.conf\n") != null);

    const ufw_script = try recoveryScriptAlloc(std.testing.allocator, .ufw, "/etc/ufw");
    defer std.testing.allocator.free(ufw_script);
    try std.testing.expect(std.mem.indexOf(u8, ufw_script, "ufw reload\n") != null);
}

test "recovery script rejects unsafe path" {
    try std.testing.expectError(error.InvalidTransferPath, recoveryScriptAlloc(std.testing.allocator, .iptables, "/etc/iptables/rules.v4;rm"));
}

test "systemd-run recovery argv is structured and validated" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        std.testing.allocator.free(argv.items[1]);
        std.testing.allocator.free(argv.items[2]);
        argv.deinit(std.testing.allocator);
    }
    try appendSystemdRunRecoveryArgv(std.testing.allocator, &argv, "hostlift-firewall-recovery-123", "/tmp/hostlift-firewall-recovery-123.sh", 90);
    try std.testing.expectEqualStrings("systemd-run", argv.items[0]);
    try std.testing.expectEqualStrings("--on-active=90", argv.items[1]);
    try std.testing.expectEqualStrings("--unit=hostlift-firewall-recovery-123", argv.items[2]);
    try std.testing.expectEqualStrings("/bin/sh", argv.items[3]);
    try std.testing.expectEqualStrings("/tmp/hostlift-firewall-recovery-123.sh", argv.items[4]);
    for (argv.items) |arg| try remote_planner.validateCommandToken(arg);
}

test "firewall backend command argv is accepted by remote planner validation" {
    const path = "/etc/nftables.conf";
    const validation_argv = validationArgv(.nftables, path);
    const reload_argv = reloadArgv(.nftables, path);
    for (validation_argv.slice()) |arg| try remote_planner.validateCommandToken(arg);
    for (reload_argv.slice()) |arg| try remote_planner.validateCommandToken(arg);
}
