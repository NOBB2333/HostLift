const std = @import("std");
const backend_rules = @import("backend.zig");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const remote_planner = @import("../remote/planner.zig");
const transport_runner = @import("../transport/runner.zig");

pub const Backend = backend_rules.Backend;

// 防火墙恢复选项，控制是否启用和恢复时间窗口。
pub const RecoveryOptions = struct {
    enabled: bool = false,
    window_seconds: u32 = 90,
};

// 防火墙恢复任务，保存远端脚本路径和 systemd unit 名称。
pub const RecoveryJob = struct {
    script_path: []const u8,
    unit_name: []const u8,

    // 释放防火墙恢复任务中分配的路径和 unit 名称。
    pub fn deinit(job: RecoveryJob, allocator: std.mem.Allocator) void {
        allocator.free(job.script_path);
        allocator.free(job.unit_name);
    }
};

// 在远程主机上安排延迟防火墙恢复任务。
pub fn schedule(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    backend: Backend,
    config_path: []const u8,
    window_seconds: u32,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !RecoveryJob {
    if (window_seconds < 10 or window_seconds > 3600) return error.InvalidFirewallRecoveryWindow;
    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    const script_path = try std.fmt.allocPrint(allocator, "/tmp/hostlift-firewall-recovery-{d}.sh", .{timestamp});
    errdefer allocator.free(script_path);
    const unit_name = try std.fmt.allocPrint(allocator, "hostlift-firewall-recovery-{d}", .{timestamp});
    errdefer allocator.free(unit_name);
    const script_body = try backend_rules.recoveryScriptAlloc(allocator, backend, config_path);
    defer allocator.free(script_body);

    try writeRemoteFile(io, allocator, host, script_path, script_body, stdout, stderr, execution_options);
    var chmod_argv = [_][]const u8{ "chmod", "700", script_path };
    const chmod_plan = try remote_planner.buildCommandPlanWithOptions(host, chmod_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, chmod_plan, stdout, stderr);

    var start_argv: std.ArrayList([]const u8) = .empty;
    defer {
        if (start_argv.items.len >= 3) {
            allocator.free(start_argv.items[1]);
            allocator.free(start_argv.items[2]);
        }
        start_argv.deinit(allocator);
    }
    try backend_rules.appendSystemdRunRecoveryArgv(allocator, &start_argv, unit_name, script_path, window_seconds);
    const start_plan = try remote_planner.buildCommandPlanWithOptions(host, start_argv.items, execution_options);
    try stdout.print("  firewall recovery scheduled in {d}s: {s}\n", .{ window_seconds, script_path });
    try remote_exec.executePlan(io, allocator, start_plan, stdout, stderr);
    return .{ .script_path = script_path, .unit_name = unit_name };
}

// 取消已安排的远程防火墙恢复任务并删除临时脚本。
pub fn cancel(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    job: RecoveryJob,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const timer_unit = try std.fmt.allocPrint(allocator, "{s}.timer", .{job.unit_name});
    defer allocator.free(timer_unit);
    const service_unit = try std.fmt.allocPrint(allocator, "{s}.service", .{job.unit_name});
    defer allocator.free(service_unit);
    var stop_argv = [_][]const u8{ "systemctl", "stop", timer_unit, service_unit };
    const stop_plan = try remote_planner.buildCommandPlanWithOptions(host, stop_argv[0..], execution_options);
    try stdout.print("  firewall recovery cancelled: {s}\n", .{job.unit_name});
    try remote_exec.executePlan(io, allocator, stop_plan, stdout, stderr);

    var rm_argv = [_][]const u8{ "rm", "-f", job.script_path };
    const rm_plan = try remote_planner.buildCommandPlanWithOptions(host, rm_argv[0..], execution_options);
    try remote_exec.executePlan(io, allocator, rm_plan, stdout, stderr);
}

// 通过 scp 将本地内容写入远程主机指定路径。
fn writeRemoteFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    remote_path: []const u8,
    content: []const u8,
    stdout: anytype,
    stderr: anytype,
    execution_options: remote_options.ExecutionOptions,
) !void {
    const local_path = try std.fmt.allocPrint(allocator, "/tmp/hostlift-firewall-recovery-local-{d}.sh", .{std.Io.Timestamp.now(io, .real).toSeconds()});
    defer allocator.free(local_path);
    var file = try std.Io.Dir.cwd().createFile(io, local_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(content);
    try writer.flush();
    defer std.Io.Dir.cwd().deleteFile(io, local_path) catch {};

    const remote_target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ host, remote_path });
    defer allocator.free(remote_target);
    var scp_argv: std.ArrayList([]const u8) = .empty;
    defer scp_argv.deinit(allocator);
    try scp_argv.append(allocator, "scp");
    if (execution_options.ssh_identity_file) |path| try scp_argv.appendSlice(allocator, &.{ "-i", path });
    try scp_argv.appendSlice(allocator, &.{ local_path, remote_target });
    try transport_runner.runWithRetries(io, allocator, scp_argv.items, execution_options.timeout_seconds, execution_options.retries, stdout, stderr);
}
