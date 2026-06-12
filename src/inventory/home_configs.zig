const std = @import("std");
const home_user = @import("home_user.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描 root 和非系统用户的精选 dotfile/XDG 配置路径。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.HomeConfigInventory {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    var configs: std.ArrayList(schema.HomeConfig) = .empty;
    errdefer {
        for (configs.items) |config| {
            allocator.free(config.user);
            allocator.free(config.path);
            allocator.free(config.relative_path);
        }
        configs.deinit(allocator);
    }

    var truncated = false;
    for (users) |user| {
        if (configs.items.len >= 512) {
            truncated = true;
            break;
        }
        if (!home_user.shouldScanHome(user)) continue;
        try appendKnownConfigs(io, allocator, &configs, user, &truncated);
        if (truncated) break;
    }

    return .{
        .configs = try configs.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

// 为用户追加一组常见 home 配置路径。
fn appendKnownConfigs(
    io: std.Io,
    allocator: std.mem.Allocator,
    configs: *std.ArrayList(schema.HomeConfig),
    user: schema.UserAccount,
    truncated: *bool,
) !void {
    const candidates = [_]struct {
        relative_path: []const u8,
        kind: schema.HomeConfigKind,
    }{
        .{ .relative_path = ".profile", .kind = .shell },
        .{ .relative_path = ".bashrc", .kind = .shell },
        .{ .relative_path = ".bash_profile", .kind = .shell },
        .{ .relative_path = ".bash_aliases", .kind = .shell },
        .{ .relative_path = ".zshrc", .kind = .shell },
        .{ .relative_path = ".config/fish/config.fish", .kind = .shell },
        .{ .relative_path = ".gitconfig", .kind = .git },
        .{ .relative_path = ".gitignore_global", .kind = .git },
        .{ .relative_path = ".ssh/config", .kind = .ssh },
        .{ .relative_path = ".config/git", .kind = .git },
        .{ .relative_path = ".config/nvim", .kind = .editor },
        .{ .relative_path = ".vimrc", .kind = .editor },
        .{ .relative_path = ".tmux.conf", .kind = .app },
        .{ .relative_path = ".config/systemd/user", .kind = .systemd_user },
        .{ .relative_path = ".config/Code/User/settings.json", .kind = .editor },
        .{ .relative_path = ".config/Code/User/keybindings.json", .kind = .editor },
        .{ .relative_path = ".npmrc", .kind = .app },
        .{ .relative_path = ".config/npm/npmrc", .kind = .app },
        .{ .relative_path = ".pip/pip.conf", .kind = .app },
        .{ .relative_path = ".config/pip/pip.conf", .kind = .app },
        .{ .relative_path = ".pypirc", .kind = .app },
        .{ .relative_path = ".m2/settings.xml", .kind = .app },
        .{ .relative_path = ".cargo/config.toml", .kind = .app },
        .{ .relative_path = ".cargo/config", .kind = .app },
        .{ .relative_path = ".gradle/gradle.properties", .kind = .app },
        .{ .relative_path = ".config/go/env", .kind = .app },
    };

    for (candidates) |candidate| {
        if (configs.items.len >= 512) {
            truncated.* = true;
            return;
        }
        try appendConfig(io, allocator, configs, user, candidate.relative_path, candidate.kind);
    }
}

// 检查并追加单个 home 配置路径记录。
fn appendConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    configs: *std.ArrayList(schema.HomeConfig),
    user: schema.UserAccount,
    relative_path: []const u8,
    kind: schema.HomeConfigKind,
) !void {
    const path = try std.fs.path.join(allocator, &.{ user.home, relative_path });
    defer allocator.free(path);
    if (!probe.pathExists(io, path)) return;

    const directory = probe.pathIsDirectory(io, path);
    try configs.append(allocator, .{
        .user = try allocator.dupe(u8, user.name),
        .path = try allocator.dupe(u8, path),
        .relative_path = try allocator.dupe(u8, relative_path),
        .present = true,
        .directory = directory,
        .kind = kind,
        .size = if (directory) 0 else probe.fileSize(io, path) orelse 0,
    });
}
