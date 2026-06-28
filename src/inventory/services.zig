const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const startup = @import("services_startup.zig");
const systemd = @import("services_systemd.zig");

// 扫描服务和启动项事实，只记录元数据，不决定是否迁移。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.ServiceInventory {
    const units = try systemd.scanUnits(io, allocator);
    errdefer freeUnits(allocator, units);
    const drop_ins = try scanSystemdDropIns(io, allocator);
    errdefer freeDropIns(allocator, drop_ins);
    const env_files = try scanServiceEnvFiles(io, allocator, units, drop_ins);
    errdefer freeEnvFiles(allocator, env_files);

    return .{
        .init_system = try allocator.dupe(u8, detectInitSystem(io)),
        .units = units,
        .drop_ins = drop_ins,
        .env_files = env_files,
        .timers = try systemd.scanTimers(io, allocator),
        .sockets = try systemd.scanSockets(io, allocator),
        .user_units = try startup.scanUserSystemdUnits(io, allocator),
        .xdg_autostart = try startup.scanXdgAutostart(io, allocator),
        .sysv_init = try startup.scanSysvInitScripts(io, allocator),
        .openrc = try startup.scanOpenRcServices(io, allocator),
    };
}

// 通过检查路径探测当前 init 系统类型。
fn detectInitSystem(io: std.Io) []const u8 {
    if (probe.pathExists(io, "/run/systemd/system")) return "systemd";
    if (probe.pathExists(io, "/etc/runlevels")) return "openrc";
    if (probe.pathExists(io, "/etc/init.d")) return "sysvinit";
    return "unknown";
}

// 扫描 /etc/systemd/system 下的 drop-in 配置片段。
fn scanSystemdDropIns(io: std.Io, allocator: std.mem.Allocator) ![]schema.SystemdDropIn {
    var result: std.ArrayList(schema.SystemdDropIn) = .empty;
    errdefer freeDropIns(allocator, result.items);

    var dir = std.Io.Dir.openDirAbsolute(io, "/etc/systemd/system", .{ .iterate = true }) catch return allocator.alloc(schema.SystemdDropIn, 0);
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".d")) continue;
        const unit = entry.name[0 .. entry.name.len - ".d".len];
        const dropin_dir = try std.fs.path.join(allocator, &.{ "/etc/systemd/system", entry.name });
        defer allocator.free(dropin_dir);
        try appendDropInDir(io, allocator, &result, unit, dropin_dir);
    }

    return result.toOwnedSlice(allocator);
}

// 扫描单个 systemd drop-in 目录。
fn appendDropInDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    result: *std.ArrayList(schema.SystemdDropIn),
    unit: []const u8,
    path: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try result.append(allocator, .{
            .unit = try allocator.dupe(u8, unit),
            .path = try allocator.dupe(u8, child_path),
            .size = probe.fileSize(io, child_path) orelse 0,
            .meaningful_lines = countMeaningfulLinesInFile(io, allocator, child_path),
        });
    }
}

// 扫描服务关联的环境文件，只记录路径和摘要。
fn scanServiceEnvFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    units: []const schema.ServiceUnit,
    drop_ins: []const schema.SystemdDropIn,
) ![]schema.ServiceEnvFile {
    var result: std.ArrayList(schema.ServiceEnvFile) = .empty;
    errdefer freeEnvFiles(allocator, result.items);

    for (units) |unit| {
        const stem = serviceStem(unit.name);
        try appendEnvCandidate(io, allocator, &result, unit.name, "/etc/default", stem);
        try appendEnvCandidate(io, allocator, &result, unit.name, "/etc/sysconfig", stem);
    }
    for (drop_ins) |drop_in| {
        try appendEnvironmentFilesFromUnitText(io, allocator, &result, drop_in.unit, drop_in.path);
    }

    return result.toOwnedSlice(allocator);
}

// 追加 /etc/default 或 /etc/sysconfig 下的服务环境文件。
fn appendEnvCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    result: *std.ArrayList(schema.ServiceEnvFile),
    unit: []const u8,
    dir: []const u8,
    basename: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(path);
    try appendEnvFile(io, allocator, result, unit, path);
}

// 从 unit/drop-in 文本中提取 EnvironmentFile= 引用。
fn appendEnvironmentFilesFromUnitText(
    io: std.Io,
    allocator: std.mem.Allocator,
    result: *std.ArrayList(schema.ServiceEnvFile),
    unit: []const u8,
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimUnitLine(raw_line);
        if (!std.mem.startsWith(u8, line, "EnvironmentFile=")) continue;
        const values = line["EnvironmentFile=".len..];
        var tokens = std.mem.tokenizeAny(u8, values, " \t");
        while (tokens.next()) |token| {
            const env_path = trimEnvFileToken(token);
            if (env_path.len == 0 or env_path[0] != '/') continue;
            try appendEnvFile(io, allocator, result, unit, env_path);
        }
    }
}

// 追加一个存在的服务环境文件。
fn appendEnvFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    result: *std.ArrayList(schema.ServiceEnvFile),
    unit: []const u8,
    path: []const u8,
) !void {
    const maybe_size = probe.fileSize(io, path) orelse return;
    if (containsEnvFile(result.items, unit, path)) return;
    try result.append(allocator, .{
        .unit = try allocator.dupe(u8, unit),
        .path = try allocator.dupe(u8, path),
        .size = maybe_size,
        .meaningful_lines = countMeaningfulLinesInFile(io, allocator, path),
    });
}

// 返回 service unit 去掉 .service 后的名称。
fn serviceStem(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".service")) name[0 .. name.len - ".service".len] else name;
}

// 去除 unit 行注释和空白。
fn trimUnitLine(raw_line: []const u8) []const u8 {
    const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |idx| raw_line[0..idx] else raw_line;
    return std.mem.trim(u8, without_comment, " \t\r\n");
}

// 规范化 EnvironmentFile token，处理可选 - 前缀和引号。
fn trimEnvFileToken(token: []const u8) []const u8 {
    var value = std.mem.trim(u8, token, " \t\r\n");
    if (value.len > 0 and value[0] == '-') value = value[1..];
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        value = value[1 .. value.len - 1];
    }
    return value;
}

// 判断服务环境文件是否已记录。
fn containsEnvFile(files: []const schema.ServiceEnvFile, unit: []const u8, path: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file.unit, unit) and std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}

// 读取文件并统计有效行数；读取失败返回 0。
fn countMeaningfulLinesInFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) u32 {
    const contents = probe.readWholeFile(io, allocator, path) catch return 0;
    defer allocator.free(contents);
    return probe.countMeaningfulLines(contents);
}

// 释放 systemd service unit 列表。
fn freeUnits(allocator: std.mem.Allocator, units: []schema.ServiceUnit) void {
    for (units) |unit| {
        allocator.free(unit.name);
        if (unit.path) |path| allocator.free(path);
        if (unit.dependency_summary) |summary| allocator.free(summary);
    }
    allocator.free(units);
}

// 释放 systemd drop-in 列表。
fn freeDropIns(allocator: std.mem.Allocator, drop_ins: []schema.SystemdDropIn) void {
    for (drop_ins) |drop_in| {
        allocator.free(drop_in.unit);
        allocator.free(drop_in.path);
    }
    allocator.free(drop_ins);
}

// 释放服务环境文件列表。
fn freeEnvFiles(allocator: std.mem.Allocator, files: []schema.ServiceEnvFile) void {
    for (files) |file| {
        allocator.free(file.unit);
        allocator.free(file.path);
    }
    allocator.free(files);
}

test "init system detector falls back to unknown in test environment" {
    _ = detectInitSystem(std.testing.io);
}

test "service helper parses environment file token" {
    try std.testing.expectEqualStrings("/etc/default/nginx", trimEnvFileToken("-/etc/default/nginx"));
    try std.testing.expectEqualStrings("/etc/sysconfig/app", trimEnvFileToken("\"/etc/sysconfig/app\""));
    try std.testing.expectEqualStrings("nginx", serviceStem("nginx.service"));
}
