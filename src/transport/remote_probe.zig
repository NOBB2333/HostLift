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
    if (!validFindKind(kind)) return error.InvalidRemoteFindKind;
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

fn validFindKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "f") or
        std.mem.eql(u8, kind, "d") or
        std.mem.eql(u8, kind, "l") or
        std.mem.eql(u8, kind, "p") or
        std.mem.eql(u8, kind, "s") or
        std.mem.eql(u8, kind, "b") or
        std.mem.eql(u8, kind, "c");
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

// 批量读取远程普通文件大小；输出顺序必须与输入路径完全一致。
pub fn fileSizes(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    paths: []const []const u8,
    options: remote_options.ExecutionOptions,
) ![]u64 {
    if (paths.len == 0) return allocator.alloc(u64, 0);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "stat", "-c", "%s", "--" });
    for (paths) |path| {
        try validation.validatePath(path);
        try argv.append(allocator, path);
    }
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, argv.items, options, 1024 * 1024);
    defer allocator.free(output);

    const sizes = try allocator.alloc(u64, paths.len);
    errdefer allocator.free(sizes);
    var tokens = std.mem.tokenizeAny(u8, output, " \t\r\n");
    for (sizes) |*size| size.* = std.fmt.parseUnsigned(u64, tokens.next() orelse return error.RemoteManifestFailed, 10) catch return error.RemoteManifestFailed;
    if (tokens.next() != null) return error.RemoteManifestFailed;
    return sizes;
}

// 批量读取远程普通文件 SHA-256；拒绝输出缺项、乱序或路径不一致。
pub fn fileHashes(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    paths: []const []const u8,
    options: remote_options.ExecutionOptions,
) ![][32]u8 {
    if (paths.len == 0) return allocator.alloc([32]u8, 0);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "sha256sum", "--" });
    for (paths) |path| {
        try validation.validatePath(path);
        try argv.append(allocator, path);
    }
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, argv.items, options, 1024 * 1024);
    defer allocator.free(output);

    const hashes = try allocator.alloc([32]u8, paths.len);
    errdefer allocator.free(hashes);
    var lines = std.mem.splitScalar(u8, output, '\n');
    for (paths, hashes) |expected_path, *file_hash| {
        const line = std.mem.trimEnd(u8, lines.next() orelse return error.RemoteManifestFailed, "\r");
        if (line.len < 66 or (line[64] != ' ' and line[64] != '*')) return error.RemoteManifestFailed;
        file_hash.* = local_manifest.parseSha256Hex(line[0..64]) catch return error.RemoteManifestFailed;
        const path_offset: usize = if (line[64] == '*') 65 else if (line[65] == ' ' or line[65] == '*') 66 else return error.RemoteManifestFailed;
        if (!std.mem.eql(u8, line[path_offset..], expected_path)) return error.RemoteManifestFailed;
    }
    while (lines.next()) |line| if (std.mem.trim(u8, line, " \t\r").len != 0) return error.RemoteManifestFailed;
    return hashes;
}

// 读取远程符号链接目标并返回目标字节，调用方负责释放。
pub fn readLinkTarget(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    options: remote_options.ExecutionOptions,
) ![]u8 {
    try validation.validatePath(path);
    var argv = [_][]const u8{ "readlink", "--", path };
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, &argv, options, std.fs.max_path_bytes + 1);
    errdefer allocator.free(output);
    if (output.len == 0 or output[output.len - 1] != '\n') return error.RemoteManifestFailed;
    return allocator.realloc(output, output.len - 1);
}
