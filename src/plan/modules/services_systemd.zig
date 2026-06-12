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

        if (serviceRuntimeNeedsReview(target_units, unit)) {
            try manual.appendManualStep(allocator, actions, .{
                .id_prefix = "services/review-runtime",
                .name = unit.name,
                .subject = unit.name,
                .module = .services,
                .risk = .high,
                .description = "Review running systemd service before starting on target",
            });
        }
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
