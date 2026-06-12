const std = @import("std");
const preflight = @import("preflight.zig");
const probe = @import("probe.zig");
const runner = @import("runner.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const ssh_argv = @import("ssh_argv.zig");

pub const appendSshPrefix = ssh_argv.appendSshPrefix;
pub const commandSucceeded = probe.commandSucceeded;
pub const commandSucceededWithOptions = probe.commandSucceededWithOptions;
pub const commandOutputWithOptions = probe.commandOutputWithOptions;
pub const pathExists = probe.pathExists;
pub const pathExistsWithOptions = probe.pathExistsWithOptions;
pub const pathIsDirectory = probe.pathIsDirectory;
pub const pathIsDirectoryWithOptions = probe.pathIsDirectoryWithOptions;

// 执行已经通过 remote planner 校验的 SSH 命令计划。
pub fn executePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    command_plan: schema.CommandPlan,
    stdout: anytype,
    stderr: anytype,
) !void {
    try preflight.runCheck(io, allocator, preflight.commandCheck(command_plan), .{
        .timeout_seconds = command_plan.timeout_seconds,
        .retries = command_plan.retries,
        .ssh_identity_file = command_plan.ssh_identity_file,
        .operation_id = command_plan.operation_id,
        .cancel_file = command_plan.cancel_file,
        .operation_state_file = command_plan.operation_state_file,
    });

    const connect_timeout = try std.fmt.allocPrint(allocator, "ConnectTimeout={d}", .{command_plan.timeout_seconds});
    defer allocator.free(connect_timeout);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &argv, command_plan.ssh_identity_file, connect_timeout, command_plan.host);
    try argv.appendSlice(allocator, command_plan.argv);

    try runner.runWithSession(
        io,
        allocator,
        argv.items,
        command_plan.timeout_seconds,
        command_plan.retries,
        try session.controlWithState(command_plan.operation_id, command_plan.cancel_file, command_plan.operation_state_file),
        stdout,
        stderr,
    );
}
