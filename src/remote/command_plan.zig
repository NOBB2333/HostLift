const std = @import("std");
const schema = @import("schema.zig");
const defaults = @import("defaults.zig");
const remote_options = @import("options.zig");
const risk = @import("risk.zig");
const validation = @import("../security/validation.zig");

// 生成远程命令执行计划，并给命令做基础风险分级。
pub fn buildCommandPlan(
    host: []const u8,
    argv: []const []const u8,
    timeout_seconds: u32,
) !schema.CommandPlan {
    return buildCommandPlanWithOptions(host, argv, .{ .timeout_seconds = timeout_seconds });
}

// 生成带执行选项的远程命令计划。
pub fn buildCommandPlanWithOptions(
    host: []const u8,
    argv: []const []const u8,
    options: remote_options.ExecutionOptions,
) !schema.CommandPlan {
    try validation.validateHost(host);
    if (argv.len == 0) return error.MissingRemoteCommand;
    for (argv) |arg| try validation.validateCommandToken(arg);
    const normalized_options = try remote_options.normalize(options);

    return .{
        .schema_version = schema.command_plan_schema_version,
        .host = host,
        .argv = argv,
        .timeout_seconds = normalized_options.timeout_seconds,
        .retries = normalized_options.retries,
        .ssh_identity_file = normalized_options.ssh_identity_file,
        .credential_source = normalized_options.credential_source,
        .operation_id = normalized_options.operation_id,
        .cancel_file = normalized_options.cancel_file,
        .operation_state_file = normalized_options.operation_state_file,
        .risk = risk.classifyCommand(argv),
        .requires_approval = true,
    };
}

test "command plan accepts safe argv and classifies package commands" {
    var argv = [_][]const u8{ "apt-get", "install", "nginx" };
    const command_plan = try buildCommandPlan("root@192.0.2.10", argv[0..], 0);

    try std.testing.expectEqualStrings(schema.command_plan_schema_version, command_plan.schema_version);
    try std.testing.expectEqual(@as(u32, defaults.default_timeout_seconds), command_plan.timeout_seconds);
    try std.testing.expectEqual(@import("../plan/schema.zig").RiskLevel.medium, command_plan.risk);
    try std.testing.expect(command_plan.requires_approval);
}

test "command plan accepts retry options" {
    var argv = [_][]const u8{ "systemctl", "restart", "nginx" };
    const command_plan = try buildCommandPlanWithOptions("root@192.0.2.10", argv[0..], .{
        .timeout_seconds = 30,
        .retries = 3,
        .ssh_identity_file = "/home/me/.ssh/id_ed25519",
    });

    try std.testing.expectEqual(@as(u32, 30), command_plan.timeout_seconds);
    try std.testing.expectEqual(@as(u8, 3), command_plan.retries);
    try std.testing.expectEqualStrings("/home/me/.ssh/id_ed25519", command_plan.ssh_identity_file.?);
}

test "command plan carries ssh agent credential source" {
    var argv = [_][]const u8{ "whoami" };
    const command_plan = try buildCommandPlanWithOptions("root@192.0.2.10", argv[0..], .{
        .credential_provider = "ssh-agent",
    });

    try std.testing.expect(command_plan.ssh_identity_file == null);
    try std.testing.expectEqual(@import("../credentials/source.zig").SourceKind.ssh_agent, command_plan.credential_source);
}

test "command plan carries operation metadata" {
    var argv = [_][]const u8{ "systemctl", "status", "nginx" };
    const command_plan = try buildCommandPlanWithOptions("root@192.0.2.10", argv[0..], .{
        .operation_id = "OPS-123/remote:1",
        .cancel_file = "/tmp/hostlift-cancel-OPS-123",
        .operation_state_file = "/tmp/hostlift-operation-state.jsonl",
    });

    try std.testing.expectEqualStrings("OPS-123/remote:1", command_plan.operation_id.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-cancel-OPS-123", command_plan.cancel_file.?);
    try std.testing.expectEqualStrings("/tmp/hostlift-operation-state.jsonl", command_plan.operation_state_file.?);
}

test "command plan rejects shell metacharacters" {
    var argv = [_][]const u8{ "sh", "-c", "whoami;id" };
    try std.testing.expectError(error.InvalidRemoteCommandToken, buildCommandPlan("root@192.0.2.10", argv[0..], 60));
}
