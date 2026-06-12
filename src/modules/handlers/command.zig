const std = @import("std");
const plan = @import("../../plan/schema.zig");
const rollback_manifest = @import("../../rollback/manifest.zig");
const handler = @import("../handler.zig");

const apply_actions = @import("../../apply/actions.zig");
const package_provider = @import("../../apply/action/package_provider.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_package_manager = @import("../../remote/package_manager.zig");
const remote_planner = @import("../../remote/planner.zig");

// 声明命令型 action 在目标机器执行前需要具备的入口命令。
pub fn applyRequirements(ctx: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    return switch (action.action_type) {
        .install_package => packageInstallCommands(ctx.migration_plan),
        .enable_systemd_unit => &.{"systemctl"},
        .create_group => &.{ "groupadd", "getent" },
        .create_user => &.{ "useradd", "getent" },
        .start_compose_project, .verify_compose_project => &.{"docker"},
        else => &.{},
    };
}

// 执行命令型迁移动作，统一走安全 argv 和 remote command plan。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    var command = try apply_actions.commandForAction(ctx.allocator, ctx.migration_plan, action);
    defer command.deinit(ctx.allocator);

    const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.options.execution);
    try ctx.stdout.print("  - {s}: ", .{action.id});
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
    return .{ .changed = action.action_type != .verify_compose_project };
}

// 验证命令型 action 的最小可观测结果。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    switch (action.action_type) {
        .install_package => {
            const package = apply_actions.subject(action);
            if (package.len == 0) return error.MissingApplySubject;
            var command = try apply_actions.packageVerifyCommand(ctx.allocator, ctx.migration_plan.package_manager, package);
            defer command.deinit(ctx.allocator);
            const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
            try ctx.stdout.print("  verify {s}: ", .{action.id});
            try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
            return .{ .ok = true };
        },
        .enable_systemd_unit => {
            const service = apply_actions.subject(action);
            if (service.len == 0) return error.MissingApplySubject;
            var argv = [_][]const u8{ "systemctl", "is-enabled", service };
            const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, argv[0..], ctx.execution);
            try ctx.stdout.print("  verify {s}: ", .{action.id});
            try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
            return .{ .ok = true };
        },
        .create_user => {
            const user = apply_actions.subject(action);
            if (user.len == 0) return error.MissingApplySubject;
            var argv = [_][]const u8{ "getent", "passwd", user };
            try ctx.stdout.print("  verify {s}: ", .{action.id});
            const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, argv[0..], ctx.execution, 16 * 1024);
            defer ctx.allocator.free(output);
            try verifyPasswdEntry(action, output);
            try ctx.stdout.print("user metadata matched {s}\n", .{user});
            return .{ .ok = true, .message = "user metadata matched" };
        },
        .create_group => {
            const group = apply_actions.subject(action);
            if (group.len == 0) return error.MissingApplySubject;
            var argv = [_][]const u8{ "getent", "group", group };
            const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, argv[0..], ctx.execution);
            try ctx.stdout.print("  verify {s}: ", .{action.id});
            try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
            return .{ .ok = true };
        },
        .verify_compose_project => return .{ .ok = true, .message = "compose ps action is itself the verification" },
        .start_compose_project => {
            const compose_file = apply_actions.subject(action);
            if (compose_file.len == 0) return error.MissingApplySubject;
            var command = try apply_actions.dockerComposePsCommand(ctx.allocator, compose_file);
            defer command.deinit(ctx.allocator);
            const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
            try ctx.stdout.print("  verify {s}: ", .{action.id});
            try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
            return .{ .ok = true };
        },
        else => return error.UnsupportedVerifyAction,
    }
}

// 回滚命令型迁移动作；当前支持包、用户和组的保守回滚。
pub fn rollback(ctx: handler.RollbackContext, entry: rollback_manifest.Entry) !handler.RollbackResult {
    if (std.mem.eql(u8, entry.action_type, "install_package")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        const package_manager = try remote_package_manager.detect(ctx.io, ctx.allocator, ctx.target_host, ctx.execution);
        var command = try apply_actions.packageRemoveCommand(ctx.allocator, package_manager, entry.subject);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
        try ctx.stdout.print("  - rollback {s}: remove package {s}\n", .{ entry.action_id, entry.subject });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }
    if (std.mem.eql(u8, entry.action_type, "create_user")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        var command = try apply_actions.userDeleteCommand(ctx.allocator, entry.subject);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
        try ctx.stdout.print("  - rollback {s}: delete user {s} (home preserved)\n", .{ entry.action_id, entry.subject });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }
    if (std.mem.eql(u8, entry.action_type, "create_group")) {
        if (entry.subject.len == 0) return error.MissingRollbackSubject;
        var command = try apply_actions.groupDeleteCommand(ctx.allocator, entry.subject);
        defer command.deinit(ctx.allocator);
        const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, command.argv, ctx.execution);
        try ctx.stdout.print("  - rollback {s}: delete group {s}\n", .{ entry.action_id, entry.subject });
        try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
        return .{ .restored = true };
    }
    return error.UnsupportedRollbackAction;
}

// 根据包管理器类型返回安装包所需的最小命令集合。
fn packageInstallCommands(migration_plan: plan.MigrationPlan) []const []const u8 {
    const install_prefix = package_provider.commandPrefix(migration_plan.package_manager, .install) orelse return &.{};
    const verify_prefix = package_provider.commandPrefix(migration_plan.package_manager, .verify) orelse return &.{install_prefix[0]};
    if (std.mem.eql(u8, install_prefix[0], verify_prefix[0])) return install_prefix[0..1];
    return switch (migration_plan.package_manager) {
        .apt => &.{ "apt-get", "dpkg-query" },
        .dnf, .yum, .zypper => &.{ install_prefix[0], "rpm" },
        .pacman => &.{"pacman"},
        .unknown => &.{},
    };
}

// 校验 getent passwd 输出的 uid/gid/home/shell 是否符合预期。
fn verifyPasswdEntry(action: plan.Action, output: []const u8) !void {
    const user = apply_actions.subject(action);
    const line = std.mem.trim(u8, output, " \t\r\n");
    var fields = std.mem.splitScalar(u8, line, ':');
    const name = fields.next() orelse return error.InvalidPasswdEntry;
    _ = fields.next() orelse return error.InvalidPasswdEntry;
    const uid_text = fields.next() orelse return error.InvalidPasswdEntry;
    const gid_text = fields.next() orelse return error.InvalidPasswdEntry;
    _ = fields.next() orelse return error.InvalidPasswdEntry;
    const home = fields.next() orelse return error.InvalidPasswdEntry;
    const shell = fields.next() orelse return error.InvalidPasswdEntry;
    if (!std.mem.eql(u8, name, user)) return error.VerifyUserNameMismatch;
    if (action.uid) |expected| {
        const actual = try std.fmt.parseUnsigned(u32, uid_text, 10);
        if (actual != expected) return error.VerifyUserUidMismatch;
    }
    if (action.gid) |expected| {
        const actual = try std.fmt.parseUnsigned(u32, gid_text, 10);
        if (actual != expected) return error.VerifyUserGidMismatch;
    }
    if (action.home) |expected| {
        if (!std.mem.eql(u8, home, expected)) return error.VerifyUserHomeMismatch;
    }
    if (action.shell) |expected| {
        if (!std.mem.eql(u8, shell, expected)) return error.VerifyUserShellMismatch;
    }
}

test "passwd verifier checks uid gid home and shell" {
    try verifyPasswdEntry(.{
        .id = "users/create-user/deploy",
        .module = .users,
        .action_type = .create_user,
        .subject = "deploy",
        .uid = 1001,
        .gid = 1001,
        .home = "/home/deploy",
        .shell = "/bin/bash",
        .description = "create user",
        .risk = .medium,
        .requires_confirmation = false,
    }, "deploy:x:1001:1001:Deploy User:/home/deploy:/bin/bash\n");
}

test "passwd verifier rejects mismatched shell" {
    try std.testing.expectError(error.VerifyUserShellMismatch, verifyPasswdEntry(.{
        .id = "users/create-user/deploy",
        .module = .users,
        .action_type = .create_user,
        .subject = "deploy",
        .uid = 1001,
        .gid = 1001,
        .home = "/home/deploy",
        .shell = "/bin/zsh",
        .description = "create user",
        .risk = .medium,
        .requires_confirmation = false,
    }, "deploy:x:1001:1001:Deploy User:/home/deploy:/bin/bash\n"));
}
