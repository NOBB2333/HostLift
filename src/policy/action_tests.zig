const std = @import("std");
const action_policy = @import("action.zig");
const plan_schema = @import("../plan/schema.zig");

const fixture_plan_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const other_plan_hash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

// 构造测试用的 action fixture。
fn fixtureAction(id: []const u8, module: plan_schema.ModuleName, risk: plan_schema.RiskLevel) plan_schema.Action {
    return .{
        .id = id,
        .module = module,
        .action_type = .manual_step,
        .description = "fixture action",
        .risk = risk,
        .requires_confirmation = risk == .high or risk == .critical,
    };
}

// 构造测试用的迁移计划 fixture。
fn fixturePlan(actions: []plan_schema.Action) plan_schema.MigrationPlan {
    return .{
        .schema_version = "hostlift.plan.v1",
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{
            .compatible = true,
            .same_distro = true,
            .same_version = true,
            .same_package_manager = true,
            .same_arch = true,
            .reason = "compatible",
        },
        .actions = actions,
        .created_at = 0,
    };
}

test "policy denies matching module and action prefix" {
    const action = fixtureAction("firewall/apply//etc/nftables.conf", .firewall, .high);
    const policy: action_policy.RuleSet = .{
        .deny_modules = &.{.firewall},
        .deny_actions = &.{"packages/install/"},
    };

    try std.testing.expect(!action_policy.allowsAction(policy, action));
}

test "policy allowlist permits selected modules only" {
    const package_action = fixtureAction("packages/install/nginx", .packages, .low);
    const service_action = fixtureAction("services/enable/nginx.service", .services, .medium);
    const policy: action_policy.RuleSet = .{ .allow_modules = &.{.packages} };

    try std.testing.expect(action_policy.allowsAction(policy, package_action));
    try std.testing.expect(!action_policy.allowsAction(policy, service_action));
}

test "policy enforces max risk" {
    const action = fixtureAction("appdata/copy//var/lib/postgresql", .appdata, .high);
    const policy: action_policy.RuleSet = .{ .max_risk = .medium };

    try std.testing.expect(!action_policy.allowsAction(policy, action));
}

test "policy evaluates whole plan" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .low),
        fixtureAction("firewall/apply//etc/nftables.conf", .firewall, .high),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{ .deny_modules = &.{.firewall} };

    const report = action_policy.evaluatePlan(plan, policy);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(usize, 2), report.checked_actions);
    try std.testing.expectEqual(@as(usize, 1), report.allowed_actions);
    try std.testing.expectEqual(@as(usize, 1), report.denied_actions);
}

test "policy rejects empty action prefixes" {
    const action = fixtureAction("packages/install/nginx", .packages, .low);
    const policy: action_policy.RuleSet = .{ .deny_actions = &.{""} };

    try std.testing.expect(!action_policy.allowsAction(policy, action));
}

test "policy parses JSON rule set with enum names" {
    const bytes =
        \\{
        \\  "schema_version": "hostlift.policy.v1",
        \\  "default": "allow",
        \\  "allow_modules": ["packages", "configs", "ssh"],
        \\  "deny_modules": ["firewall"],
        \\  "deny_actions": ["services/install-unit/experimental.service"],
        \\  "allow_hosts": ["root@192.0.2.10"],
        \\  "allow_plan_hashes": ["0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
        \\  "deny_plan_hashes": ["ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"],
        \\  "allow_operators": ["ops/alice"],
        \\  "deny_operators": ["ops/bob"],
        \\  "max_risk": "high",
        \\  "require_approval_ticket": true,
        \\  "allow_approval_ticket_prefixes": ["OPS-"],
        \\  "deny_approval_tickets": ["OPS-999"],
        \\  "approval_scopes": [
        \\    {
        \\      "ticket_prefix": "OPS-",
        \\      "hosts": ["root@192.0.2.10"],
        \\      "operators": ["ops/alice"],
        \\      "modules": ["packages"],
        \\      "action_prefixes": ["packages/install/"],
        \\      "max_risk": "medium"
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try action_policy.parseFromSlice(std.testing.allocator, bytes);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(action_policy.schema_version, parsed.value.schema_version);
    try std.testing.expectEqual(action_policy.Decision.allow, parsed.value.default);
    try std.testing.expectEqual(plan_schema.ModuleName.packages, parsed.value.allow_modules[0]);
    try std.testing.expectEqual(plan_schema.ModuleName.firewall, parsed.value.deny_modules[0]);
    try std.testing.expectEqualStrings("root@192.0.2.10", parsed.value.allow_hosts[0]);
    try std.testing.expectEqualStrings(fixture_plan_hash, parsed.value.allow_plan_hashes[0]);
    try std.testing.expectEqualStrings(other_plan_hash, parsed.value.deny_plan_hashes[0]);
    try std.testing.expectEqualStrings("ops/alice", parsed.value.allow_operators[0]);
    try std.testing.expectEqualStrings("ops/bob", parsed.value.deny_operators[0]);
    try std.testing.expectEqual(plan_schema.RiskLevel.high, parsed.value.max_risk.?);
    try std.testing.expect(parsed.value.require_approval_ticket);
    try std.testing.expectEqualStrings("OPS-", parsed.value.allow_approval_ticket_prefixes[0]);
    try std.testing.expectEqualStrings("OPS-999", parsed.value.deny_approval_tickets[0]);
    try std.testing.expectEqualStrings("OPS-", parsed.value.approval_scopes[0].ticket_prefix.?);
    try std.testing.expectEqualStrings("ops/alice", parsed.value.approval_scopes[0].operators[0]);
    try std.testing.expectEqualStrings("services/install-unit/experimental.service", parsed.value.deny_actions[0]);
}

test "policy can require approval ticket" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .low),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{ .require_approval_ticket = true };

    const validation_only = action_policy.evaluatePlan(plan, policy);
    try std.testing.expect(validation_only.valid);
    try std.testing.expect(validation_only.requires_approval_ticket);
    try std.testing.expect(!validation_only.approval_ticket_present);

    const missing = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(!missing.valid);
    try std.testing.expect(missing.requires_approval_ticket);
    try std.testing.expect(!missing.approval_ticket_present);

    const present = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(present.valid);
    try std.testing.expect(present.approval_ticket_present);
    try std.testing.expect(present.approval_ticket_allowed);
}

test "policy can restrict approved apply tickets by prefix and deny exact values" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .low),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{
        .require_approval_ticket = true,
        .allow_approval_ticket_prefixes = &.{"OPS-"},
        .deny_approval_tickets = &.{"OPS-999"},
    };

    const wrong_prefix = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "CHG-123", "ops/alice");
    try std.testing.expect(!wrong_prefix.valid);
    try std.testing.expect(!wrong_prefix.approval_ticket_allowed);

    const denied_ticket = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "OPS-999", "ops/alice");
    try std.testing.expect(!denied_ticket.valid);
    try std.testing.expect(!denied_ticket.approval_ticket_allowed);

    const allowed = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.approval_ticket_allowed);
}

test "policy can restrict approved apply hosts" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .low),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{ .allow_hosts = &.{"root@192.0.2.10"} };

    const denied = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.11", null, "ops/alice");
    try std.testing.expect(!denied.valid);
    try std.testing.expect(!denied.target_host_allowed);

    const allowed = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.target_host_allowed);
}

test "policy can restrict approved apply operators" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .low),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{ .allow_operators = &.{"ops/alice"} };

    const denied = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", null, "ops/bob");
    try std.testing.expect(!denied.valid);
    try std.testing.expect(!denied.operator_allowed);

    const allowed = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.operator_allowed);
}

test "policy can bind migration plan to approved hash" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .low),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{ .allow_plan_hashes = &.{fixture_plan_hash} };

    const missing_context = action_policy.evaluatePlan(plan, policy);
    try std.testing.expect(!missing_context.valid);
    try std.testing.expect(!missing_context.plan_hash_allowed);

    const wrong_hash = action_policy.evaluatePlanWithContext(plan, policy, .{ .plan_hash = other_plan_hash });
    try std.testing.expect(!wrong_hash.valid);
    try std.testing.expect(!wrong_hash.plan_hash_allowed);

    const allowed = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.plan_hash_allowed);
}

test "policy deny plan hash wins over allow plan hash" {
    const policy: action_policy.RuleSet = .{
        .allow_plan_hashes = &.{fixture_plan_hash},
        .deny_plan_hashes = &.{fixture_plan_hash},
    };

    try std.testing.expect(!action_policy.allowsPlanHash(policy, fixture_plan_hash));
}

test "policy can scope approval tickets to approved apply context" {
    var actions = [_]plan_schema.Action{
        fixtureAction("packages/install/nginx", .packages, .medium),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{
        .require_approval_ticket = true,
        .allow_approval_ticket_prefixes = &.{"OPS-"},
        .approval_scopes = &.{.{
            .ticket_prefix = "OPS-",
            .hosts = &.{"root@192.0.2.10"},
            .operators = &.{"ops/alice"},
            .modules = &.{.packages},
            .max_risk = .medium,
        }},
    };

    const wrong_host = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.11", "OPS-123", "ops/alice");
    try std.testing.expect(!wrong_host.valid);
    try std.testing.expect(wrong_host.requires_approval_ticket);
    try std.testing.expect(!wrong_host.approval_scope_allowed);

    const wrong_operator = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "OPS-123", "ops/bob");
    try std.testing.expect(!wrong_operator.valid);
    try std.testing.expect(!wrong_operator.approval_scope_allowed);

    const allowed = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.approval_scope_allowed);
}

test "policy approval scope denies actions above scoped risk" {
    var actions = [_]plan_schema.Action{
        fixtureAction("services/restart/postgresql.service", .services, .high),
    };
    const plan = fixturePlan(actions[0..]);
    const policy: action_policy.RuleSet = .{
        .allow_approval_ticket_prefixes = &.{"OPS-"},
        .approval_scopes = &.{.{
            .ticket_prefix = "OPS-",
            .modules = &.{.services},
            .max_risk = .medium,
        }},
    };

    const denied = action_policy.evaluatePlanForApply(plan, policy, fixture_plan_hash, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(!denied.valid);
    try std.testing.expect(!denied.approval_scope_allowed);
}

test "policy deny operator wins over allow operator" {
    const policy: action_policy.RuleSet = .{
        .allow_operators = &.{"ops/alice"},
        .deny_operators = &.{"ops/alice"},
    };

    try std.testing.expect(!action_policy.allowsOperator(policy, "ops/alice"));
}

test "policy deny host wins over allow host" {
    const policy: action_policy.RuleSet = .{
        .allow_hosts = &.{"root@192.0.2.10"},
        .deny_hosts = &.{"root@192.0.2.10"},
    };

    try std.testing.expect(!action_policy.allowsHost(policy, "root@192.0.2.10"));
}

test "policy evaluates rollback-style execution host and ticket" {
    const policy: action_policy.RuleSet = .{
        .allow_hosts = &.{"root@192.0.2.10"},
        .require_approval_ticket = true,
    };

    const missing_ticket = action_policy.evaluateExecution(policy, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(!missing_ticket.valid);
    try std.testing.expect(missing_ticket.target_host_allowed);
    try std.testing.expect(!missing_ticket.approval_ticket_present);

    const wrong_host = action_policy.evaluateExecution(policy, "root@192.0.2.11", "OPS-123", "ops/alice");
    try std.testing.expect(!wrong_host.valid);
    try std.testing.expect(!wrong_host.target_host_allowed);

    const allowed = action_policy.evaluateExecution(policy, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.target_host_allowed);
    try std.testing.expect(allowed.approval_ticket_present);
    try std.testing.expect(allowed.approval_ticket_allowed);
}

test "policy evaluates rollback-style operator allowlist" {
    const policy: action_policy.RuleSet = .{
        .allow_operators = &.{"ops/alice"},
    };

    const denied = action_policy.evaluateExecution(policy, "root@192.0.2.10", null, "ops/bob");
    try std.testing.expect(!denied.valid);
    try std.testing.expect(!denied.operator_allowed);

    const allowed = action_policy.evaluateExecution(policy, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.operator_allowed);
}

test "policy evaluates rollback-style approval scopes" {
    const policy: action_policy.RuleSet = .{
        .allow_approval_ticket_prefixes = &.{"OPS-"},
        .approval_scopes = &.{.{
            .ticket_prefix = "OPS-",
            .hosts = &.{"root@192.0.2.10"},
            .operators = &.{"ops/alice"},
        }},
    };

    const wrong_operator = action_policy.evaluateExecution(policy, "root@192.0.2.10", "OPS-123", "ops/bob");
    try std.testing.expect(!wrong_operator.valid);
    try std.testing.expect(!wrong_operator.approval_scope_allowed);

    const allowed = action_policy.evaluateExecution(policy, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.approval_scope_allowed);
}

test "policy evaluates rollback-style ticket allowlist" {
    const policy: action_policy.RuleSet = .{
        .allow_approval_ticket_prefixes = &.{"OPS-"},
    };

    const missing = action_policy.evaluateExecution(policy, "root@192.0.2.10", null, "ops/alice");
    try std.testing.expect(!missing.valid);
    try std.testing.expect(!missing.approval_ticket_allowed);

    const denied = action_policy.evaluateExecution(policy, "root@192.0.2.10", "CHG-123", "ops/alice");
    try std.testing.expect(!denied.valid);
    try std.testing.expect(!denied.approval_ticket_allowed);

    const allowed = action_policy.evaluateExecution(policy, "root@192.0.2.10", "OPS-123", "ops/alice");
    try std.testing.expect(allowed.valid);
    try std.testing.expect(allowed.approval_ticket_allowed);
}
