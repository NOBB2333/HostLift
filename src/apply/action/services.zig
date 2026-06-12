const std = @import("std");
const plan_schema = @import("../../plan/schema.zig");
const common = @import("common.zig");

// 将源 systemd unit 路径映射到目标机器的 unit 安装路径。
pub fn targetPath(allocator: std.mem.Allocator, action: plan_schema.Action, source_path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, source_path, "/etc/systemd/system/")) return allocator.dupe(u8, source_path);
    const unit_name = if (std.mem.startsWith(u8, action.id, "services/install-unit/"))
        action.id["services/install-unit/".len..]
    else
        source_path;
    return std.fmt.allocPrint(allocator, "/etc/systemd/system/{s}", .{unit_name});
}

// 生成 systemctl enable 命令。
pub fn enableCommand(allocator: std.mem.Allocator, service: []const u8) !common.Command {
    if (service.len == 0) return error.MissingApplySubject;
    const argv = try allocator.alloc([]const u8, 3);
    argv[0] = "systemctl";
    argv[1] = "enable";
    argv[2] = service;
    return common.commandWithoutOwned(allocator, argv);
}

// 生成 systemctl disable 命令，用于撤销 enable_systemd_unit。
pub fn disableCommand(allocator: std.mem.Allocator, service: []const u8) !common.Command {
    if (service.len == 0) return error.MissingApplySubject;
    const argv = try allocator.alloc([]const u8, 3);
    argv[0] = "systemctl";
    argv[1] = "disable";
    argv[2] = service;
    return common.commandWithoutOwned(allocator, argv);
}

// 生成用户级 systemctl enable 命令。
pub fn userEnableCommand(allocator: std.mem.Allocator, unit_ref: []const u8) !common.Command {
    return userCommand(allocator, unit_ref, "enable");
}

// 生成用户级 systemctl is-enabled 验证命令。
pub fn userIsEnabledCommand(allocator: std.mem.Allocator, unit_ref: []const u8) !common.Command {
    return userCommand(allocator, unit_ref, "is-enabled");
}

// 生成用户级 systemctl disable 命令，用于撤销 enable_user_systemd_unit。
pub fn userDisableCommand(allocator: std.mem.Allocator, unit_ref: []const u8) !common.Command {
    return userCommand(allocator, unit_ref, "disable");
}

// 生成 OpenRC runlevel 添加命令。
pub fn openRcAddCommand(allocator: std.mem.Allocator, service: []const u8, runlevel: []const u8) !common.Command {
    return openRcCommand(allocator, "add", service, runlevel);
}

// 生成 OpenRC runlevel 删除命令，用于撤销 enable_openrc_service。
pub fn openRcDeleteCommand(allocator: std.mem.Allocator, service: []const u8, runlevel: []const u8) !common.Command {
    return openRcCommand(allocator, "del", service, runlevel);
}

// OpenRC 服务与 runlevel 引用。
pub const OpenRcRef = struct {
    service: []const u8,
    runlevels: []const u8,
};

// SysV 服务与 runlevel 引用。
pub const SysvRef = struct {
    service: []const u8,
    runlevels: []const u8,
};

// 解析 OpenRC action subject，格式为 service:runlevel1,runlevel2。
pub fn parseOpenRcRef(value: []const u8) !OpenRcRef {
    const separator = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidOpenRcServiceRef;
    const service = value[0..separator];
    const runlevels = value[separator + 1 ..];
    if (service.len == 0 or runlevels.len == 0) return error.InvalidOpenRcServiceRef;
    if (std.mem.indexOfScalar(u8, runlevels, ':') != null) return error.InvalidOpenRcServiceRef;
    return .{ .service = service, .runlevels = runlevels };
}

// 解析 SysV action subject，格式为 service:2,3,5。
pub fn parseSysvRef(value: []const u8) !SysvRef {
    const separator = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidSysvInitRef;
    const service = value[0..separator];
    const runlevels = value[separator + 1 ..];
    if (service.len == 0 or runlevels.len == 0) return error.InvalidSysvInitRef;
    if (std.mem.indexOfScalar(u8, runlevels, ':') != null) return error.InvalidSysvInitRef;
    return .{ .service = service, .runlevels = runlevels };
}

// 生成 SysV chkconfig on 命令。
pub fn sysvEnableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !common.Command {
    return sysvCommand(allocator, service, runlevels, "on");
}

// 生成 SysV chkconfig off 命令。
pub fn sysvDisableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !common.Command {
    return sysvCommand(allocator, service, runlevels, "off");
}

// 生成 SysV update-rc.d enable 命令。
pub fn sysvUpdateRcDEnableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !common.Command {
    return sysvUpdateRcDCommand(allocator, service, runlevels, "enable");
}

// 生成 SysV update-rc.d disable 命令。
pub fn sysvUpdateRcDDisableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !common.Command {
    return sysvUpdateRcDCommand(allocator, service, runlevels, "disable");
}

// 生成 runuser 执行用户级 systemctl 命令。
fn userCommand(allocator: std.mem.Allocator, unit_ref: []const u8, verb: []const u8) !common.Command {
    const parsed = try parseUserUnitRef(unit_ref);
    const argv = try allocator.alloc([]const u8, 8);
    argv[0] = "runuser";
    argv[1] = "-u";
    argv[2] = parsed.user;
    argv[3] = "--";
    argv[4] = "systemctl";
    argv[5] = "--user";
    argv[6] = verb;
    argv[7] = parsed.unit;
    return common.commandWithoutOwned(allocator, argv);
}

// 拼接 rc-update 命令，操作指定 runlevel 下的服务。
fn openRcCommand(allocator: std.mem.Allocator, verb: []const u8, service: []const u8, runlevel: []const u8) !common.Command {
    if (service.len == 0 or runlevel.len == 0) return error.InvalidOpenRcServiceRef;
    const argv = try allocator.alloc([]const u8, 4);
    argv[0] = "rc-update";
    argv[1] = verb;
    argv[2] = service;
    argv[3] = runlevel;
    return common.commandWithoutOwned(allocator, argv);
}

// 拼接 chkconfig 命令，设置服务在指定 runlevel 的开关状态。
fn sysvCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8, state: []const u8) !common.Command {
    if (service.len == 0 or runlevels.len == 0) return error.InvalidSysvInitRef;
    const normalized = try normalizeSysvRunlevels(allocator, runlevels);
    errdefer allocator.free(normalized);
    const argv = try allocator.alloc([]const u8, 5);
    argv[0] = "chkconfig";
    argv[1] = "--level";
    argv[2] = normalized;
    argv[3] = service;
    argv[4] = state;
    const owned = try allocator.alloc([]const u8, 1);
    owned[0] = normalized;
    return .{ .argv = argv, .owned = owned };
}

// 拼接 update-rc.d 命令，逐 runlevel 启用或禁用 SysV 服务。
fn sysvUpdateRcDCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8, verb: []const u8) !common.Command {
    if (service.len == 0 or runlevels.len == 0) return error.InvalidSysvInitRef;
    const count = try countUpdateRcDRunlevels(runlevels);
    const argv = try allocator.alloc([]const u8, 3 + count);
    argv[0] = "update-rc.d";
    argv[1] = service;
    argv[2] = verb;
    var index: usize = 3;
    var iterator = std.mem.splitScalar(u8, runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) continue;
        if (!isUpdateRcDRunlevel(runlevel)) return error.InvalidSysvInitRef;
        argv[index] = runlevel;
        index += 1;
    }
    return common.commandWithoutOwned(allocator, argv);
}

// 统计 update-rc.d 格式中合法 runlevel 的数量。
fn countUpdateRcDRunlevels(runlevels: []const u8) !usize {
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) continue;
        if (!isUpdateRcDRunlevel(runlevel)) return error.InvalidSysvInitRef;
        count += 1;
    }
    if (count == 0) return error.InvalidSysvInitRef;
    return count;
}

// 判断 runlevel 是否属于 update-rc.d 支持的 2-5 范围。
fn isUpdateRcDRunlevel(runlevel: []const u8) bool {
    return runlevel.len == 1 and runlevel[0] >= '2' and runlevel[0] <= '5';
}

// 将逗号分隔的 runlevel 列表规范化为合法的 SysV runlevel 字符串。
fn normalizeSysvRunlevels(allocator: std.mem.Allocator, runlevels: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, runlevels, ',');
    while (iterator.next()) |runlevel| {
        if (runlevel.len == 0) continue;
        if (runlevel.len != 1 or runlevel[0] < '0' or runlevel[0] > '6') return error.InvalidSysvInitRef;
        try result.append(allocator, runlevel[0]);
    }
    if (result.items.len == 0) return error.InvalidSysvInitRef;
    return result.toOwnedSlice(allocator);
}

// 用户级 systemd unit 引用，解析后得到 user 和 unit。
const UserUnitRef = struct {
    user: []const u8,
    unit: []const u8,
};

// 解析 user:unit 格式的用户级 systemd unit 引用。
fn parseUserUnitRef(unit_ref: []const u8) !UserUnitRef {
    const separator = std.mem.indexOfScalar(u8, unit_ref, ':') orelse return error.InvalidUserSystemdUnitRef;
    const user = unit_ref[0..separator];
    const unit = unit_ref[separator + 1 ..];
    if (user.len == 0 or unit.len == 0) return error.InvalidUserSystemdUnitRef;
    if (std.mem.indexOfScalar(u8, unit, ':') != null) return error.InvalidUserSystemdUnitRef;
    return .{ .user = user, .unit = unit };
}
