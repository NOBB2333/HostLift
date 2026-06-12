const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描运行中进程摘要，记录完整命令行摘要。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.ProcessInventory {
    const lines = probe.runLines(io, allocator, &.{ "ps", "-eo", "pid=,user=,args=" }, 2 * 1024 * 1024) catch return .{
        .processes = try allocator.alloc(schema.ProcessSummary, 0),
        .truncated = false,
    };
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var processes: std.ArrayList(schema.ProcessSummary) = .empty;
    errdefer {
        for (processes.items) |process| {
            allocator.free(process.user);
            allocator.free(process.command);
        }
        processes.deinit(allocator);
    }

    var truncated = false;
    for (lines) |line| {
        if (processes.items.len >= 256) {
            truncated = true;
            break;
        }
        const parsed = parseProcessLine(line) orelse continue;
        const pid = std.fmt.parseUnsigned(u32, parsed.pid, 10) catch continue;
        const command = std.mem.trim(u8, parsed.command, " \t");
        if (command.len == 0) continue;
        try processes.append(allocator, .{
            .pid = pid,
            .user = try allocator.dupe(u8, parsed.user),
            .command = try allocator.dupe(u8, command),
        });
    }

    return .{
        .processes = try processes.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

// ps -eo pid=,user=,args= 输出解析后的进程字段。
const ParsedProcessLine = struct {
    pid: []const u8,
    user: []const u8,
    command: []const u8,
};

// 解析 ps 输出行，提取 pid、user 和完整命令。
fn parseProcessLine(line: []const u8) ?ParsedProcessLine {
    var rest = std.mem.trim(u8, line, " \t");
    const pid_end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    const pid = rest[0..pid_end];
    rest = std.mem.trim(u8, rest[pid_end..], " \t");
    const user_end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    const user = rest[0..user_end];
    const command = std.mem.trim(u8, rest[user_end..], " \t");
    if (pid.len == 0 or user.len == 0 or command.len == 0) return null;
    return .{ .pid = pid, .user = user, .command = command };
}

test "process parser preserves full command line" {
    const parsed = parseProcessLine("123 deploy /usr/bin/python3 /srv/app/worker.py --queue long").?;
    try std.testing.expectEqualStrings("123", parsed.pid);
    try std.testing.expectEqualStrings("deploy", parsed.user);
    try std.testing.expectEqualStrings("/usr/bin/python3 /srv/app/worker.py --queue long", parsed.command);
}
