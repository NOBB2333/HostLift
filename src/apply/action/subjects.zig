const std = @import("std");
const plan_schema = @import("../../plan/schema.zig");
const services = @import("services.zig");

// 根据 action 类型计算需要提前备份的远程目标路径。
pub fn backupTargetForAction(allocator: std.mem.Allocator, action: plan_schema.Action) !?[]const u8 {
    return switch (action.action_type) {
        .install_systemd_unit => {
            const source_path = subject(action);
            if (source_path.len == 0) return error.MissingApplySubject;
            return try services.targetPath(allocator, action, source_path);
        },
        .write_file, .install_cron_entry, .add_authorized_key, .copy_home_config, .apply_firewall_config => {
            const action_subject = subject(action);
            if (action_subject.len == 0) return error.MissingApplySubject;
            return try allocator.dupe(u8, action_subject);
        },
        else => null,
    };
}

// 根据 action subject 或 id 前缀推导实际操作对象。
pub fn subject(action: plan_schema.Action) []const u8 {
    if (action.subject.len > 0) return action.subject;
    const prefix = switch (action.action_type) {
        .install_package => "packages/install/",
        .enable_systemd_unit => "services/enable/",
        .enable_user_systemd_unit => "services/enable-user-unit/",
        .enable_openrc_service => "services/enable-openrc/",
        .disable_openrc_service => "services/disable-openrc/",
        .enable_sysv_init => "services/enable-sysv-init/",
        .disable_sysv_init => "services/disable-sysv-init/",
        .install_systemd_unit => "services/install-unit/",
        .write_file => "configs/write/",
        .copy_home_config => "home-configs/copy/",
        .copy_data_path => "appdata/copy/",
        .copy_project_path => "projects/copy/",
        .start_compose_project => "projects/compose-up/",
        .verify_compose_project => "projects/compose-verify/",
        .install_cron_entry => "cron/install/",
        .apply_firewall_config => "firewall/apply-config/",
        .add_authorized_key => "ssh/authorized-keys/",
        .create_group => "users/create-group/",
        .create_user => "users/create-user/",
        else => "",
    };
    if (prefix.len > 0 and std.mem.startsWith(u8, action.id, prefix)) return action.id[prefix.len..];
    return "";
}
