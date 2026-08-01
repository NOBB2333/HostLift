const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const remote_options = @import("../remote/options.zig");
const remote_probe = @import("remote_probe.zig");
const validation = @import("../security/validation.zig");

const remote_file_batch_size = 32;

const RemoteEntryKind = struct {
    find_kind: []const u8,
    manifest_kind: []const u8,
};

const remote_special_kinds = [_]RemoteEntryKind{
    .{ .find_kind = "p", .manifest_kind = "named_pipe" },
    .{ .find_kind = "s", .manifest_kind = "unix_domain_socket" },
    .{ .find_kind = "b", .manifest_kind = "block_device" },
    .{ .find_kind = "c", .manifest_kind = "character_device" },
};

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
    if (max_entries == 0) return error.InvalidManifestEntryLimit;
    try validation.validateHost(host);
    try validation.validatePath(root_path);
    _ = try remote_options.normalize(options);

    if (!try @import("../remote/exec.zig").pathIsDirectoryWithOptions(io, allocator, host, root_path, options)) {
        return buildRemoteSinglePath(io, allocator, host, root_path, options);
    }

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
        var offset: usize = 0;
        while (offset < files.len and entries.items.len < max_entries) {
            const available = max_entries - entries.items.len;
            const batch_len = @min(@min(remote_file_batch_size, files.len - offset), available);
            const batch = files[offset .. offset + batch_len];
            const sizes = try remote_probe.fileSizes(io, allocator, host, batch, options);
            defer allocator.free(sizes);
            const hashes = try remote_probe.fileHashes(io, allocator, host, batch, options);
            defer allocator.free(hashes);
            for (batch, sizes, hashes) |path, size, file_hash| {
                const relative = try relativePath(allocator, root_path, path) orelse continue;
                errdefer allocator.free(relative);
                const hash_text = local_manifest.hexSha256(file_hash);
                const owned_hash = try allocator.dupe(u8, &hash_text);
                errdefer allocator.free(owned_hash);
                try entries.append(allocator, .{
                    .path = relative,
                    .kind = "file",
                    .size = size,
                    .sha256 = owned_hash,
                });
                file_count += 1;
                total_bytes += size;
            }
            offset += batch_len;
        }
        if (offset < files.len) truncated = true;
    }

    if (!truncated) {
        const links = try remote_probe.findPaths(io, allocator, host, root_path, "l", options);
        defer freeStringSlice(allocator, links);
        for (links) |path| {
            if (entries.items.len >= max_entries) {
                truncated = true;
                break;
            }
            const relative = try relativePath(allocator, root_path, path) orelse continue;
            errdefer allocator.free(relative);
            const target = try remote_probe.readLinkTarget(io, allocator, host, path, options);
            defer allocator.free(target);
            const link_hash = try @import("../manifest/hash.zig").sha256BytesHexAlloc(allocator, target);
            errdefer allocator.free(link_hash);
            try entries.append(allocator, .{
                .path = relative,
                .kind = "sym_link",
                .size = target.len,
                .sha256 = link_hash,
            });
        }
    }

    if (!truncated) {
        for (remote_special_kinds) |kind| {
            const paths = try remote_probe.findPaths(io, allocator, host, root_path, kind.find_kind, options);
            defer freeStringSlice(allocator, paths);
            for (paths) |path| {
                if (entries.items.len >= max_entries) {
                    truncated = true;
                    break;
                }
                const relative = try relativePath(allocator, root_path, path) orelse continue;
                errdefer allocator.free(relative);
                try entries.append(allocator, .{
                    .path = relative,
                    .kind = kind.manifest_kind,
                    .size = 0,
                    .sha256 = null,
                });
            }
            if (truncated) break;
        }
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

fn buildRemoteSinglePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    root_path: []const u8,
    options: remote_options.ExecutionOptions,
) !local_manifest.Manifest {
    var link_argv = [_][]const u8{ "test", "-L", root_path };
    if (try @import("../remote/exec.zig").commandSucceededWithOptions(io, allocator, host, &link_argv, options)) {
        const target = try remote_probe.readLinkTarget(io, allocator, host, root_path, options);
        defer allocator.free(target);
        const link_hash = try @import("../manifest/hash.zig").sha256BytesHexAlloc(allocator, target);
        errdefer allocator.free(link_hash);
        const entries = try allocator.alloc(local_manifest.Entry, 1);
        errdefer allocator.free(entries);
        const entry_path = try allocator.dupe(u8, ".");
        errdefer allocator.free(entry_path);
        entries[0] = .{
            .path = entry_path,
            .kind = "sym_link",
            .size = target.len,
            .sha256 = link_hash,
        };
        const owned_root = try allocator.dupe(u8, root_path);
        return .{
            .root = owned_root,
            .entries = entries,
            .file_count = 0,
            .dir_count = 0,
            .total_bytes = 0,
            .truncated = false,
        };
    }

    var file_argv = [_][]const u8{ "test", "-f", root_path };
    if (!try @import("../remote/exec.zig").commandSucceededWithOptions(io, allocator, host, &file_argv, options)) return error.UnsupportedRemoteManifestRoot;
    const size = try remote_probe.fileSize(io, allocator, host, root_path, options);
    const file_hash = try sha256HexAlloc(io, allocator, host, root_path, options);
    errdefer allocator.free(file_hash);
    const entries = try allocator.alloc(local_manifest.Entry, 1);
    errdefer allocator.free(entries);
    const entry_path = try allocator.dupe(u8, ".");
    errdefer allocator.free(entry_path);
    entries[0] = .{
        .path = entry_path,
        .kind = "file",
        .size = size,
        .sha256 = file_hash,
    };
    const owned_root = try allocator.dupe(u8, root_path);
    return .{
        .root = owned_root,
        .entries = entries,
        .file_count = 1,
        .dir_count = 0,
        .total_bytes = size,
        .truncated = false,
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
