const std = @import("std");
const security_validation = @import("../security/validation.zig");

// 审批票据规则配置。
pub const Rules = struct {
    require_ticket: bool = false,
    allow_tickets: []const []const u8 = &.{},
    allow_ticket_prefixes: []const []const u8 = &.{},
    deny_tickets: []const []const u8 = &.{},
    deny_ticket_prefixes: []const []const u8 = &.{},
};

// 审批票据评估结果。
pub const Result = struct {
    required: bool,
    present: bool,
    allowed: bool,
};

// 校验审批票据规则中的精确值和前缀，避免无效规则进入执行判断。
pub fn validateRules(rules: Rules) bool {
    return allTicketsValid(rules.allow_tickets) and
        allTicketsValid(rules.allow_ticket_prefixes) and
        allTicketsValid(rules.deny_tickets) and
        allTicketsValid(rules.deny_ticket_prefixes);
}

// 根据策略规则判断审批票据是否满足 approved 执行要求。
pub fn evaluate(rules: Rules, ticket: ?[]const u8) Result {
    const present = ticket != null;
    var result: Result = .{
        .required = rules.require_ticket,
        .present = present,
        .allowed = true,
    };
    if (!validateRules(rules)) {
        result.allowed = false;
        return result;
    }
    const value = ticket orelse {
        if (rules.require_ticket or hasAllowRules(rules)) result.allowed = false;
        return result;
    };
    security_validation.validateApprovalTicket(value) catch {
        result.allowed = false;
        return result;
    };
    if (matchesExact(rules.deny_tickets, value) or matchesPrefix(rules.deny_ticket_prefixes, value)) {
        result.allowed = false;
        return result;
    }
    if (hasAllowRules(rules)) {
        result.allowed = matchesExact(rules.allow_tickets, value) or matchesPrefix(rules.allow_ticket_prefixes, value);
    }
    return result;
}

// 判断审批规则中是否配置了 allow 白名单。
fn hasAllowRules(rules: Rules) bool {
    return rules.allow_tickets.len > 0 or rules.allow_ticket_prefixes.len > 0;
}

// 校验所有审批票据值是否合法。
fn allTicketsValid(values: []const []const u8) bool {
    for (values) |value| {
        if (!ticketValueValid(value)) return false;
    }
    return true;
}

// 判断单个审批票据或前缀是否符合允许的字符集。
pub fn ticketValueValid(value: []const u8) bool {
    security_validation.validateApprovalTicket(value) catch return false;
    return true;
}

// 精确匹配票据值列表。
fn matchesExact(values: []const []const u8, target: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

// 前缀匹配票据值列表。
fn matchesPrefix(prefixes: []const []const u8, target: []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, target, prefix)) return true;
    }
    return false;
}

test "approval rules require ticket and allow prefixes" {
    const rules: Rules = .{
        .require_ticket = true,
        .allow_ticket_prefixes = &.{"OPS-"},
    };

    try std.testing.expect(!evaluate(rules, null).allowed);
    try std.testing.expect(evaluate(rules, "OPS-123").allowed);
    try std.testing.expect(!evaluate(rules, "CHG-123").allowed);
}

test "approval deny rules win over allow rules" {
    const rules: Rules = .{
        .allow_ticket_prefixes = &.{"OPS-"},
        .deny_tickets = &.{"OPS-999"},
    };

    try std.testing.expect(evaluate(rules, "OPS-123").allowed);
    try std.testing.expect(!evaluate(rules, "OPS-999").allowed);
}

test "approval rules reject invalid configured ticket values" {
    try std.testing.expect(!validateRules(.{ .allow_ticket_prefixes = &.{"OPS;"} }));
    try std.testing.expect(!evaluate(.{ .allow_tickets = &.{"OPS;"} }, "OPS-123").allowed);
}
