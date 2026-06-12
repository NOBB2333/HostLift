const std = @import("std");
const scanner = @import("../inventory/scanner.zig");
const fs_util = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");
const summary_util = @import("../util/summary.zig");

// 扫描本机 inventory，支持输出 JSON 或人类可读摘要。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var output_path: ?[]const u8 = null;
    var summary = false;
    var force = false;
    var filter: scanner.ModuleFilter = .empty;
    defer filter.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--include-module")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try filter.appendModuleList(allocator, .include, args[index]);
        } else if (std.mem.eql(u8, arg, "--exclude-module")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try filter.appendModuleList(allocator, .exclude, args[index]);
        } else {
            return error.UnknownScanArgument;
        }
    }

    var scanned_inventory = try scanner.scanLocalWithOptions(io, allocator, .{ .filter = filter });
    defer scanned_inventory.deinit(allocator);

    if (output_path) |path| {
        if (!force and fs_util.pathExists(io, path)) return error.OutputFileExists;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        if (summary) {
            try summary_util.writeInventorySummary(&file_writer.interface, scanned_inventory);
        } else {
            try json_util.writeInventory(&file_writer.interface, scanned_inventory);
        }
        try file_writer.flush();
    } else {
        if (summary) {
            try summary_util.writeInventorySummary(writer, scanned_inventory);
        } else {
            try json_util.writeInventory(writer, scanned_inventory);
        }
    }
}
