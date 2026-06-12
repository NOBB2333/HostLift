const std = @import("std");
const audit_operator = @import("../audit/operator.zig");
const approval_policy = @import("approval.zig");
const policy_match = @import("match.zig");
const plan_hash_policy = @import("plan_hash.zig");
const policy_ruleset = @import("ruleset.zig");
const policy_scope = @import("scope.zig");
const plan_schema = @import("../plan/schema.zig");

pub const policy_schema_version = policy_ruleset.policy_schema_version;
pub const schema_version = policy_ruleset.schema_version;

pub const Decision = policy_ruleset.Decision;
pub const RuleSet = policy_ruleset.RuleSet;

// 动作级策略评估报告，记录审批、scope、host 和 operator 校验结果。
pub const Report = struct {
    schema_version: []const u8 = "hostlift.policy.report.v1",
    valid: bool,
    checked_actions: usize,
    allowed_actions: usize,
    denied_actions: usize,
    requires_approval_ticket: bool = false,
    approval_ticket_present: bool = false,
    approval_ticket_allowed: bool = true,
    approval_scope_allowed: bool = true,
    plan_hash_allowed: bool = true,
    target_host_allowed: bool = true,
    operator_allowed: bool = true,
};

// 无 plan 的执行入口策略评估报告。
pub const ExecutionReport = struct {
    schema_version: []const u8 = "hostlift.policy.execution.report.v1",
    valid: bool,
    requires_approval_ticket: bool = false,
    approval_ticket_present: bool = false,
    approval_ticket_allowed: bool = true,
    approval_scope_allowed: bool = true,
    target_host_allowed: bool = true,
    operator_allowed: bool = true,
};

pub const PlanContext = policy_ruleset.PlanContext;

// 从 JSON bytes 解析 action policy。
pub fn parseFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(RuleSet) {
    return policy_ruleset.parseFromSlice(allocator, bytes);
}

// 对 migration plan 执行动作级策略检查。
pub fn evaluatePlan(plan: plan_schema.MigrationPlan, policy: RuleSet) Report {
    return evaluatePlanWithContext(plan, policy, .{});
}

// 对 migration plan 执行动作级策略检查，并带入 plan hash 等上下文。
pub fn evaluatePlanWithContext(plan: plan_schema.MigrationPlan, policy: RuleSet, context: PlanContext) Report {
    return evaluatePlanInternal(plan, policy, context, null, null, null, false);
}

// 对 approved apply 执行动作级策略检查，并强制审批票据要求。
pub fn evaluatePlanForApply(plan: plan_schema.MigrationPlan, policy: RuleSet, plan_hash: []const u8, target_host: []const u8, approval_ticket: ?[]const u8, operator: []const u8) Report {
    return evaluatePlanInternal(plan, policy, .{ .plan_hash = plan_hash }, target_host, approval_ticket, operator, true);
}

// 对没有 migration plan 的 approved 执行入口校验目标主机和审批票据。
pub fn evaluateExecution(policy: RuleSet, target_host: []const u8, approval_ticket: ?[]const u8, operator: []const u8) ExecutionReport {
    const target_host_allowed = allowsHost(policy, target_host);
    const operator_allowed = allowsOperator(policy, operator);
    const approval_result = evaluateApproval(policy, approval_ticket);
    const approval_required = approval_result.required or policy.approval_scopes.len > 0;
    const scope_allowed = policy_scope.allows(policy.approval_scopes, approval_ticket, .{ .host = target_host, .operator = operator });
    var report: ExecutionReport = .{
        .valid = true,
        .requires_approval_ticket = approval_required,
        .approval_ticket_present = approval_result.present,
        .approval_ticket_allowed = approval_result.allowed,
        .approval_scope_allowed = scope_allowed,
        .target_host_allowed = target_host_allowed,
        .operator_allowed = operator_allowed,
    };
    if (!policy_ruleset.isValid(policy)) {
        report.valid = false;
        return report;
    }
    if (!approval_result.allowed) report.valid = false;
    if (!scope_allowed) report.valid = false;
    if (!target_host_allowed) report.valid = false;
    if (!operator_allowed) report.valid = false;
    return report;
}

// 内部策略评估核心，遍历 plan 动作并校验审批、scope、host、operator 和 plan hash。
fn evaluatePlanInternal(plan: plan_schema.MigrationPlan, policy: RuleSet, context: PlanContext, target_host: ?[]const u8, approval_ticket: ?[]const u8, operator: ?[]const u8, enforce_approval_ticket: bool) Report {
    const plan_hash_allowed = if (context.plan_hash) |value| allowsPlanHash(policy, value) else policy.allow_plan_hashes.len == 0;
    const target_host_allowed = if (target_host) |host| allowsHost(policy, host) else true;
    const operator_allowed = if (operator) |value| allowsOperator(policy, value) else true;
    const approval_result = evaluateApproval(policy, approval_ticket);
    const approval_required = approval_result.required or policy.approval_scopes.len > 0;
    var report: Report = .{
        .valid = true,
        .checked_actions = plan.actions.len,
        .allowed_actions = 0,
        .denied_actions = 0,
        .requires_approval_ticket = approval_required,
        .approval_ticket_present = approval_result.present,
        .approval_ticket_allowed = if (enforce_approval_ticket) approval_result.allowed else true,
        .approval_scope_allowed = true,
        .plan_hash_allowed = plan_hash_allowed,
        .target_host_allowed = target_host_allowed,
        .operator_allowed = operator_allowed,
    };

    if (!policy_ruleset.isValid(policy)) {
        report.valid = false;
        return report;
    }
    if (enforce_approval_ticket and !approval_result.allowed) {
        report.valid = false;
    }
    if (!plan_hash_allowed) {
        report.valid = false;
    }
    if (enforce_approval_ticket and !target_host_allowed) {
        report.valid = false;
    }
    if (enforce_approval_ticket and !operator_allowed) {
        report.valid = false;
    }

    for (plan.actions) |action| {
        const action_allowed = allowsAction(policy, action);
        const scope_allowed = if (enforce_approval_ticket and target_host != null and operator != null)
            policy_scope.allows(policy.approval_scopes, approval_ticket, .{ .host = target_host.?, .operator = operator.?, .action = action })
        else
            true;
        if (!scope_allowed) report.approval_scope_allowed = false;
        if (action_allowed and scope_allowed) {
            report.allowed_actions += 1;
        } else {
            report.valid = false;
            report.denied_actions += 1;
        }
    }

    return report;
}

// 判断单个 action 是否被策略允许；deny 规则优先于 allow 规则。
pub fn allowsAction(policy: RuleSet, action: plan_schema.Action) bool {
    if (!policy_ruleset.isValid(policy)) return false;
    if (policy_match.containsModule(policy.deny_modules, action.module)) return false;
    if (policy_match.matchesAnyPrefix(policy.deny_actions, action.id)) return false;
    if (policy.max_risk) |max_risk| {
        if (policy_match.riskRank(action.risk) > policy_match.riskRank(max_risk)) return false;
    }

    const has_allow_modules = policy.allow_modules.len > 0;
    const has_allow_actions = policy.allow_actions.len > 0;
    if (has_allow_modules or has_allow_actions) {
        return policy_match.containsModule(policy.allow_modules, action.module) or policy_match.matchesAnyPrefix(policy.allow_actions, action.id);
    }

    return policy.default == .allow;
}

// 判断 approved apply 目标 host 是否被策略允许；deny 优先于 allow。
pub fn allowsHost(policy: RuleSet, host: []const u8) bool {
    if (!policy_ruleset.isValid(policy)) return false;
    if (!policy_match.hostValid(host)) return false;
    if (policy_match.matchesExact(policy.deny_hosts, host)) return false;
    if (policy.allow_hosts.len > 0) return policy_match.matchesExact(policy.allow_hosts, host);
    return true;
}

// 判断 plan hash 是否被策略允许；deny 优先于 allow。
pub fn allowsPlanHash(policy: RuleSet, plan_hash: []const u8) bool {
    return plan_hash_policy.allows(policy_ruleset.planHashRules(policy), plan_hash);
}

// 判断 approved 执行操作人是否被策略允许；deny 优先于 allow。
pub fn allowsOperator(policy: RuleSet, operator: []const u8) bool {
    if (!policy_ruleset.isValid(policy)) return false;
    audit_operator.validate(operator) catch return false;
    if (policy_match.matchesExact(policy.deny_operators, operator)) return false;
    if (policy.allow_operators.len > 0) return policy_match.matchesExact(policy.allow_operators, operator);
    return true;
}

// 委托审批策略模块评估审批票据。
fn evaluateApproval(policy: RuleSet, approval_ticket: ?[]const u8) approval_policy.Result {
    return approval_policy.evaluate(policy_ruleset.approvalRules(policy), approval_ticket);
}
