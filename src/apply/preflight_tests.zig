const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan_schema = @import("../plan/schema.zig");
const preflight = @import("preflight.zig");

// 构造测试用的基础迁移计划。
fn basePlan(package_manager: inventory.PackageManagerKind) plan_schema.MigrationPlan {
    return .{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{0} ** 32,
        .package_manager = package_manager,
        .compatibility = .{
            .compatible = true,
            .same_distro = true,
            .same_version = true,
            .same_package_manager = true,
            .same_arch = true,
            .reason = "test",
        },
        .actions = &.{},
        .created_at = 0,
    };
}

test "package apply preflight declares install and verify commands" {
    const action = plan_schema.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .subject = "nginx",
        .description = "install nginx",
        .risk = .low,
        .requires_confirmation = false,
    };

    const apt_check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", action);
    defer std.testing.allocator.free(apt_check.commands);
    try std.testing.expectEqualStrings("root@192.0.2.10", apt_check.host);
    try std.testing.expectEqual(@as(usize, 2), apt_check.commands.len);
    try std.testing.expectEqualStrings("apt-get", apt_check.commands[0]);
    try std.testing.expectEqualStrings("dpkg-query", apt_check.commands[1]);

    const pacman_check = try preflight.actionCheck(std.testing.allocator, basePlan(.pacman), "root@192.0.2.10", action);
    defer std.testing.allocator.free(pacman_check.commands);
    try std.testing.expectEqual(@as(usize, 1), pacman_check.commands.len);
    try std.testing.expectEqualStrings("pacman", pacman_check.commands[0]);
}

test "service and identity actions declare command dependencies" {
    const service_action = plan_schema.Action{
        .id = "services/enable/nginx.service",
        .module = .services,
        .action_type = .enable_systemd_unit,
        .subject = "nginx.service",
        .description = "enable nginx",
        .risk = .medium,
        .requires_confirmation = false,
    };
    const service_check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", service_action);
    defer std.testing.allocator.free(service_check.commands);
    try std.testing.expectEqual(@as(usize, 1), service_check.commands.len);
    try std.testing.expectEqualStrings("systemctl", service_check.commands[0]);

    const user_service_action = plan_schema.Action{
        .id = "services/enable-user-unit/deploy:syncthing.service",
        .module = .services,
        .action_type = .enable_user_systemd_unit,
        .subject = "deploy:syncthing.service",
        .owner = "deploy",
        .description = "enable user service",
        .risk = .high,
        .requires_confirmation = true,
    };
    const user_service_check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", user_service_action);
    defer std.testing.allocator.free(user_service_check.commands);
    try std.testing.expectEqual(@as(usize, 2), user_service_check.commands.len);
    try std.testing.expectEqualStrings("runuser", user_service_check.commands[0]);
    try std.testing.expectEqualStrings("systemctl", user_service_check.commands[1]);

    const user_action = plan_schema.Action{
        .id = "users/create-user/app",
        .module = .users,
        .action_type = .create_user,
        .subject = "app",
        .description = "create app user",
        .risk = .medium,
        .requires_confirmation = false,
    };
    const user_check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", user_action);
    defer std.testing.allocator.free(user_check.commands);
    try std.testing.expectEqual(@as(usize, 2), user_check.commands.len);
    try std.testing.expectEqualStrings("useradd", user_check.commands[0]);
    try std.testing.expectEqualStrings("getent", user_check.commands[1]);
}

test "service-owned xdg autostart copy declares home config dependencies" {
    const action = plan_schema.Action{
        .id = "services/install-xdg-autostart/deploy:syncthing-start.desktop",
        .module = .services,
        .action_type = .copy_home_config,
        .subject = "/home/deploy/.config/autostart/syncthing-start.desktop",
        .owner = "deploy",
        .description = "copy user autostart",
        .risk = .high,
        .requires_confirmation = true,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    try std.testing.expectEqual(@as(usize, 4), check.commands.len);
    try std.testing.expectEqualStrings("mkdir", check.commands[0]);
    try std.testing.expectEqualStrings("cp", check.commands[1]);
    try std.testing.expectEqualStrings("chown", check.commands[2]);
    try std.testing.expectEqualStrings("chmod", check.commands[3]);
}

test "service-owned user systemd unit copy declares home config dependencies" {
    const action = plan_schema.Action{
        .id = "services/install-user-unit/deploy:syncthing.service",
        .module = .services,
        .action_type = .copy_home_config,
        .subject = "/home/deploy/.config/systemd/user/syncthing.service",
        .owner = "deploy",
        .description = "copy user unit",
        .risk = .high,
        .requires_confirmation = true,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    try std.testing.expectEqual(@as(usize, 4), check.commands.len);
    try std.testing.expectEqualStrings("mkdir", check.commands[0]);
    try std.testing.expectEqualStrings("cp", check.commands[1]);
    try std.testing.expectEqualStrings("chown", check.commands[2]);
    try std.testing.expectEqualStrings("chmod", check.commands[3]);
}

test "service-owned init script copy declares file backup dependencies" {
    const action = plan_schema.Action{
        .id = "services/install-sysv-init/legacy",
        .module = .services,
        .action_type = .write_file,
        .subject = "/etc/init.d/legacy",
        .description = "copy init script",
        .risk = .high,
        .requires_confirmation = true,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    try std.testing.expectEqual(@as(usize, 2), check.commands.len);
    try std.testing.expectEqualStrings("mkdir", check.commands[0]);
    try std.testing.expectEqualStrings("cp", check.commands[1]);
}

test "service-owned OpenRC enable declares rc-update dependency" {
    const action = plan_schema.Action{
        .id = "services/enable-openrc/nginx",
        .module = .services,
        .action_type = .enable_openrc_service,
        .subject = "nginx:default",
        .description = "enable openrc service",
        .risk = .high,
        .requires_confirmation = true,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.unknown), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    try std.testing.expectEqual(@as(usize, 1), check.commands.len);
    try std.testing.expectEqualStrings("rc-update", check.commands[0]);
}

test "service-owned OpenRC disable declares rc-update dependency" {
    const action = plan_schema.Action{
        .id = "services/disable-openrc/nginx",
        .module = .services,
        .action_type = .disable_openrc_service,
        .subject = "nginx:boot",
        .description = "disable openrc service runlevel",
        .risk = .high,
        .requires_confirmation = true,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.unknown), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    try std.testing.expectEqual(@as(usize, 1), check.commands.len);
    try std.testing.expectEqualStrings("rc-update", check.commands[0]);
}

test "service-owned SysV runlevel actions declare provider alternatives" {
    const action = plan_schema.Action{
        .id = "services/enable-sysv-init/legacy",
        .module = .services,
        .action_type = .enable_sysv_init,
        .subject = "legacy:2,3,5",
        .description = "enable sysv init",
        .risk = .high,
        .requires_confirmation = true,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.unknown), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    defer preflight.freeAlternateCommands(std.testing.allocator, check.any_commands);
    try std.testing.expectEqual(@as(usize, 1), check.commands.len);
    try std.testing.expectEqualStrings("ls", check.commands[0]);
    try std.testing.expectEqual(@as(usize, 1), check.any_commands.len);
    try std.testing.expectEqual(@as(usize, 2), check.any_commands[0].len);
    try std.testing.expectEqualStrings("chkconfig", check.any_commands[0][0]);
    try std.testing.expectEqualStrings("update-rc.d", check.any_commands[0][1]);
}

test "file backup actions include backup command dependencies once" {
    const action = plan_schema.Action{
        .id = "configs/write//etc/hosts",
        .module = .configs,
        .action_type = .write_file,
        .subject = "/etc/hosts",
        .description = "copy hosts",
        .risk = .medium,
        .requires_confirmation = false,
    };
    const check = try preflight.actionCheck(std.testing.allocator, basePlan(.apt), "root@192.0.2.10", action);
    defer std.testing.allocator.free(check.commands);
    try std.testing.expectEqual(@as(usize, 2), check.commands.len);
    try std.testing.expectEqualStrings("mkdir", check.commands[0]);
    try std.testing.expectEqualStrings("cp", check.commands[1]);
}
