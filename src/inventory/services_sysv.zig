const std = @import("std");
const init_common = @import("services_init_common.zig");
const schema = @import("schema.zig");

// 扫描 SysV init 脚本和 runlevel 启用摘要。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) ![]schema.SysvInitScript {
    var dir = std.Io.Dir.openDirAbsolute(io, "/etc/init.d", .{ .iterate = true }) catch return allocator.alloc(schema.SysvInitScript, 0);
    defer dir.close(io);

    var scripts: std.ArrayList(schema.SysvInitScript) = .empty;
    errdefer {
        for (scripts.items) |script| {
            allocator.free(script.name);
            allocator.free(script.path);
            allocator.free(script.runlevels);
        }
        scripts.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (scripts.items.len >= 512) break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (init_common.ignoreInitScriptName(entry.name)) continue;
        const path = try std.fs.path.join(allocator, &.{ "/etc/init.d", entry.name });
        defer allocator.free(path);
        const runlevels = try scanRunlevels(io, allocator, entry.name);
        errdefer allocator.free(runlevels);
        try scripts.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, path),
            .enabled = runlevels.len > 0,
            .runlevels = runlevels,
        });
    }

    return scripts.toOwnedSlice(allocator);
}

// 扫描脚本在各 rc?.d 目录中的启用 runlevel。
fn scanRunlevels(io: std.Io, allocator: std.mem.Allocator, script_name: []const u8) ![]const u8 {
    var runlevels: std.ArrayList(u8) = .empty;
    errdefer runlevels.deinit(allocator);

    const level_names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "S" };
    for (level_names) |level| {
        const dir_path = try std.fmt.allocPrint(allocator, "/etc/rc{s}.d", .{level});
        defer allocator.free(dir_path);
        if (!runlevelEnablesScript(io, dir_path, script_name)) continue;
        if (runlevels.items.len > 0) try runlevels.append(allocator, ',');
        try runlevels.appendSlice(allocator, level);
    }

    return runlevels.toOwnedSlice(allocator);
}

// 检查 rc?.d 目录中是否有以 S 开头的符号链接指向指定脚本。
fn runlevelEnablesScript(io: std.Io, dir_path: []const u8, script_name: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch return false) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const linked_name = scriptNameFromRcEntry(entry.name) orelse continue;
        if (std.mem.eql(u8, linked_name, script_name)) return true;
    }
    return false;
}

// 从 rc 链接名（如 S20legacy）提取脚本名。
fn scriptNameFromRcEntry(name: []const u8) ?[]const u8 {
    if (name.len <= 3 or name[0] != 'S') return null;
    if (!std.ascii.isDigit(name[1]) or !std.ascii.isDigit(name[2])) return null;
    return name[3..];
}

test "sysv rc entry parser extracts script name from start links" {
    try std.testing.expectEqualStrings("legacy", scriptNameFromRcEntry("S20legacy").?);
    try std.testing.expect(scriptNameFromRcEntry("K20legacy") == null);
    try std.testing.expect(scriptNameFromRcEntry("Sbad") == null);
}
