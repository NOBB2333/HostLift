const std = @import("std");
const home_user = @import("home_user.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描系统和用户级开发工具配置路径。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.DevConfig {
    var configs: std.ArrayList(schema.DevConfig) = .empty;
    errdefer {
        for (configs.items) |config| {
            allocator.free(config.tool);
            allocator.free(config.path);
        }
        configs.deinit(allocator);
    }

    try appendSystemConfigs(io, allocator, &configs);
    try appendUserConfigs(io, allocator, &configs);

    return configs.toOwnedSlice(allocator);
}

// 扫描系统级开发工具配置路径（pip/npm/apt/shell）。
fn appendSystemConfigs(io: std.Io, allocator: std.mem.Allocator, configs: *std.ArrayList(schema.DevConfig)) !void {
    try appendConfig(io, allocator, configs, "pip", "/etc/pip.conf");
    try appendConfig(io, allocator, configs, "pip", "/etc/xdg/pip/pip.conf");
    try appendConfig(io, allocator, configs, "npm", "/etc/npmrc");
    try appendConfig(io, allocator, configs, "apt", "/etc/apt/apt.conf");
    try appendConfig(io, allocator, configs, "apt", "/etc/apt/apt.conf.d/proxy.conf");
    try appendConfig(io, allocator, configs, "shell", "/etc/environment");
    try appendConfig(io, allocator, configs, "shell", "/etc/profile");
    try appendConfig(io, allocator, configs, "shell", "/etc/profile.d/proxy.sh");
}

// 遍历所有用户扫描其 home 目录下的开发工具配置。
fn appendUserConfigs(io: std.Io, allocator: std.mem.Allocator, configs: *std.ArrayList(schema.DevConfig)) !void {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    for (users) |user| {
        if (!home_user.shouldScanHome(user)) continue;
        try appendUserConfig(io, allocator, configs, "pip", user.home, ".pip/pip.conf");
        try appendUserConfig(io, allocator, configs, "pip", user.home, ".config/pip/pip.conf");
        try appendUserConfig(io, allocator, configs, "pip", user.home, ".pypirc");
        try appendUserConfig(io, allocator, configs, "npm", user.home, ".npmrc");
        try appendUserConfig(io, allocator, configs, "npm", user.home, ".config/npm/npmrc");
        try appendUserConfig(io, allocator, configs, "maven", user.home, ".m2/settings.xml");
        try appendUserConfig(io, allocator, configs, "cargo", user.home, ".cargo/config.toml");
        try appendUserConfig(io, allocator, configs, "cargo", user.home, ".cargo/config");
        try appendUserConfig(io, allocator, configs, "gradle", user.home, ".gradle/gradle.properties");
        try appendUserConfig(io, allocator, configs, "go", user.home, ".config/go/env");
        try appendUserConfig(io, allocator, configs, "shell", user.home, ".profile");
        try appendUserConfig(io, allocator, configs, "shell", user.home, ".bashrc");
        try appendUserConfig(io, allocator, configs, "shell", user.home, ".zshrc");
        try appendUserConfig(io, allocator, configs, "git", user.home, ".gitconfig");
    }
}

// 将用户 home 目录和相对路径拼接后加入配置列表。
fn appendUserConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    configs: *std.ArrayList(schema.DevConfig),
    tool: []const u8,
    home: []const u8,
    relative_path: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ home, relative_path });
    defer allocator.free(path);
    try appendConfig(io, allocator, configs, tool, path);
}

// 检测配置文件是否存在并追加到配置列表。
fn appendConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    configs: *std.ArrayList(schema.DevConfig),
    tool: []const u8,
    path: []const u8,
) !void {
    const maybe_size = probe.fileSize(io, path);
    try configs.append(allocator, .{
        .tool = try allocator.dupe(u8, tool),
        .path = try allocator.dupe(u8, path),
        .present = maybe_size != null,
        .size = maybe_size orelse 0,
    });
}
