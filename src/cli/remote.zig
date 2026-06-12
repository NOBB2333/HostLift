const std = @import("std");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const remote_planner = @import("../remote/planner.zig");
const json_util = @import("../util/json.zig");

// remote 子命令入口，目前只分发 exec。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    if (args.len == 0) return error.MissingRemoteSubcommand;
    if (!std.mem.eql(u8, args[0], "exec")) return error.UnknownRemoteSubcommand;
    try exec(io, allocator, args[1..], stdout, stderr);
}

// 构建或执行远程命令计划；没有 --approve 时只输出 JSON plan。
fn exec(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    var host: ?[]const u8 = null;
    var timeout_seconds = remote_planner.default_timeout_seconds;
    var retries: u8 = remote_options.default_retries;
    var identity_file: ?[]const u8 = null;
    var credential_provider: ?[]const u8 = null;
    var operation_id: ?[]const u8 = null;
    var cancel_file: ?[]const u8 = null;
    var operation_state_file: ?[]const u8 = null;
    var approve = false;
    var allow_critical = false;
    var command_start: ?usize = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--host")) {
            index += 1;
            if (index >= args.len) return error.MissingRemoteHost;
            host = args[index];
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            index += 1;
            if (index >= args.len) return error.MissingTimeout;
            timeout_seconds = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--retries")) {
            index += 1;
            if (index >= args.len) return error.MissingRetries;
            retries = try std.fmt.parseUnsigned(u8, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            index += 1;
            if (index >= args.len) return error.MissingIdentityFile;
            identity_file = args[index];
        } else if (std.mem.eql(u8, arg, "--credential-provider")) {
            index += 1;
            if (index >= args.len) return error.MissingCredentialProvider;
            credential_provider = args[index];
        } else if (std.mem.eql(u8, arg, "--operation-id")) {
            index += 1;
            if (index >= args.len) return error.MissingRemoteOperationId;
            operation_id = args[index];
        } else if (std.mem.eql(u8, arg, "--cancel-file")) {
            index += 1;
            if (index >= args.len) return error.MissingRemoteCancelFile;
            cancel_file = args[index];
        } else if (std.mem.eql(u8, arg, "--operation-state")) {
            index += 1;
            if (index >= args.len) return error.MissingOperationStatePath;
            operation_state_file = args[index];
        } else if (std.mem.eql(u8, arg, "--approve")) {
            approve = true;
        } else if (std.mem.eql(u8, arg, "--allow-critical")) {
            allow_critical = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            command_start = index + 1;
            break;
        } else {
            return error.UnknownRemoteExecArgument;
        }
    }

    const start = command_start orelse return error.MissingRemoteCommand;
    const command_argv = args[start..];
    const command_plan = try remote_planner.buildCommandPlanWithOptions(
        host orelse return error.MissingRemoteHost,
        command_argv,
        .{
            .timeout_seconds = timeout_seconds,
            .retries = retries,
            .ssh_identity_file = identity_file,
            .credential_provider = credential_provider,
            .operation_id = operation_id,
            .cancel_file = cancel_file,
            .operation_state_file = operation_state_file,
        },
    );

    if (!approve) {
        try json_util.writeCommandPlan(stdout, command_plan);
        return;
    }
    if (command_plan.risk == .critical and !allow_critical) return error.CriticalRemoteCommandRequiresAllowCritical;
    try remote_exec.executePlan(io, allocator, command_plan, stdout, stderr);
}
