const std = @import("std");

// 判断 PATH 常见目录中是否存在某个可执行文件。
pub fn executableExists(io: std.Io, allocator: std.mem.Allocator, name: []const u8) bool {
    const search_dirs = [_][]const u8{
        "/usr/local/sbin",
        "/usr/local/bin",
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin",
    };

    for (search_dirs) |dir| {
        const full_path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        defer allocator.free(full_path);

        var file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch continue;
        file.close(io);
        return true;
    }

    return false;
}

// 判断本地路径是否存在。
pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

// 拼接目录和文件名后判断路径是否存在。
pub fn pathExistsJoin(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, basename: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ dir, basename }) catch return false;
    defer allocator.free(path);
    return pathExists(io, path);
}

// 判断本地路径是否为目录。
pub fn pathIsDirectory(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

// 读取文件大小；路径不存在时返回 null。
pub fn fileSize(io: std.Io, path: []const u8) ?u64 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    return stat.size;
}

// 读取文件并去掉首尾空白。
pub fn readTrimmedFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const contents = try readWholeFile(io, allocator, path);
    defer allocator.free(contents);
    return allocator.dupe(u8, std.mem.trim(u8, contents, " \t\r\n"));
}

const default_read_limit = 8 * 1024 * 1024;

// 按默认上限读取整个文件；超限会返回 StreamTooLong，不静默截断。
pub fn readWholeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var file_reader = file.readerStreaming(io, &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(default_read_limit)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

// 执行本地命令并按字节上限收集 stdout。
pub fn runCommand(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, limit: usize) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.CommandFailed;
        },
    }

    return result.stdout;
}

// 执行命令并按非空行切分输出。
pub fn runLines(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, limit: usize) ![][]const u8 {
    const output = runCommand(io, allocator, argv, limit) catch return allocator.alloc([]const u8, 0);
    defer allocator.free(output);
    return splitMeaningfulLines(allocator, output);
}

// 执行命令并返回第一行输出。
pub fn runFirstLine(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const output = try runCommand(io, allocator, argv, 256 * 1024);
    defer allocator.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        return allocator.dupe(u8, line);
    }

    return error.EmptyOutput;
}

// 将文本拆成去空白后的有效行。
pub fn splitMeaningfulLines(allocator: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var lines_out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines_out.items) |line| allocator.free(line);
        lines_out.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        try lines_out.append(allocator, try allocator.dupe(u8, line));
    }

    return lines_out.toOwnedSlice(allocator);
}

// 统计非空且非注释的有效行数。
pub fn countMeaningfulLines(bytes: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        count += 1;
    }
    return count;
}

test "meaningful lines ignore blanks and comments" {
    const lines = try splitMeaningfulLines(std.testing.allocator, "  a  \n# comment\n\n b\n");
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
    try std.testing.expectEqual(@as(u32, 2), countMeaningfulLines("a\n#x\n\nb\n"));
}
