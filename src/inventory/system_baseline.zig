const std = @import("std");
const home_user = @import("home_user.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

const max_hosts_entries = 256;
const max_script_apps = 512;
const redacted_system_env_value = "[REDACTED]";

// 扫描系统基线事实；只记录元数据和安装痕迹，不复制高风险系统配置正文。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.SystemBaselineInventory {
    const paths = try scanPaths(io, allocator);
    errdefer freePaths(allocator, paths);

    const commands = try scanCommands(io, allocator);
    errdefer freeCommands(allocator, commands);

    const config_facts = try scanConfigFacts(io, allocator);
    errdefer freeConfigFacts(allocator, config_facts);

    const hosts_entries = try parseHostsFile(io, allocator, "/etc/hosts");
    errdefer freeHostsEntries(allocator, hosts_entries);

    var truncated = false;
    const script_apps = try scanScriptInstalledApps(io, allocator, &truncated);
    errdefer freeScriptApps(allocator, script_apps);

    const at_count = countCommandLines(commands, "atq");
    return .{
        .paths = paths,
        .commands = commands,
        .config_facts = config_facts,
        .hosts_entries = hosts_entries,
        .script_apps = script_apps,
        .at_jobs_present = at_count > 0,
        .at_jobs_count = at_count,
        .truncated = truncated,
    };
}

// 释放系统基线清单中的分配字段。
pub fn freeInventory(allocator: std.mem.Allocator, baseline: schema.SystemBaselineInventory) void {
    freePaths(allocator, baseline.paths);
    freeCommands(allocator, baseline.commands);
    freeConfigFacts(allocator, baseline.config_facts);
    freeHostsEntries(allocator, baseline.hosts_entries);
    freeScriptApps(allocator, baseline.script_apps);
}

// 解析 hosts 文本，跳过空行和注释。
pub fn parseHosts(allocator: std.mem.Allocator, contents: []const u8) ![]schema.HostsEntry {
    var entries: std.ArrayList(schema.HostsEntry) = .empty;
    errdefer freeHostsEntries(allocator, entries.items);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        if (entries.items.len >= max_hosts_entries) break;
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |idx| raw_line[0..idx] else raw_line;
        const line = std.mem.trim(u8, without_comment, " \t\r\n");
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const address = fields.next() orelse continue;
        const names_start = std.mem.indexOf(u8, line, address).? + address.len;
        const names = std.mem.trim(u8, line[names_start..], " \t\r\n");
        if (names.len == 0) continue;

        try entries.append(allocator, .{
            .address = try allocator.dupe(u8, address),
            .names = try allocator.dupe(u8, names),
        });
    }

    return entries.toOwnedSlice(allocator);
}

// 扫描系统基线路径存在性和元数据。
fn scanPaths(io: std.Io, allocator: std.mem.Allocator) ![]schema.SystemPathFact {
    const candidates = [_]struct {
        path: []const u8,
        kind: schema.SystemPathKind,
    }{
        .{ .path = "/etc/locale.conf", .kind = .locale },
        .{ .path = "/etc/default/locale", .kind = .locale },
        .{ .path = "/etc/timezone", .kind = .timezone },
        .{ .path = "/etc/localtime", .kind = .timezone },
        .{ .path = "/etc/crypttab", .kind = .storage },
        .{ .path = "/etc/exports", .kind = .remote_mount },
        .{ .path = "/etc/auto.master", .kind = .remote_mount },
        .{ .path = "/etc/auto.master.d", .kind = .remote_mount },
        .{ .path = "/etc/modules", .kind = .kernel_module },
        .{ .path = "/etc/modules-load.d", .kind = .kernel_module },
        .{ .path = "/etc/modprobe.d", .kind = .kernel_module },
        .{ .path = "/etc/security/limits.conf", .kind = .limits },
        .{ .path = "/etc/security/limits.d", .kind = .limits },
        .{ .path = "/etc/pam.d", .kind = .pam },
        .{ .path = "/etc/chrony.conf", .kind = .ntp },
        .{ .path = "/etc/chrony", .kind = .ntp },
        .{ .path = "/etc/ntp.conf", .kind = .ntp },
        .{ .path = "/etc/systemd/timesyncd.conf", .kind = .ntp },
        .{ .path = "/etc/sysctl.conf", .kind = .sysctl },
        .{ .path = "/etc/sysctl.d", .kind = .sysctl },
        .{ .path = "/etc/sssd/sssd.conf", .kind = .identity },
        .{ .path = "/etc/ldap", .kind = .identity },
        .{ .path = "/etc/openldap", .kind = .identity },
        .{ .path = "/etc/krb5.conf", .kind = .identity },
        .{ .path = "/etc/logrotate.conf", .kind = .logrotate },
        .{ .path = "/etc/logrotate.d", .kind = .logrotate },
        .{ .path = "/etc/environment", .kind = .system_env },
        .{ .path = "/etc/profile", .kind = .system_env },
        .{ .path = "/etc/profile.d", .kind = .profile },
        .{ .path = "/etc/tmpfiles.d", .kind = .tmpfiles },
        .{ .path = "/etc/resolv.conf", .kind = .dns },
        .{ .path = "/etc/nsswitch.conf", .kind = .nss },
        .{ .path = "/etc/netplan", .kind = .network },
        .{ .path = "/etc/network/interfaces", .kind = .network },
        .{ .path = "/etc/network/interfaces.d", .kind = .network },
        .{ .path = "/etc/NetworkManager/system-connections", .kind = .network },
        .{ .path = "/etc/systemd/network", .kind = .network },
        .{ .path = "/etc/letsencrypt", .kind = .security },
        .{ .path = "/etc/ssl", .kind = .security },
        .{ .path = "/etc/caddy", .kind = .security },
        .{ .path = "/etc/nginx", .kind = .security },
        .{ .path = "/etc/traefik", .kind = .security },
    };

    var facts: std.ArrayList(schema.SystemPathFact) = .empty;
    errdefer freePaths(allocator, facts.items);

    for (candidates) |candidate| {
        try appendPathFact(io, allocator, &facts, candidate.path, candidate.kind);
    }
    try appendUserSensitivePathFacts(io, allocator, &facts);
    try appendUserRuntimePathFacts(io, allocator, &facts);

    return facts.toOwnedSlice(allocator);
}

// 记录单个系统路径的存在性、是否为目录、大小和有效行数。
fn appendPathFact(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemPathFact),
    path: []const u8,
    kind: schema.SystemPathKind,
) !void {
    const present = probe.pathExists(io, path);
    const directory = present and probe.pathIsDirectory(io, path);
    const size = if (present and !directory) probe.fileSize(io, path) orelse 0 else 0;
    const line_count = if (present and !directory) countMeaningfulLinesInFile(io, allocator, path) else 0;
    try facts.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .present = present,
        .directory = directory,
        .kind = kind,
        .size = size,
        .meaningful_lines = line_count,
    });
}

// 扫描系统命令可用性和输出行数。
fn scanCommands(io: std.Io, allocator: std.mem.Allocator) ![]schema.CommandFact {
    const candidates = [_]struct {
        name: []const u8,
        executable: []const u8,
        argv: []const []const u8,
    }{
        .{ .name = "timedatectl", .executable = "timedatectl", .argv = &.{ "timedatectl", "show" } },
        .{ .name = "locale", .executable = "locale", .argv = &.{"locale"} },
        .{ .name = "lsmod", .executable = "lsmod", .argv = &.{"lsmod"} },
        .{ .name = "vgs", .executable = "vgs", .argv = &.{ "vgs", "--noheadings" } },
        .{ .name = "lvs", .executable = "lvs", .argv = &.{ "lvs", "--noheadings" } },
        .{ .name = "zpool", .executable = "zpool", .argv = &.{ "zpool", "list", "-H" } },
        .{ .name = "zfs", .executable = "zfs", .argv = &.{ "zfs", "list", "-H" } },
        .{ .name = "btrfs", .executable = "btrfs", .argv = &.{ "btrfs", "filesystem", "show" } },
        .{ .name = "ip-address", .executable = "ip", .argv = &.{ "ip", "-brief", "address" } },
        .{ .name = "ip-route", .executable = "ip", .argv = &.{ "ip", "route" } },
        .{ .name = "ip-route6", .executable = "ip", .argv = &.{ "ip", "-6", "route" } },
        .{ .name = "nmcli-connections", .executable = "nmcli", .argv = &.{ "nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show" } },
        .{ .name = "networkctl", .executable = "networkctl", .argv = &.{ "networkctl", "list", "--no-pager", "--no-legend" } },
        .{ .name = "atq", .executable = "atq", .argv = &.{"atq"} },
    };

    var facts: std.ArrayList(schema.CommandFact) = .empty;
    errdefer freeCommands(allocator, facts.items);

    for (candidates) |candidate| {
        const present = probe.executableExists(io, allocator, candidate.executable);
        const lines = if (present) commandLineCount(io, allocator, candidate.argv) else 0;
        try facts.append(allocator, .{
            .name = try allocator.dupe(u8, candidate.name),
            .present = present,
            .line_count = lines,
        });
    }

    return facts.toOwnedSlice(allocator);
}

// 扫描用户 home 目录下脚本安装的通用痕迹，基于路径和旁路证据而不是应用名硬编码。
fn scanScriptInstalledApps(io: std.Io, allocator: std.mem.Allocator, truncated: *bool) ![]schema.ScriptInstallCandidate {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    var apps: std.ArrayList(schema.ScriptInstallCandidate) = .empty;
    errdefer freeScriptApps(allocator, apps.items);

    for (users) |user| {
        if (!home_user.shouldScanHome(user)) continue;
        try appendScriptMarkersForUser(io, allocator, &apps, user.home, truncated);
        if (truncated.*) break;
    }

    return apps.toOwnedSlice(allocator);
}

// 扫描系统配置文件的实际键值对（locale、sysctl、limits、NTP、DNS、NSS、NFS、存储）。
fn scanConfigFacts(io: std.Io, allocator: std.mem.Allocator) ![]schema.SystemConfigFact {
    var facts: std.ArrayList(schema.SystemConfigFact) = .empty;
    errdefer freeConfigFacts(allocator, facts.items);

    try appendKeyValueFile(io, allocator, &facts, "/etc/locale.conf", .locale);
    try appendKeyValueFile(io, allocator, &facts, "/etc/default/locale", .locale);
    try appendSingleValueFile(io, allocator, &facts, "/etc/timezone", .timezone, "timezone");
    try appendKeyValueFile(io, allocator, &facts, "/etc/sysctl.conf", .sysctl);
    try appendDirectoryKeyValueFiles(io, allocator, &facts, "/etc/sysctl.d", .sysctl);
    try appendLimitsFile(io, allocator, &facts, "/etc/security/limits.conf");
    try appendDirectoryLimitsFiles(io, allocator, &facts, "/etc/security/limits.d");
    try appendNtpFile(io, allocator, &facts, "/etc/chrony.conf");
    try appendNtpDirectory(io, allocator, &facts, "/etc/chrony");
    try appendNtpFile(io, allocator, &facts, "/etc/ntp.conf");
    try appendKeyValueFile(io, allocator, &facts, "/etc/systemd/timesyncd.conf", .ntp);
    try appendResolverFacts(io, allocator, &facts, "/etc/resolv.conf");
    try appendNsswitchFacts(io, allocator, &facts, "/etc/nsswitch.conf");
    try appendExportsFacts(io, allocator, &facts, "/etc/exports");
    try appendKeyValueFile(io, allocator, &facts, "/etc/environment", .system_env);
    try appendShellEnvFile(io, allocator, &facts, "/etc/profile");
    try appendShellEnvDirectory(io, allocator, &facts, "/etc/profile.d");
    try appendCommandFacts(io, allocator, &facts, .network, "ip_address", &.{ "ip", "-brief", "address" });
    try appendCommandFacts(io, allocator, &facts, .network, "ip_route", &.{ "ip", "route" });
    try appendCommandFacts(io, allocator, &facts, .network, "ip_route6", &.{ "ip", "-6", "route" });
    try appendCommandFacts(io, allocator, &facts, .network, "nmcli_connections", &.{ "nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show" });
    try appendCommandFacts(io, allocator, &facts, .network, "networkctl", &.{ "networkctl", "list", "--no-pager", "--no-legend" });
    try appendCommandFacts(io, allocator, &facts, .storage, "lvm_vgs", &.{ "vgs", "--noheadings", "-o", "vg_name,vg_size,vg_free" });
    try appendCommandFacts(io, allocator, &facts, .storage, "lvm_lvs", &.{ "lvs", "--noheadings", "-o", "lv_name,vg_name,lv_size,origin" });
    try appendCommandFacts(io, allocator, &facts, .storage, "zpool", &.{ "zpool", "list", "-H", "-o", "name,size,free,health" });
    try appendCommandFacts(io, allocator, &facts, .storage, "zfs", &.{ "zfs", "list", "-H", "-o", "name,used,avail,mountpoint" });
    try appendCommandFacts(io, allocator, &facts, .storage, "btrfs", &.{ "btrfs", "filesystem", "show" });

    return facts.toOwnedSlice(allocator);
}

// 解析 shell/profile 文件中的 export 或 key=value 环境变量。
fn appendShellEnvFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        var line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line["export ".len..], " \t");
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        if (!looksLikeEnvKey(key)) continue;
        const value = trimQuotes(std.mem.trim(u8, line[separator + 1 ..], " \t"));
        if (value.len == 0) continue;
        try appendConfigFact(allocator, facts, .system_env, path, key, value);
    }
}

// 遍历 profile.d 目录下的 shell 环境脚本。
fn appendShellEnvDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendShellEnvFile(io, allocator, facts, child_path);
    }
}

// 读取 key=value 格式的配置文件，按行解析为配置事实。
fn appendKeyValueFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
    kind: schema.SystemPathKind,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = trimQuotes(std.mem.trim(u8, line[separator + 1 ..], " \t"));
        if (key.len == 0 or value.len == 0) continue;
        try appendConfigFact(allocator, facts, kind, path, key, value);
    }
}

// 读取单值配置文件（如 /etc/timezone）。
fn appendSingleValueFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
    kind: schema.SystemPathKind,
    key: []const u8,
) !void {
    const value = probe.readTrimmedFile(io, allocator, path) catch return;
    defer allocator.free(value);
    if (value.len == 0) return;
    try appendConfigFact(allocator, facts, kind, path, key, value);
}

// 遍历目录下的 key=value 配置文件（如 /etc/sysctl.d/*.conf）。
fn appendDirectoryKeyValueFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
    kind: schema.SystemPathKind,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendKeyValueFile(io, allocator, facts, child_path, kind);
    }
}

// 解析 limits.conf 中的 domain.type.item=value 条目。
fn appendLimitsFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const domain = fields.next() orelse continue;
        const limit_type = fields.next() orelse continue;
        const item = fields.next() orelse continue;
        const value = fields.next() orelse continue;
        const key = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ domain, limit_type, item });
        defer allocator.free(key);
        try appendConfigFact(allocator, facts, .limits, path, key, value);
    }
}

// 遍历 limits.d 目录下的配置片段。
fn appendDirectoryLimitsFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendLimitsFile(io, allocator, facts, child_path);
    }
}

// 解析 NTP 配置中的 server/pool 指令。
fn appendNtpFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const directive = fields.next() orelse continue;
        if (!std.mem.eql(u8, directive, "server") and !std.mem.eql(u8, directive, "pool")) continue;
        const value = fields.next() orelse continue;
        try appendConfigFact(allocator, facts, .ntp, path, directive, value);
    }
}

// 遍历 NTP 配置目录（如 /etc/chrony/*.conf）。
fn appendNtpDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        try appendNtpFile(io, allocator, facts, child_path);
    }
}

// 解析 /etc/resolv.conf 中的 nameserver/search/domain/options。
fn appendResolverFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key = fields.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver") and !std.mem.eql(u8, key, "search") and !std.mem.eql(u8, key, "domain") and !std.mem.eql(u8, key, "options")) continue;
        const value_start = std.mem.indexOf(u8, line, key).? + key.len;
        const value = std.mem.trim(u8, line[value_start..], " \t");
        if (value.len == 0) continue;
        try appendConfigFact(allocator, facts, .dns, path, key, value);
    }
}

// 解析 /etc/nsswitch.conf 中的数据库查找链。
fn appendNsswitchFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) continue;
        try appendConfigFact(allocator, facts, .nss, path, key, value);
    }
}

// 解析 /etc/exports 中的 NFS 导出路径和客户端列表。
fn appendExportsFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    path: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimConfigLine(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const export_path = fields.next() orelse continue;
        const clients_start = std.mem.indexOf(u8, line, export_path).? + export_path.len;
        const clients = std.mem.trim(u8, line[clients_start..], " \t");
        if (clients.len == 0) continue;
        try appendConfigFact(allocator, facts, .remote_mount, path, export_path, clients);
    }
}

// 执行命令并将每行输出记录为配置事实。
fn appendCommandFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    kind: schema.SystemPathKind,
    key_prefix: []const u8,
    argv: []const []const u8,
) !void {
    const lines = probe.runLines(io, allocator, argv, 512 * 1024) catch return;
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    for (lines, 0..) |line, index| {
        const key = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ key_prefix, index + 1 });
        defer allocator.free(key);
        try appendConfigFact(allocator, facts, kind, key_prefix, key, line);
    }
}

// 追加一条配置事实记录。
fn appendConfigFact(
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemConfigFact),
    kind: schema.SystemPathKind,
    source: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const stored_value = if (kind == .system_env and shouldRedactSystemEnv(key, value))
        redacted_system_env_value
    else
        value;
    try facts.append(allocator, .{
        .kind = kind,
        .source = try allocator.dupe(u8, source),
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, stored_value),
    });
}

fn shouldRedactSystemEnv(key: []const u8, value: []const u8) bool {
    return isSensitiveEnvKey(key) or containsCredentialUrl(value);
}

fn isSensitiveEnvKey(key: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, key, "_-. ");
    while (tokens.next()) |token| {
        if (isSensitiveEnvKeyToken(token)) return true;
    }
    return false;
}

fn isSensitiveEnvKeyToken(token: []const u8) bool {
    const sensitive_tokens = [_][]const u8{
        "PASSWORD",
        "PASSWD",
        "PASS",
        "PASSPHRASE",
        "TOKEN",
        "SECRET",
        "CREDENTIAL",
        "CREDENTIALS",
        "AUTHORIZATION",
        "KEY",
        "APIKEY",
        "ACCESSKEY",
        "PRIVATEKEY",
        "SECRETKEY",
    };
    for (sensitive_tokens) |candidate| {
        if (std.ascii.eqlIgnoreCase(token, candidate)) return true;
    }
    return false;
}

fn containsCredentialUrl(value: []const u8) bool {
    var search_start: usize = 0;
    while (search_start < value.len) {
        const scheme_offset = std.mem.indexOf(u8, value[search_start..], "://") orelse return false;
        const authority_start = search_start + scheme_offset + 3;
        var authority_end = authority_start;
        while (authority_end < value.len) : (authority_end += 1) {
            switch (value[authority_end]) {
                '/', '?', '#', ' ', '\t', '\r', '\n' => break,
                else => {},
            }
        }
        const authority = value[authority_start..authority_end];
        if (std.mem.indexOfScalar(u8, authority, '@')) |at| {
            if (at > 0) return true;
        }
        search_start = if (authority_end > authority_start) authority_end else authority_start;
    }
    return false;
}

// 扫描用户 home 下的敏感路径（GnuPG、SSH 私钥）。
fn appendUserSensitivePathFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemPathFact),
) !void {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    const markers = [_][]const u8{
        ".gnupg",
        ".ssh/id_rsa",
        ".ssh/id_ed25519",
        ".ssh/id_ecdsa",
        ".ssh/id_dsa",
    };

    for (users) |user| {
        if (!home_user.shouldScanHome(user)) continue;
        for (markers) |marker| {
            const path = try std.fs.path.join(allocator, &.{ user.home, marker });
            defer allocator.free(path);
            if (!probe.pathExists(io, path)) continue;
            try appendPathFact(io, allocator, facts, path, .security);
        }
    }
}

// 扫描用户级语言运行时和包管理器状态目录；只记录目录事实，不默认复制 cache。
fn appendUserRuntimePathFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(schema.SystemPathFact),
) !void {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    const markers = [_][]const u8{
        ".nvm",
        ".pyenv",
        ".conda",
        ".local/share/pipx",
        ".local/share/uv",
        ".local/share/pnpm",
        ".npm-global",
        ".rustup",
        ".cargo",
        "go",
    };

    for (users) |user| {
        if (!home_user.shouldScanHome(user)) continue;
        for (markers) |marker| {
            const path = try std.fs.path.join(allocator, &.{ user.home, marker });
            defer allocator.free(path);
            if (!probe.pathExists(io, path)) continue;
            try appendPathFact(io, allocator, facts, path, .runtime_env);
        }
    }
}

// 扫描单个用户 home 下的脚本安装应用标记。
fn appendScriptMarkersForUser(
    io: std.Io,
    allocator: std.mem.Allocator,
    apps: *std.ArrayList(schema.ScriptInstallCandidate),
    home: []const u8,
    truncated: *bool,
) !void {
    const runtime_markers = [_]struct {
        relative_path: []const u8,
        kind: schema.ScriptInstallKind,
    }{
        .{ .relative_path = ".nvm", .kind = .runtime_manager },
        .{ .relative_path = ".pyenv", .kind = .runtime_manager },
        .{ .relative_path = ".conda", .kind = .runtime_manager },
        .{ .relative_path = ".rustup", .kind = .runtime_manager },
        .{ .relative_path = ".cargo", .kind = .runtime_manager },
        .{ .relative_path = ".local/share/pipx", .kind = .runtime_manager },
        .{ .relative_path = ".local/share/uv", .kind = .runtime_manager },
        .{ .relative_path = ".local/share/pnpm", .kind = .runtime_manager },
        .{ .relative_path = ".npm-global", .kind = .runtime_manager },
        .{ .relative_path = ".linuxbrew", .kind = .package_manager },
        .{ .relative_path = "go", .kind = .runtime_manager },
    };

    for (runtime_markers) |marker| {
        if (apps.items.len >= max_script_apps) {
            truncated.* = true;
            return;
        }
        const path = try std.fs.path.join(allocator, &.{ home, marker.relative_path });
        defer allocator.free(path);
        try appendScriptCandidate(io, allocator, apps, home, path, marker.kind, "known user runtime/package-manager state path");
    }

    const bin_dirs = [_][]const u8{
        ".local/bin",
        ".cargo/bin",
        ".deno/bin",
        ".bun/bin",
        ".npm-global/bin",
        "go/bin",
    };
    for (bin_dirs) |relative_dir| {
        if (apps.items.len >= max_script_apps) {
            truncated.* = true;
            return;
        }
        const dir_path = try std.fs.path.join(allocator, &.{ home, relative_dir });
        defer allocator.free(dir_path);
        try appendUserBinCandidates(io, allocator, apps, home, dir_path, truncated);
        if (truncated.*) return;
    }
}

// 扫描用户级 bin 目录中的未托管可执行文件候选。
fn appendUserBinCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    apps: *std.ArrayList(schema.ScriptInstallCandidate),
    home: []const u8,
    dir_path: []const u8,
    truncated: *bool,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (apps.items.len >= max_script_apps) {
            truncated.* = true;
            return;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        try appendScriptCandidate(io, allocator, apps, home, path, .user_binary, "user-level bin executable candidate");
    }
}

// 检查路径下的脚本安装候选并追加证据摘要。
fn appendScriptCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    apps: *std.ArrayList(schema.ScriptInstallCandidate),
    home: []const u8,
    path: []const u8,
    kind: schema.ScriptInstallKind,
    evidence: []const u8,
) !void {
    if (!probe.pathExists(io, path)) return;
    if (containsScriptApp(apps.items, path)) return;

    const name = try scriptCandidateName(allocator, path);
    defer allocator.free(name);
    const root = candidateEvidenceRoot(path, kind);
    const source_hint = try findSourceHint(io, allocator, root);
    errdefer if (source_hint) |value| allocator.free(value);
    const version_hint = try findVersionHint(io, allocator, root);
    errdefer if (version_hint) |value| allocator.free(value);
    const checksum_hint = try findChecksumHint(io, allocator, root);
    errdefer if (checksum_hint) |value| allocator.free(value);
    const config_hint = try findConfigHint(io, allocator, home, name);
    errdefer if (config_hint) |value| allocator.free(value);
    const reinstall_hint = try reinstallHint(allocator, kind, source_hint, version_hint, checksum_hint, config_hint);
    errdefer allocator.free(reinstall_hint);

    try apps.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
        .kind = kind,
        .present = true,
        .evidence = try allocator.dupe(u8, evidence),
        .source_hint = source_hint,
        .version_hint = version_hint,
        .checksum_hint = checksum_hint,
        .config_hint = config_hint,
        .reinstall_hint = reinstall_hint,
    });
}

fn containsScriptApp(apps: []const schema.ScriptInstallCandidate, path: []const u8) bool {
    for (apps) |app| {
        if (std.mem.eql(u8, app.path, path)) return true;
    }
    return false;
}

fn scriptCandidateName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 0 and base[0] == '.') return allocator.dupe(u8, base[1..]);
    return allocator.dupe(u8, base);
}

fn candidateEvidenceRoot(path: []const u8, kind: schema.ScriptInstallKind) []const u8 {
    if (kind == .user_binary) return parentDir(path) orelse path;
    return path;
}

fn parentDir(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return path[0..1];
    return path[0..slash];
}

fn findSourceHint(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    const files = [_][]const u8{ ".hostlift-source", "source.url", "origin.url", "install.sh", "README", "README.md" };
    for (files) |name| {
        const path = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(path);
        if (try firstUrlInFile(io, allocator, path)) |url| return url;
    }
    return null;
}

fn firstUrlInFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const contents = probe.readWholeFile(io, allocator, path) catch return null;
    defer allocator.free(contents);
    const search = contents[0..@min(contents.len, 64 * 1024)];
    const start = std.mem.indexOf(u8, search, "https://") orelse std.mem.indexOf(u8, search, "http://") orelse return null;
    var end = start;
    while (end < search.len and !std.ascii.isWhitespace(search[end]) and search[end] != '"' and search[end] != '\'' and search[end] != ')' and search[end] != ';') {
        end += 1;
    }
    var url = search[start..end];
    if (std.mem.indexOfScalar(u8, url, '?')) |query| url = url[0..query];
    if (url.len > 512) url = url[0..512];
    return @as(?[]const u8, try allocator.dupe(u8, url));
}

fn findVersionHint(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    const files = [_][]const u8{ "VERSION", "version", ".version", "RELEASE", "package.json", "pyproject.toml", "Cargo.toml", "go.mod" };
    for (files) |name| {
        const path = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(path);
        if (try firstVersionLine(io, allocator, path)) |value| return value;
    }
    return null;
}

fn firstVersionLine(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const contents = probe.readWholeFile(io, allocator, path) catch return null;
    defer allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents[0..@min(contents.len, 64 * 1024)], '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n,");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "version") != null or std.ascii.isDigit(line[0])) {
            return @as(?[]const u8, try allocator.dupe(u8, line[0..@min(line.len, 256)]));
        }
    }
    return null;
}

fn findChecksumHint(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    const files = [_][]const u8{ "SHA256SUMS", "sha256sum.txt", "checksums.txt", ".sha256" };
    for (files) |name| {
        const path = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(path);
        if (try firstChecksumLine(io, allocator, path)) |value| return value;
    }
    return null;
}

fn firstChecksumLine(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const contents = probe.readWholeFile(io, allocator, path) catch return null;
    defer allocator.free(contents);
    var fields = std.mem.tokenizeAny(u8, contents[0..@min(contents.len, 64 * 1024)], " \t\r\n");
    while (fields.next()) |field| {
        if (looksLikeSha256(field)) return @as(?[]const u8, try allocator.dupe(u8, field));
    }
    return null;
}

fn looksLikeSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn findConfigHint(io: std.Io, allocator: std.mem.Allocator, home: []const u8, name: []const u8) !?[]const u8 {
    const candidates = [_][]const u8{ ".config", ".local/share" };
    for (candidates) |base| {
        const path = try std.fs.path.join(allocator, &.{ home, base, name });
        defer allocator.free(path);
        if (probe.pathExists(io, path)) return @as(?[]const u8, try allocator.dupe(u8, path));
    }
    const dot_path = try std.fmt.allocPrint(allocator, "{s}/.{s}", .{ home, name });
    defer allocator.free(dot_path);
    if (probe.pathExists(io, dot_path)) return @as(?[]const u8, try allocator.dupe(u8, dot_path));
    return null;
}

fn reinstallHint(
    allocator: std.mem.Allocator,
    kind: schema.ScriptInstallKind,
    source_hint: ?[]const u8,
    version_hint: ?[]const u8,
    checksum_hint: ?[]const u8,
    config_hint: ?[]const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Review script-installed {s}; source={s}; version={s}; checksum={s}; config={s}; reinstall manually and do not auto-run downloaded scripts",
        .{
            @tagName(kind),
            source_hint orelse "unknown",
            version_hint orelse "unknown",
            checksum_hint orelse "unknown",
            config_hint orelse "unknown",
        },
    );
}

// 读取 hosts 文件并解析为条目列表；读取失败返回空。
fn parseHostsFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]schema.HostsEntry {
    const contents = probe.readWholeFile(io, allocator, path) catch return allocator.alloc(schema.HostsEntry, 0);
    defer allocator.free(contents);
    return parseHosts(allocator, contents);
}

// 读取文件并计算有效行数；读取失败返回 0。
fn countMeaningfulLinesInFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) u32 {
    const contents = probe.readWholeFile(io, allocator, path) catch return 0;
    defer allocator.free(contents);
    return probe.countMeaningfulLines(contents);
}

// 去除行内注释和首尾空白。
fn trimConfigLine(raw_line: []const u8) []const u8 {
    const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |idx| raw_line[0..idx] else raw_line;
    return std.mem.trim(u8, without_comment, " \t\r\n");
}

// 去除值两端的引号（单引号或双引号）。
fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return value;
}

// 判断字符串是否像环境变量名，避免把普通 shell 表达式写入事实。
fn looksLikeEnvKey(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |byte, index| {
        if (byte == '_') continue;
        if (byte >= 'A' and byte <= 'Z') continue;
        if (byte >= 'a' and byte <= 'z') continue;
        if (index > 0 and byte >= '0' and byte <= '9') continue;
        return false;
    }
    return true;
}

// 执行命令并返回输出行数；失败返回 0。
fn commandLineCount(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) u32 {
    const lines = probe.runLines(io, allocator, argv, 512 * 1024) catch return 0;
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    return @intCast(lines.len);
}

// 从命令事实列表中查找指定名称的行数。
fn countCommandLines(commands: []const schema.CommandFact, name: []const u8) u32 {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command.line_count;
    }
    return 0;
}

// 释放路径事实列表。
fn freePaths(allocator: std.mem.Allocator, paths: []schema.SystemPathFact) void {
    for (paths) |path| allocator.free(path.path);
    allocator.free(paths);
}

// 释放命令事实列表。
fn freeCommands(allocator: std.mem.Allocator, commands: []schema.CommandFact) void {
    for (commands) |command| allocator.free(command.name);
    allocator.free(commands);
}

// 释放配置事实列表。
fn freeConfigFacts(allocator: std.mem.Allocator, facts: []schema.SystemConfigFact) void {
    for (facts) |fact| {
        allocator.free(fact.source);
        allocator.free(fact.key);
        allocator.free(fact.value);
    }
    allocator.free(facts);
}

// 释放 hosts 条目列表。
fn freeHostsEntries(allocator: std.mem.Allocator, entries: []schema.HostsEntry) void {
    for (entries) |entry| {
        allocator.free(entry.address);
        allocator.free(entry.names);
    }
    allocator.free(entries);
}

// 释放脚本安装候选列表。
fn freeScriptApps(allocator: std.mem.Allocator, apps: []schema.ScriptInstallCandidate) void {
    for (apps) |app| {
        allocator.free(app.name);
        allocator.free(app.path);
        if (app.evidence) |evidence| allocator.free(evidence);
        if (app.source_hint) |hint| allocator.free(hint);
        if (app.version_hint) |hint| allocator.free(hint);
        if (app.checksum_hint) |hint| allocator.free(hint);
        if (app.config_hint) |hint| allocator.free(hint);
        allocator.free(app.reinstall_hint);
    }
    allocator.free(apps);
}

test "hosts parser keeps address and names without comments" {
    const entries = try parseHosts(std.testing.allocator,
        \\127.0.0.1 localhost
        \\# comment
        \\10.0.0.2 app app.internal # inline
    );
    defer freeHostsEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("127.0.0.1", entries[0].address);
    try std.testing.expectEqualStrings("localhost", entries[0].names);
    try std.testing.expectEqualStrings("10.0.0.2", entries[1].address);
    try std.testing.expectEqualStrings("app app.internal", entries[1].names);
}

test "script install helper redacts URL query and detects checksum" {
    const url: []const u8 = "curl https://example.com/install.sh?token=secret";
    const start = std.mem.indexOf(u8, url, "https://").?;
    var found = url[start..];
    if (std.mem.indexOfScalar(u8, found, '?')) |query| found = found[0..query];
    try std.testing.expectEqualStrings("https://example.com/install.sh", found);
    try std.testing.expect(looksLikeSha256("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}

test "system env redaction covers secret keys and credential URLs" {
    try std.testing.expect(shouldRedactSystemEnv("DATABASE_PASSWORD", "correct-horse"));
    try std.testing.expect(shouldRedactSystemEnv("github_token", "ghp-secret"));
    try std.testing.expect(shouldRedactSystemEnv("OPENAI_API_KEY", "api-secret"));
    try std.testing.expect(shouldRedactSystemEnv("AWS_ACCESSKEY", "access-secret"));
    try std.testing.expect(shouldRedactSystemEnv("HTTPS_PROXY", "http://deploy:proxy-pass@proxy.example.test:8080"));
    try std.testing.expect(shouldRedactSystemEnv("DATABASE_URL", "postgresql://app:db-pass@db.example.test/app"));
}

test "system env redaction preserves ordinary operational values and substring boundaries" {
    try std.testing.expect(!shouldRedactSystemEnv("PATH", "/usr/local/bin:/usr/bin"));
    try std.testing.expect(!shouldRedactSystemEnv("LANG", "zh_CN.UTF-8"));
    try std.testing.expect(!shouldRedactSystemEnv("TOKENIZER_MODE", "parallel"));
    try std.testing.expect(!shouldRedactSystemEnv("MONKEY_PATCH", "enabled"));
    try std.testing.expect(!shouldRedactSystemEnv("SECRETARY_EMAIL", "ops@example.test"));
    try std.testing.expect(!shouldRedactSystemEnv("DOCS_URL", "https://example.test/path@owner"));
}

test "config facts store only the redaction marker for sensitive system env" {
    var facts: std.ArrayList(schema.SystemConfigFact) = .empty;
    errdefer {
        for (facts.items) |fact| {
            std.testing.allocator.free(fact.source);
            std.testing.allocator.free(fact.key);
            std.testing.allocator.free(fact.value);
        }
        facts.deinit(std.testing.allocator);
    }
    try appendConfigFact(std.testing.allocator, &facts, .system_env, "/etc/environment", "API_TOKEN", "plain-secret-value");
    try appendConfigFact(std.testing.allocator, &facts, .system_env, "/etc/environment", "PATH", "/opt/bin:/usr/bin");
    try appendConfigFact(std.testing.allocator, &facts, .sysctl, "/etc/sysctl.conf", "TOKEN", "non-env-value");
    const owned = try facts.toOwnedSlice(std.testing.allocator);
    defer freeConfigFacts(std.testing.allocator, owned);

    try std.testing.expectEqualStrings(redacted_system_env_value, owned[0].value);
    try std.testing.expectEqualStrings("/opt/bin:/usr/bin", owned[1].value);
    try std.testing.expectEqualStrings("non-env-value", owned[2].value);

    var json_buffer: std.ArrayList(u8) = .empty;
    defer json_buffer.deinit(std.testing.allocator);
    var json_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &json_buffer);
    try std.json.Stringify.value(owned, .{}, &json_writer.writer);
    json_buffer = json_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, json_buffer.items, "plain-secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, json_buffer.items, redacted_system_env_value) != null);
}
