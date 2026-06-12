const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const remote_options = @import("../remote/options.zig");
const remote_probe = @import("remote_probe.zig");
const validation = @import("../security/validation.zig");

pub const sha256File = remote_probe.sha256File;
pub const sha256FileWithOptions = remote_probe.sha256FileWithOptions;

// 通过 SSH 在远程目录上构建 manifest，用于递归复制后的结果校验。
pub fn buildRemote(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    root_path: []const u8,
    max_entries: usize,
) !local_manifest.Manifest {
    return buildRemoteWithOptions(io, allocator, host, root_path, max_entries, .{});
}

// 通过 SSH 在远程目录上构建 manifest，并使用指定 SSH 执行选项。
pub fn buildRemoteWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    root_path: []const u8,
    max_entries: usize,
    options: remote_options.ExecutionOptions,
) !local_manifest.Manifest {
    try validation.validateHost(host);
    try validation.validatePath(root_path);
    _ = try remote_options.normalize(options);

    var entries: std.ArrayList(local_manifest.Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.path);
            if (entry.sha256) |hash| allocator.free(hash);
        }
        entries.deinit(allocator);
    }

    var file_count: usize = 0;
    var dir_count: usize = 0;
    var total_bytes: u64 = 0;
    var truncated = false;

    const dirs = try remote_probe.findPaths(io, allocator, host, root_path, "d", options);
    defer freeStringSlice(allocator, dirs);
    for (dirs) |path| {
        if (entries.items.len >= max_entries) {
            truncated = true;
            break;
        }
        const relative = try relativePath(allocator, root_path, path) orelse continue;
        errdefer allocator.free(relative);
        try entries.append(allocator, .{
            .path = relative,
            .kind = "directory",
            .size = 0,
            .sha256 = null,
        });
        dir_count += 1;
    }

    if (!truncated) {
        const files = try remote_probe.findPaths(io, allocator, host, root_path, "f", options);
        defer freeStringSlice(allocator, files);
        for (files) |path| {
            if (entries.items.len >= max_entries) {
                truncated = true;
                break;
            }
            const relative = try relativePath(allocator, root_path, path) orelse continue;
            errdefer allocator.free(relative);
            const size = try remote_probe.fileSize(io, allocator, host, path, options);
            const hash = try sha256HexAlloc(io, allocator, host, path, options);
            errdefer allocator.free(hash);
            try entries.append(allocator, .{
                .path = relative,
                .kind = "file",
                .size = size,
                .sha256 = hash,
            });
            file_count += 1;
            total_bytes += size;
        }
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

// 将远程绝对路径折算为 manifest 相对路径，并确保没有逃出根目录。
fn relativePath(allocator: std.mem.Allocator, root_path: []const u8, child_path: []const u8) !?[]const u8 {
    const normalized_root = std.mem.trimEnd(u8, root_path, "/");
    if (std.mem.eql(u8, child_path, normalized_root)) return null;

    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{normalized_root});
    defer allocator.free(prefix);
    if (!std.mem.startsWith(u8, child_path, prefix)) return error.InvalidRemoteManifestPath;
    return try allocator.dupe(u8, child_path[prefix.len..]);
}

// 计算远程文件 SHA-256，并返回堆分配的十六进制字符串。
fn sha256HexAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    options: remote_options.ExecutionOptions,
) ![]const u8 {
    const hash = try remote_probe.sha256FileWithOptions(io, allocator, host, path, options);
    const hex = local_manifest.hexSha256(hash);
    return allocator.dupe(u8, &hex);
}

// 释放字符串切片列表及其中每个字符串。
fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "remote manifest relative paths stay under target root" {
    const nested = (try relativePath(std.testing.allocator, "/srv/app", "/srv/app/config/settings.json")).?;
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("config/settings.json", nested);

    try std.testing.expect((try relativePath(std.testing.allocator, "/srv/app/", "/srv/app")) == null);
    try std.testing.expectError(error.InvalidRemoteManifestPath, relativePath(std.testing.allocator, "/srv/app", "/srv/app-copy/config"));
}
