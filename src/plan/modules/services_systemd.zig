const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual = @import("manual_common.zig");

// 规划系统级 systemd service、timer 和 socket 动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ServiceInventory,
    target: inventory.ServiceInventory,
) !void {
    try appendServiceUnitActions(allocator, actions, source.units, target.units);
    try appendDropInActions(allocator, actions, source.drop_ins, target.drop_ins);
    try appendEnvFileActions(allocator, actions, source.env_files, target.env_files);
    try appendTimerActions(allocator, actions, source.timers, target.timers);
    try appendSocketActions(allocator, actions, source.sockets, target.sockets);
}

// 规划 systemd service unit 的安装、启用和运行时审查动作。
fn appendServiceUnitActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_units: []const inventory.ServiceUnit,
    target_units: []const inventory.ServiceUnit,
) !void {
    for (source_units) |unit| {
        if (unit.custom and !hasService(target_units, unit.name)) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/install-unit",
                .name = unit.name,
                .subject = unit.path orelse unit.name,
                .module = .services,
                .action_type = .install_systemd_unit,
                .risk = .medium,
                .requires_confirmation = true,
                .description = "Install custom systemd service unit from source",
            });
        }

        if (unit.state == .enabled and !hasEnabledService(target_units, unit.name)) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/enable",
                .name = unit.name,
                .module = .services,
                .action_type = .enable_systemd_unit,
                .risk = if (unit.custom) .medium else .low,
                .requires_confirmation = unit.custom,
                .description = "Enable service on target after validation",
            });
        }

        if (dependencySummaryNeedsReview(target_units, unit)) {
            try manual.appendManualStep(allocator, actions, .{
                .id_prefix = "services/review-deps",
                .name = unit.name,
                .subject = unit.name,
                .module = .services,
                .risk = .high,
                .description = "Review systemd dependency graph before migration; compare Requires/Wants/After/EnvironmentFile/ExecStart and merge target-specific differences manually",
            });
        }

        if (serviceRuntimeNeedsReview(target_units, unit)) {
            const status_probes = [_]common.ManualProbeSpec{.{
                .kind = .systemd,
                .target = unit.name,
            }};
            try manual.appendManualStep(allocator, actions, .{
                .id_prefix = "services/review-start",
                .name = unit.name,
                .subject = unit.name,
                .module = .services,
                .risk = .high,
                .description = "Review whether to start this source-active service after package, config, data and dependency checks; HostLift does not start services by default",
                .task_provider = "systemd_status",
                .task_verify_probes = &status_probes,
            });
            try manual.appendManualStep(allocator, actions, .{
                .id_prefix = "services/check-status",
                .name = unit.name,
                .subject = unit.name,
                .module = .services,
                .risk = .high,
                .description = "Check systemctl status, journal tail, expected ports and service-specific health after migration; HostLift reports failures without acting as a heavy gate",
                .task_provider = "systemd_status",
                .task_verify_probes = &status_probes,
            });
        }
    }
}

// 规划 systemd drop-in 配置片段的人工审查动作。
fn appendDropInActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_drop_ins: []const inventory.SystemdDropIn,
    target_drop_ins: []const inventory.SystemdDropIn,
) !void {
    for (source_drop_ins) |drop_in| {
        if (hasEquivalentDropIn(target_drop_ins, drop_in)) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-drop-in",
            .name = drop_in.path,
            .subject = drop_in.unit,
            .module = .services,
            .risk = .high,
            .description = "Review systemd drop-in override before migration; merge with target unit instead of blindly overwriting",
        });
    }
}

// 规划服务环境文件的人工审查动作。
fn appendEnvFileActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_env_files: []const inventory.ServiceEnvFile,
    target_env_files: []const inventory.ServiceEnvFile,
) !void {
    for (source_env_files) |env_file| {
        if (hasEquivalentEnvFile(target_env_files, env_file)) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-env",
            .name = env_file.path,
            .subject = env_file.unit,
            .module = .services,
            .risk = .high,
            .description = "Review service environment file before migration; variables often contain host-specific paths, ports or credentials",
        });
    }
}

// 规划 systemd timer 的安装、启用和等价性审查动作。
fn appendTimerActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_timers: []const inventory.SystemdTimer,
    target_timers: []const inventory.SystemdTimer,
) !void {
    for (source_timers) |timer| {
        const target_has_timer = hasTimer(target_timers, timer.name);
        if (timer.custom and !target_has_timer) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/install-unit",
                .name = timer.name,
                .subject = timer.path orelse timer.name,
                .module = .services,
                .action_type = .install_systemd_unit,
                .risk = .medium,
                .requires_confirmation = true,
                .description = "Install custom systemd timer unit from source",
            });
        }

        if (timer.state == .enabled and !hasEnabledTimer(target_timers, timer.name)) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/enable",
                .name = timer.name,
                .module = .services,
                .action_type = .enable_systemd_unit,
                .risk = if (timer.custom) .medium else .low,
                .requires_confirmation = timer.custom,
                .description = "Enable systemd timer on target after validation",
            });
        }

        if (timer.custom and !target_has_timer) continue;
        if (hasEquivalentTimer(target_timers, timer)) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-timer",
            .name = timer.name,
            .subject = timer.path orelse timer.name,
            .module = .services,
            .risk = .high,
            .description = "Review systemd timer before migration",
        });
    }
}

// 规划 systemd socket 的安装、启用和等价性审查动作。
fn appendSocketActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source_sockets: []const inventory.SystemdSocket,
    target_sockets: []const inventory.SystemdSocket,
) !void {
    for (source_sockets) |socket| {
        const target_has_socket = hasSocket(target_sockets, socket.name);
        if (socket.custom and !target_has_socket) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/install-unit",
                .name = socket.name,
                .subject = socket.path orelse socket.name,
                .module = .services,
                .action_type = .install_systemd_unit,
                .risk = .medium,
                .requires_confirmation = true,
                .description = "Install custom systemd socket unit from source",
            });
        }

        if (socket.state == .enabled and !hasEnabledSocket(target_sockets, socket.name)) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "services/enable",
                .name = socket.name,
                .module = .services,
                .action_type = .enable_systemd_unit,
                .risk = if (socket.custom) .medium else .low,
                .requires_confirmation = socket.custom,
                .description = "Enable systemd socket on target after validation",
            });
        }

        if (socket.custom and !target_has_socket) continue;
        if (hasEquivalentSocket(target_sockets, socket)) continue;
        try manual.appendManualStep(allocator, actions, .{
            .id_prefix = "services/review-socket",
            .name = socket.name,
            .subject = socket.path orelse socket.name,
            .module = .services,
            .risk = .high,
            .description = "Review systemd socket before migration",
        });
    }
}

// 判断目标列表中是否已存在同名服务。
fn hasService(units: []const inventory.ServiceUnit, name: []const u8) bool {
    for (units) |unit| {
        if (std.mem.eql(u8, unit.name, name)) return true;
    }
    return false;
}

// 判断目标列表中是否已存在同名且已启用的服务。
fn hasEnabledService(units: []const inventory.ServiceUnit, name: []const u8) bool {
    for (units) |unit| {
        if (std.mem.eql(u8, unit.name, name) and unit.state == .enabled) return true;
    }
    return false;
}

// 判断源端活跃的服务在目标端是否未活跃，需要人工审查。
fn serviceRuntimeNeedsReview(target_units: []const inventory.ServiceUnit, source: inventory.ServiceUnit) bool {
    if (!isActiveLike(source.active_state)) return false;
    return !isActiveLike(serviceActiveState(target_units, source.name));
}

fn dependencySummaryNeedsReview(target_units: []const inventory.ServiceUnit, source: inventory.ServiceUnit) bool {
    const source_summary = source.dependency_summary orelse return false;
    if (source_summary.len == 0) return false;
    for (target_units) |unit| {
        if (!std.mem.eql(u8, unit.name, source.name)) continue;
        if (unit.dependency_summary == null) return true;
        return !std.mem.eql(u8, source_summary, unit.dependency_summary.?);
    }
    return true;
}

// 查询目标列表中指定服务的运行状态，未找到返回 unknown。
fn serviceActiveState(units: []const inventory.ServiceUnit, name: []const u8) inventory.ServiceActiveState {
    for (units) |unit| {
        if (std.mem.eql(u8, unit.name, name)) return unit.active_state;
    }
    return .unknown;
}

// 判断服务状态是否属于活跃类（active、reloading、activating）。
fn isActiveLike(state: inventory.ServiceActiveState) bool {
    return switch (state) {
        .active, .reloading, .activating => true,
        .inactive, .failed, .deactivating, .maintenance, .unknown => false,
    };
}

// 判断目标列表中是否已存在同名 timer。
fn hasTimer(timers: []const inventory.SystemdTimer, name: []const u8) bool {
    for (timers) |timer| {
        if (std.mem.eql(u8, timer.name, name)) return true;
    }
    return false;
}

// 判断目标列表中是否已存在同名且已启用的 timer。
fn hasEnabledTimer(timers: []const inventory.SystemdTimer, name: []const u8) bool {
    for (timers) |timer| {
        if (std.mem.eql(u8, timer.name, name) and timer.state == .enabled) return true;
    }
    return false;
}

// 判断目标列表中是否存在与源 timer 完全等价的条目。
fn hasEquivalentTimer(timers: []const inventory.SystemdTimer, source: inventory.SystemdTimer) bool {
    for (timers) |timer| {
        if (!std.mem.eql(u8, timer.name, source.name)) continue;
        if (timer.state != source.state) continue;
        if (!std.mem.eql(u8, timer.activates, source.activates)) continue;
        if (!std.mem.eql(u8, timer.schedule, source.schedule)) continue;
        if (timer.custom != source.custom) continue;
        return true;
    }
    return false;
}

// 判断目标列表中是否已存在同名 socket。
fn hasSocket(sockets: []const inventory.SystemdSocket, name: []const u8) bool {
    for (sockets) |socket| {
        if (std.mem.eql(u8, socket.name, name)) return true;
    }
    return false;
}

// 判断目标列表中是否已存在同名且已启用的 socket。
fn hasEnabledSocket(sockets: []const inventory.SystemdSocket, name: []const u8) bool {
    for (sockets) |socket| {
        if (std.mem.eql(u8, socket.name, name) and socket.state == .enabled) return true;
    }
    return false;
}

// 判断目标列表中是否存在与源 socket 完全等价的条目。
fn hasEquivalentSocket(sockets: []const inventory.SystemdSocket, source: inventory.SystemdSocket) bool {
    for (sockets) |socket| {
        if (!std.mem.eql(u8, socket.name, source.name)) continue;
        if (socket.state != source.state) continue;
        if (!optionalStringEqual(socket.activates, source.activates)) continue;
        if (socket.custom != source.custom) continue;
        return true;
    }
    return false;
}

// 比较两个可选字符串是否相等，两者均为 null 视为相等。
fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

// 判断目标中是否已有等价的 drop-in 摘要。
fn hasEquivalentDropIn(drop_ins: []const inventory.SystemdDropIn, source: inventory.SystemdDropIn) bool {
    for (drop_ins) |drop_in| {
        if (!std.mem.eql(u8, drop_in.unit, source.unit)) continue;
        if (!std.mem.eql(u8, drop_in.path, source.path)) continue;
        if (drop_in.size != source.size) continue;
        if (drop_in.meaningful_lines != source.meaningful_lines) continue;
        return true;
    }
    return false;
}

// 判断目标中是否已有等价的服务环境文件摘要。
fn hasEquivalentEnvFile(files: []const inventory.ServiceEnvFile, source: inventory.ServiceEnvFile) bool {
    for (files) |file| {
        if (!std.mem.eql(u8, file.unit, source.unit)) continue;
        if (!std.mem.eql(u8, file.path, source.path)) continue;
        if (file.size != source.size) continue;
        if (file.meaningful_lines != source.meaningful_lines) continue;
        return true;
    }
    return false;
}

test "systemd plan reviews drop-ins env files and start status" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var source_units = [_]inventory.ServiceUnit{.{
        .name = "app.service",
        .state = .enabled,
        .active_state = .active,
        .custom = false,
    }};
    var target_units = [_]inventory.ServiceUnit{.{
        .name = "app.service",
        .state = .enabled,
        .active_state = .inactive,
        .custom = false,
    }};
    var source_dropins = [_]inventory.SystemdDropIn{.{
        .unit = "app.service",
        .path = "/etc/systemd/system/app.service.d/override.conf",
        .size = 42,
        .meaningful_lines = 2,
    }};
    var source_env = [_]inventory.ServiceEnvFile{.{
        .unit = "app.service",
        .path = "/etc/default/app",
        .size = 12,
        .meaningful_lines = 1,
    }};

    try appendActions(std.testing.allocator, &actions, .{
        .init_system = "systemd",
        .units = source_units[0..],
        .drop_ins = source_dropins[0..],
        .env_files = source_env[0..],
    }, .{
        .init_system = "systemd",
        .units = target_units[0..],
    });

    try std.testing.expect(hasTestAction(actions.items, "services/review-start/app.service"));
    try std.testing.expect(hasTestAction(actions.items, "services/check-status/app.service"));
    try std.testing.expect(hasTestAction(actions.items, "services/review-drop-in//etc/systemd/system/app.service.d/override.conf"));
    try std.testing.expect(hasTestAction(actions.items, "services/review-env//etc/default/app"));
    for (actions.items) |action| {
        if (!std.mem.eql(u8, action.id, "services/check-status/app.service")) continue;
        const task = action.manual_task.?;
        try std.testing.expectEqualStrings("systemd_status", task.provider);
        try std.testing.expectEqual(plan.ManualProbeKind.systemd, task.verify_probes[0].kind);
        try std.testing.expectEqualStrings("app.service", task.verify_probes[0].target);
    }
}

// 测试辅助：释放 action 列表。
fn freeTestActions(actions: *std.ArrayList(plan.Action)) void {
    for (actions.items) |action| plan.deinitAction(std.testing.allocator, action);
    actions.deinit(std.testing.allocator);
}

// 测试辅助：判断 action id 是否存在。
fn hasTestAction(actions: []const plan.Action, id: []const u8) bool {
    for (actions) |action| {
        if (std.mem.eql(u8, action.id, id)) return true;
    }
    return false;
}
