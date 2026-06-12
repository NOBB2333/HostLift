const std = @import("std");
const actions = @import("actions.zig");
const plan_schema = @import("../plan/schema.zig");

test "apply command maps package managers to safe argv" {
    var apt = try actions.packageInstallCommand(std.testing.allocator, .apt, "nginx");
    defer apt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("apt-get", apt.argv[0]);
    try std.testing.expectEqualStrings("install", apt.argv[1]);
    try std.testing.expectEqualStrings("-y", apt.argv[2]);
    try std.testing.expectEqualStrings("nginx", apt.argv[3]);

    var pacman = try actions.packageInstallCommand(std.testing.allocator, .pacman, "nginx");
    defer pacman.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pacman", pacman.argv[0]);
    try std.testing.expectEqualStrings("-S", pacman.argv[1]);
    try std.testing.expectEqualStrings("--noconfirm", pacman.argv[2]);
    try std.testing.expectEqualStrings("nginx", pacman.argv[3]);
}

test "apply command maps package verification to safe argv" {
    var apt = try actions.packageVerifyCommand(std.testing.allocator, .apt, "nginx");
    defer apt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dpkg-query", apt.argv[0]);
    try std.testing.expectEqualStrings("-W", apt.argv[1]);
    try std.testing.expectEqualStrings("nginx", apt.argv[2]);

    var dnf = try actions.packageVerifyCommand(std.testing.allocator, .dnf, "nginx");
    defer dnf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rpm", dnf.argv[0]);
    try std.testing.expectEqualStrings("-q", dnf.argv[1]);
    try std.testing.expectEqualStrings("nginx", dnf.argv[2]);

    var zypper = try actions.packageVerifyCommand(std.testing.allocator, .zypper, "nginx");
    defer zypper.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rpm", zypper.argv[0]);
    try std.testing.expectEqualStrings("-q", zypper.argv[1]);
    try std.testing.expectEqualStrings("nginx", zypper.argv[2]);

    var pacman = try actions.packageVerifyCommand(std.testing.allocator, .pacman, "nginx");
    defer pacman.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pacman", pacman.argv[0]);
    try std.testing.expectEqualStrings("-Q", pacman.argv[1]);
    try std.testing.expectEqualStrings("nginx", pacman.argv[2]);
}

test "apply command maps package rollback removal to safe argv" {
    var apt = try actions.packageRemoveCommand(std.testing.allocator, .apt, "nginx");
    defer apt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("apt-get", apt.argv[0]);
    try std.testing.expectEqualStrings("remove", apt.argv[1]);
    try std.testing.expectEqualStrings("-y", apt.argv[2]);
    try std.testing.expectEqualStrings("nginx", apt.argv[3]);

    var zypper = try actions.packageRemoveCommand(std.testing.allocator, .zypper, "nginx");
    defer zypper.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zypper", zypper.argv[0]);
    try std.testing.expectEqualStrings("--non-interactive", zypper.argv[1]);
    try std.testing.expectEqualStrings("remove", zypper.argv[2]);
    try std.testing.expectEqualStrings("nginx", zypper.argv[3]);

    var pacman = try actions.packageRemoveCommand(std.testing.allocator, .pacman, "nginx");
    defer pacman.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pacman", pacman.argv[0]);
    try std.testing.expectEqualStrings("-R", pacman.argv[1]);
    try std.testing.expectEqualStrings("--noconfirm", pacman.argv[2]);
    try std.testing.expectEqualStrings("nginx", pacman.argv[3]);
}

test "apply command maps user and group creation to safe argv" {
    var group = try actions.groupAddCommand(std.testing.allocator, "deploy", 1001);
    defer group.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("groupadd", group.argv[0]);
    try std.testing.expectEqualStrings("-g", group.argv[1]);
    try std.testing.expectEqualStrings("1001", group.argv[2]);
    try std.testing.expectEqualStrings("deploy", group.argv[3]);

    var user = try actions.userAddCommand(std.testing.allocator, "deploy", 1001, 1001, "/home/deploy", "/bin/bash");
    defer user.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("useradd", user.argv[0]);
    try std.testing.expectEqualStrings("-m", user.argv[1]);
    try std.testing.expectEqualStrings("-u", user.argv[2]);
    try std.testing.expectEqualStrings("1001", user.argv[3]);
    try std.testing.expectEqualStrings("-g", user.argv[4]);
    try std.testing.expectEqualStrings("1001", user.argv[5]);
    try std.testing.expectEqualStrings("-d", user.argv[6]);
    try std.testing.expectEqualStrings("/home/deploy", user.argv[7]);
    try std.testing.expectEqualStrings("-s", user.argv[8]);
    try std.testing.expectEqualStrings("/bin/bash", user.argv[9]);

    var compose = try actions.dockerComposeUpCommand(std.testing.allocator, "/srv/app/docker-compose.yml");
    defer compose.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("docker", compose.argv[0]);
    try std.testing.expectEqualStrings("compose", compose.argv[1]);
    try std.testing.expectEqualStrings("-f", compose.argv[2]);
    try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", compose.argv[3]);
    try std.testing.expectEqualStrings("up", compose.argv[4]);
    try std.testing.expectEqualStrings("-d", compose.argv[5]);

    var compose_ps = try actions.dockerComposePsCommand(std.testing.allocator, "/srv/app/docker-compose.yml");
    defer compose_ps.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("docker", compose_ps.argv[0]);
    try std.testing.expectEqualStrings("compose", compose_ps.argv[1]);
    try std.testing.expectEqualStrings("-f", compose_ps.argv[2]);
    try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", compose_ps.argv[3]);
    try std.testing.expectEqualStrings("ps", compose_ps.argv[4]);

    var compose_down = try actions.dockerComposeDownCommand(std.testing.allocator, "/srv/app/docker-compose.yml");
    defer compose_down.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("docker", compose_down.argv[0]);
    try std.testing.expectEqualStrings("compose", compose_down.argv[1]);
    try std.testing.expectEqualStrings("-f", compose_down.argv[2]);
    try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", compose_down.argv[3]);
    try std.testing.expectEqualStrings("down", compose_down.argv[4]);
}

test "apply command maps user and group rollback to conservative argv" {
    var user_delete = try actions.userDeleteCommand(std.testing.allocator, "deploy");
    defer user_delete.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("userdel", user_delete.argv[0]);
    try std.testing.expectEqualStrings("deploy", user_delete.argv[1]);
    try std.testing.expectEqual(@as(usize, 2), user_delete.argv.len);

    var group_delete = try actions.groupDeleteCommand(std.testing.allocator, "deploy");
    defer group_delete.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("groupdel", group_delete.argv[0]);
    try std.testing.expectEqualStrings("deploy", group_delete.argv[1]);
    try std.testing.expectEqual(@as(usize, 2), group_delete.argv.len);
}

test "apply command maps systemd disable rollback to safe argv" {
    var command = try actions.systemctlDisableCommand(std.testing.allocator, "nginx.service");
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("systemctl", command.argv[0]);
    try std.testing.expectEqualStrings("disable", command.argv[1]);
    try std.testing.expectEqualStrings("nginx.service", command.argv[2]);
}

test "apply command maps user systemd enable and disable to safe argv" {
    var enable = try actions.userSystemctlEnableCommand(std.testing.allocator, "deploy:syncthing.service");
    defer enable.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("runuser", enable.argv[0]);
    try std.testing.expectEqualStrings("-u", enable.argv[1]);
    try std.testing.expectEqualStrings("deploy", enable.argv[2]);
    try std.testing.expectEqualStrings("--", enable.argv[3]);
    try std.testing.expectEqualStrings("systemctl", enable.argv[4]);
    try std.testing.expectEqualStrings("--user", enable.argv[5]);
    try std.testing.expectEqualStrings("enable", enable.argv[6]);
    try std.testing.expectEqualStrings("syncthing.service", enable.argv[7]);

    var disable = try actions.userSystemctlDisableCommand(std.testing.allocator, "deploy:syncthing.service");
    defer disable.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("runuser", disable.argv[0]);
    try std.testing.expectEqualStrings("deploy", disable.argv[2]);
    try std.testing.expectEqualStrings("disable", disable.argv[6]);
    try std.testing.expectEqualStrings("syncthing.service", disable.argv[7]);

    try std.testing.expectError(error.InvalidUserSystemdUnitRef, actions.userSystemctlEnableCommand(std.testing.allocator, "deploy"));
}

test "apply command maps OpenRC add and delete to safe argv" {
    var add = try actions.openRcAddCommand(std.testing.allocator, "nginx", "default");
    defer add.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rc-update", add.argv[0]);
    try std.testing.expectEqualStrings("add", add.argv[1]);
    try std.testing.expectEqualStrings("nginx", add.argv[2]);
    try std.testing.expectEqualStrings("default", add.argv[3]);

    var delete = try actions.openRcDeleteCommand(std.testing.allocator, "nginx", "default");
    defer delete.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rc-update", delete.argv[0]);
    try std.testing.expectEqualStrings("del", delete.argv[1]);
    try std.testing.expectEqualStrings("nginx", delete.argv[2]);
    try std.testing.expectEqualStrings("default", delete.argv[3]);

    const parsed = try actions.parseOpenRcRef("nginx:default,boot");
    try std.testing.expectEqualStrings("nginx", parsed.service);
    try std.testing.expectEqualStrings("default,boot", parsed.runlevels);
    try std.testing.expectError(error.InvalidOpenRcServiceRef, actions.parseOpenRcRef("nginx"));
}

test "apply command maps SysV chkconfig on and off to safe argv" {
    var enable = try actions.sysvEnableCommand(std.testing.allocator, "legacy", "2,3,5");
    defer enable.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("chkconfig", enable.argv[0]);
    try std.testing.expectEqualStrings("--level", enable.argv[1]);
    try std.testing.expectEqualStrings("235", enable.argv[2]);
    try std.testing.expectEqualStrings("legacy", enable.argv[3]);
    try std.testing.expectEqualStrings("on", enable.argv[4]);

    var disable = try actions.sysvDisableCommand(std.testing.allocator, "legacy", "2");
    defer disable.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("chkconfig", disable.argv[0]);
    try std.testing.expectEqualStrings("2", disable.argv[2]);
    try std.testing.expectEqualStrings("off", disable.argv[4]);

    const parsed = try actions.parseSysvRef("legacy:2,3,5");
    try std.testing.expectEqualStrings("legacy", parsed.service);
    try std.testing.expectEqualStrings("2,3,5", parsed.runlevels);
    try std.testing.expectError(error.InvalidSysvInitRef, actions.parseSysvRef("legacy"));
}

test "apply command maps SysV update-rc.d enable and disable to safe argv" {
    var enable = try actions.sysvUpdateRcDEnableCommand(std.testing.allocator, "legacy", "2,3,5");
    defer enable.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("update-rc.d", enable.argv[0]);
    try std.testing.expectEqualStrings("legacy", enable.argv[1]);
    try std.testing.expectEqualStrings("enable", enable.argv[2]);
    try std.testing.expectEqualStrings("2", enable.argv[3]);
    try std.testing.expectEqualStrings("3", enable.argv[4]);
    try std.testing.expectEqualStrings("5", enable.argv[5]);

    var disable = try actions.sysvUpdateRcDDisableCommand(std.testing.allocator, "legacy", "2");
    defer disable.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("update-rc.d", disable.argv[0]);
    try std.testing.expectEqualStrings("disable", disable.argv[2]);
    try std.testing.expectEqualStrings("2", disable.argv[3]);

    try std.testing.expectError(error.InvalidSysvInitRef, actions.sysvUpdateRcDEnableCommand(std.testing.allocator, "legacy", "0"));
}

test "action subject falls back to known id prefixes" {
    const service_action = plan_schema.Action{
        .id = "services/enable/nginx.service",
        .module = .services,
        .action_type = .enable_systemd_unit,
        .description = "Enable service",
        .risk = .low,
        .requires_confirmation = false,
    };
    const user_service_action = plan_schema.Action{
        .id = "services/enable-user-unit/deploy:syncthing.service",
        .module = .services,
        .action_type = .enable_user_systemd_unit,
        .description = "Enable user service",
        .risk = .high,
        .requires_confirmation = true,
    };
    const openrc_action = plan_schema.Action{
        .id = "services/enable-openrc/nginx",
        .module = .services,
        .action_type = .enable_openrc_service,
        .description = "Enable OpenRC service",
        .risk = .high,
        .requires_confirmation = true,
    };
    const openrc_disable_action = plan_schema.Action{
        .id = "services/disable-openrc/nginx",
        .module = .services,
        .action_type = .disable_openrc_service,
        .description = "Disable OpenRC service",
        .risk = .high,
        .requires_confirmation = true,
    };
    const sysv_action = plan_schema.Action{
        .id = "services/enable-sysv-init/legacy",
        .module = .services,
        .action_type = .enable_sysv_init,
        .description = "Enable SysV init",
        .risk = .high,
        .requires_confirmation = true,
    };
    const config_action = plan_schema.Action{
        .id = "configs/write//etc/nginx/nginx.conf",
        .module = .configs,
        .action_type = .write_file,
        .description = "Copy config",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const appdata_action = plan_schema.Action{
        .id = "appdata/copy//srv/app",
        .module = .appdata,
        .action_type = .copy_data_path,
        .description = "Copy app data",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const home_config_action = plan_schema.Action{
        .id = "home-configs/copy//home/deploy/.config/nvim",
        .module = .home_configs,
        .action_type = .copy_home_config,
        .description = "Copy home config",
        .risk = .medium,
        .requires_confirmation = true,
        .recursive = true,
    };
    const project_action = plan_schema.Action{
        .id = "projects/copy//srv/app",
        .module = .projects,
        .action_type = .copy_project_path,
        .description = "Copy project",
        .risk = .high,
        .requires_confirmation = true,
    };
    const compose_action = plan_schema.Action{
        .id = "projects/compose-up//srv/app",
        .module = .projects,
        .action_type = .start_compose_project,
        .subject = "/srv/app/docker-compose.yml",
        .description = "Start compose project",
        .risk = .high,
        .requires_confirmation = true,
    };
    const compose_verify_action = plan_schema.Action{
        .id = "projects/compose-verify//srv/app",
        .module = .projects,
        .action_type = .verify_compose_project,
        .subject = "/srv/app/docker-compose.yml",
        .description = "Verify compose project",
        .risk = .low,
        .requires_confirmation = false,
    };
    const cron_action = plan_schema.Action{
        .id = "cron/install//etc/cron.d/app",
        .module = .cron,
        .action_type = .install_cron_entry,
        .description = "Install cron",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const user_action = plan_schema.Action{
        .id = "users/create-user/deploy",
        .module = .users,
        .action_type = .create_user,
        .description = "Create user",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const authorized_keys_action = plan_schema.Action{
        .id = "ssh/authorized-keys/deploy",
        .module = .ssh,
        .action_type = .add_authorized_key,
        .subject = "/home/deploy/.ssh/authorized_keys",
        .description = "Copy authorized keys",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const group_action = plan_schema.Action{
        .id = "users/create-group/deploy",
        .module = .users,
        .action_type = .create_group,
        .description = "Create group",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const firewall_action = plan_schema.Action{
        .id = "firewall/apply-config//etc/nftables.conf",
        .module = .firewall,
        .action_type = .apply_firewall_config,
        .description = "Copy firewall config",
        .risk = .high,
        .requires_confirmation = true,
    };

    try std.testing.expectEqualStrings("nginx.service", actions.subject(service_action));
    try std.testing.expectEqualStrings("deploy:syncthing.service", actions.subject(user_service_action));
    try std.testing.expectEqualStrings("nginx", actions.subject(openrc_action));
    try std.testing.expectEqualStrings("nginx", actions.subject(openrc_disable_action));
    try std.testing.expectEqualStrings("legacy", actions.subject(sysv_action));
    try std.testing.expectEqualStrings("/etc/nginx/nginx.conf", actions.subject(config_action));
    try std.testing.expectEqualStrings("/srv/app", actions.subject(appdata_action));
    try std.testing.expectEqualStrings("/home/deploy/.config/nvim", actions.subject(home_config_action));
    try std.testing.expectEqualStrings("/srv/app", actions.subject(project_action));
    try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", actions.subject(compose_action));
    try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", actions.subject(compose_verify_action));
    try std.testing.expectEqualStrings("/etc/cron.d/app", actions.subject(cron_action));
    try std.testing.expectEqualStrings("deploy", actions.subject(user_action));
    try std.testing.expectEqualStrings("deploy", actions.subject(group_action));
    try std.testing.expectEqualStrings("/home/deploy/.ssh/authorized_keys", actions.subject(authorized_keys_action));
    try std.testing.expectEqualStrings("/etc/nftables.conf", actions.subject(firewall_action));
}

test "systemd target path preserves explicit system unit paths" {
    const action = plan_schema.Action{
        .id = "services/install-unit/app.service",
        .module = .services,
        .action_type = .install_systemd_unit,
        .subject = "/tmp/app.service",
        .description = "Install unit",
        .risk = .medium,
        .requires_confirmation = true,
    };

    const inferred = try actions.systemdTargetPath(std.testing.allocator, action, action.subject);
    defer std.testing.allocator.free(inferred);
    try std.testing.expectEqualStrings("/etc/systemd/system/app.service", inferred);

    const explicit = try actions.systemdTargetPath(std.testing.allocator, action, "/etc/systemd/system/app.service");
    defer std.testing.allocator.free(explicit);
    try std.testing.expectEqualStrings("/etc/systemd/system/app.service", explicit);
}

test "systemd target path supports timer unit ids" {
    const action = plan_schema.Action{
        .id = "services/install-unit/backup.timer",
        .module = .services,
        .action_type = .install_systemd_unit,
        .subject = "/tmp/backup.timer",
        .description = "Install timer",
        .risk = .medium,
        .requires_confirmation = true,
    };

    const inferred = try actions.systemdTargetPath(std.testing.allocator, action, action.subject);
    defer std.testing.allocator.free(inferred);
    try std.testing.expectEqualStrings("/etc/systemd/system/backup.timer", inferred);
}

test "systemd target path supports socket unit ids" {
    const action = plan_schema.Action{
        .id = "services/install-unit/ssh.socket",
        .module = .services,
        .action_type = .install_systemd_unit,
        .subject = "/tmp/ssh.socket",
        .description = "Install socket",
        .risk = .medium,
        .requires_confirmation = true,
    };

    const inferred = try actions.systemdTargetPath(std.testing.allocator, action, action.subject);
    defer std.testing.allocator.free(inferred);
    try std.testing.expectEqualStrings("/etc/systemd/system/ssh.socket", inferred);
}

test "rollback target selection covers file-backed apply actions" {
    const unit_action = plan_schema.Action{
        .id = "services/install-unit/app.service",
        .module = .services,
        .action_type = .install_systemd_unit,
        .subject = "/tmp/app.service",
        .description = "Install unit",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const config_action = plan_schema.Action{
        .id = "configs/write//etc/hosts",
        .module = .configs,
        .action_type = .write_file,
        .description = "Copy config",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const package_action = plan_schema.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install package",
        .risk = .low,
        .requires_confirmation = false,
    };
    const home_config_action = plan_schema.Action{
        .id = "home-configs/copy//home/deploy/.bashrc",
        .module = .home_configs,
        .action_type = .copy_home_config,
        .description = "Copy home config",
        .risk = .medium,
        .requires_confirmation = true,
    };

    const unit_target = (try actions.backupTargetForAction(std.testing.allocator, unit_action)).?;
    defer std.testing.allocator.free(unit_target);
    try std.testing.expectEqualStrings("/etc/systemd/system/app.service", unit_target);

    const config_target = (try actions.backupTargetForAction(std.testing.allocator, config_action)).?;
    defer std.testing.allocator.free(config_target);
    try std.testing.expectEqualStrings("/etc/hosts", config_target);

    const home_config_target = (try actions.backupTargetForAction(std.testing.allocator, home_config_action)).?;
    defer std.testing.allocator.free(home_config_target);
    try std.testing.expectEqualStrings("/home/deploy/.bashrc", home_config_target);

    try std.testing.expect(try actions.backupTargetForAction(std.testing.allocator, package_action) == null);
}
