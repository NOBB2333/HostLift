const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("../plan/schema.zig");
const remote_options = @import("../remote/options.zig");
const remote_schema = @import("../remote/schema.zig");
const rollback_manifest = @import("../rollback/manifest.zig");

// 模块扫描上下文，持有 IO、分配器和模块清单指针。
pub const ScanContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    modules: *inventory.ModuleInventory,
};

// 模块规划上下文，包含源和目标清单用于生成 action。
pub const PlanContext = struct {
    allocator: std.mem.Allocator,
    source: inventory.ModuleInventory,
    target: inventory.ModuleInventory,
};

// 模块执行上下文，包含迁移计划、主机信息和执行选项。
pub const ApplyContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan.MigrationPlan,
    source_host: ?[]const u8,
    target_host: []const u8,
    options: ApplyOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

// apply 前置依赖查询上下文，用于声明目标机所需命令。
pub const ApplyRequirementsContext = struct {
    migration_plan: plan.MigrationPlan,
    options: ApplyOptions = .{},
};

// apply 执行选项，包含防火墙、SSH 端口和传输相关参数。
pub const ApplyOptions = struct {
    firewall_reload: bool = false,
    ssh_port: u16 = 22,
    firewall_recovery_window_seconds: u32 = 0,
    execution: remote_options.ExecutionOptions = .{},
    transfer_transport: remote_schema.TransferTransport = .scp,
    transfer_partial: bool = false,
    transfer_resume: bool = false,
    transfer_bandwidth_limit_kbps: ?u32 = null,
};

// 验证阶段上下文，用于校验 apply 结果。
pub const VerifyContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    migration_plan: plan.MigrationPlan,
    source_host: ?[]const u8 = null,
    target_host: []const u8,
    execution: remote_options.ExecutionOptions = .{},
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

// 回滚执行上下文，包含目标主机和执行选项。
pub const RollbackContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    target_host: []const u8,
    execution: remote_options.ExecutionOptions = .{},
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

// apply 执行结果，记录是否有变更。
pub const ApplyResult = struct {
    changed: bool,
};

// 验证结果，记录是否通过及可选说明。
pub const VerifyResult = struct {
    ok: bool,
    message: []const u8 = "",
};

// 回滚结果，记录是否已恢复。
pub const RollbackResult = struct {
    restored: bool,
};

// 模块处理器契约：每个迁移模块按 scan/plan/apply/verify/rollback 独立接入。
pub const ModuleHandler = struct {
    name: plan.ModuleName,
    scan: ?*const fn (ctx: ScanContext) anyerror!void = null,
    planActions: ?*const fn (ctx: PlanContext, actions: *std.ArrayList(plan.Action)) anyerror!void = null,
    applyRequirements: ?*const fn (ctx: ApplyRequirementsContext, action: plan.Action) []const []const u8 = null,
    apply: ?*const fn (ctx: ApplyContext, action: plan.Action) anyerror!ApplyResult = null,
    verify: ?*const fn (ctx: VerifyContext, action: plan.Action) anyerror!VerifyResult = null,
    rollback: ?*const fn (ctx: RollbackContext, entry: rollback_manifest.Entry) anyerror!RollbackResult = null,
};
