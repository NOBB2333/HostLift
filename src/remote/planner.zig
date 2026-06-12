const std = @import("std");
const command_plan = @import("command_plan.zig");
const defaults = @import("defaults.zig");
const transfer_plan = @import("transfer_plan.zig");
const validation = @import("../security/validation.zig");

pub const default_timeout_seconds = defaults.default_timeout_seconds;
pub const buildCommandPlan = command_plan.buildCommandPlan;
pub const buildCommandPlanWithOptions = command_plan.buildCommandPlanWithOptions;
pub const buildTransferPlan = transfer_plan.buildTransferPlan;
pub const buildTransferPlanWithOptions = transfer_plan.buildTransferPlanWithOptions;
pub const buildTransferPlanAdvanced = transfer_plan.buildTransferPlanAdvanced;
pub const buildTransferPlanAdvancedWithResume = transfer_plan.buildTransferPlanAdvancedWithResume;
pub const buildTransferPlanAdvancedWithLimits = transfer_plan.buildTransferPlanAdvancedWithLimits;

// 校验 SSH host 字符串，避免把 shell 元字符带入命令边界。
pub fn validateHost(host: []const u8) !void {
    return validation.validateHost(host);
}

// 校验远程命令的单个 argv token；当前只允许保守字符集。
pub fn validateCommandToken(token: []const u8) !void {
    return validation.validateCommandToken(token);
}

// 校验传输路径，拒绝空白、通配符和常见 shell 元字符。
pub fn validatePath(path: []const u8) !void {
    return validation.validatePath(path);
}

test "host validation rejects whitespace" {
    try std.testing.expectError(error.InvalidRemoteHost, validateHost("root@bad host"));
}
