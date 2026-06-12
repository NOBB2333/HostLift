const std = @import("std");
const plan = @import("schema.zig");

// 将命令行模块名解析为计划模块枚举。
pub fn parseModuleName(value: []const u8) !plan.ModuleName {
    if (std.mem.eql(u8, value, "security")) return .dev_env;
    if (std.mem.eql(u8, value, "kernel")) return .processes;
    inline for (std.meta.fields(plan.ModuleName)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidFilterModule;
}

// 校验 action 过滤模式，避免危险字符进入匹配逻辑。
pub fn validateActionPattern(value: []const u8) !void {
    if (value.len == 0 or value.len > 512) return error.InvalidActionFilter;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidActionFilter;
        switch (byte) {
            '\'', '"', ';', '&', '|', '`', '$', '<', '>', '\\', '*', '?', '[', ']', '!' => return error.InvalidActionFilter,
            else => {},
        }
    }
}

// 判断模块列表中是否包含指定模块。
pub fn containsModule(values: []const plan.ModuleName, needle: plan.ModuleName) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

// 判断 action id 是否匹配任意完整 id 或前缀模式。
pub fn matchesAnyActionPattern(patterns: []const []const u8, action_id: []const u8) bool {
    for (patterns) |pattern| {
        if (std.mem.eql(u8, action_id, pattern) or std.mem.startsWith(u8, action_id, pattern)) return true;
    }
    return false;
}

// 判断 action 是否通过 include/exclude 过滤集合。
pub fn actionMatches(
    include_modules: []const plan.ModuleName,
    exclude_modules: []const plan.ModuleName,
    include_actions: []const []const u8,
    exclude_actions: []const []const u8,
    action: plan.Action,
) bool {
    if (containsModule(exclude_modules, action.module)) return false;
    if (matchesAnyActionPattern(exclude_actions, action.id)) return false;

    const module_included = include_modules.len == 0 or containsModule(include_modules, action.module);
    const action_included = include_actions.len == 0 or matchesAnyActionPattern(include_actions, action.id);
    return module_included and action_included;
}

test "filter match parses module names" {
    try std.testing.expectEqual(plan.ModuleName.packages, try parseModuleName("packages"));
    try std.testing.expectEqual(plan.ModuleName.services, try parseModuleName("services"));
    try std.testing.expectError(error.InvalidFilterModule, parseModuleName("unknown"));
}

test "filter match validates safe action patterns" {
    try validateActionPattern("packages/install/nginx");
    try validateActionPattern("projects/copy//srv/app");
    try std.testing.expectError(error.InvalidActionFilter, validateActionPattern(""));
    try std.testing.expectError(error.InvalidActionFilter, validateActionPattern("packages/install/*"));
    try std.testing.expectError(error.InvalidActionFilter, validateActionPattern("packages/install/nginx;rm"));
}

test "filter match handles exact and prefix action ids" {
    try std.testing.expect(matchesAnyActionPattern(&.{"packages/install/"}, "packages/install/nginx"));
    try std.testing.expect(matchesAnyActionPattern(&.{"packages/install/nginx"}, "packages/install/nginx"));
    try std.testing.expect(!matchesAnyActionPattern(&.{"services/enable/"}, "packages/install/nginx"));
}

test "filter match applies include and exclude precedence" {
    const package_action = plan.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install package",
        .risk = .low,
        .requires_confirmation = false,
    };
    const service_action = plan.Action{
        .id = "services/enable/nginx.service",
        .module = .services,
        .action_type = .enable_systemd_unit,
        .description = "Enable service",
        .risk = .low,
        .requires_confirmation = false,
    };

    try std.testing.expect(actionMatches(&.{.packages}, &.{}, &.{}, &.{}, package_action));
    try std.testing.expect(!actionMatches(&.{.packages}, &.{}, &.{}, &.{}, service_action));
    try std.testing.expect(!actionMatches(&.{.packages}, &.{.packages}, &.{}, &.{}, package_action));
    try std.testing.expect(!actionMatches(&.{}, &.{}, &.{"packages/install/"}, &.{"packages/install/nginx"}, package_action));
}
