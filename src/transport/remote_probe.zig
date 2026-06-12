const std = @import("std");
const local_manifest = @import("../manifest/local.zig");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const validation = @import("../security/validation.zig");

// 读取远程文件 SHA-256。
pub fn sha256File(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
) ![32]u8 {
    return sha256FileWithOptions(io, allocator, host, path, .{});
}

// 读取远程文件 SHA-256，并使用指定 SSH 执行选项。
pub fn sha256FileWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    options: remote_options.ExecutionOptions,
) ![32]u8 {
    try validation.validateHost(host);
    try validation.validatePath(path);
    const normalized_options = try remote_options.normalize(options);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try remote_exec.appendSshPrefix(allocator, &argv, normalized_options.ssh_identity_file, null, host);
    try argv.appendSlice(allocator, &.{ "sha256sum", path });
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = remote_options.ioTimeout(normalized_options.timeout_seconds),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.RemoteChecksumFailed,
        else => return error.RemoteChecksumFailed,
    }

    var tokens = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    const hash_text = tokens.next() orelse return error.RemoteChecksumFailed;
    return local_manifest.parseSha256Hex(hash_text);
}

// 用远程 find 列出文件或目录；返回路径后仍会再次做本地 path 校验。
pub fn findPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    root_path: []const u8,
    kind: []const u8,
    options: remote_options.ExecutionOptions,
) ![][]const u8 {
    try validation.validateHost(host);
    try validation.validatePath(root_path);
    if (!std.mem.eql(u8, kind, "f") and !std.mem.eql(u8, kind, "d")) return error.InvalidRemoteFindKind;
    const normalized_options = try remote_options.normalize(options);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try remote_exec.appendSshPrefix(allocator, &argv, normalized_options.ssh_identity_file, null, host);
    try argv.appendSlice(allocator, &.{ "find", root_path, "-type", kind, "-print" });
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = remote_options.ioTimeout(normalized_options.timeout_seconds),
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.RemoteManifestFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.RemoteManifestFailed;
        },
    }

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
        allocator.free(result.stdout);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        try validation.validatePath(line);
        try paths.append(allocator, try allocator.dupe(u8, line));
    }

    allocator.free(result.stdout);
    return paths.toOwnedSlice(allocator);
}

// 读取远程文件大小，供远程 manifest 构建使用。
pub fn fileSize(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    options: remote_options.ExecutionOptions,
) !u64 {
    try validation.validateHost(host);
    try validation.validatePath(path);
    const normalized_options = try remote_options.normalize(options);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try remote_exec.appendSshPrefix(allocator, &argv, normalized_options.ssh_identity_file, null, host);
    try argv.appendSlice(allocator, &.{ "stat", "-c", "%s", path });
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = remote_options.ioTimeout(normalized_options.timeout_seconds),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.RemoteManifestFailed,
        else => return error.RemoteManifestFailed,
    }

    const size_text = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.fmt.parseUnsigned(u64, size_text, 10) catch error.RemoteManifestFailed;
}
