const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描 systemd service unit 及其启用状态。
pub fn scanUnits(io: std.Io, allocator: std.mem.Allocator) ![]schema.ServiceUnit {
    if (!probe.executableExists(io, allocator, "systemctl")) return allocator.alloc(schema.ServiceUnit, 0);

    const output = probe.runCommand(io, allocator, &.{ "systemctl", "list-unit-files", "--type=service", "--no-pager", "--plain", "--no-legend" }, 2 * 1024 * 1024) catch return allocator.alloc(schema.ServiceUnit, 0);
    defer allocator.free(output);

    const active_output = probe.runCommand(io, allocator, &.{ "systemctl", "list-units", "--type=service", "--all", "--no-pager", "--plain", "--no-legend" }, 2 * 1024 * 1024) catch null;
    defer if (active_output) |active| allocator.free(active);

    var units: std.ArrayList(schema.ServiceUnit) = .empty;
    errdefer {
        for (units.items) |unit| {
            allocator.free(unit.name);
            if (unit.path) |path| allocator.free(path);
        }
        units.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var columns = std.mem.tokenizeAny(u8, line, " \t");
        const name = columns.next() orelse continue;
        const state_text = columns.next() orelse "unknown";
        if (!std.mem.endsWith(u8, name, ".service")) continue;
        const unit_path = try std.fs.path.join(allocator, &.{ "/etc/systemd/system", name });
        defer allocator.free(unit_path);
        const custom = probe.pathExists(io, unit_path);

        try units.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .state = parseServiceState(state_text),
            .active_state = if (active_output) |active| findServiceActiveState(active, name) else .unknown,
            .custom = custom,
            .path = if (custom) try allocator.dupe(u8, unit_path) else null,
        });
    }

    return units.toOwnedSlice(allocator);
}

// 扫描 systemd timer 及其激活目标。
pub fn scanTimers(io: std.Io, allocator: std.mem.Allocator) ![]schema.SystemdTimer {
    if (!probe.executableExists(io, allocator, "systemctl")) return allocator.alloc(schema.SystemdTimer, 0);

    const files_output = probe.runCommand(io, allocator, &.{ "systemctl", "list-unit-files", "--type=timer", "--no-pager", "--plain", "--no-legend" }, 2 * 1024 * 1024) catch null;
    defer if (files_output) |output| allocator.free(output);

    const output = probe.runCommand(io, allocator, &.{ "systemctl", "list-timers", "--all", "--no-pager", "--plain", "--no-legend" }, 2 * 1024 * 1024) catch return allocator.alloc(schema.SystemdTimer, 0);
    defer allocator.free(output);

    var timers: std.ArrayList(schema.SystemdTimer) = .empty;
    errdefer {
        for (timers.items) |timer| {
            allocator.free(timer.name);
            allocator.free(timer.activates);
            allocator.free(timer.schedule);
        }
        timers.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const parsed = parseSystemdTimerLine(line) orelse continue;
        const timer_path = try std.fs.path.join(allocator, &.{ "/etc/systemd/system", parsed.name });
        defer allocator.free(timer_path);
        const custom = probe.pathExists(io, timer_path);
        try timers.append(allocator, .{
            .name = try allocator.dupe(u8, parsed.name),
            .state = if (files_output) |unit_files| findUnitFileState(unit_files, parsed.name) else .unknown,
            .activates = try allocator.dupe(u8, parsed.activates),
            .schedule = try allocator.dupe(u8, parsed.schedule),
            .custom = custom,
            .path = if (custom) try allocator.dupe(u8, timer_path) else null,
        });
    }

    return timers.toOwnedSlice(allocator);
}

// 扫描 systemd socket 及其激活目标。
pub fn scanSockets(io: std.Io, allocator: std.mem.Allocator) ![]schema.SystemdSocket {
    if (!probe.executableExists(io, allocator, "systemctl")) return allocator.alloc(schema.SystemdSocket, 0);

    const files_output = probe.runCommand(io, allocator, &.{ "systemctl", "list-unit-files", "--type=socket", "--no-pager", "--plain", "--no-legend" }, 2 * 1024 * 1024) catch return allocator.alloc(schema.SystemdSocket, 0);
    defer allocator.free(files_output);

    const sockets_output = probe.runCommand(io, allocator, &.{ "systemctl", "list-sockets", "--all", "--no-pager", "--plain", "--no-legend" }, 2 * 1024 * 1024) catch null;
    defer if (sockets_output) |output| allocator.free(output);

    var sockets: std.ArrayList(schema.SystemdSocket) = .empty;
    errdefer {
        for (sockets.items) |socket| {
            allocator.free(socket.name);
            if (socket.activates) |activates| allocator.free(activates);
            if (socket.path) |path| allocator.free(path);
        }
        sockets.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, files_output, '\n');
    while (lines.next()) |line| {
        var columns = std.mem.tokenizeAny(u8, line, " \t");
        const name = columns.next() orelse continue;
        const state_text = columns.next() orelse "unknown";
        if (!std.mem.endsWith(u8, name, ".socket")) continue;
        const socket_path = try std.fs.path.join(allocator, &.{ "/etc/systemd/system", name });
        defer allocator.free(socket_path);
        const custom = probe.pathExists(io, socket_path);
        const activates = if (sockets_output) |output| findSocketActivates(output, name) else null;
        try sockets.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .state = parseServiceState(state_text),
            .activates = if (activates) |value| try allocator.dupe(u8, value) else null,
            .custom = custom,
            .path = if (custom) try allocator.dupe(u8, socket_path) else null,
        });
    }

    return sockets.toOwnedSlice(allocator);
}

// 从 unit-files 输出中按名称查找 unit 的启用状态。
fn findUnitFileState(output: []const u8, name: []const u8) schema.ServiceState {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var columns = std.mem.tokenizeAny(u8, line, " \t");
        const unit_name = columns.next() orelse continue;
        const state_text = columns.next() orelse "unknown";
        if (std.mem.eql(u8, unit_name, name)) return parseServiceState(state_text);
    }
    return .unknown;
}

// 将 systemd unit-file 状态字符串解析为枚举值。
fn parseServiceState(value: []const u8) schema.ServiceState {
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "static")) return .static;
    if (std.mem.eql(u8, value, "masked")) return .masked;
    if (std.mem.eql(u8, value, "indirect")) return .indirect;
    if (std.mem.eql(u8, value, "generated")) return .generated;
    if (std.mem.eql(u8, value, "transient")) return .transient;
    return .unknown;
}

// 将 systemd 活跃状态字符串解析为枚举值。
fn parseServiceActiveState(value: []const u8) schema.ServiceActiveState {
    if (std.mem.eql(u8, value, "active")) return .active;
    if (std.mem.eql(u8, value, "reloading")) return .reloading;
    if (std.mem.eql(u8, value, "inactive")) return .inactive;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "activating")) return .activating;
    if (std.mem.eql(u8, value, "deactivating")) return .deactivating;
    if (std.mem.eql(u8, value, "maintenance")) return .maintenance;
    return .unknown;
}

// 从 list-units 输出中按名称查找 service 的活跃状态。
fn findServiceActiveState(output: []const u8, name: []const u8) schema.ServiceActiveState {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const parsed = parseServiceRuntimeLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.name, name)) return parsed.active_state;
    }
    return .unknown;
}

// systemd service 运行时行解析结果，含名称和活跃状态。
const ServiceRuntimeLine = struct {
    name: []const u8,
    active_state: schema.ServiceActiveState,
};

// 解析 systemctl list-units 单行，提取 service 名称和活跃状态。
fn parseServiceRuntimeLine(line: []const u8) ?ServiceRuntimeLine {
    var columns = std.mem.tokenizeAny(u8, line, " \t");
    var name = columns.next() orelse return null;
    if (!std.mem.endsWith(u8, name, ".service")) {
        name = columns.next() orelse return null;
    }
    if (!std.mem.endsWith(u8, name, ".service")) return null;
    _ = columns.next() orelse return null;
    const active_text = columns.next() orelse return null;
    return .{ .name = name, .active_state = parseServiceActiveState(active_text) };
}

// systemd timer 行解析结果，含名称、激活目标和调度表达式。
const TimerLine = struct {
    name: []const u8,
    activates: []const u8,
    schedule: []const u8,
};

// 解析 systemctl list-timers 单行，提取 timer 名称、激活 unit 和调度。
fn parseSystemdTimerLine(line: []const u8) ?TimerLine {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const activates_start = lastTokenStart(trimmed) orelse return null;
    const activates = trimmed[activates_start..];
    const before_activates = std.mem.trimEnd(u8, trimmed[0..activates_start], " \t");
    const name_start = lastTokenStart(before_activates) orelse return null;
    const name = before_activates[name_start..];
    if (!std.mem.endsWith(u8, name, ".timer")) return null;
    const schedule = std.mem.trim(u8, before_activates[0..name_start], " \t");
    if (schedule.len == 0) return null;
    return .{ .name = name, .activates = activates, .schedule = schedule };
}

// 从 list-sockets 输出中按名称查找 socket 激活的 unit。
fn findSocketActivates(output: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const parsed = parseSystemdSocketLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.name, name)) return parsed.activates;
    }
    return null;
}

// systemd socket 行解析结果，含名称和激活目标。
const SocketLine = struct {
    name: []const u8,
    activates: []const u8,
};

// 解析 systemctl list-sockets 单行，提取 socket 名称和激活 unit。
fn parseSystemdSocketLine(line: []const u8) ?SocketLine {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const activates_start = lastTokenStart(trimmed) orelse return null;
    const activates = trimmed[activates_start..];
    const before_activates = std.mem.trimEnd(u8, trimmed[0..activates_start], " \t");
    const name_start = lastTokenStart(before_activates) orelse return null;
    const name = before_activates[name_start..];
    if (!std.mem.endsWith(u8, name, ".socket")) return null;
    return .{ .name = name, .activates = activates };
}

// 查找字符串中最后一个空白分隔 token 的起始位置。
fn lastTokenStart(value: []const u8) ?usize {
    if (value.len == 0) return null;
    var index = value.len;
    while (index > 0) {
        if (std.ascii.isWhitespace(value[index - 1])) break;
        index -= 1;
    }
    if (index == value.len) return null;
    return index;
}

test "service state parser maps common systemd states" {
    try std.testing.expectEqual(schema.ServiceState.enabled, parseServiceState("enabled"));
    try std.testing.expectEqual(schema.ServiceState.disabled, parseServiceState("disabled"));
    try std.testing.expectEqual(schema.ServiceState.static, parseServiceState("static"));
    try std.testing.expectEqual(schema.ServiceState.masked, parseServiceState("masked"));
    try std.testing.expectEqual(schema.ServiceState.unknown, parseServiceState("bad"));
}

test "service active state parser maps common systemd runtime states" {
    try std.testing.expectEqual(schema.ServiceActiveState.active, parseServiceActiveState("active"));
    try std.testing.expectEqual(schema.ServiceActiveState.inactive, parseServiceActiveState("inactive"));
    try std.testing.expectEqual(schema.ServiceActiveState.failed, parseServiceActiveState("failed"));
    try std.testing.expectEqual(schema.ServiceActiveState.unknown, parseServiceActiveState("weird"));
}

test "service active state lookup returns runtime state" {
    const output =
        \\nginx.service loaded active running A high performance web server
        \\ssh.service loaded inactive dead OpenBSD Secure Shell server
        \\broken.service loaded failed failed Broken service
    ;

    try std.testing.expectEqual(schema.ServiceActiveState.active, findServiceActiveState(output, "nginx.service"));
    try std.testing.expectEqual(schema.ServiceActiveState.inactive, findServiceActiveState(output, "ssh.service"));
    try std.testing.expectEqual(schema.ServiceActiveState.failed, findServiceActiveState(output, "broken.service"));
    try std.testing.expectEqual(schema.ServiceActiveState.unknown, findServiceActiveState(output, "missing.service"));
}

test "unit file state lookup returns timer state" {
    const output =
        \\backup.timer enabled
        \\apt-daily.timer static
    ;
    try std.testing.expectEqual(schema.ServiceState.enabled, findUnitFileState(output, "backup.timer"));
    try std.testing.expectEqual(schema.ServiceState.static, findUnitFileState(output, "apt-daily.timer"));
    try std.testing.expectEqual(schema.ServiceState.unknown, findUnitFileState(output, "missing.timer"));
}

test "systemd timer parser keeps schedule and activated unit" {
    const parsed = parseSystemdTimerLine("Mon 2026-06-15 00:00:00 UTC 2 days left Sun 2026-06-07 00:00:00 UTC 4 days ago logrotate.timer logrotate.service").?;

    try std.testing.expectEqualStrings("logrotate.timer", parsed.name);
    try std.testing.expectEqualStrings("logrotate.service", parsed.activates);
    try std.testing.expect(std.mem.indexOf(u8, parsed.schedule, "2 days left") != null);
}

test "systemd timer parser ignores non timer lines" {
    try std.testing.expect(parseSystemdTimerLine("bad.service bad.service") == null);
    try std.testing.expect(parseSystemdTimerLine("") == null);
}

test "systemd socket parser keeps socket and activated unit" {
    const parsed = parseSystemdSocketLine("[::]:22 ssh.socket ssh.service").?;

    try std.testing.expectEqualStrings("ssh.socket", parsed.name);
    try std.testing.expectEqualStrings("ssh.service", parsed.activates);
}

test "systemd socket parser ignores non socket lines" {
    try std.testing.expect(parseSystemdSocketLine("n/a ssh.service ssh.service") == null);
    try std.testing.expect(parseSystemdSocketLine("") == null);
}
