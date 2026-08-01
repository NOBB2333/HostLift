const inventory = @import("../inventory/schema.zig");

pub const schema_version_v1 = "hostlift.plan.v1";
pub const schema_version_v2 = "hostlift.plan.v2";
pub const current_schema_version = schema_version_v2;
pub const manual_task_schema_version = "hostlift.manual_task.v2";
pub const manual_evidence_schema_version = "hostlift.manual_evidence.v1";

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
    postgresql_dump,
    postgresql_target_baseline,
    postgresql_transfer,
    postgresql_restore,
    postgresql_verify,
    reinstall_download,
    reinstall_execute,
    reinstall_verify,
    start_compose_project,
    verify_compose_project,
    apply_firewall_config,
    run_command,
    manual_step,
};

// action 的迁移阶段；枚举顺序也是依赖允许的单向阶段顺序。
pub const ActionPhase = enum {
    prepare,
    quiesce,
    transfer,
    restore,
    configure,
    start,
    verify,
    cutover,
    finalize,
};

// AI 可直接分发的人工任务类型，不依赖 description 文本分类。
pub const ManualTaskKind = enum {
    review,
    reinstall,
    data_restore,
    quiesce,
    health_check,
    merge,
    rescan,
    capacity_review,
    service_start,
    cleanup,
};

pub const ManualConditionKind = enum {
    approval,
    source_reviewed,
    writers_stopped,
    backup_verified,
    capacity_verified,
};

pub const ManualProbeKind = enum {
    manual_evidence,
    command,
    systemd,
    tcp,
    http,
    container,
    log,
};

pub const ManualRollbackPolicy = enum {
    none,
    manual,
    compensating_action,
    provider_required,
};

pub const ReinstallKind = enum {
    verified_script,
    verified_binary,
};

// 进入 plan 的可信重装合同；不保存 secret，argv 只能引用受控 artifact 占位符。
pub const ReinstallSpec = struct {
    schema_version: []const u8,
    recipe_id: []const u8,
    source_manual_action_id: []const u8,
    kind: ReinstallKind,
    source_url: []const u8,
    sha256: []const u8,
    artifact_size_bytes: u64,
    target_distro_id: []const u8,
    target_distro_version: []const u8,
    target_arch: []const u8,
    install_argv: []const []const u8,
    verify_argv: []const []const u8,
    verify_stdout_sha256: []const u8,
    managed_paths: []const []const u8,
};

pub const ManualInput = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    secret_ref: ?[]const u8 = null,
    required: bool = true,
};

pub const ManualCondition = struct {
    kind: ManualConditionKind,
    target: []const u8,
    required: bool = true,
};

pub const ManualOutput = struct {
    name: []const u8,
    required: bool = true,
};

pub const ManualProbe = struct {
    kind: ManualProbeKind,
    target: []const u8,
    required: bool = true,
};

// manual_step.v2 机器合同；AI 可按 provider/kind/输入输出执行并提交 evidence。
pub const ManualTask = struct {
    schema_version: []const u8,
    kind: ManualTaskKind,
    provider: []const u8,
    inputs: []ManualInput,
    secret_refs: ?[]const []const u8 = null,
    preconditions: []ManualCondition,
    expected_outputs: []ManualOutput,
    verify_probes: []ManualProbe,
    rollback_policy: ManualRollbackPolicy,
    evidence_schema: []const u8,
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
    phase: ?ActionPhase = null,
    depends_on: ?[]const []const u8 = null,
    manual_task: ?ManualTask = null,
    reinstall: ?ReinstallSpec = null,
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
        for (self.actions) |action| deinitAction(allocator, action);
        allocator.free(self.actions);
    }
};

// 释放 builder 或 JSON parser 为单个 action 持有的全部嵌套字段。
pub fn deinitAction(allocator: @import("std").mem.Allocator, action: Action) void {
    allocator.free(action.id);
    allocator.free(action.subject);
    if (action.home) |home| allocator.free(home);
    if (action.shell) |shell| allocator.free(shell);
    if (action.owner) |owner| allocator.free(owner);
    allocator.free(action.description);
    if (action.depends_on) |dependency_ids| {
        for (dependency_ids) |dependency| allocator.free(dependency);
        allocator.free(dependency_ids);
    }
    if (action.manual_task) |task| deinitManualTask(allocator, task);
    if (action.reinstall) |spec| deinitReinstallSpec(allocator, spec);
}

// 释放 plan action 持有的可信重装合同。
pub fn deinitReinstallSpec(allocator: @import("std").mem.Allocator, spec: ReinstallSpec) void {
    allocator.free(spec.schema_version);
    allocator.free(spec.recipe_id);
    allocator.free(spec.source_manual_action_id);
    allocator.free(spec.source_url);
    allocator.free(spec.sha256);
    allocator.free(spec.target_distro_id);
    allocator.free(spec.target_distro_version);
    allocator.free(spec.target_arch);
    for (spec.install_argv) |arg| allocator.free(arg);
    allocator.free(spec.install_argv);
    for (spec.verify_argv) |arg| allocator.free(arg);
    allocator.free(spec.verify_argv);
    allocator.free(spec.verify_stdout_sha256);
    for (spec.managed_paths) |path| allocator.free(path);
    allocator.free(spec.managed_paths);
}

// 释放 manual_step.v2 合同中的 provider、输入、前置条件、探针和 evidence schema。
pub fn deinitManualTask(allocator: @import("std").mem.Allocator, task: ManualTask) void {
    allocator.free(task.schema_version);
    allocator.free(task.provider);
    for (task.inputs) |input| {
        allocator.free(input.name);
        if (input.value) |value| allocator.free(value);
        if (input.secret_ref) |secret_ref| allocator.free(secret_ref);
    }
    allocator.free(task.inputs);
    if (task.secret_refs) |secret_refs| {
        for (secret_refs) |secret_ref| allocator.free(secret_ref);
        allocator.free(secret_refs);
    }
    for (task.preconditions) |condition| allocator.free(condition.target);
    allocator.free(task.preconditions);
    for (task.expected_outputs) |output| allocator.free(output.name);
    allocator.free(task.expected_outputs);
    for (task.verify_probes) |probe| allocator.free(probe.target);
    allocator.free(task.verify_probes);
    allocator.free(task.evidence_schema);
}

// 返回 action 的依赖列表；旧 v1 action 没有 depends_on 时视为空。
pub fn dependencies(action: Action) []const []const u8 {
    return action.depends_on orelse &.{};
}
