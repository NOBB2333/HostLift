const std = @import("std");
const plan = @import("../plan/schema.zig");
const registry = @import("registry.zig");

test "registry exposes all currently planned modules" {
    const expected = [_]plan.ModuleName{
        .packages,
        .services,
        .cron,
        .users,
        .ssh,
        .configs,
        .home_configs,
        .appdata,
        .projects,
        .resources,
        .network,
        .firewall,
        .docker,
        .sudoers,
        .acl,
        .security_policy,
        .storage,
        .system_baseline,
    };

    try std.testing.expectEqual(expected.len, registry.all().len);
    for (expected) |module_name| {
        const module_handler = registry.find(module_name) orelse return error.MissingHandler;
        try std.testing.expectEqual(module_name, module_handler.name);
        try std.testing.expect(module_handler.planActions != null);
    }
}

test "plan registry keeps low-level observation-only modules out of planning" {
    try std.testing.expect(registry.find(.dev_env) == null);
    try std.testing.expect(registry.find(.security) == null);
    try std.testing.expect(registry.find(.processes) == null);
    try std.testing.expect(registry.find(.kernel) == null);
}

test "high-risk scan-only modules expose plan review but no apply" {
    const review_modules = [_]plan.ModuleName{ .network, .sudoers, .acl, .security_policy, .storage, .system_baseline };
    for (review_modules) |module_name| {
        const module_handler = registry.find(module_name) orelse return error.MissingHandler;
        try std.testing.expect(module_handler.planActions != null);
        try std.testing.expect(module_handler.apply == null);
        try std.testing.expect(module_handler.verify == null);
        try std.testing.expect(module_handler.rollback == null);
    }
}

test "registry exposes scanner handlers including observation-only modules" {
    var found_docker = false;
    var found_network = false;
    var found_dev_env = false;
    var found_security_policy = false;
    var found_processes = false;
    var found_resources = false;
    var found_sudoers = false;
    var found_storage = false;
    var found_acl = false;
    var found_system_baseline = false;

    for (registry.allScan()) |module_handler| {
        try std.testing.expect(module_handler.scan != null);
        switch (module_handler.name) {
            .docker => found_docker = true,
            .network => found_network = true,
            .dev_env => found_dev_env = true,
            .security_policy => found_security_policy = true,
            .processes => found_processes = true,
            .resources => found_resources = true,
            .sudoers => found_sudoers = true,
            .storage => found_storage = true,
            .acl => found_acl = true,
            .system_baseline => found_system_baseline = true,
            else => {},
        }
    }

    try std.testing.expect(found_docker);
    try std.testing.expect(found_network);
    try std.testing.expect(found_dev_env);
    try std.testing.expect(found_security_policy);
    try std.testing.expect(found_processes);
    try std.testing.expect(found_resources);
    try std.testing.expect(found_sudoers);
    try std.testing.expect(found_storage);
    try std.testing.expect(found_acl);
    try std.testing.expect(found_system_baseline);
}

test "registry classifies current apply action support" {
    const package_action = plan.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install package",
        .risk = .low,
        .requires_confirmation = false,
    };
    const config_action = plan.Action{
        .id = "configs/write//etc/hosts",
        .module = .configs,
        .action_type = .write_file,
        .description = "Copy config",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const manual_action = plan.Action{
        .id = "packages/review-held/nginx",
        .module = .packages,
        .action_type = .manual_step,
        .description = "Review held package",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const future_action = plan.Action{
        .id = "docker/run/example",
        .module = .docker,
        .action_type = .run_command,
        .description = "Future docker action",
        .risk = .high,
        .requires_confirmation = true,
    };

    try std.testing.expectEqual(.handler, try registry.ensureApplySupported(package_action));
    try std.testing.expectEqual(.handler, try registry.ensureApplySupported(config_action));
    try std.testing.expectError(error.UnsupportedApplyAction, registry.ensureApplySupported(manual_action));
    try std.testing.expectError(error.UnsupportedApplyAction, registry.ensureApplySupported(future_action));
}

test "registry exposes handler apply for all currently executable modules" {
    try std.testing.expect((registry.find(.packages) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.services) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.users) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.projects) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.configs) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.cron) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.ssh) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.home_configs) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.appdata) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.resources) orelse return error.MissingHandler).apply != null);
    try std.testing.expect((registry.find(.firewall) orelse return error.MissingHandler).apply != null);
}

test "registry exposes apply requirement declarations for executable modules" {
    const migration_plan = plan.MigrationPlan{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{0} ** 32,
        .package_manager = .apt,
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
    const ctx = registry.ApplyRequirementsContext{ .migration_plan = migration_plan };

    const package_requirements = (registry.find(.packages) orelse return error.MissingHandler).applyRequirements.?(ctx, .{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .subject = "nginx",
        .description = "Install package",
        .risk = .low,
        .requires_confirmation = false,
    });
    try std.testing.expectEqual(@as(usize, 2), package_requirements.len);
    try std.testing.expectEqualStrings("apt-get", package_requirements[0]);
    try std.testing.expectEqualStrings("dpkg-query", package_requirements[1]);

    const service_requirements = (registry.find(.services) orelse return error.MissingHandler).applyRequirements.?(ctx, .{
        .id = "services/install-unit/nginx.service",
        .module = .services,
        .action_type = .install_systemd_unit,
        .subject = "/etc/systemd/system/nginx.service",
        .description = "Install unit",
        .risk = .medium,
        .requires_confirmation = false,
    });
    try std.testing.expectEqual(@as(usize, 1), service_requirements.len);
    try std.testing.expectEqualStrings("systemctl", service_requirements[0]);

    const ssh_requirements = (registry.find(.ssh) orelse return error.MissingHandler).applyRequirements.?(ctx, .{
        .id = "ssh/authorized-keys/deploy",
        .module = .ssh,
        .action_type = .add_authorized_key,
        .subject = "/home/deploy/.ssh/authorized_keys",
        .description = "Install keys",
        .risk = .medium,
        .requires_confirmation = true,
    });
    try std.testing.expectEqual(@as(usize, 2), ssh_requirements.len);
    try std.testing.expectEqualStrings("chmod", ssh_requirements[0]);
    try std.testing.expectEqualStrings("chown", ssh_requirements[1]);
}

test "registry apply requirements include conditional permission and firewall dependencies" {
    const migration_plan = plan.MigrationPlan{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{0} ** 32,
        .package_manager = .apt,
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

    const home_ctx = registry.ApplyRequirementsContext{ .migration_plan = migration_plan };
    const home_requirements = (registry.find(.home_configs) orelse return error.MissingHandler).applyRequirements.?(home_ctx, .{
        .id = "home-configs/copy/alice/.ssh/config",
        .module = .home_configs,
        .action_type = .copy_home_config,
        .subject = "/home/alice/.ssh/config",
        .description = "Install SSH client config",
        .risk = .medium,
        .requires_confirmation = true,
    });
    try std.testing.expectEqual(@as(usize, 3), home_requirements.len);
    try std.testing.expectEqualStrings("mkdir", home_requirements[0]);
    try std.testing.expectEqualStrings("chown", home_requirements[1]);
    try std.testing.expectEqualStrings("chmod", home_requirements[2]);

    const firewall_ctx = registry.ApplyRequirementsContext{
        .migration_plan = migration_plan,
        .options = .{
            .firewall_reload = true,
            .firewall_recovery_window_seconds = 120,
        },
    };
    const firewall_requirements = (registry.find(.firewall) orelse return error.MissingHandler).applyRequirements.?(firewall_ctx, .{
        .id = "firewall/apply-config//etc/nftables.conf",
        .module = .firewall,
        .action_type = .apply_firewall_config,
        .subject = "/etc/nftables.conf",
        .description = "Apply nftables config",
        .risk = .high,
        .requires_confirmation = true,
    });
    try std.testing.expectEqual(@as(usize, 8), firewall_requirements.len);
    try std.testing.expectEqualStrings("grep", firewall_requirements[0]);
    try std.testing.expectEqualStrings("nft", firewall_requirements[1]);
    try std.testing.expectEqualStrings("chmod", firewall_requirements[2]);
    try std.testing.expectEqualStrings("systemd-run", firewall_requirements[3]);
    try std.testing.expectEqualStrings("/bin/sh", firewall_requirements[4]);
    try std.testing.expectEqualStrings("true", firewall_requirements[5]);
    try std.testing.expectEqualStrings("systemctl", firewall_requirements[6]);
    try std.testing.expectEqualStrings("rm", firewall_requirements[7]);
}

test "registry exposes verify where checks are currently implemented" {
    try std.testing.expect((registry.find(.packages) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.services) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.users) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.projects) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.configs) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.ssh) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.home_configs) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.appdata) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.resources) orelse return error.MissingHandler).verify != null);
    try std.testing.expect((registry.find(.firewall) orelse return error.MissingHandler).verify != null);
}

test "registry exposes rollback for file and compose-capable modules" {
    try std.testing.expect((registry.find(.packages) orelse return error.MissingHandler).rollback != null);
    try std.testing.expect((registry.find(.services) orelse return error.MissingHandler).rollback != null);
    try std.testing.expect((registry.find(.users) orelse return error.MissingHandler).rollback != null);
    try std.testing.expect((registry.find(.projects) orelse return error.MissingHandler).rollback != null);
    try std.testing.expect((registry.find(.configs) orelse return error.MissingHandler).rollback != null);
    try std.testing.expect((registry.find(.resources) orelse return error.MissingHandler).rollback != null);
    try std.testing.expect((registry.find(.firewall) orelse return error.MissingHandler).rollback != null);
}
