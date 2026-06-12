const std = @import("std");
const audit_operator = @import("../audit/operator.zig");
const approval_policy = @import("approval.zig");
const policy_match = @import("match.zig");
const plan_hash_policy = @import("plan_hash.zig");
const policy_scope = @import("scope.zig");
const plan_schema = @import("../plan/schema.zig");

pub const policy_schema_version = "hostlift.policy.v1";
pub const schema_version = policy_schema_version;

// 策略决策枚举。
pub const Decision = enum {
    allow,
    deny,
};

// 策略规则集，包含模块、动作、主机、plan hash、operator 和审批规则。
pub const RuleSet = struct {
    schema_version: []const u8 = policy_schema_version,
    default: Decision = .allow,
    allow_modules: []const plan_schema.ModuleName = &.{},
    deny_modules: []const plan_schema.ModuleName = &.{},
    allow_actions: []const []const u8 = &.{},
    deny_actions: []const []const u8 = &.{},
    allow_hosts: []const []const u8 = &.{},
    deny_hosts: []const []const u8 = &.{},
    allow_plan_hashes: []const []const u8 = &.{},
    deny_plan_hashes: []const []const u8 = &.{},
    allow_operators: []const []const u8 = &.{},
    deny_operators: []const []const u8 = &.{},
    max_risk: ?plan_schema.RiskLevel = null,
    require_approval_ticket: bool = false,
    allow_approval_tickets: []const []const u8 = &.{},
    allow_approval_ticket_prefixes: []const []const u8 = &.{},
    deny_approval_tickets: []const []const u8 = &.{},
    deny_approval_ticket_prefixes: []const []const u8 = &.{},
    approval_scopes: []const policy_scope.Scope = &.{},
};

// 策略评估 plan 上下文。
pub const PlanContext = struct {
    plan_hash: ?[]const u8 = null,
};

// 从 JSON bytes 解析 action policy。
pub fn parseFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(RuleSet) {
    return std.json.parseFromSlice(RuleSet, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

// 校验 RuleSet 的版本、host、operator、审批和 scope 规则是否可安全评估。
pub fn isValid(policy: RuleSet) bool {
    if (!std.mem.eql(u8, policy.schema_version, schema_version)) return false;
    if (!policy_match.allPrefixesValid(policy.allow_actions) or !policy_match.allPrefixesValid(policy.deny_actions)) return false;
    return policy_match.allHostsValid(policy.allow_hosts) and
        policy_match.allHostsValid(policy.deny_hosts) and
        plan_hash_policy.validateRules(planHashRules(policy)) and
        allOperatorsValid(policy.allow_operators) and
        allOperatorsValid(policy.deny_operators) and
        approval_policy.validateRules(approvalRules(policy)) and
        policy_scope.validateScopes(policy.approval_scopes);
}

// 从 RuleSet 派生 plan hash 子规则。
pub fn planHashRules(policy: RuleSet) plan_hash_policy.Rules {
    return .{
        .allow_hashes = policy.allow_plan_hashes,
        .deny_hashes = policy.deny_plan_hashes,
    };
}

// 从 RuleSet 派生审批票据子规则。
pub fn approvalRules(policy: RuleSet) approval_policy.Rules {
    return .{
        .require_ticket = policy.require_approval_ticket,
        .allow_tickets = policy.allow_approval_tickets,
        .allow_ticket_prefixes = policy.allow_approval_ticket_prefixes,
        .deny_tickets = policy.deny_approval_tickets,
        .deny_ticket_prefixes = policy.deny_approval_ticket_prefixes,
    };
}

// 校验所有 operator 值是否合法。
fn allOperatorsValid(values: []const []const u8) bool {
    for (values) |value| {
        audit_operator.validate(value) catch return false;
    }
    return true;
}
