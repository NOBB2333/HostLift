const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 识别防火墙 backend 和持久化配置路径。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.FirewallInventory {
    const backend: schema.FirewallBackend = if (probe.executableExists(io, allocator, "ufw"))
        .ufw
    else if (probe.executableExists(io, allocator, "firewall-cmd"))
        .firewalld
    else if (probe.executableExists(io, allocator, "nft"))
        .nftables
    else if (probe.executableExists(io, allocator, "iptables"))
        .iptables
    else
        .unknown;

    var configs: std.ArrayList(schema.FirewallConfig) = .empty;
    errdefer {
        for (configs.items) |config| allocator.free(config.path);
        configs.deinit(allocator);
    }

    switch (backend) {
        .ufw => {
            try appendConfig(io, allocator, &configs, "/etc/ufw");
            try appendConfig(io, allocator, &configs, "/etc/default/ufw");
        },
        .firewalld => try appendConfig(io, allocator, &configs, "/etc/firewalld"),
        .nftables => try appendConfig(io, allocator, &configs, "/etc/nftables.conf"),
        .iptables => {
            try appendConfig(io, allocator, &configs, "/etc/iptables");
            try appendConfig(io, allocator, &configs, "/etc/sysconfig/iptables");
        },
        .unknown => {},
    }

    return .{
        .backend = backend,
        .configs = try configs.toOwnedSlice(allocator),
    };
}

// 检查并追加防火墙持久化配置路径。
fn appendConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    configs: *std.ArrayList(schema.FirewallConfig),
    path: []const u8,
) !void {
    const maybe_size = probe.fileSize(io, path);
    try configs.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .present = probe.pathExists(io, path),
        .size = maybe_size orelse 0,
    });
}
