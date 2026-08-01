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
    if (max_entries == 0) return error.InvalidManifestEntryLimit;
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
            switch (entry.kind) {
                .file => {
                    const entry_stat = try entry.dir.statFile(io, entry.basename, .{});
                    const file_hash = try hash.sha256FileInDirHexAlloc(io, allocator, entry.dir, entry.basename);
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
                .sym_link => {
                    var link_target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    const link_target_len = try entry.dir.readLink(io, entry.basename, &link_target_buffer);
                    const link_hash = try hash.sha256BytesHexAlloc(allocator, link_target_buffer[0..link_target_len]);
                    errdefer allocator.free(link_hash);
                    try entries.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.path),
                        .kind = "sym_link",
                        .size = link_target_len,
                        .sha256 = link_hash,
                    });
                },
                else => {
                    try entries.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.path),
                        .kind = @tagName(entry.kind),
                        .size = 0,
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

    const owned_root = try allocator.dupe(u8, root_path);
    errdefer allocator.free(owned_root);
    const owned_entries = try entries.toOwnedSlice(allocator);
    return .{
        .root = owned_root,
        .entries = owned_entries,
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

test "local manifest detects file and symlink target changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source");

    var app_file = try tmp.dir.createFile(std.testing.io, "source/app.txt", .{});
    try app_file.writePositionalAll(std.testing.io, "alpha", 0);
    app_file.close(std.testing.io);
    try tmp.dir.symLink(std.testing.io, "app.txt", "source/current", .{});

    const source_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source", .{tmp.sub_path});
    defer std.testing.allocator.free(source_path);
    var expected = try build(std.testing.io, std.testing.allocator, source_path, 100);
    defer expected.deinit(std.testing.allocator);
    try verifier.ensureCompleteContent(expected);

    try tmp.dir.deleteFile(std.testing.io, "source/current");
    try tmp.dir.symLink(std.testing.io, "next.txt", "source/current", .{});
    var actual = try build(std.testing.io, std.testing.allocator, source_path, 100);
    defer actual.deinit(std.testing.allocator);
    const report = try verify(std.testing.allocator, expected, actual);
    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.changed);
}

test "local manifest truncation fails complete content validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try tmp.dir.createFile(std.testing.io, "first", .{});
    first.close(std.testing.io);
    var second = try tmp.dir.createFile(std.testing.io, "second", .{});
    second.close(std.testing.io);

    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root_path);
    var value = try build(std.testing.io, std.testing.allocator, root_path, 1);
    defer value.deinit(std.testing.allocator);
    try std.testing.expect(value.truncated);
    try std.testing.expectError(error.ManifestTruncated, verifier.ensureCompleteContent(value));
    try std.testing.expectError(error.InvalidManifestEntryLimit, build(std.testing.io, std.testing.allocator, root_path, 0));
}
