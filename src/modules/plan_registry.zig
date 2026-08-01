const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("../plan/schema.zig");
const handler = @import("handler.zig");

const appdata_rules = @import("../plan/modules/appdata.zig");
const appdata_handler = @import("handlers/appdata.zig");
const configs_rules = @import("../plan/modules/configs.zig");
const command_handler = @import("handlers/command.zig");
const container_review_rules = @import("../plan/modules/container_review.zig");
const cron_rules = @import("../plan/modules/cron.zig");
const firewall_rules = @import("../plan/modules/firewall.zig");
const home_configs_rules = @import("../plan/modules/home_configs.zig");
const acl_review_rules = @import("../plan/modules/acl_review.zig");
const network_review_rules = @import("../plan/modules/network_review.zig");
const packages_rules = @import("../plan/modules/packages.zig");
const project_handler = @import("handlers/projects.zig");
const projects_rules = @import("../plan/modules/projects.zig");
const resources_rules = @import("../plan/modules/resources.zig");
const rollback_handler = @import("handlers/rollback.zig");
const security_policy_review_rules = @import("../plan/modules/security_policy_review.zig");
const service_handler = @import("handlers/services.zig");
const services_rules = @import("../plan/modules/services.zig");
const ssh_rules = @import("../plan/modules/ssh.zig");
const storage_review_rules = @import("../plan/modules/storage_review.zig");
const sudoers_review_rules = @import("../plan/modules/sudoers_review.zig");
const system_baseline_review_rules = @import("../plan/modules/system_baseline_review.zig");
const transfer_handler = @import("handlers/transfer.zig");
const resources_handler = @import("handlers/resources.zig");
const users_rules = @import("../plan/modules/users.zig");

const ModuleHandler = handler.ModuleHandler;
const PlanContext = handler.PlanContext;

const registered_handlers = [_]ModuleHandler{
    .{ .name = .packages, .planActions = planPackages, .applyRequirements = command_handler.applyRequirements, .apply = command_handler.apply, .verify = command_handler.verify, .rollback = command_handler.rollback },
    .{ .name = .services, .planActions = planServices, .applyRequirements = service_handler.applyRequirements, .preflight = service_handler.preflight, .apply = service_handler.apply, .verify = service_handler.verify, .rollback = service_handler.rollback },
    .{ .name = .cron, .planActions = planCron, .applyRequirements = transfer_handler.applyRequirements, .preflight = transfer_handler.preflight, .apply = transfer_handler.apply, .verify = transfer_handler.verify, .rollback = rollback_handler.restoreFileBackup },
    .{ .name = .users, .planActions = planUsers, .applyRequirements = command_handler.applyRequirements, .apply = command_handler.apply, .verify = command_handler.verify, .rollback = command_handler.rollback },
    .{ .name = .ssh, .planActions = planSsh, .applyRequirements = transfer_handler.applyRequirements, .preflight = transfer_handler.preflight, .apply = transfer_handler.apply, .verify = transfer_handler.verify, .rollback = rollback_handler.restoreFileBackup },
    .{ .name = .configs, .planActions = planConfigs, .applyRequirements = transfer_handler.applyRequirements, .preflight = transfer_handler.preflight, .apply = transfer_handler.apply, .verify = transfer_handler.verify, .rollback = rollback_handler.restoreFileBackup },
    .{ .name = .home_configs, .planActions = planHomeConfigs, .applyRequirements = transfer_handler.applyRequirements, .preflight = transfer_handler.preflight, .apply = transfer_handler.apply, .verify = transfer_handler.verify, .rollback = rollback_handler.restoreFileBackup },
    .{ .name = .appdata, .planActions = planAppData, .applyRequirements = appdata_handler.applyRequirements, .preflight = appdata_handler.preflight, .apply = appdata_handler.apply, .verify = appdata_handler.verify, .rollback = appdata_handler.rollback },
    .{ .name = .projects, .planActions = planProjects, .applyRequirements = project_handler.applyRequirements, .preflight = project_handler.preflight, .apply = project_handler.apply, .verify = project_handler.verify, .rollback = project_handler.rollback },
    .{ .name = .firewall, .planActions = planFirewall, .applyRequirements = transfer_handler.applyRequirements, .preflight = transfer_handler.preflight, .apply = transfer_handler.apply, .verify = transfer_handler.verify, .rollback = rollback_handler.restoreFileBackup },
    .{ .name = .docker, .planActions = planContainerManualReview, .applyRequirements = transfer_handler.applyRequirements, .preflight = transfer_handler.preflight, .apply = transfer_handler.apply, .verify = transfer_handler.verify, .rollback = rollback_handler.restoreFileBackup },
    .{ .name = .resources, .planActions = planResources, .applyRequirements = resources_handler.applyRequirements, .preflight = resources_handler.preflight, .apply = resources_handler.apply, .verify = resources_handler.verify, .rollback = resources_handler.rollback },
    .{ .name = .network, .planActions = planNetworkManualReview },
    .{ .name = .sudoers, .planActions = planSudoersManualReview },
    .{ .name = .acl, .planActions = planAclManualReview },
    .{ .name = .security_policy, .planActions = planSecurityPolicyManualReview },
    .{ .name = .storage, .planActions = planStorageManualReview },
    .{ .name = .system_baseline, .planActions = planSystemBaselineManualReview },
};

// 返回当前已注册的迁移模块处理器列表。
pub fn all() []const ModuleHandler {
    return &registered_handlers;
}

// 按模块名查找迁移处理器。
pub fn find(name: plan.ModuleName) ?ModuleHandler {
    for (registered_handlers) |module_handler| {
        if (module_handler.name == name) return module_handler;
    }
    return null;
}

// 通过 registry 追加所有已接入规划阶段的模块动作。
pub fn appendPlanActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ModuleInventory,
    target: inventory.ModuleInventory,
) !void {
    const ctx = PlanContext{
        .allocator = allocator,
        .source = source,
        .target = target,
    };

    for (registered_handlers) |module_handler| {
        if (module_handler.planActions) |appendActions| {
            try appendActions(ctx, actions);
        }
    }
}

// 规划包管理模块的迁移 action。
fn planPackages(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try packages_rules.appendActions(ctx.allocator, actions, ctx.source.packages, ctx.target.packages);
}

// 规划服务模块的迁移 action。
fn planServices(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try services_rules.appendActions(ctx.allocator, actions, ctx.source.services, ctx.target.services);
}

// 规划定时任务模块的迁移 action。
fn planCron(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try cron_rules.appendActions(ctx.allocator, actions, ctx.source.cron, ctx.target.cron);
}

// 规划用户和组模块的迁移 action。
fn planUsers(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try users_rules.appendActions(ctx.allocator, actions, ctx.source.users, ctx.target.users);
}

// 规划 SSH 配置模块的迁移 action。
fn planSsh(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try ssh_rules.appendActions(ctx.allocator, actions, ctx.source.ssh, ctx.target.ssh);
}

// 规划系统级配置文件模块的迁移 action。
fn planConfigs(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try configs_rules.appendActions(ctx.allocator, actions, ctx.source.configs, ctx.target.configs);
}

// 规划用户 home 目录配置模块的迁移 action。
fn planHomeConfigs(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try home_configs_rules.appendActions(ctx.allocator, actions, ctx.source.home_configs, ctx.target.home_configs);
}

// 规划应用数据路径模块的迁移 action。
fn planAppData(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try appdata_rules.appendActions(ctx.allocator, actions, ctx.source.appdata, ctx.target.appdata);
}

// 规划项目模块的迁移 action。
fn planProjects(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try projects_rules.appendActions(ctx.allocator, actions, ctx.source.projects, ctx.target.projects);
}

// 规划整机资源模块的迁移 action。
fn planResources(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try resources_rules.appendActions(ctx.allocator, actions, ctx.source.resources, ctx.target.resources);
    try resources_rules.appendCapacityReviewActions(ctx.allocator, actions, ctx.source.resources, ctx.target.resources, ctx.source.storage, ctx.target.storage);
}

// 生成网络监听和健康检查人工审查 action。
fn planNetworkManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try network_review_rules.appendActions(ctx.allocator, actions, ctx.source.network, ctx.target.network);
}

// 规划防火墙模块的迁移 action。
fn planFirewall(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try firewall_rules.appendActions(ctx.allocator, actions, ctx.source.firewall, ctx.target.firewall);
}

// 生成容器模块的手动审核 action。
fn planContainerManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try container_review_rules.appendActions(ctx.allocator, actions, ctx.source.docker, ctx.target.docker);
}

// 生成 sudoers 模块的手动审核 action。
fn planSudoersManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try sudoers_review_rules.appendActions(ctx.allocator, actions, ctx.source.sudoers, ctx.target.sudoers);
}

// 生成 ACL 模块的手动审核 action。
fn planAclManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try acl_review_rules.appendActions(ctx.allocator, actions, ctx.source.acl, ctx.target.acl);
}

// 生成安全策略模块的手动审核 action。
fn planSecurityPolicyManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try security_policy_review_rules.appendActions(ctx.allocator, actions, ctx.source.security_policy, ctx.target.security_policy);
}

// 生成存储模块的手动审核 action。
fn planStorageManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try storage_review_rules.appendActions(ctx.allocator, actions, ctx.source.storage, ctx.target.storage);
}

// 生成系统基线模块的手动审核 action。
fn planSystemBaselineManualReview(ctx: PlanContext, actions: *std.ArrayList(plan.Action)) !void {
    try system_baseline_review_rules.appendActions(ctx.allocator, actions, ctx.source.system_baseline, ctx.target.system_baseline);
}

test "transfer backed handlers register module preflight" {
    const expected = [_]plan.ModuleName{
        .services,
        .cron,
        .ssh,
        .configs,
        .home_configs,
        .appdata,
        .projects,
        .firewall,
        .docker,
        .resources,
    };

    for (expected) |name| {
        const module_handler = find(name) orelse return error.MissingRegisteredHandler;
        try std.testing.expect(module_handler.preflight != null);
    }
}
