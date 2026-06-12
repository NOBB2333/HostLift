const std = @import("std");
const inventory_schema = @import("../inventory/schema.zig");
const plan_schema = @import("../plan/schema.zig");
const common = @import("action/common.zig");
const package_actions = @import("action/packages.zig");
const service_actions = @import("action/services.zig");
const user_actions = @import("action/users.zig");
const project_actions = @import("action/projects.zig");
const subject_actions = @import("action/subjects.zig");

pub const Command = common.Command;
pub const OpenRcRef = service_actions.OpenRcRef;
pub const SysvRef = service_actions.SysvRef;

// 根据 action 类型计算需要提前备份的远程目标路径。
pub fn backupTargetForAction(allocator: std.mem.Allocator, action: plan_schema.Action) !?[]const u8 {
    return subject_actions.backupTargetForAction(allocator, action);
}

// 将源 systemd unit 路径映射到目标机器的 unit 安装路径。
pub fn systemdTargetPath(allocator: std.mem.Allocator, action: plan_schema.Action, source_path: []const u8) ![]const u8 {
    return service_actions.targetPath(allocator, action, source_path);
}

// 根据 action 类型生成安全 argv，后续还会经过 remote planner 校验。
pub fn commandForAction(
    allocator: std.mem.Allocator,
    migration_plan: plan_schema.MigrationPlan,
    action: plan_schema.Action,
) !Command {
    return switch (action.action_type) {
        .install_package => packageInstallCommand(allocator, migration_plan.package_manager, subject(action)),
        .enable_systemd_unit => systemctlEnableCommand(allocator, subject(action)),
        .enable_user_systemd_unit => userSystemctlEnableCommand(allocator, subject(action)),
        .enable_openrc_service => openRcEnableCommand(allocator, subject(action)),
        .disable_openrc_service => openRcDisableCommand(allocator, subject(action)),
        .enable_sysv_init => sysvEnableActionCommand(allocator, subject(action)),
        .disable_sysv_init => sysvDisableActionCommand(allocator, subject(action)),
        .create_group => groupAddCommand(allocator, subject(action), action.gid),
        .create_user => userAddCommand(allocator, subject(action), action.uid, action.gid, action.home, action.shell),
        .start_compose_project => dockerComposeUpCommand(allocator, subject(action)),
        .verify_compose_project => dockerComposePsCommand(allocator, subject(action)),
        else => error.UnsupportedApplyAction,
    };
}

// 根据目标包管理器生成安装包命令。
pub fn packageInstallCommand(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !Command {
    return package_actions.installCommand(allocator, package_manager, package);
}

// 根据目标包管理器生成包安装结果验证命令。
pub fn packageVerifyCommand(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !Command {
    return package_actions.verifyCommand(allocator, package_manager, package);
}

// 根据目标包管理器生成卸载包命令，用于回滚 HostLift 安装的包。
pub fn packageRemoveCommand(
    allocator: std.mem.Allocator,
    package_manager: inventory_schema.PackageManagerKind,
    package: []const u8,
) !Command {
    return package_actions.removeCommand(allocator, package_manager, package);
}

// 生成 systemctl enable 命令。
pub fn systemctlEnableCommand(allocator: std.mem.Allocator, service: []const u8) !Command {
    return service_actions.enableCommand(allocator, service);
}

// 生成 systemctl disable 命令，用于回滚 service enable。
pub fn systemctlDisableCommand(allocator: std.mem.Allocator, service: []const u8) !Command {
    return service_actions.disableCommand(allocator, service);
}

// 生成用户级 systemctl enable 命令。
pub fn userSystemctlEnableCommand(allocator: std.mem.Allocator, unit_ref: []const u8) !Command {
    return service_actions.userEnableCommand(allocator, unit_ref);
}

// 生成用户级 systemctl is-enabled 验证命令。
pub fn userSystemctlIsEnabledCommand(allocator: std.mem.Allocator, unit_ref: []const u8) !Command {
    return service_actions.userIsEnabledCommand(allocator, unit_ref);
}

// 生成用户级 systemctl disable 命令，用于回滚用户级 unit enable。
pub fn userSystemctlDisableCommand(allocator: std.mem.Allocator, unit_ref: []const u8) !Command {
    return service_actions.userDisableCommand(allocator, unit_ref);
}

// 解析 OpenRC service/runlevel subject。
pub fn parseOpenRcRef(value: []const u8) !OpenRcRef {
    return service_actions.parseOpenRcRef(value);
}

// 生成 OpenRC rc-update add 命令。
pub fn openRcAddCommand(allocator: std.mem.Allocator, service: []const u8, runlevel: []const u8) !Command {
    return service_actions.openRcAddCommand(allocator, service, runlevel);
}

// 生成 OpenRC rc-update del 命令。
pub fn openRcDeleteCommand(allocator: std.mem.Allocator, service: []const u8, runlevel: []const u8) !Command {
    return service_actions.openRcDeleteCommand(allocator, service, runlevel);
}

// 解析 SysV service/runlevel subject。
pub fn parseSysvRef(value: []const u8) !SysvRef {
    return service_actions.parseSysvRef(value);
}

// 生成 SysV chkconfig on 命令。
pub fn sysvEnableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !Command {
    return service_actions.sysvEnableCommand(allocator, service, runlevels);
}

// 生成 SysV chkconfig off 命令。
pub fn sysvDisableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !Command {
    return service_actions.sysvDisableCommand(allocator, service, runlevels);
}

// 生成 SysV update-rc.d enable 命令。
pub fn sysvUpdateRcDEnableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !Command {
    return service_actions.sysvUpdateRcDEnableCommand(allocator, service, runlevels);
}

// 生成 SysV update-rc.d disable 命令。
pub fn sysvUpdateRcDDisableCommand(allocator: std.mem.Allocator, service: []const u8, runlevels: []const u8) !Command {
    return service_actions.sysvUpdateRcDDisableCommand(allocator, service, runlevels);
}

// 解析 OpenRC subject 并生成 rc-update add 命令。
fn openRcEnableCommand(allocator: std.mem.Allocator, service_ref: []const u8) !Command {
    const parsed = try parseOpenRcRef(service_ref);
    if (std.mem.indexOfScalar(u8, parsed.runlevels, ',') != null) return error.OpenRcEnableCommandRequiresSingleRunlevel;
    return openRcAddCommand(allocator, parsed.service, parsed.runlevels);
}

// 解析 OpenRC subject 并生成 rc-update del 命令。
fn openRcDisableCommand(allocator: std.mem.Allocator, service_ref: []const u8) !Command {
    const parsed = try parseOpenRcRef(service_ref);
    if (std.mem.indexOfScalar(u8, parsed.runlevels, ',') != null) return error.OpenRcDisableCommandRequiresSingleRunlevel;
    return openRcDeleteCommand(allocator, parsed.service, parsed.runlevels);
}

// 解析 SysV subject 并生成 chkconfig on 命令。
fn sysvEnableActionCommand(allocator: std.mem.Allocator, service_ref: []const u8) !Command {
    const parsed = try parseSysvRef(service_ref);
    return sysvEnableCommand(allocator, parsed.service, parsed.runlevels);
}

// 解析 SysV subject 并生成 chkconfig off 命令。
fn sysvDisableActionCommand(allocator: std.mem.Allocator, service_ref: []const u8) !Command {
    const parsed = try parseSysvRef(service_ref);
    return sysvDisableCommand(allocator, parsed.service, parsed.runlevels);
}

// 生成 groupadd 命令，必要时保留 gid。
pub fn groupAddCommand(allocator: std.mem.Allocator, group: []const u8, gid: ?u32) !Command {
    return user_actions.groupAddCommand(allocator, group, gid);
}

// 生成 useradd 命令，保留 uid/gid/home/shell 等基础属性。
pub fn userAddCommand(
    allocator: std.mem.Allocator,
    user: []const u8,
    uid: ?u32,
    gid: ?u32,
    home: ?[]const u8,
    shell: ?[]const u8,
) !Command {
    return user_actions.userAddCommand(allocator, user, uid, gid, home, shell);
}

// 生成 groupdel 命令，用于回滚 HostLift 创建的组。
pub fn groupDeleteCommand(allocator: std.mem.Allocator, group: []const u8) !Command {
    return user_actions.groupDeleteCommand(allocator, group);
}

// 生成 userdel 命令，用于回滚 HostLift 创建的用户；不删除 home。
pub fn userDeleteCommand(allocator: std.mem.Allocator, user: []const u8) !Command {
    return user_actions.userDeleteCommand(allocator, user);
}

// 生成 Docker Compose 后台启动命令。
pub fn dockerComposeUpCommand(allocator: std.mem.Allocator, compose_file: []const u8) !Command {
    return project_actions.composeUpCommand(allocator, compose_file);
}

// 生成 Docker Compose 状态检查命令。
pub fn dockerComposePsCommand(allocator: std.mem.Allocator, compose_file: []const u8) !Command {
    return project_actions.composePsCommand(allocator, compose_file);
}

// 生成 Docker Compose down 命令，用于回滚 compose up。
pub fn dockerComposeDownCommand(allocator: std.mem.Allocator, compose_file: []const u8) !Command {
    return project_actions.composeDownCommand(allocator, compose_file);
}

// 根据 action subject 或 id 前缀推导实际操作对象。
pub fn subject(action: plan_schema.Action) []const u8 {
    return subject_actions.subject(action);
}
