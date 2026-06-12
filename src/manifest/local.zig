const std = @import("std");
const fs_util = @import("../util/fs.zig");
const hash = @import("hash.zig");
const schema = @import("schema.zig");
const verifier = @import("verify.zig");

pub const schema_version = schema.schema_version;
pub const Entry = schema.Entry;
pub const Manifest = schema.Manifest;
pub const VerificationReport = schema.VerificationReport;

pub const sha256File = hash.sha256File;
pub const parseSha256Hex = hash.parseSha256Hex;
pub const hexSha256 = hash.hexSha256;

pub const verify = verifier.verify;
pub const writeVerificationSummary = verifier.writeVerificationSummary;

// 扫描本地文件或目录，生成带 SHA-256 的 manifest。
pub fn build(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, max_entries: usize) !Manifest {
    const stat = try std.Io.Dir.cwd().statFile(io, root_path, .{});
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.path);
            if (entry.sha256) |entry_hash| allocator.free(entry_hash);
        }
        entries.deinit(allocator);
    }

    var file_count: usize = 0;
    var dir_count: usize = 0;
    var total_bytes: u64 = 0;
    var truncated = false;

    if (stat.kind == .file) {
        const file_hash = try hash.sha256FileHexAlloc(io, allocator, root_path);
        errdefer allocator.free(file_hash);
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, "."),
            .kind = "file",
            .size = stat.size,
            .sha256 = file_hash,
        });
        file_count = 1;
        total_bytes = stat.size;
    } else if (stat.kind == .directory) {
        var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entries.items.len >= max_entries) {
                truncated = true;
                break;
            }
            const entry_stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            switch (entry.kind) {
                .file => {
                    const file_hash = hash.sha256FileInDirHexAlloc(io, allocator, entry.dir, entry.basename) catch continue;
                    errdefer allocator.free(file_hash);
                    try entries.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.path),
                        .kind = "file",
                        .size = entry_stat.size,
                        .sha256 = file_hash,
                    });
                    file_count += 1;
                    total_bytes += entry_stat.size;
                },
                .directory => {
                    try entries.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.path),
                        .kind = "directory",
                        .size = 0,
                        .sha256 = null,
                    });
                    dir_count += 1;
                },
                else => {
                    try entries.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.path),
                        .kind = @tagName(entry.kind),
                        .size = entry_stat.size,
                        .sha256 = null,
                    });
                },
            }
        }
    } else {
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, "."),
            .kind = @tagName(stat.kind),
            .size = stat.size,
            .sha256 = null,
        });
    }

    return .{
        .root = try allocator.dupe(u8, root_path),
        .entries = try entries.toOwnedSlice(allocator),
        .file_count = file_count,
        .dir_count = dir_count,
        .total_bytes = total_bytes,
        .truncated = truncated,
    };
}

// 写 manifest 文件；默认拒绝覆盖，避免误删已有审计材料。
pub fn writeFile(io: std.Io, path: []const u8, value: Manifest, force: bool) !void {
    if (!force and fs_util.pathExists(io, path)) return error.OutputFileExists;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try write(&file_writer.interface, value);
    try file_writer.flush();
}

// 将本地路径 manifest 输出为 JSON。
pub fn write(writer: anytype, value: Manifest) !void {
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = true,
    }, writer);
    try writer.writeByte('\n');
}
