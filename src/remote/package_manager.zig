const std = @import("std");
const inventory_schema = @import("../inventory/schema.zig");
const remote_options = @import("options.zig");
const probe = @import("probe.zig");

// 探测远端主机可用的包管理器，用于 rollback 和远程验证。
pub fn detect(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution_options: remote_options.ExecutionOptions,
) !inventory_schema.PackageManagerKind {
    if (try executableExists(io, allocator, host, "apt-get", execution_options)) return .apt;
    if (try executableExists(io, allocator, host, "dnf", execution_options)) return .dnf;
    if (try executableExists(io, allocator, host, "yum", execution_options)) return .yum;
    if (try executableExists(io, allocator, host, "zypper", execution_options)) return .zypper;
    if (try executableExists(io, allocator, host, "pacman", execution_options)) return .pacman;
    return error.UnsupportedPackageManager;
}

// 通过远程 command -v 检查指定可执行文件是否存在。
fn executableExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    command: []const u8,
    execution_options: remote_options.ExecutionOptions,
) !bool {
    var argv = [_][]const u8{ "command", "-v", command };
    return probe.commandSucceededWithOptions(io, allocator, host, argv[0..], execution_options);
}
