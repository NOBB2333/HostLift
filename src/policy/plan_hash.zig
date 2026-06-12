const std = @import("std");
const policy_match = @import("match.zig");

// plan hash 白名单和黑名单规则。
pub const Rules = struct {
    allow_hashes: []const []const u8 = &.{},
    deny_hashes: []const []const u8 = &.{},
};

// 判断 plan hash 规则列表是否都是 64 位十六进制 SHA-256。
pub fn validateRules(rules: Rules) bool {
    return allHashesValid(rules.allow_hashes) and allHashesValid(rules.deny_hashes);
}

// 判断 plan hash 是否被规则允许；deny 优先于 allow。
pub fn allows(rules: Rules, plan_hash: []const u8) bool {
    if (!validateRules(rules)) return false;
    if (!hashValid(plan_hash)) return false;
    if (policy_match.matchesExact(rules.deny_hashes, plan_hash)) return false;
    if (rules.allow_hashes.len > 0) return policy_match.matchesExact(rules.allow_hashes, plan_hash);
    return true;
}

// 校验所有 hash 值是否为合法 SHA-256 十六进制。
fn allHashesValid(values: []const []const u8) bool {
    for (values) |value| {
        if (!hashValid(value)) return false;
    }
    return true;
}

// 校验单个 hash 值是否为 64 字符十六进制。
fn hashValid(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

test "plan hash rules allow and deny exact hashes" {
    const good = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const other = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    try std.testing.expect(allows(.{ .allow_hashes = &.{good} }, good));
    try std.testing.expect(!allows(.{ .allow_hashes = &.{good} }, other));
    try std.testing.expect(!allows(.{ .allow_hashes = &.{good}, .deny_hashes = &.{good} }, good));
}

test "plan hash rules reject invalid configured hashes" {
    try std.testing.expect(!validateRules(.{ .allow_hashes = &.{"not-a-hash"} }));
}
