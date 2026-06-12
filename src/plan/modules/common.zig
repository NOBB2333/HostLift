const std = @import("std");
const plan = @import("../schema.zig");

// 迁移动作输入参数结构体，统一各模块的动作构造字段。
pub const ActionInput = struct {
    id_prefix: []const u8,
    name: []const u8,
    subject: ?[]const u8 = null,
    module: plan.ModuleName,
    action_type: plan.ActionType,
    uid: ?u32 = null,
    gid: ?u32 = null,
    home: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    risk: plan.RiskLevel,
    requires_confirmation: bool,
    description: []const u8,
    recursive: bool = false,
};

// 构造并追加一条迁移动作，统一 action id、subject 和描述生成规则。
pub fn appendAction(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    input: ActionInput,
) !void {
    try actions.append(allocator, .{
        .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ input.id_prefix, input.name }),
        .module = input.module,
        .action_type = input.action_type,
        .subject = try allocator.dupe(u8, input.subject orelse input.name),
        .uid = input.uid,
        .gid = input.gid,
        .home = if (input.home) |home| try allocator.dupe(u8, home) else null,
        .shell = if (input.shell) |shell| try allocator.dupe(u8, shell) else null,
        .owner = if (input.owner) |owner| try allocator.dupe(u8, owner) else null,
        .description = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ input.description, input.name }),
        .risk = input.risk,
        .requires_confirmation = input.requires_confirmation,
        .recursive = input.recursive,
    });
}

// 判断字符串列表是否包含指定值。
pub fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
