const apply_actions = @import("actions.zig");
const plan_schema = @import("../plan/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// 为不需要文件备份的 action 写入命令型 rollback entry；返回是否已处理。
pub fn writeCommandRollbackEntry(
    writer: anytype,
    action: plan_schema.Action,
    host: []const u8,
    created_at: i64,
) !bool {
    const subject = apply_actions.subject(action);
    switch (action.action_type) {
        .enable_systemd_unit,
        .enable_user_systemd_unit,
        .enable_openrc_service,
        .disable_openrc_service,
        .enable_sysv_init,
        .disable_sysv_init,
        .install_package,
        .create_user,
        .create_group,
        .start_compose_project,
        => {
            if (subject.len == 0) return error.MissingApplySubject;
            try rollback_manifest.writeEntry(writer, .{
                .created_at = created_at,
                .host = host,
                .action_id = action.id,
                .action_type = @tagName(action.action_type),
                .original_path = "",
                .backup_path = "",
                .subject = subject,
            });
            return true;
        },
        else => return false,
    }
}
