const std = @import("std");
const audit_operator = @import("../audit/operator.zig");
const security_validation = @import("../security/validation.zig");

pub const schema_version = "hostlift.host_authz.v1";

// 主机授权规则，定义 operator 可操作的主机列表。
pub const Rule = struct {
    operator: []const u8,
    hosts: []const []const u8 = &.{},
    host_prefixes: []const []const u8 = &.{},
    allow_all_hosts: bool = false,
};

// 主机授权文档，包含规则列表。
pub const Document = struct {
    schema_version: []const u8 = schema_version,
    rules: []const Rule = &.{},
};

// 主机授权评估报告。
pub const Report = struct {
    schema_version: []const u8 = "hostlift.host_authz.report.v1",
    valid: bool,
    operator_matched: bool,
    host_allowed: bool,
};

// 从 JSON bytes 解析本地主机授权文件。
pub fn parseFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Document) {
    return std.json.parseFromSlice(Document, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

// 评估 operator 是否被允许操作指定 host。
pub fn evaluate(document: Document, operator: []const u8, host: []const u8) Report {
    var report: Report = .{
        .valid = true,
        .operator_matched = false,
        .host_allowed = false,
    };
    if (!isValidDocument(document)) {
        report.valid = false;
        return report;
    }
    audit_operator.validate(operator) catch {
        report.valid = false;
        return report;
    };
    security_validation.validateHost(host) catch {
        report.valid = false;
        return report;
    };

    for (document.rules) |rule| {
        if (!std.mem.eql(u8, rule.operator, operator)) continue;
        report.operator_matched = true;
        if (rule.allow_all_hosts or matchesExact(rule.hosts, host) or matchesPrefix(rule.host_prefixes, host)) {
            report.host_allowed = true;
            return report;
        }
    }
    report.valid = report.operator_matched and report.host_allowed;
    return report;
}

// 校验主机授权文档的 schema 版本和所有规则合法性。
fn isValidDocument(document: Document) bool {
    if (!std.mem.eql(u8, document.schema_version, schema_version)) return false;
    for (document.rules) |rule| {
        audit_operator.validate(rule.operator) catch return false;
        if (!allHostsValid(rule.hosts)) return false;
        if (!allHostPrefixesValid(rule.host_prefixes)) return false;
        if (!rule.allow_all_hosts and rule.hosts.len == 0 and rule.host_prefixes.len == 0) return false;
    }
    return true;
}

// 校验所有主机值是否合法。
fn allHostsValid(values: []const []const u8) bool {
    for (values) |value| {
        security_validation.validateHost(value) catch return false;
    }
    return true;
}

// 校验所有主机前缀值是否合法。
fn allHostPrefixesValid(values: []const []const u8) bool {
    for (values) |value| {
        if (value.len == 0 or value.len > 255) return false;
        for (value) |byte| {
            if (std.ascii.isAlphanumeric(byte)) continue;
            switch (byte) {
                '.', '-', '_', '@', ':', '[', ']' => {},
                else => return false,
            }
        }
    }
    return true;
}

// 精确匹配主机列表。
fn matchesExact(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

// 前缀匹配主机列表。
fn matchesPrefix(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.startsWith(u8, needle, value)) return true;
    }
    return false;
}

test "host authorization allows exact host for operator" {
    const document: Document = .{ .rules = &.{.{
        .operator = "ops/alice",
        .hosts = &.{"root@192.0.2.10"},
    }} };
    const report = evaluate(document, "ops/alice", "root@192.0.2.10");
    try std.testing.expect(report.valid);
    try std.testing.expect(report.operator_matched);
    try std.testing.expect(report.host_allowed);
}

test "host authorization denies unmatched host" {
    const document: Document = .{ .rules = &.{.{
        .operator = "ops/alice",
        .hosts = &.{"root@192.0.2.10"},
    }} };
    const report = evaluate(document, "ops/alice", "root@192.0.2.11");
    try std.testing.expect(!report.valid);
    try std.testing.expect(report.operator_matched);
    try std.testing.expect(!report.host_allowed);
}

test "host authorization allows host prefix" {
    const document: Document = .{ .rules = &.{.{
        .operator = "ops/alice",
        .host_prefixes = &.{"root@192.0.2."},
    }} };
    try std.testing.expect(evaluate(document, "ops/alice", "root@192.0.2.99").valid);
}

test "host authorization parses JSON document" {
    const bytes =
        \\{
        \\  "schema_version": "hostlift.host_authz.v1",
        \\  "rules": [
        \\    {
        \\      "operator": "ops/alice",
        \\      "hosts": ["root@192.0.2.10"],
        \\      "host_prefixes": ["admin@2001:db8:"]
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try parseFromSlice(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(schema_version, parsed.value.schema_version);
    try std.testing.expect(evaluate(parsed.value, "ops/alice", "root@192.0.2.10").valid);
    try std.testing.expect(evaluate(parsed.value, "ops/alice", "admin@2001:db8::1").valid);
}

test "host authorization rejects invalid rule shapes" {
    const empty_rule: Document = .{ .rules = &.{.{ .operator = "ops/alice" }} };
    try std.testing.expect(!evaluate(empty_rule, "ops/alice", "root@192.0.2.10").valid);

    const invalid_host: Document = .{ .rules = &.{.{
        .operator = "ops/alice",
        .hosts = &.{"root@bad host"},
    }} };
    try std.testing.expect(!evaluate(invalid_host, "ops/alice", "root@192.0.2.10").valid);
}
