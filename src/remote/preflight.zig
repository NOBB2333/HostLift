const std = @import("std");
const options_mod = @import("options.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const validation = @import("../security/validation.zig");

// 远程依赖预检项，描述目标主机必须具备的命令。
pub const Check = struct {
    host: []const u8,
    commands: []const []const u8,
    any_commands: []const []const []const u8 = &.{},
};

// 根据远程命令计划推导目标机必须具备的入口命令。
pub fn commandCheck(command_plan: schema.CommandPlan) Check {
    const command = if (command_plan.argv.len > 0) command_plan.argv[0] else "";
    return .{
        .host = command_plan.host,
        .commands = if (command.len > 0)
            command_plan.argv[0..1]
        else
            &.{},
    };
}

// 根据传输计划推导远程目标机必须具备的命令。
pub fn transferTargetCheck(transfer_plan: schema.TransferPlan) Check {
    return .{
        .host = transfer_plan.host,
        .commands = if (transfer_plan.transport == .chunk)
            &.{ "mkdir", "rsync", "find", "stat", "sha256sum" }
        else if (transfer_plan.verify_checksum)
            &.{"sha256sum"}
        else
            &.{},
    };
}

// 根据传输计划推导远程源机器必须具备的命令。
pub fn transferSourceCheck(transfer_plan: schema.TransferPlan) ?Check {
    const source_host = transfer_plan.source_host orelse return null;
    return .{
        .host = source_host,
        .commands = if (transfer_plan.verify_checksum)
            &.{"sha256sum"}
        else
            &.{},
    };
}

// 生成 command -v 形式的远程依赖检查 argv。
pub fn commandExistsArgv(command: []const u8) ![3][]const u8 {
    try validation.validateCommandToken(command);
    return .{ "command", "-v", command };
}

// 执行远程依赖预检；任一命令缺失都会失败关闭。
pub fn runCheck(
    io: std.Io,
    allocator: std.mem.Allocator,
    check: Check,
    options: options_mod.ExecutionOptions,
) !void {
    if (check.commands.len == 0 and check.any_commands.len == 0) return;
    try validation.validateHost(check.host);
    for (check.commands) |command| {
        const argv = try commandExistsArgv(command);
        const ok = try probe.commandSucceededWithOptions(io, allocator, check.host, argv[0..], options);
        if (!ok) return error.RemoteDependencyMissing;
    }
    for (check.any_commands) |group| {
        if (!try anyCommandExists(io, allocator, check.host, group, options)) return error.RemoteDependencyMissing;
    }
}

// 检查一组替代命令中是否有任一存在。
fn anyCommandExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    commands: []const []const u8,
    options: options_mod.ExecutionOptions,
) !bool {
    if (commands.len == 0) return false;
    for (commands) |command| {
        const argv = try commandExistsArgv(command);
        if (try probe.commandSucceededWithOptions(io, allocator, host, argv[0..], options)) return true;
    }
    return false;
}

test "transfer preflight requires sha256sum for checksum verification" {
    const transfer_plan = schema.TransferPlan{
        .schema_version = schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/tmp/app.tar",
        .target_path = "/opt/app.tar",
        .preserve_metadata = true,
        .verify_checksum = true,
        .risk = .medium,
        .requires_approval = true,
    };

    const check = transferTargetCheck(transfer_plan);
    try std.testing.expectEqualStrings("root@192.0.2.10", check.host);
    try std.testing.expectEqual(@as(usize, 1), check.commands.len);
    try std.testing.expectEqualStrings("sha256sum", check.commands[0]);
}

test "transfer preflight requires chunk target commands" {
    const transfer_plan = schema.TransferPlan{
        .schema_version = schema.transfer_plan_schema_version,
        .host = "root@192.0.2.10",
        .source_path = "/srv/app",
        .target_path = "/srv/app",
        .recursive = true,
        .preserve_metadata = true,
        .verify_checksum = false,
        .transport = .chunk,
        .risk = .high,
        .requires_approval = true,
    };

    const check = transferTargetCheck(transfer_plan);
    try std.testing.expectEqualStrings("root@192.0.2.10", check.host);
    try std.testing.expectEqual(@as(usize, 5), check.commands.len);
    try std.testing.expectEqualStrings("mkdir", check.commands[0]);
    try std.testing.expectEqualStrings("rsync", check.commands[1]);
    try std.testing.expectEqualStrings("find", check.commands[2]);
    try std.testing.expectEqualStrings("stat", check.commands[3]);
    try std.testing.expectEqualStrings("sha256sum", check.commands[4]);
}

test "remote command preflight checks argv entrypoint" {
    var command_argv = [_][]const u8{ "systemctl", "restart", "nginx" };
    const command_plan = schema.CommandPlan{
        .schema_version = schema.command_plan_schema_version,
        .host = "root@192.0.2.10",
        .argv = command_argv[0..],
        .timeout_seconds = 60,
        .risk = .medium,
        .requires_approval = true,
    };

    const check = commandCheck(command_plan);
    try std.testing.expectEqualStrings("root@192.0.2.10", check.host);
    try std.testing.expectEqual(@as(usize, 1), check.commands.len);
    try std.testing.expectEqualStrings("systemctl", check.commands[0]);
}

test "preflight check can express alternative command providers" {
    const alternatives = [_][]const u8{ "chkconfig", "update-rc.d" };
    const groups = [_][]const []const u8{ alternatives[0..] };
    const check = Check{
        .host = "root@192.0.2.10",
        .commands = &.{"command"},
        .any_commands = groups[0..],
    };

    try std.testing.expectEqual(@as(usize, 1), check.commands.len);
    try std.testing.expectEqual(@as(usize, 1), check.any_commands.len);
    try std.testing.expectEqual(@as(usize, 2), check.any_commands[0].len);
    try std.testing.expectEqualStrings("chkconfig", check.any_commands[0][0]);
    try std.testing.expectEqualStrings("update-rc.d", check.any_commands[0][1]);
}

test "command existence argv is structured and rejects unsafe names" {
    const argv = try commandExistsArgv("sha256sum");
    try std.testing.expectEqualStrings("command", argv[0]);
    try std.testing.expectEqualStrings("-v", argv[1]);
    try std.testing.expectEqualStrings("sha256sum", argv[2]);
    try std.testing.expectError(error.InvalidRemoteCommandToken, commandExistsArgv("sha256sum;rm"));
}
