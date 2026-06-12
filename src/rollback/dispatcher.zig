const std = @import("std");
const manifest = @import("manifest.zig");
const inventory_schema = @import("../inventory/schema.zig");
const module_registry = @import("../modules/registry.zig");
const services_openrc_handler = @import("../modules/handlers/services_openrc.zig");
const services_sysv_handler = @import("../modules/handlers/services_sysv.zig");
const services_user_systemd_handler = @import("../modules/handlers/services_user_systemd.zig");
const plan_schema = @import("../plan/schema.zig");
const package_provider = @import("../apply/action/package_provider.zig");
const remote_exec = @import("../remote/exec.zig");
const remote_options = @import("../remote/options.zig");
const remote_package_manager = @import("../remote/package_manager.zig");

// 执行单条 rollback；按 action module 分发到模块 rollback handler。
pub fn executeEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry: manifest.Entry,
    host: []const u8,
    execution_options: remote_options.ExecutionOptions,
    stdout: anytype,
    stderr: anytype,
) !void {
    const module_name = moduleNameForActionId(entry.action_id) orelse return error.UnsupportedRollbackAction;
    const module_handler = module_registry.find(module_name) orelse return error.UnsupportedRollbackAction;
    const rollback = module_handler.rollback orelse return error.UnsupportedRollbackAction;
    const result = try rollback(.{
        .io = io,
        .allocator = allocator,
        .target_host = host,
        .execution = execution_options,
        .stdout = stdout,
        .stderr = stderr,
    }, entry);
    if (result.restored) try verifyEntryRestored(io, allocator, entry, host, execution_options, stdout);
}

// 从 rollback action id 前缀解析所属模块。
pub fn moduleNameForActionId(action_id: []const u8) ?plan_schema.ModuleName {
    const slash = std.mem.indexOfScalar(u8, action_id, '/') orelse return null;
    const prefix = action_id[0..slash];
    if (std.mem.eql(u8, prefix, "packages")) return .packages;
    if (std.mem.eql(u8, prefix, "services")) return .services;
    if (std.mem.eql(u8, prefix, "users")) return .users;
    if (std.mem.eql(u8, prefix, "cron")) return .cron;
    if (std.mem.eql(u8, prefix, "ssh")) return .ssh;
    if (std.mem.eql(u8, prefix, "configs")) return .configs;
    if (std.mem.eql(u8, prefix, "home-configs")) return .home_configs;
    if (std.mem.eql(u8, prefix, "appdata")) return .appdata;
    if (std.mem.eql(u8, prefix, "projects")) return .projects;
    if (std.mem.eql(u8, prefix, "docker")) return .docker;
    if (std.mem.eql(u8, prefix, "firewall")) return .firewall;
    return null;
}

// 回滚后验证：按动作类型检查文件恢复、包卸载、用户/组删除、服务禁用。
fn verifyEntryRestored(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry: manifest.Entry,
    host: []const u8,
    execution_options: remote_options.ExecutionOptions,
    stdout: anytype,
) !void {
    if (entry.original_path.len > 0) {
        if (!try remote_exec.pathExistsWithOptions(io, allocator, host, entry.original_path, execution_options)) return error.RollbackVerifyOriginalMissing;
        try stdout.print("  verify rollback {s}: restored path exists {s}\n", .{ entry.action_id, entry.original_path });
        return;
    }
    if (entry.subject.len == 0) return;
    if (std.mem.eql(u8, entry.action_type, "install_package")) {
        const package_manager = try remote_package_manager.detect(io, allocator, host, execution_options);
        var argv = try packageVerifyArgv(allocator, package_manager, entry.subject);
        defer argv.deinit(allocator);
        if (try remote_exec.commandSucceededWithOptions(io, allocator, host, argv.items, execution_options)) return error.RollbackVerifyPackageStillInstalled;
        try stdout.print("  verify rollback {s}: package absent {s}\n", .{ entry.action_id, entry.subject });
        return;
    }
    if (std.mem.eql(u8, entry.action_type, "create_user")) {
        var argv = [_][]const u8{ "getent", "passwd", entry.subject };
        if (try remote_exec.commandSucceededWithOptions(io, allocator, host, argv[0..], execution_options)) return error.RollbackVerifyUserStillExists;
        try stdout.print("  verify rollback {s}: user absent {s}\n", .{ entry.action_id, entry.subject });
        return;
    }
    if (std.mem.eql(u8, entry.action_type, "create_group")) {
        var argv = [_][]const u8{ "getent", "group", entry.subject };
        if (try remote_exec.commandSucceededWithOptions(io, allocator, host, argv[0..], execution_options)) return error.RollbackVerifyGroupStillExists;
        try stdout.print("  verify rollback {s}: group absent {s}\n", .{ entry.action_id, entry.subject });
        return;
    }
    if (std.mem.eql(u8, entry.action_type, "enable_systemd_unit")) {
        var argv = [_][]const u8{ "systemctl", "is-enabled", entry.subject };
        if (try remote_exec.commandSucceededWithOptions(io, allocator, host, argv[0..], execution_options)) return error.RollbackVerifyServiceStillEnabled;
        try stdout.print("  verify rollback {s}: service disabled {s}\n", .{ entry.action_id, entry.subject });
        return;
    }
    if (std.mem.eql(u8, entry.action_type, "enable_user_systemd_unit")) {
        try services_user_systemd_handler.verifyRollback(io, allocator, host, execution_options, stdout, entry.action_id, entry.subject);
        return;
    }
    if (std.mem.eql(u8, entry.action_type, "enable_openrc_service") or std.mem.eql(u8, entry.action_type, "disable_openrc_service")) {
        try services_openrc_handler.verifyRollback(io, allocator, host, execution_options, stdout, entry.action_id, entry.action_type, entry.subject);
        return;
    }
    if (std.mem.eql(u8, entry.action_type, "enable_sysv_init") or std.mem.eql(u8, entry.action_type, "disable_sysv_init")) {
        try services_sysv_handler.verifyRollback(io, allocator, host, execution_options, stdout, entry.action_id, entry.action_type, entry.subject);
        return;
    }
}

// 构造包管理器的验证命令 argv（如 rpm -q、pacman -Q）。
fn packageVerifyArgv(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !std.ArrayList([]const u8) {
    const prefix = package_provider.commandPrefix(package_manager, .verify) orelse return error.UnsupportedPackageManager;
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, prefix);
    try argv.append(allocator, package);
    return argv;
}

// 判断 rollback 条目是否需要回滚后验证。
fn shouldPostVerify(entry: manifest.Entry) bool {
    return entry.original_path.len > 0 or
        std.mem.eql(u8, entry.action_type, "install_package") or
        std.mem.eql(u8, entry.action_type, "create_user") or
        std.mem.eql(u8, entry.action_type, "create_group") or
        std.mem.eql(u8, entry.action_type, "enable_systemd_unit") or
        std.mem.eql(u8, entry.action_type, "enable_user_systemd_unit") or
        std.mem.eql(u8, entry.action_type, "enable_openrc_service") or
        std.mem.eql(u8, entry.action_type, "disable_openrc_service") or
        std.mem.eql(u8, entry.action_type, "enable_sysv_init") or
        std.mem.eql(u8, entry.action_type, "disable_sysv_init");
}

test "rollback dispatcher maps rollback action ids to modules" {
    try std.testing.expectEqual(plan_schema.ModuleName.configs, moduleNameForActionId("configs/write//etc/hosts").?);
    try std.testing.expectEqual(plan_schema.ModuleName.home_configs, moduleNameForActionId("home-configs/copy//home/deploy/.bashrc").?);
    try std.testing.expectEqual(plan_schema.ModuleName.appdata, moduleNameForActionId("appdata/copy//srv/app").?);
    try std.testing.expectEqual(plan_schema.ModuleName.docker, moduleNameForActionId("docker/copy-volume/app-data").?);
    try std.testing.expectEqual(plan_schema.ModuleName.services, moduleNameForActionId("services/install-unit/app.service").?);
    try std.testing.expectEqual(plan_schema.ModuleName.services, moduleNameForActionId("services/enable/nginx.service").?);
    try std.testing.expectEqual(plan_schema.ModuleName.services, moduleNameForActionId("services/enable-user-unit/deploy:syncthing.service").?);
    try std.testing.expectEqual(plan_schema.ModuleName.services, moduleNameForActionId("services/enable-openrc/nginx").?);
    try std.testing.expectEqual(plan_schema.ModuleName.services, moduleNameForActionId("services/disable-openrc/nginx").?);
    try std.testing.expectEqual(plan_schema.ModuleName.services, moduleNameForActionId("services/enable-sysv-init/legacy").?);
    try std.testing.expectEqual(plan_schema.ModuleName.projects, moduleNameForActionId("projects/compose-up//srv/app").?);
    try std.testing.expectEqual(plan_schema.ModuleName.packages, moduleNameForActionId("packages/install/nginx").?);
    try std.testing.expectEqual(plan_schema.ModuleName.users, moduleNameForActionId("users/create-user/deploy").?);
}

test "rollback post verify covers file and command rollback entries" {
    try std.testing.expect(shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "configs/write//etc/hosts",
        .action_type = "write_file",
        .original_path = "/etc/hosts",
        .backup_path = "/tmp/backup/hosts",
    }));
    try std.testing.expect(shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "users/create-user/deploy",
        .action_type = "create_user",
        .original_path = "",
        .backup_path = "",
        .subject = "deploy",
    }));
    try std.testing.expect(shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-user-unit/deploy:syncthing.service",
        .action_type = "enable_user_systemd_unit",
        .original_path = "",
        .backup_path = "",
        .subject = "deploy:syncthing.service",
    }));
    try std.testing.expect(shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-openrc/nginx",
        .action_type = "enable_openrc_service",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx:default",
    }));
    try std.testing.expect(shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "services/disable-openrc/nginx",
        .action_type = "disable_openrc_service",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx:boot",
    }));
    try std.testing.expect(shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-sysv-init/legacy",
        .action_type = "enable_sysv_init",
        .original_path = "",
        .backup_path = "",
        .subject = "legacy:2,3,5",
    }));
    try std.testing.expect(!shouldPostVerify(.{
        .schema_version = "hostlift.rollback.v1",
        .created_at = 1,
        .host = "root@192.0.2.10",
        .action_id = "projects/compose-up//srv/app",
        .action_type = "start_compose_project",
        .original_path = "",
        .backup_path = "",
        .subject = "/srv/app/docker-compose.yml",
    }));
}

test "rollback package verify argv follows package manager provider" {
    var rpm = try packageVerifyArgv(std.testing.allocator, .dnf, "nginx");
    defer rpm.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rpm", rpm.items[0]);
    try std.testing.expectEqualStrings("-q", rpm.items[1]);
    try std.testing.expectEqualStrings("nginx", rpm.items[2]);

    var pacman = try packageVerifyArgv(std.testing.allocator, .pacman, "nginx");
    defer pacman.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pacman", pacman.items[0]);
    try std.testing.expectEqualStrings("-Q", pacman.items[1]);
    try std.testing.expectEqualStrings("nginx", pacman.items[2]);
}
