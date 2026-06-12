const std = @import("std");
const remote_options = @import("options.zig");
const planner = @import("planner.zig");
const runner = @import("runner.zig");
const ssh_argv = @import("ssh_argv.zig");

// 通过远程 test -e 判断路径是否存在。
pub fn pathExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
) !bool {
    return pathExistsWithOptions(io, allocator, host, path, .{});
}

// 通过远程 test -e 判断路径是否存在，并使用指定 SSH 执行选项。
pub fn pathExistsWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    options: remote_options.ExecutionOptions,
) !bool {
    return testPath(io, allocator, host, path, "-e", options);
}

// 通过远程 test -d 判断路径是否是目录。
pub fn pathIsDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
) !bool {
    return pathIsDirectoryWithOptions(io, allocator, host, path, .{});
}

// 通过远程 test -d 判断路径是否是目录，并使用指定 SSH 执行选项。
pub fn pathIsDirectoryWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    options: remote_options.ExecutionOptions,
) !bool {
    return testPath(io, allocator, host, path, "-d", options);
}

// 执行一个短远程命令，并只关心退出状态是否成功。
pub fn commandSucceeded(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    argv: []const []const u8,
) !bool {
    return commandSucceededWithOptions(io, allocator, host, argv, .{});
}

// 执行一个短远程命令，并只关心退出状态是否成功。
pub fn commandSucceededWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    argv: []const []const u8,
    options: remote_options.ExecutionOptions,
) !bool {
    _ = try planner.buildCommandPlan(host, argv, planner.default_timeout_seconds);
    const normalized_options = try remote_options.normalize(options);

    var command_argv: std.ArrayList([]const u8) = .empty;
    defer command_argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &command_argv, normalized_options.ssh_identity_file, null, host);
    try command_argv.appendSlice(allocator, argv);

    return exitCodeMeansSuccess(try runner.runForExitCode(io, allocator, command_argv.items, normalized_options.timeout_seconds));
}

// 执行一个短远程命令并返回 stdout；调用方负责释放返回 buffer。
pub fn commandOutputWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    argv: []const []const u8,
    options: remote_options.ExecutionOptions,
    stdout_limit: usize,
) ![]u8 {
    _ = try planner.buildCommandPlan(host, argv, planner.default_timeout_seconds);
    const normalized_options = try remote_options.normalize(options);

    var command_argv: std.ArrayList([]const u8) = .empty;
    defer command_argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &command_argv, normalized_options.ssh_identity_file, null, host);
    try command_argv.appendSlice(allocator, argv);

    return runner.runForOutput(io, allocator, command_argv.items, normalized_options.timeout_seconds, stdout_limit);
}

// 通过远程 test 命令检测路径属性。
fn testPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    flag: []const u8,
    options: remote_options.ExecutionOptions,
) !bool {
    try planner.validateHost(host);
    try planner.validatePath(path);
    const normalized_options = try remote_options.normalize(options);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &argv, normalized_options.ssh_identity_file, null, host);
    try argv.appendSlice(allocator, &.{ "test", flag, path });

    return exitCodeMeansSuccess(try runner.runForExitCode(io, allocator, argv.items, normalized_options.timeout_seconds));
}

// 将远程命令退出码转换为成功/失败布尔值。
fn exitCodeMeansSuccess(code: u8) !bool {
    return switch (code) {
        0 => true,
        1 => false,
        else => error.RemoteCommandFailed,
    };
}
