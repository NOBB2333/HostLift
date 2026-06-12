const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const fs_util = @import("../util/fs.zig");

// 生成或校验本地路径 manifest，用于传输前后证明文件树一致。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var root_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var verify_path: ?[]const u8 = null;
    var force = false;
    var max_entries: usize = 100_000;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--path")) {
            index += 1;
            if (index >= args.len) return error.MissingManifestPath;
            root_path = args[index];
        } else if (std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--verify")) {
            index += 1;
            if (index >= args.len) return error.MissingManifestVerifyPath;
            verify_path = args[index];
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--max-entries")) {
            index += 1;
            if (index >= args.len) return error.MissingMaxEntries;
            max_entries = try std.fmt.parseUnsigned(usize, args[index], 10);
            if (max_entries == 0) return error.InvalidMaxEntries;
        } else {
            return error.UnknownManifestArgument;
        }
    }

    if (verify_path) |path| {
        if (output_path != null) return error.ManifestVerifyOutputConflict;
        const manifest_bytes = try fs_util.readFileAlloc(io, allocator, path, 256 * 1024 * 1024);
        defer allocator.free(manifest_bytes);
        const parsed = try std.json.parseFromSlice(local_manifest.Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema_version, local_manifest.schema_version)) return error.InvalidLocalManifest;

        var actual = try local_manifest.build(io, allocator, root_path orelse return error.MissingManifestPath, max_entries);
        defer actual.deinit(allocator);
        const report = local_manifest.verify(parsed.value, actual);
        try local_manifest.writeVerificationSummary(writer, report);
        if (!report.valid) return error.ManifestVerificationFailed;
        return;
    }

    var value = try local_manifest.build(io, allocator, root_path orelse return error.MissingManifestPath, max_entries);
    defer value.deinit(allocator);

    if (output_path) |path| {
        try local_manifest.writeFile(io, path, value, force);
    } else {
        try local_manifest.write(writer, value);
    }
}
