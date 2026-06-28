const std = @import("std");
const schema = @import("schema.zig");

test "rollback manifest accepts service enable rollback subject without paths" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable/nginx.service",
        .action_type = "enable_systemd_unit",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx.service",
    };
    try schema.validateEntry(entry);

    const missing_subject = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable/nginx.service",
        .action_type = "enable_systemd_unit",
        .original_path = "",
        .backup_path = "",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(missing_subject));
}

test "rollback manifest accepts user systemd enable rollback subject without paths" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-user-unit/deploy:syncthing.service",
        .action_type = "enable_user_systemd_unit",
        .original_path = "",
        .backup_path = "",
        .subject = "deploy:syncthing.service",
    };
    try schema.validateEntry(entry);

    const unsafe_subject = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-user-unit/deploy:syncthing.service",
        .action_type = "enable_user_systemd_unit",
        .original_path = "",
        .backup_path = "",
        .subject = "deploy:syncthing.service;rm",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(unsafe_subject));
}

test "rollback manifest accepts OpenRC enable rollback subject without paths" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-openrc/nginx",
        .action_type = "enable_openrc_service",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx:default,boot",
    };
    try schema.validateEntry(entry);

    const unsafe_subject = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-openrc/nginx",
        .action_type = "enable_openrc_service",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx:default;rm",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(unsafe_subject));
}

test "rollback manifest accepts OpenRC disable rollback subject without paths" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/disable-openrc/nginx",
        .action_type = "disable_openrc_service",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx:boot",
    };
    try schema.validateEntry(entry);
}

test "rollback manifest accepts SysV runlevel rollback subject without paths" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/enable-sysv-init/legacy",
        .action_type = "enable_sysv_init",
        .original_path = "",
        .backup_path = "",
        .subject = "legacy:2,3,5",
    };
    try schema.validateEntry(entry);

    const disable_entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "services/disable-sysv-init/legacy",
        .action_type = "disable_sysv_init",
        .original_path = "",
        .backup_path = "",
        .subject = "legacy:2",
    };
    try schema.validateEntry(disable_entry);
}

test "rollback manifest accepts package install rollback subject" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx",
    };
    try schema.validateEntry(entry);

    const unsafe_subject = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .original_path = "",
        .backup_path = "",
        .subject = "nginx;rm",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(unsafe_subject));
}

test "rollback manifest accepts user and group creation rollback subjects" {
    const user_entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "users/create-user/deploy",
        .action_type = "create_user",
        .original_path = "",
        .backup_path = "",
        .subject = "deploy",
    };
    try schema.validateEntry(user_entry);

    const group_entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "users/create-group/deploy",
        .action_type = "create_group",
        .original_path = "",
        .backup_path = "",
        .subject = "deploy",
    };
    try schema.validateEntry(group_entry);
}

test "rollback manifest accepts compose start rollback subject path" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "projects/compose-up//srv/app",
        .action_type = "start_compose_project",
        .original_path = "",
        .backup_path = "",
        .subject = "/srv/app/docker-compose.yml",
    };
    try schema.validateEntry(entry);

    const relative_subject = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "projects/compose-up//srv/app",
        .action_type = "start_compose_project",
        .original_path = "",
        .backup_path = "",
        .subject = "srv/app/docker-compose.yml",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(relative_subject));
}

test "rollback manifest accepts delete-created-path rollback entry" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "resources/copy//srv/app",
        .action_type = "delete_created_path",
        .original_path = "/srv/app",
        .backup_path = "",
        .subject = "stat:v1:4096:12:1710000000",
    };
    try schema.validateEntry(entry);

    const unsafe = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "resources/copy//srv/app",
        .action_type = "delete_created_path",
        .original_path = "/srv/app*",
        .backup_path = "",
        .subject = "stat:v1:4096:12:1710000000",
    };
    try std.testing.expectError(error.InvalidTransferPath, schema.validateEntry(unsafe));

    const missing_baseline = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "resources/copy//srv/app",
        .action_type = "delete_created_path",
        .original_path = "/srv/app",
        .backup_path = "",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(missing_baseline));

    const incomplete_baseline = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "resources/copy//srv/app",
        .action_type = "delete_created_path",
        .original_path = "/srv/app",
        .backup_path = "",
        .subject = "stat:v1:4096:12",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(incomplete_baseline));
}

test "rollback manifest entries validate schema host and absolute paths" {
    const entry = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "configs/write//etc/hosts",
        .action_type = "write_file",
        .original_path = "/etc/hosts",
        .backup_path = "/var/lib/hostlift/backups/123/etc/hosts",
    };
    try schema.validateEntry(entry);

    const bad_schema = schema.Entry{
        .schema_version = "bad",
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "configs/write//etc/hosts",
        .action_type = "write_file",
        .original_path = "/etc/hosts",
        .backup_path = "/var/lib/hostlift/backups/123/etc/hosts",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(bad_schema));

    const relative_path = schema.Entry{
        .created_at = 123,
        .host = "root@192.0.2.10",
        .action_id = "configs/write//etc/hosts",
        .action_type = "write_file",
        .original_path = "etc/hosts",
        .backup_path = "/var/lib/hostlift/backups/123/etc/hosts",
    };
    try std.testing.expectError(error.InvalidRollbackManifestEntry, schema.validateEntry(relative_path));
}
