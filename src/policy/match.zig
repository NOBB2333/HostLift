const std = @import("std");
const plan_schema = @import("../plan/schema.zig");
const security_validation = @import("../security/validation.zig");

// 判断模块列表中是否包含指定模块。
pub fn containsModule(items: []const plan_schema.ModuleName, value: plan_schema.ModuleName) bool {
    for (items) |item| {
        if (item == value) return true;
    }
    return false;
}

// 判断字符串是否匹配任一 action id 前缀。
pub fn matchesAnyPrefix(prefixes: []const []const u8, value: []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}

// 判断字符串是否精确命中列表中的任一值。
pub fn matchesExact(values: []const []const u8, target: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

// 判断 action 前缀列表是否都非空。
pub fn allPrefixesValid(prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (prefix.len == 0) return false;
    }
    return true;
}

// 判断 host 列表是否都符合 HostLift 远程主机格式。
pub fn allHostsValid(hosts: []const []const u8) bool {
    for (hosts) |host| {
        security_validation.validateHost(host) catch return false;
    }
    return true;
}

// 判断单个 host 是否符合 HostLift 远程主机格式。
pub fn hostValid(host: []const u8) bool {
    security_validation.validateHost(host) catch return false;
    return true;
}

// 将风险等级转换为可比较的顺序值。
pub fn riskRank(value: plan_schema.RiskLevel) u8 {
    return switch (value) {
        .low => 0,
        .medium => 1,
        .high => 2,
        .critical => 3,
    };
}
