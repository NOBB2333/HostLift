const std = @import("std");
const plan_schema = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");
const action_policy = @import("../policy/action.zig");
const manifest_hash = @import("../manifest/hash.zig");
const fs_util = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");
const summary_util = @import("../util/summary.zig");

// 校验 migration plan 文件，并输出 JSON 或摘要报告。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var plan_path: ?[]const u8 = null;
    var policy_path: ?[]const u8 = null;
    var summary = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plan")) {
            index += 1;
            if (index >= args.len) return error.MissingPlanPath;
            plan_path = args[index];
        } else if (std.mem.eql(u8, arg, "--policy")) {
            index += 1;
            if (index >= args.len) return error.MissingPolicyPath;
            policy_path = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else {
            return error.UnknownValidateArgument;
        }
    }

    const file_path = plan_path orelse return error.MissingPlanPath;
    const plan_bytes = try fs_util.readFileAlloc(io, allocator, file_path, 16 * 1024 * 1024);
    defer allocator.free(plan_bytes);
    const plan_hash = try manifest_hash.sha256BytesHexAlloc(allocator, plan_bytes);
    defer allocator.free(plan_hash);

    const parsed = try std.json.parseFromSlice(plan_schema.MigrationPlan, allocator, plan_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const report = plan_validator.validate(parsed.value);
    if (summary) {
        try summary_util.writePlanValidationSummary(writer, report);
    } else {
        try json_util.writePlanValidationReport(writer, report);
    }

    var policy_valid = true;
    if (policy_path) |path| {
        const policy = try readPolicy(io, allocator, path);
        defer policy.deinit();
        const policy_report = action_policy.evaluatePlanWithContext(parsed.value, policy.value, .{ .plan_hash = plan_hash });
        policy_valid = policy_report.valid;
        try writer.print(
            "Policy: valid={} checked={} allowed={} denied={} plan_hash_allowed={}\n",
            .{ policy_report.valid, policy_report.checked_actions, policy_report.allowed_actions, policy_report.denied_actions, policy_report.plan_hash_allowed },
        );
    }

    if (!report.valid) return error.InvalidMigrationPlan;
    if (!policy_valid) return error.PolicyDeniedMigrationPlan;
}

const ParsedPolicy = std.json.Parsed(action_policy.RuleSet);

// 读取并解析 action policy JSON。
fn readPolicy(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ParsedPolicy {
    const policy_bytes = try fs_util.readFileAlloc(io, allocator, path, 1024 * 1024);
    defer allocator.free(policy_bytes);
    return action_policy.parseFromSlice(allocator, policy_bytes);
}
