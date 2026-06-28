const inventory = @import("../inventory/schema.zig");

// 模块名称枚举，列出所有可迁移子系统。
pub const ModuleName = enum {
    packages,
    services,
    cron,
    users,
    ssh,
    sudoers,
    acl,
    configs,
    home_configs,
    appdata,
    projects,
    docker,
    firewall,
    network,
    dev_env,
    resources,
    security,
    security_policy,
    processes,
    kernel,
    storage,
    system_baseline,
};

// 风险等级枚举，从低到严重。
pub const RiskLevel = enum {
    low,
    medium,
    high,
    critical,
};

// 架构兼容性枚举，描述跨架构迁移的兼容程度。
pub const ArchCompatibility = enum {
    independent,
    rebuild_required,
    incompatible,
    unknown,
};

// 兼容性约束结构体，定义源与目标之间的匹配要求。
pub const Compatibility = struct {
    same_distro_required: bool,
    same_version_required: bool,
    arch: ArchCompatibility,
    host_identity_bound: bool,
    cloud_provider_bound: bool,
    hardware_bound: bool,
};

// 兼容性检查结果，包含具体匹配状态和不兼容原因。
pub const CompatibilityResult = struct {
    compatible: bool,
    same_distro: bool,
    same_version: bool,
    same_package_manager: bool,
    same_arch: bool,
    reason: []const u8,
};

// 迁移动作类型枚举，覆盖所有支持的操作种类。
pub const ActionType = enum {
    install_package,
    add_repository,
    write_file,
    merge_file,
    create_directory,
    create_user,
    create_group,
    add_authorized_key,
    install_systemd_unit,
    enable_systemd_unit,
    enable_user_systemd_unit,
    enable_openrc_service,
    disable_openrc_service,
    enable_sysv_init,
    disable_sysv_init,
    install_cron_entry,
    copy_home_config,
    copy_data_path,
    copy_project_path,
    start_compose_project,
    verify_compose_project,
    apply_firewall_config,
    run_command,
    manual_step,
};

// 单条迁移动作，描述一次具体的迁移操作及其风险等级。
pub const Action = struct {
    id: []const u8,
    module: ModuleName,
    action_type: ActionType,
    subject: []const u8 = "",
    uid: ?u32 = null,
    gid: ?u32 = null,
    home: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    description: []const u8,
    risk: RiskLevel,
    requires_confirmation: bool,
    recursive: bool = false,
    file_count: u64 = 0,
};

// 完整迁移计划，包含兼容性判定结果和所有待执行动作。
pub const MigrationPlan = struct {
    schema_version: []const u8,
    source_inventory_hash: [32]u8,
    target_inventory_hash: [32]u8,
    package_manager: inventory.PackageManagerKind = .unknown,
    compatibility: CompatibilityResult,
    actions: []Action,
    created_at: i64,

    // 释放迁移计划中为兼容性原因和 action 字段分配的内存。
    pub fn deinit(self: *MigrationPlan, allocator: @import("std").mem.Allocator) void {
        allocator.free(self.compatibility.reason);
        for (self.actions) |action| {
            allocator.free(action.id);
            allocator.free(action.subject);
            if (action.home) |home| allocator.free(home);
            if (action.shell) |shell| allocator.free(shell);
            if (action.owner) |owner| allocator.free(owner);
            allocator.free(action.description);
        }
        allocator.free(self.actions);
    }
};
