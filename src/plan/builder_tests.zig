const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");
const builder = @import("builder.zig");

test "builder creates package and service actions for missing target state" {
    var source_explicit = [_][]const u8{ "nginx", "git" };
    var source_held = [_][]const u8{"nginx"};
    var source_units = [_]inventory.ServiceUnit{
        .{ .name = "nginx.service", .state = .enabled, .custom = false },
        .{ .name = "app.service", .state = .enabled, .custom = true, .path = "/etc/systemd/system/app.service" },
    };
    var target_explicit = [_][]const u8{"git"};
    var target_units = [_]inventory.ServiceUnit{
        .{ .name = "nginx.service", .state = .disabled, .custom = false },
    };
    const source = fixture(.{
        .packages = .{ .explicit = source_explicit[0..], .held = source_held[0..] },
        .services = .{ .init_system = "systemd", .units = source_units[0..] },
    });
    const target = fixture(.{
        .packages = .{ .explicit = target_explicit[0..], .held = &.{} },
        .services = .{ .init_system = "systemd", .units = target_units[0..] },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(migration_plan.compatibility.compatible);
    try std.testing.expectEqual(@as(usize, 5), migration_plan.actions.len);
    try std.testing.expect(hasAction(migration_plan.actions, .install_package, "packages/install/nginx"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "packages/review-held/nginx"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_systemd_unit, "services/enable/nginx.service"));
    try std.testing.expect(hasAction(migration_plan.actions, .install_systemd_unit, "services/install-unit/app.service"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_systemd_unit, "services/enable/app.service"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "services/install-unit/app.service")) {
            try std.testing.expectEqualStrings("/etc/systemd/system/app.service", action.subject);
        }
    }
}

test "builder creates user ssh cron and config review actions" {
    var source_cron = [_]inventory.CronEntry{.{ .source = "/etc/cron.d/app", .owner = null, .line_count = 1 }};
    var source_users = [_]inventory.UserAccount{.{ .name = "deploy", .uid = 1001, .gid = 1001, .home = "/home/deploy", .shell = "/bin/bash", .system = false }};
    var source_groups = [_]inventory.GroupAccount{.{ .name = "deploy", .gid = 1001, .system = false }};
    var source_keys = [_]inventory.AuthorizedKeys{.{ .user = "deploy", .path = "/home/deploy/.ssh/authorized_keys", .key_count = 1 }};
    var source_configs = [_]inventory.ConfigFile{.{ .path = "/etc/nginx/nginx.conf", .present = true, .size = 10 }};
    const source = fixture(.{
        .cron = .{ .entries = source_cron[0..] },
        .users = .{
            .users = source_users[0..],
            .groups = source_groups[0..],
        },
        .ssh = .{ .authorized_keys = source_keys[0..], .sshd_config_present = true, .client_config_present = true },
        .configs = .{ .files = source_configs[0..] },
    });
    const target = fixture(.{});

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), migration_plan.actions.len);
    try std.testing.expect(hasAction(migration_plan.actions, .install_cron_entry, "cron/install//etc/cron.d/app"));
    try std.testing.expect(hasAction(migration_plan.actions, .create_group, "users/create-group/deploy"));
    try std.testing.expect(hasAction(migration_plan.actions, .create_user, "users/create-user/deploy"));
    try std.testing.expect(hasAction(migration_plan.actions, .add_authorized_key, "ssh/authorized-keys/deploy"));
    try std.testing.expect(hasAction(migration_plan.actions, .write_file, "configs/write//etc/nginx/nginx.conf"));
    for (migration_plan.actions) |action| {
        if (action.action_type == .create_user) {
            try std.testing.expectEqual(@as(?u32, 1001), action.uid);
            try std.testing.expectEqual(@as(?u32, 1001), action.gid);
            try std.testing.expectEqualStrings("/home/deploy", action.home.?);
            try std.testing.expectEqualStrings("/bin/bash", action.shell.?);
        }
        if (action.action_type == .create_group) {
            try std.testing.expectEqual(@as(?u32, 1001), action.gid);
        }
        if (action.action_type == .add_authorized_key) {
            try std.testing.expectEqualStrings("/home/deploy/.ssh/authorized_keys", action.subject);
        }
    }
}

test "builder creates service review actions for timers and user units" {
    var source_timers = [_]inventory.SystemdTimer{
        .{
            .name = "backup.timer",
            .state = .enabled,
            .activates = "backup.service",
            .schedule = "Mon 00:00",
            .custom = true,
            .path = "/etc/systemd/system/backup.timer",
        },
        .{
            .name = "apt-daily.timer",
            .state = .enabled,
            .activates = "apt-daily.service",
            .schedule = "daily",
        },
        .{
            .name = "nightly.timer",
            .state = .enabled,
            .activates = "nightly.service",
            .schedule = "02:00",
            .custom = true,
            .path = "/etc/systemd/system/nightly.timer",
        },
    };
    var target_timers = [_]inventory.SystemdTimer{
        .{
            .name = "apt-daily.timer",
            .state = .enabled,
            .activates = "apt-daily.service",
            .schedule = "daily",
        },
        .{
            .name = "nightly.timer",
            .state = .enabled,
            .activates = "nightly.service",
            .schedule = "03:00",
        },
    };
    var source_sockets = [_]inventory.SystemdSocket{
        .{
            .name = "ssh.socket",
            .state = .enabled,
            .activates = "ssh.service",
            .custom = true,
            .path = "/etc/systemd/system/ssh.socket",
        },
        .{
            .name = "dbus.socket",
            .state = .enabled,
            .activates = "dbus.service",
        },
    };
    var target_sockets = [_]inventory.SystemdSocket{.{
        .name = "dbus.socket",
        .state = .enabled,
        .activates = "dbus.service",
    }};
    var source_user_units = [_]inventory.UserSystemdUnit{
        .{
            .user = "deploy",
            .name = "syncthing.service",
            .path = "/home/deploy/.config/systemd/user/syncthing.service",
            .kind = .service,
            .enabled = true,
        },
        .{
            .user = "deploy",
            .name = "podman.socket",
            .path = "/home/deploy/.config/systemd/user/podman.socket",
            .kind = .socket,
            .enabled = false,
        },
    };
    var target_user_units = [_]inventory.UserSystemdUnit{.{
        .user = "deploy",
        .name = "podman.socket",
        .path = "/home/deploy/.config/systemd/user/podman.socket",
        .kind = .socket,
        .enabled = false,
    }};
    const source = fixture(.{
        .services = .{
            .init_system = "systemd",
            .units = &.{},
            .timers = source_timers[0..],
            .sockets = source_sockets[0..],
            .user_units = source_user_units[0..],
        },
    });
    const target = fixture(.{
        .services = .{
            .init_system = "systemd",
            .units = &.{},
            .timers = target_timers[0..],
            .sockets = target_sockets[0..],
            .user_units = target_user_units[0..],
        },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .install_systemd_unit, "services/install-unit/backup.timer"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_systemd_unit, "services/enable/backup.timer"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-timer/backup.timer"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-timer/apt-daily.timer"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "services/review-timer/nightly.timer"));
    try std.testing.expect(hasAction(migration_plan.actions, .install_systemd_unit, "services/install-unit/ssh.socket"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_systemd_unit, "services/enable/ssh.socket"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-socket/ssh.socket"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-socket/dbus.socket"));
    try std.testing.expect(hasAction(migration_plan.actions, .copy_home_config, "services/install-user-unit/deploy:syncthing.service"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_user_systemd_unit, "services/enable-user-unit/deploy:syncthing.service"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-user-unit/deploy:syncthing.service"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-user-unit/deploy:podman.socket"));
    for (migration_plan.actions) |action| {
        if (action.action_type == .manual_step) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
        }
        if (std.mem.eql(u8, action.id, "services/install-unit/backup.timer")) {
            try std.testing.expectEqualStrings("/etc/systemd/system/backup.timer", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/install-unit/ssh.socket")) {
            try std.testing.expectEqualStrings("/etc/systemd/system/ssh.socket", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/install-user-unit/deploy:syncthing.service")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("deploy", action.owner.?);
            try std.testing.expectEqualStrings("/home/deploy/.config/systemd/user/syncthing.service", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/enable-user-unit/deploy:syncthing.service")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("deploy", action.owner.?);
            try std.testing.expectEqualStrings("deploy:syncthing.service", action.subject);
        }
    }
}

test "builder creates manual review for active source service runtime drift" {
    var source_units = [_]inventory.ServiceUnit{.{
        .name = "worker.service",
        .state = .enabled,
        .active_state = .active,
        .custom = false,
    }};
    var target_units = [_]inventory.ServiceUnit{.{
        .name = "worker.service",
        .state = .enabled,
        .active_state = .inactive,
        .custom = false,
    }};
    const source = fixture(.{
        .services = .{ .init_system = "systemd", .units = source_units[0..] },
    });
    const target = fixture(.{
        .services = .{ .init_system = "systemd", .units = target_units[0..] },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "services/review-runtime/worker.service"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "services/review-runtime/worker.service")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("worker.service", action.subject);
        }
    }
}

test "builder creates service review actions for xdg autostart entries" {
    var source_autostart = [_]inventory.XdgAutostartEntry{
        .{
            .scope = .system,
            .user = null,
            .name = "nm-applet.desktop",
            .path = "/etc/xdg/autostart/nm-applet.desktop",
        },
        .{
            .scope = .user,
            .user = "deploy",
            .name = "syncthing-start.desktop",
            .path = "/home/deploy/.config/autostart/syncthing-start.desktop",
        },
        .{
            .scope = .user,
            .user = "deploy",
            .name = "keep.desktop",
            .path = "/home/deploy/.config/autostart/keep.desktop",
        },
    };
    var target_autostart = [_]inventory.XdgAutostartEntry{.{
        .scope = .user,
        .user = "deploy",
        .name = "keep.desktop",
        .path = "/home/deploy/.config/autostart/keep.desktop",
    }};
    const source = fixture(.{
        .services = .{
            .init_system = "systemd",
            .units = &.{},
            .xdg_autostart = source_autostart[0..],
        },
    });
    const target = fixture(.{
        .services = .{
            .init_system = "systemd",
            .units = &.{},
            .xdg_autostart = target_autostart[0..],
        },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .write_file, "services/install-xdg-autostart/system:nm-applet.desktop"));
    try std.testing.expect(hasAction(migration_plan.actions, .copy_home_config, "services/install-xdg-autostart/deploy:syncthing-start.desktop"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-xdg-autostart/system:nm-applet.desktop"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-xdg-autostart/deploy:syncthing-start.desktop"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-xdg-autostart/deploy:keep.desktop"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "services/install-xdg-autostart/system:nm-applet.desktop")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("/etc/xdg/autostart/nm-applet.desktop", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/install-xdg-autostart/deploy:syncthing-start.desktop")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("deploy", action.owner.?);
            try std.testing.expectEqualStrings("/home/deploy/.config/autostart/syncthing-start.desktop", action.subject);
        }
    }
}

test "builder creates service review actions for sysv init scripts" {
    var source_sysv = [_]inventory.SysvInitScript{
        .{
            .name = "legacy",
            .path = "/etc/init.d/legacy",
            .enabled = true,
            .runlevels = "2,3,5",
        },
        .{
            .name = "keep",
            .path = "/etc/init.d/keep",
            .enabled = true,
            .runlevels = "2",
        },
        .{
            .name = "cleanup",
            .path = "/etc/init.d/cleanup",
            .enabled = true,
            .runlevels = "3",
        },
    };
    var target_sysv = [_]inventory.SysvInitScript{
        .{
            .name = "keep",
            .path = "/etc/init.d/keep",
            .enabled = true,
            .runlevels = "2",
        },
        .{
            .name = "cleanup",
            .path = "/etc/init.d/cleanup",
            .enabled = true,
            .runlevels = "2,3",
        },
    };
    const source = fixture(.{
        .services = .{
            .init_system = "sysvinit",
            .units = &.{},
            .sysv_init = source_sysv[0..],
        },
    });
    const target = fixture(.{
        .services = .{
            .init_system = "sysvinit",
            .units = &.{},
            .sysv_init = target_sysv[0..],
        },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .write_file, "services/install-sysv-init/legacy"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_sysv_init, "services/enable-sysv-init/legacy"));
    try std.testing.expect(hasAction(migration_plan.actions, .disable_sysv_init, "services/disable-sysv-init/cleanup"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-sysv-init/legacy"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-sysv-init/keep"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-sysv-init/cleanup"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "services/install-sysv-init/legacy")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("/etc/init.d/legacy", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/enable-sysv-init/legacy")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("legacy:2,3,5", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/disable-sysv-init/cleanup")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("cleanup:2", action.subject);
        }
    }
}

test "builder creates service review actions for openrc services" {
    var source_openrc = [_]inventory.OpenRcService{
        .{
            .name = "nginx",
            .path = "/etc/init.d/nginx",
            .enabled = true,
            .runlevels = "default",
        },
        .{
            .name = "keep",
            .path = "/etc/init.d/keep",
            .enabled = true,
            .runlevels = "boot",
        },
        .{
            .name = "cleanup",
            .path = "/etc/init.d/cleanup",
            .enabled = true,
            .runlevels = "default",
        },
    };
    var target_openrc = [_]inventory.OpenRcService{
        .{
            .name = "keep",
            .path = "/etc/init.d/keep",
            .enabled = true,
            .runlevels = "boot",
        },
        .{
            .name = "cleanup",
            .path = "/etc/init.d/cleanup",
            .enabled = true,
            .runlevels = "default,boot",
        },
    };
    const source = fixture(.{
        .services = .{
            .init_system = "openrc",
            .units = &.{},
            .openrc = source_openrc[0..],
        },
    });
    const target = fixture(.{
        .services = .{
            .init_system = "openrc",
            .units = &.{},
            .openrc = target_openrc[0..],
        },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .write_file, "services/install-openrc/nginx"));
    try std.testing.expect(hasAction(migration_plan.actions, .enable_openrc_service, "services/enable-openrc/nginx"));
    try std.testing.expect(hasAction(migration_plan.actions, .disable_openrc_service, "services/disable-openrc/cleanup"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-openrc/nginx"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-openrc/keep"));
    try std.testing.expect(!hasAction(migration_plan.actions, .manual_step, "services/review-openrc/cleanup"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "services/install-openrc/nginx")) {
            try std.testing.expectEqual(plan.ModuleName.services, action.module);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("/etc/init.d/nginx", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/enable-openrc/nginx")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("nginx:default", action.subject);
        }
        if (std.mem.eql(u8, action.id, "services/disable-openrc/cleanup")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expectEqualStrings("cleanup:boot", action.subject);
        }
    }
}

test "builder creates selective home config copy actions" {
    var source_home_configs = [_]inventory.HomeConfig{
        .{
            .user = "deploy",
            .path = "/home/deploy/.bashrc",
            .relative_path = ".bashrc",
            .present = true,
            .directory = false,
            .kind = .shell,
            .size = 20,
        },
        .{
            .user = "deploy",
            .path = "/home/deploy/.config/nvim",
            .relative_path = ".config/nvim",
            .present = true,
            .directory = true,
            .kind = .editor,
            .size = 0,
        },
        .{
            .user = "deploy",
            .path = "/home/deploy/.ssh/config",
            .relative_path = ".ssh/config",
            .present = true,
            .directory = false,
            .kind = .ssh,
            .size = 40,
        },
    };
    var target_home_configs = [_]inventory.HomeConfig{
        .{
            .user = "deploy",
            .path = "/home/deploy/.bashrc",
            .relative_path = ".bashrc",
            .present = true,
            .directory = false,
            .kind = .shell,
            .size = 15,
        },
    };
    const source = fixture(.{
        .home_configs = .{ .configs = source_home_configs[0..], .truncated = false },
    });
    const target = fixture(.{
        .home_configs = .{ .configs = target_home_configs[0..], .truncated = false },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(!hasAction(migration_plan.actions, .copy_home_config, "home-configs/copy//home/deploy/.bashrc"));
    try std.testing.expect(hasAction(migration_plan.actions, .copy_home_config, "home-configs/copy//home/deploy/.config/nvim"));
    try std.testing.expect(hasAction(migration_plan.actions, .copy_home_config, "home-configs/copy//home/deploy/.ssh/config"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "home-configs/copy//home/deploy/.config/nvim")) {
            try std.testing.expect(action.recursive);
            try std.testing.expectEqualStrings("deploy", action.owner.?);
            try std.testing.expectEqual(plan.RiskLevel.medium, action.risk);
        }
        if (std.mem.eql(u8, action.id, "home-configs/copy//home/deploy/.ssh/config")) {
            try std.testing.expect(!action.recursive);
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
        }
    }
}

test "builder does not create actions when inventories are incompatible" {
    var source_explicit = [_][]const u8{"nginx"};
    var source = fixture(.{
        .packages = .{ .explicit = source_explicit[0..], .held = &.{} },
    });
    source.distro.version_id = "22.04";
    const target = fixture(.{});

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(!migration_plan.compatibility.compatible);
    try std.testing.expectEqual(@as(usize, 0), migration_plan.actions.len);
}

test "builder creates app data copy actions with higher risk for database paths" {
    var source_paths = [_]inventory.DataPath{
        .{ .path = "/srv/app", .present = true, .kind = .app_data, .size = 0 },
        .{ .path = "/var/lib/mysql", .present = true, .kind = .database_data, .size = 0 },
    };
    const source = fixture(.{
        .appdata = .{ .paths = source_paths[0..] },
    });
    const target = fixture(.{});

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .copy_data_path, "appdata/copy//srv/app"));
    try std.testing.expect(hasAction(migration_plan.actions, .copy_data_path, "appdata/copy//var/lib/mysql"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "appdata/copy//var/lib/mysql")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
        }
    }
}

test "builder creates project copy actions with higher risk for compose projects" {
    var source_projects = [_]inventory.ProjectRef{
        .{ .root = "/srv/app", .kind = .docker_compose, .manifest_path = "/srv/app/docker-compose.yml" },
        .{ .root = "/opt/tool", .kind = .zig, .manifest_path = "/opt/tool/build.zig" },
    };
    var target_projects = [_]inventory.ProjectRef{
        .{ .root = "/opt/tool", .kind = .zig, .manifest_path = "/opt/tool/build.zig" },
    };
    const source = fixture(.{
        .projects = .{ .projects = source_projects[0..], .truncated = false },
    });
    const target = fixture(.{
        .projects = .{ .projects = target_projects[0..], .truncated = false },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .copy_project_path, "projects/copy//srv/app"));
    try std.testing.expect(hasAction(migration_plan.actions, .start_compose_project, "projects/compose-up//srv/app"));
    try std.testing.expect(hasAction(migration_plan.actions, .verify_compose_project, "projects/compose-verify//srv/app"));
    try std.testing.expect(!hasAction(migration_plan.actions, .copy_project_path, "projects/copy//opt/tool"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "projects/copy//srv/app")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
        }
        if (std.mem.eql(u8, action.id, "projects/compose-up//srv/app")) {
            try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", action.subject);
        }
        if (std.mem.eql(u8, action.id, "projects/compose-verify//srv/app")) {
            try std.testing.expectEqualStrings("/srv/app/docker-compose.yml", action.subject);
        }
    }
}

test "builder creates firewall config actions only for matching firewall backend" {
    var source_configs = [_]inventory.FirewallConfig{
        .{ .path = "/etc/nftables.conf", .present = true, .size = 10 },
        .{ .path = "/etc/iptables", .present = false, .size = 0 },
    };
    var target_configs = [_]inventory.FirewallConfig{
        .{ .path = "/etc/ufw", .present = true, .size = 10 },
    };
    const source = fixture(.{
        .firewall = .{ .backend = .nftables, .configs = source_configs[0..] },
    });
    const target = fixture(.{
        .firewall = .{ .backend = .nftables, .configs = target_configs[0..] },
    });

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .apply_firewall_config, "firewall/apply-config//etc/nftables.conf"));
    for (migration_plan.actions) |action| {
        if (std.mem.eql(u8, action.id, "firewall/apply-config//etc/nftables.conf")) {
            try std.testing.expectEqual(plan.RiskLevel.high, action.risk);
            try std.testing.expect(action.requires_confirmation);
        }
    }

    const incompatible_target = fixture(.{
        .firewall = .{ .backend = .ufw, .configs = target_configs[0..] },
    });
    var incompatible_plan = try builder.build(std.testing.allocator, source, incompatible_target, 0);
    defer incompatible_plan.deinit(std.testing.allocator);

    try std.testing.expect(!hasAction(incompatible_plan.actions, .apply_firewall_config, "firewall/apply-config//etc/nftables.conf"));
}

test "builder creates manual review actions for high-risk scan-only modules" {
    var source_sudoers = [_]inventory.SudoersEntry{.{
        .path = "/etc/sudoers.d/deploy",
        .present = true,
        .kind = .file,
        .size = 24,
        .mode = 440,
        .meaningful_lines = 1,
    }};
    var source_acl = [_]inventory.AclPath{.{
        .path = "/srv/app",
        .present = true,
        .directory = true,
        .has_extended_acl = true,
    }};
    var source_fstab = [_]inventory.FstabEntry{.{
        .device = "UUID=data",
        .mount_point = "/data",
        .fs_type = "xfs",
        .options = "defaults",
    }};
    const source = fixture(.{
        .sudoers = .{ .entries = source_sudoers[0..], .truncated = false },
        .acl = .{ .getfacl_available = true, .paths = source_acl[0..], .truncated = false },
        .security_policy = .{ .selinux = .{ .present = true, .status = .enforcing, .config_present = true, .policy_dirs = 2 } },
        .storage = .{ .fstab_entries = source_fstab[0..], .mounts = &.{}, .truncated = false },
    });
    const target = fixture(.{});

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "sudoers/review//etc/sudoers.d/deploy"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "acl/review//srv/app"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "security-policy/review-selinux/selinux"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "storage/review-fstab//data"));
    for (migration_plan.actions) |action| {
        if (action.action_type == .manual_step) {
            try std.testing.expect(action.requires_confirmation);
            try std.testing.expect(action.risk == .high or action.risk == .critical);
        }
    }
}

test "builder creates manual review actions for container runtime facts" {
    var runtimes = [_]inventory.ContainerRuntime{.{ .kind = .docker, .available = true }};
    var volumes = [_]inventory.ContainerVolume{.{ .name = "app-data", .driver = "local", .scope = "local", .mountpoint = "/var/lib/docker/volumes/app-data/_data" }};
    var networks = [_]inventory.ContainerNetwork{.{ .name = "app-net", .driver = "bridge", .scope = "local" }};
    var compose_files = [_]inventory.ComposeFile{.{ .project_root = "/srv/app", .path = "/srv/app/compose.yml" }};
    var containers = [_]inventory.DockerContainer{.{
        .name = "app",
        .image = "example/app:1",
        .status = "Up",
        .ports = "8080/tcp",
    }};
    const source = fixture(.{
        .docker = .{
            .runtimes = runtimes[0..],
            .containers = containers[0..],
            .volumes = volumes[0..],
            .networks = networks[0..],
            .compose_files = compose_files[0..],
            .truncated = false,
        },
    });
    const target = fixture(.{});

    var migration_plan = try builder.build(std.testing.allocator, source, target, 0);
    defer migration_plan.deinit(std.testing.allocator);

    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "docker/review-runtime/docker"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "docker/review-volume/app-data"));
    try std.testing.expect(hasAction(migration_plan.actions, .copy_data_path, "docker/copy-volume/app-data"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "docker/review-network/app-net"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "docker/review-compose//srv/app"));
    try std.testing.expect(hasAction(migration_plan.actions, .manual_step, "docker/review-container/app"));
}

// 测试辅助：判断计划中是否包含指定 action。
fn hasAction(actions: []const plan.Action, action_type: plan.ActionType, id: []const u8) bool {
    for (actions) |action| {
        if (action.action_type == action_type and std.mem.eql(u8, action.id, id)) return true;
    }
    return false;
}

const FixtureOverrides = struct {
    packages: inventory.PackageInventory = .{ .explicit = &.{}, .held = &.{} },
    services: inventory.ServiceInventory = .{ .init_system = "unknown", .units = &.{} },
    cron: inventory.CronInventory = .{ .entries = &.{} },
    users: inventory.UserInventory = .{ .users = &.{}, .groups = &.{} },
    ssh: inventory.SshInventory = .{ .authorized_keys = &.{}, .sshd_config_present = false, .client_config_present = false },
    configs: inventory.ConfigInventory = .{ .files = &.{} },
    home_configs: inventory.HomeConfigInventory = .{ .configs = &.{}, .truncated = false },
    appdata: inventory.AppDataInventory = .{ .paths = &.{} },
    projects: inventory.ProjectInventory = .{ .projects = &.{}, .truncated = false },
    docker: inventory.DockerInventory = .{ .runtimes = &.{}, .containers = &.{}, .volumes = &.{}, .networks = &.{}, .compose_files = &.{}, .truncated = false },
    firewall: inventory.FirewallInventory = .{ .backend = .unknown, .configs = &.{} },
    sudoers: inventory.SudoersInventory = .{ .entries = &.{}, .truncated = false },
    acl: inventory.AclInventory = .{ .getfacl_available = false, .paths = &.{}, .truncated = false },
    security_policy: inventory.SecurityPolicyInventory = .{},
    storage: inventory.StorageInventory = .{ .fstab_entries = &.{}, .mounts = &.{}, .truncated = false },
};

// 测试辅助：构造可覆盖部分字段的 inventory。
fn fixture(overrides: FixtureOverrides) inventory.Inventory {
    return .{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = "host",
            .machine_id_hash = null,
            .kernel_release = "test",
            .arch = .x86_64,
        },
        .distro = .{
            .id = "ubuntu",
            .id_like = &.{},
            .version_id = "24.04",
            .pretty_name = "Ubuntu 24.04 LTS",
        },
        .package_manager = .{
            .kind = .apt,
            .version = "apt test",
            .repos = &.{},
        },
        .modules = .{
            .packages = overrides.packages,
            .services = overrides.services,
            .cron = overrides.cron,
            .users = overrides.users,
            .ssh = overrides.ssh,
            .sudoers = overrides.sudoers,
            .acl = overrides.acl,
            .configs = overrides.configs,
            .dev_env = .{ .tools = &.{}, .configs = &.{}, .proxy_vars = &.{} },
            .home_configs = overrides.home_configs,
            .appdata = overrides.appdata,
            .projects = overrides.projects,
            .processes = .{ .processes = &.{}, .truncated = false },
            .network = .{ .listeners = &.{}, .truncated = false },
            .docker = overrides.docker,
            .firewall = overrides.firewall,
            .storage = overrides.storage,
            .security_policy = overrides.security_policy,
        },
        .scan = .{
            .scanned_at_unix = 0,
            .warnings = &.{},
        },
    };
}
