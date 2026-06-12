const std = @import("std");
const backend_rules = @import("backend.zig");
const recovery = @import("recovery.zig");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const remote_planner = @import("../remote/planner.zig");

pub const Backend = backend_rules.Backend;
pub const RecoveryOptions = recovery.RecoveryOptions;

// 根据防火墙配置路径推断对应 backend。
pub fn inferBackendFromPath(path: []const u8) !Backend {
    return backend_rules.inferFromPath(path);
}

// 根据 backend 生成远程恢复脚本内容。
pub fn recoveryScriptAlloc(allocator: std.mem.Allocator, backend: Backend, config_path: []const u8) ![]const u8 {
    return backend_rules.recoveryScriptAlloc(allocator, backend, config_path);
}

// 构造 systemd-run 延迟恢复命令 argv。
pub fn appendSystemdRunRecoveryArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    unit_name: []const u8,
    script_path: []const u8,
    window_seconds: u32,
) !void {
    return backend_rules.appendSystemdRunRecoveryArgv(allocator, argv, unit_name, script_path, window_seconds);
}

// 对已复制的防火墙配置做 SSH 端口预检、语法检查、reload 和 SSH post-check。
pub fn reloadConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    config_path: []const u8,
    ssh_port: u16,
    stdout: anytype,
    stderr: anytype,
) !void {
    return reloadConfigWithOptions(io, allocator, host, config_path, ssh_port, stdout, stderr, .{}, .{});
}

// 对已复制的防火墙配置做预检、语法检查、reload 和 SSH post-check，使用指定执行选项。
pub fn reloadConfigWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    config_path: []const u8,
    ssh_port: u16,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
    recovery_options: RecoveryOptions,
) !void {
    _ = try remote_options.normalize(execution_options);
    const backend = try inferBackendFromPath(config_path);
    try stdout.print("  firewall reload preflight [{s}] ssh_port={d}\n", .{ @tagName(backend), ssh_port });
    try preflightSshPort(io, allocator, host, config_path, ssh_port, execution_options);
    try validateConfig(io, allocator, host, backend, config_path, stdout, stderr, execution_options);
    const recovery_job = if (recovery_options.enabled)
        try recovery.schedule(io, allocator, host, backend, config_path, recovery_options.window_seconds, stdout, stderr, execution_options)
    else
        null;
    defer if (recovery_job) |value| value.deinit(allocator);

    try reloadBackend(io, allocator, host, backend, config_path, stdout, stderr, execution_options);

    var postcheck_argv = [_][]const u8{"true"};
    const postcheck_plan = try remote_planner.buildCommandPlanWithOptions(host, postcheck_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, postcheck_plan, stdout, stderr);
    if (recovery_job) |value| try recovery.cancel(io, allocator, host, value, stdout, stderr, execution_options);
}

// reload 前检查防火墙配置文本中是否包含预期 SSH 端口。
fn preflightSshPort(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    config_path: []const u8,
    ssh_port: u16,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{ssh_port});
    defer allocator.free(port_text);
    var grep_argv = [_][]const u8{ "grep", "-R", port_text, config_path };
    if (!try remote_exec.commandSucceededWithOptions(io, allocator, host, grep_argv[0..], execution_options)) return error.FirewallSshPortNotFound;
}

// 对复制后的防火墙配置运行 backend-specific 语法检查。
fn validateConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    backend: Backend,
    config_path: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const argv = backend_rules.validationArgv(backend, config_path);
    const command_plan = try remote_planner.buildCommandPlanWithOptions(host, argv.slice(), execution_options);
    try remote_exec.executePlan(io, allocator, command_plan, stdout, stderr);
}

// 调用对应 backend 的 reload 命令应用防火墙配置。
fn reloadBackend(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    backend: Backend,
    config_path: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const argv = backend_rules.reloadArgv(backend, config_path);
    const command_plan = try remote_planner.buildCommandPlanWithOptions(host, argv.slice(), execution_options);
    try remote_exec.executePlan(io, allocator, command_plan, stdout, stderr);
}
