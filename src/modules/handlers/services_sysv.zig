const std = @import("std");
const apply_actions = @import("../../apply/actions.zig");
const plan = @import("../../plan/schema.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_options = @import("../../remote/options.zig");
const remote_preflight = @import("../../remote/preflight.zig");
const remote_planner = @import("../../remote/planner.zig");

// SysV init 服务管理工具类型。
const Provider = enum { chkconfig, update_rc_d };

// 执行 SysV init runlevel 收敛动作，按目标机可用 provider 选择 chkconfig 或 update-rc.d。
pub fn apply(ctx: anytype, action: plan.Action) !void {
    const parsed = try apply_actions.parseSysvRef(apply_actions.subject(action));
    const provider = try detectProvider(ctx.io, ctx.allocator, ctx.target_host, ctx.options.execution);
    var command = try commandForProvider(ctx.allocator, provider, action.action_type == .enable_sysv_init, parsed.service, parsed.runlevels);
    defer command.deinit(ctx.allocator);
    const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.options.execution);
    try ctx.stdout.print("  - {s}: {s} {s} {s}\n", .{ action.id, providerName(provider), parsed.service, if (action.action_type == .enable_sysv_init) "enable" else "disable" });
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
}

// 验证 SysV init runlevel 收敛结果。
pub fn verify(ctx: anytype, action: plan.Action) !void {
    const parsed = try apply_actions.parseSysvRef(apply_actions.subject(action));
    const provider = try detectProvider(ctx.io, ctx.allocator, ctx.target_host, ctx.execution);
    try verifyRunlevels(ctx.io, ctx.allocator, ctx.target_host, provider, parsed, action.action_type == .enable_sysv_init, ctx.execution, ctx.stdout, action.id, error.VerifySysvRunlevelMismatch);
}

// 回滚 SysV init runlevel 收敛动作。
pub fn rollback(ctx: anytype, action_type: []const u8, action_id: []const u8, subject: []const u8) !void {
    const parsed = try apply_actions.parseSysvRef(subject);
    const provider = try detectProvider(ctx.io, ctx.allocator, ctx.target_host, ctx.execution);
    var command = try commandForProvider(ctx.allocator, provider, std.mem.eql(u8, action_type, "disable_sysv_init"), parsed.service, parsed.runlevels);
    defer command.deinit(ctx.allocator);
    const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
    try ctx.stdout.print("  - rollback {s}: {s} {s}\n", .{ action_id, providerName(provider), if (std.mem.eql(u8, action_type, "enable_sysv_init")) "disable" else "enable" });
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
}

// 验证 SysV rollback 后的 runlevel 状态。
pub fn verifyRollback(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution: remote_options.ExecutionOptions,
    stdout: anytype,
    action_id: []const u8,
    action_type: []const u8,
    subject: []const u8,
) !void {
    const parsed = try apply_actions.parseSysvRef(subject);
    const provider = try detectProvider(io, allocator, host, execution);
    try verifyRunlevels(io, allocator, host, provider, parsed, std.mem.eql(u8, action_type, "disable_sysv_init"), execution, stdout, action_id, error.RollbackVerifySysvRunlevelMismatch);
}

// 远程探测目标机可用的 SysV init 管理工具。
fn detectProvider(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    execution: remote_options.ExecutionOptions,
) !Provider {
    if (try commandExists(io, allocator, host, "chkconfig", execution)) return .chkconfig;
    if (try commandExists(io, allocator, host, "update-rc.d", execution)) return .update_rc_d;
    return error.RemoteDependencyMissing;
}

// 检测远程主机上是否存在指定命令。
fn commandExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    command: []const u8,
    execution: remote_options.ExecutionOptions,
) !bool {
    const argv = try remote_preflight.commandExistsArgv(command);
    return remote_exec.commandSucceededWithOptions(io, allocator, host, argv[0..], execution);
}

// 根据 provider 类型和 enable/disable 生成对应的 SysV 命令。
fn commandForProvider(
    allocator: std.mem.Allocator,
    provider: Provider,
    enable: bool,
    service: []const u8,
    runlevels: []const u8,
) !apply_actions.Command {
    return switch (provider) {
        .chkconfig => if (enable)
            apply_actions.sysvEnableCommand(allocator, service, runlevels)
        else
            apply_actions.sysvDisableCommand(allocator, service, runlevels),
        .update_rc_d => if (enable)
            apply_actions.sysvUpdateRcDEnableCommand(allocator, service, runlevels)
        else
            apply_actions.sysvUpdateRcDDisableCommand(allocator, service, runlevels),
    };
}

// 返回 SysV provider 的人类可读名称。
fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .chkconfig => "chkconfig",
        .update_rc_d => "update-rc.d",
    };
}

// 逐 runlevel 验证 SysV init 服务是否处于预期启用状态。
fn verifyRunlevels(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    provider: Provider,
    parsed: apply_actions.SysvRef,
    expected_enabled: bool,
    execution: remote_options.ExecutionOptions,
    stdout: anytype,
    action_id: []const u8,
    mismatch_error: anyerror,
) !void {
    var iterator = std.mem.splitScalar(u8, parsed.runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) return error.InvalidSysvInitRef;
        const matches = switch (provider) {
            .chkconfig => try chkconfigRunlevelHasState(io, allocator, host, parsed.service, runlevel, expected_enabled, execution),
            .update_rc_d => try updateRcDRunlevelHasState(io, allocator, host, parsed.service, runlevel, expected_enabled, execution),
        };
        if (!matches) return mismatch_error;
        try stdout.print("  verify {s}: SysV runlevel {s} {s}\n", .{ action_id, runlevel, if (expected_enabled) "on" else "off" });
    }
}

// 通过 chkconfig --list 输出判断服务在指定 runlevel 是否已启用。
fn chkconfigRunlevelHasState(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    service: []const u8,
    runlevel: []const u8,
    expected_enabled: bool,
    execution: remote_options.ExecutionOptions,
) !bool {
    var argv = [_][]const u8{ "chkconfig", "--list", service };
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, argv[0..], execution, 16 * 1024);
    defer allocator.free(output);
    return chkconfigOutputHasState(output, runlevel, expected_enabled);
}

// 通过 rc.d 目录链接判断 update-rc.d 管理的服务是否已启用。
fn updateRcDRunlevelHasState(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    service: []const u8,
    runlevel: []const u8,
    expected_enabled: bool,
    execution: remote_options.ExecutionOptions,
) !bool {
    if (runlevel.len != 1 or runlevel[0] < '2' or runlevel[0] > '5') return error.InvalidSysvInitRef;
    const directory = try std.fmt.allocPrint(allocator, "/etc/rc{s}.d", .{runlevel});
    defer allocator.free(directory);
    var argv = [_][]const u8{ "ls", directory };
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, argv[0..], execution, 16 * 1024);
    defer allocator.free(output);
    return sysvDirectoryListingHasPrefix(output, 'S', service) == expected_enabled;
}

// 检查 rc.d 目录列表中是否有以指定前缀开头的条目匹配服务名。
fn sysvDirectoryListingHasPrefix(output: []const u8, prefix: u8, service: []const u8) bool {
    var iterator = std.mem.tokenizeAny(u8, output, "\r\n\t ");
    while (iterator.next()) |entry| {
        if (entry.len < 4 or entry[0] != prefix) continue;
        if (!std.ascii.isDigit(entry[1]) or !std.ascii.isDigit(entry[2])) continue;
        if (std.mem.eql(u8, entry[3..], service)) return true;
    }
    return false;
}

// 解析 chkconfig --list 输出，检查指定 runlevel 的开/关状态。
fn chkconfigOutputHasState(output: []const u8, runlevel: []const u8, expected_enabled: bool) bool {
    var pattern_buf: [16]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{s}:{s}", .{ runlevel, if (expected_enabled) "on" else "off" }) catch return false;
    return std.mem.indexOf(u8, output, pattern) != null;
}

test "SysV directory listing parser matches update-rc.d links" {
    try std.testing.expect(sysvDirectoryListingHasPrefix("K01legacy\nS20legacy\n", 'S', "legacy"));
    try std.testing.expect(!sysvDirectoryListingHasPrefix("K01legacy\n", 'S', "legacy"));
    try std.testing.expect(!sysvDirectoryListingHasPrefix("S20other\n", 'S', "legacy"));
}

test "chkconfig output parser matches runlevel state" {
    const output = "legacy 0:off 1:off 2:on 3:on 4:off 5:on 6:off\n";
    try std.testing.expect(chkconfigOutputHasState(output, "2", true));
    try std.testing.expect(chkconfigOutputHasState(output, "4", false));
    try std.testing.expect(!chkconfigOutputHasState(output, "5", false));
}
