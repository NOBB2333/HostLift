const plan = @import("../plan/schema.zig");
const plan_registry = @import("plan_registry.zig");
const handler = @import("handler.zig");

// 模块 apply 支持方式枚举，当前只有 handler。
pub const ApplySupport = enum {
    handler,
};

// 按 action 查找所属模块处理器；未注册模块视为不可执行。
pub fn findForAction(action: plan.Action) ?handler.ModuleHandler {
    return plan_registry.find(action.module);
}

// 判断当前兼容 executor 是否支持指定 action 类型。
pub fn applySupportForAction(action: plan.Action) ?ApplySupport {
    return switch (action.action_type) {
        .install_package,
        .enable_systemd_unit,
        .enable_user_systemd_unit,
        .enable_openrc_service,
        .disable_openrc_service,
        .enable_sysv_init,
        .disable_sysv_init,
        .create_group,
        .create_user,
        .start_compose_project,
        .verify_compose_project,
        => .handler,

        .copy_data_path,
        .copy_project_path,
        .copy_home_config,
        .write_file,
        .install_cron_entry,
        .add_authorized_key,
        .apply_firewall_config,
        .install_systemd_unit,
        => .handler,

        else => null,
    };
}

// 在 approved apply 前校验 action 已属于注册模块且当前 executor 支持。
pub fn ensureApplySupported(action: plan.Action) !ApplySupport {
    if (findForAction(action) == null) return error.UnsupportedApplyModule;
    return applySupportForAction(action) orelse error.UnsupportedApplyAction;
}
