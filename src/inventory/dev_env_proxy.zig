const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描常见代理环境变量是否存在。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.ProxySetting {
    const names = [_][]const u8{
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
    };

    const env_lines = probe.runLines(io, allocator, &.{"env"}, 512 * 1024) catch try allocator.alloc([]const u8, 0);
    defer {
        for (env_lines) |line| allocator.free(line);
        allocator.free(env_lines);
    }

    var vars: std.ArrayList(schema.ProxySetting) = .empty;
    errdefer {
        for (vars.items) |proxy| allocator.free(proxy.name);
        vars.deinit(allocator);
    }

    for (names) |name| {
        try vars.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .present = envHasName(env_lines, name),
        });
    }

    return vars.toOwnedSlice(allocator);
}

// 在环境变量行列表中检查指定名称的变量是否存在。
fn envHasName(lines: []const []const u8, name: []const u8) bool {
    for (lines) |line| {
        if (line.len <= name.len) continue;
        if (line[name.len] != '=') continue;
        if (std.mem.eql(u8, line[0..name.len], name)) return true;
    }
    return false;
}
