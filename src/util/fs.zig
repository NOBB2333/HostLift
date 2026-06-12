const std = @import("std");

// 判断本地路径是否存在。
pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// 按大小上限读取本地文件内容。
pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_reader = file.readerStreaming(io, &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

// 按大小上限读取文件，并把超限错误归一化成输入文件过大。
pub fn readInputFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return readFileAlloc(io, allocator, path, limit) catch |err| switch (err) {
        error.StreamTooLong => error.InputFileTooLarge,
        else => err,
    };
}
