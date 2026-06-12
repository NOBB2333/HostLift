const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描常见应用、数据、数据库和 home 数据路径。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.AppDataInventory {
    var paths: std.ArrayList(schema.DataPath) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path.path);
        paths.deinit(allocator);
    }

    try appendPath(io, allocator, &paths, "/srv", .app_data);
    try appendPath(io, allocator, &paths, "/opt", .app_data);
    try appendPath(io, allocator, &paths, "/var/www", .web_root);
    try appendPath(io, allocator, &paths, "/var/lib/mysql", .database_data);
    try appendPath(io, allocator, &paths, "/var/lib/postgresql", .database_data);
    try appendPath(io, allocator, &paths, "/var/lib/redis", .database_data);
    try appendPath(io, allocator, &paths, "/var/lib/docker/volumes", .docker_data);

    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    for (users) |user| {
        if (user.system) continue;
        if (user.home.len == 0 or std.mem.eql(u8, user.home, "/nonexistent")) continue;
        try appendPath(io, allocator, &paths, user.home, .home_data);
    }

    return .{ .paths = try paths.toOwnedSlice(allocator) };
}

// 检查并追加应用/数据路径记录。
fn appendPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: *std.ArrayList(schema.DataPath),
    path: []const u8,
    kind: schema.DataPathKind,
) !void {
    const maybe_size = probe.fileSize(io, path);
    try paths.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .present = probe.pathExists(io, path),
        .kind = kind,
        .size = maybe_size orelse 0,
    });
}
