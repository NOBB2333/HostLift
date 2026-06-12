const std = @import("std");
const audit_operator = @import("../audit/operator.zig");
const approval_policy = @import("approval.zig");
const policy_match = @import("match.zig");
const plan_schema = @import("../plan/schema.zig");

// 审批 scope 规则，限定票据适用的 host、operator、模块和风险等级。
pub const Scope = struct {
    ticket: ?[]const u8 = null,
    ticket_prefix: ?[]const u8 = null,
    hosts: []const []const u8 = &.{},
    operators: []const []const u8 = &.{},
    modules: []const plan_schema.ModuleName = &.{},
    action_prefixes: []const []const u8 = &.{},
    max_risk: ?plan_schema.RiskLevel = null,
};

// 审批 scope 匹配上文。
pub const Context = struct {
    host: []const u8,
    operator: []const u8,
    action: ?plan_schema.Action = null,
};

// 校验审批 scope 配置，确保 ticket、host、operator 和 action 前缀规则可安全匹配。
pub fn validateScopes(scopes: []const Scope) bool {
    for (scopes) |scope| {
        if (scope.ticket == null and scope.ticket_prefix == null) return false;
        if (scope.ticket) |value| {
            if (!approval_policy.ticketValueValid(value)) return false;
        }
        if (scope.ticket_prefix) |value| {
            if (!approval_policy.ticketValueValid(value)) return false;
        }
        if (!policy_match.allHostsValid(scope.hosts)) return false;
        if (!allOperatorsValid(scope.operators)) return false;
        if (!policy_match.allPrefixesValid(scope.action_prefixes)) return false;
    }
    return true;
}

// 判断审批票据是否满足至少一个配置的 scope；没有 scope 时沿用旧策略。
pub fn allows(scopes: []const Scope, ticket: ?[]const u8, context: Context) bool {
    if (scopes.len == 0) return true;
    const value = ticket orelse return false;
    if (!validateScopes(scopes)) return false;
    if (!approval_policy.ticketValueValid(value)) return false;
    for (scopes) |scope| {
        if (matchesScope(scope, value, context)) return true;
    }
    return false;
}

// 检查 scope 的票据、host、operator、模块和风险是否全部匹配。
fn matchesScope(scope: Scope, ticket: []const u8, context: Context) bool {
    if (!matchesTicket(scope, ticket)) return false;
    if (scope.hosts.len > 0 and !policy_match.matchesExact(scope.hosts, context.host)) return false;
    if (scope.operators.len > 0 and !policy_match.matchesExact(scope.operators, context.operator)) return false;
    if (context.action) |action| {
        if (scope.modules.len > 0 and !policy_match.containsModule(scope.modules, action.module)) return false;
        if (scope.action_prefixes.len > 0 and !policy_match.matchesAnyPrefix(scope.action_prefixes, action.id)) return false;
        if (scope.max_risk) |max_risk| {
            if (policy_match.riskRank(action.risk) > policy_match.riskRank(max_risk)) return false;
        }
    } else {
        if (scope.modules.len > 0 or scope.action_prefixes.len > 0 or scope.max_risk != null) return false;
    }
    return true;
}

// 检查票据是否匹配 scope 的精确值或前缀。
fn matchesTicket(scope: Scope, ticket: []const u8) bool {
    if (scope.ticket) |value| {
        if (std.mem.eql(u8, value, ticket)) return true;
    }
    if (scope.ticket_prefix) |value| {
        if (std.mem.startsWith(u8, ticket, value)) return true;
    }
    return false;
}

// 校验所有 operator 值是否合法。
fn allOperatorsValid(values: []const []const u8) bool {
    for (values) |value| {
        audit_operator.validate(value) catch return false;
    }
    return true;
}

test "approval scope restricts host operator module and risk" {
    const action: plan_schema.Action = .{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "install nginx",
        .risk = .medium,
        .requires_confirmation = false,
    };
    const scopes = &[_]Scope{.{
        .ticket_prefix = "OPS-",
        .hosts = &.{"root@192.0.2.10"},
        .operators = &.{"ops/alice"},
        .modules = &.{.packages},
        .max_risk = .medium,
    }};

    try std.testing.expect(allows(scopes, "OPS-123", .{ .host = "root@192.0.2.10", .operator = "ops/alice", .action = action }));
    try std.testing.expect(!allows(scopes, "OPS-123", .{ .host = "root@192.0.2.11", .operator = "ops/alice", .action = action }));
    try std.testing.expect(!allows(scopes, "OPS-123", .{ .host = "root@192.0.2.10", .operator = "ops/bob", .action = action }));
}

test "rollback-style approval scope rejects action-only scopes" {
    const scopes = &[_]Scope{.{
        .ticket_prefix = "OPS-",
        .modules = &.{.packages},
    }};

    try std.testing.expect(!allows(scopes, "OPS-123", .{ .host = "root@192.0.2.10", .operator = "ops/alice" }));
}
