const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描一组已知系统配置路径的存在性和大小。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.ConfigInventory {
    const candidates = [_][]const u8{
        "/etc/hosts",
        "/etc/fstab",
        "/etc/sudoers",
        "/etc/ssh/sshd_config",
        "/etc/ssh/ssh_config",
        "/etc/nginx/nginx.conf",
        "/etc/apache2/apache2.conf",
        "/etc/httpd/conf/httpd.conf",
        "/etc/postgresql",
        "/etc/mysql",
        "/etc/redis",
        "/etc/docker/daemon.json",
        "/etc/containerd/config.toml",
        "/etc/podman",
        "/etc/containers",
        "/etc/systemd/journald.conf",
        "/etc/systemd/logind.conf",
        "/etc/rsyslog.conf",
        "/etc/rsyslog.d",
        "/etc/logrotate.conf",
        "/etc/logrotate.d",
        "/etc/cron.d",
        "/etc/profile.d",
        "/etc/security/limits.conf",
        "/etc/security/limits.d",
        "/etc/sysctl.conf",
        "/etc/sysctl.d",
        "/etc/resolv.conf",
        "/etc/nsswitch.conf",
    };

    var files: std.ArrayList(schema.ConfigFile) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file.path);
        files.deinit(allocator);
    }

    for (candidates) |path| {
        const maybe_size = probe.fileSize(io, path);
        try files.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .present = maybe_size != null,
            .size = maybe_size orelse 0,
        });
    }

    return .{ .files = try files.toOwnedSlice(allocator) };
}
