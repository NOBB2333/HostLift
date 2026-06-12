const std = @import("std");
const home_user = @import("home_user.zig");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

const max_hosts_entries = 256;
const max_script_apps = 512;

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
    };

    var facts: std.ArrayList(schema.SystemPathFact) = .empty;
    errdefer freePaths(allocator, facts.items);

    for (candidates) |candidate| {
        try appendPathFact(io, allocator, &facts, candidate.path, candidate.kind);
    }
    try appendUserSensitivePathFacts(io, allocator, &facts);

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
        argv: []const []const u8,
    }{
        .{ .name = "timedatectl", .argv = &.{ "timedatectl", "show" } },
        .{ .name = "locale", .argv = &.{"locale"} },
        .{ .name = "lsmod", .argv = &.{"lsmod"} },
        .{ .name = "vgs", .argv = &.{ "vgs", "--noheadings" } },
        .{ .name = "lvs", .argv = &.{ "lvs", "--noheadings" } },
        .{ .name = "zpool", .argv = &.{ "zpool", "list", "-H" } },
        .{ .name = "zfs", .argv = &.{ "zfs", "list", "-H" } },
        .{ .name = "btrfs", .argv = &.{ "btrfs", "filesystem", "show" } },
        .{ .name = "atq", .argv = &.{"atq"} },
    };

    var facts: std.ArrayList(schema.CommandFact) = .empty;
    errdefer freeCommands(allocator, facts.items);

    for (candidates) |candidate| {
        const present = probe.executableExists(io, allocator, candidate.name);
        const lines = if (present) commandLineCount(io, allocator, candidate.argv) else 0;
        try facts.append(allocator, .{
            .name = try allocator.dupe(u8, candidate.name),
            .present = present,
            .line_count = lines,
        });
    }

    return facts.toOwnedSlice(allocator);
}

// 扫描用户 home 目录下脚本安装的应用痕迹（rustup、nvm、mojo 等）。
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

    try appendGlobalScriptMarker(io, allocator, &apps, "/home/linuxbrew/.linuxbrew/bin/brew", .linuxbrew, "linuxbrew", "Review Homebrew official install script and Brewfile before reinstalling");
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
    try appendCommandFacts(io, allocator, &facts, .storage, "lvm_vgs", &.{ "vgs", "--noheadings", "-o", "vg_name,vg_size,vg_free" });
    try appendCommandFacts(io, allocator, &facts, .storage, "lvm_lvs", &.{ "lvs", "--noheadings", "-o", "lv_name,vg_name,lv_size,origin" });
    try appendCommandFacts(io, allocator, &facts, .storage, "zpool", &.{ "zpool", "list", "-H", "-o", "name,size,free,health" });
    try appendCommandFacts(io, allocator, &facts, .storage, "zfs", &.{ "zfs", "list", "-H", "-o", "name,used,avail,mountpoint" });
    try appendCommandFacts(io, allocator, &facts, .storage, "btrfs", &.{ "btrfs", "filesystem", "show" });

    return facts.toOwnedSlice(allocator);
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
    try facts.append(allocator, .{
        .kind = kind,
        .source = try allocator.dupe(u8, source),
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
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

// 扫描单个用户 home 下的脚本安装应用标记。
fn appendScriptMarkersForUser(
    io: std.Io,
    allocator: std.mem.Allocator,
    apps: *std.ArrayList(schema.ScriptInstallCandidate),
    home: []const u8,
    truncated: *bool,
) !void {
    const markers = [_]struct {
        relative_path: []const u8,
        kind: schema.ScriptInstallKind,
        name: []const u8,
        hint: []const u8,
    }{
        .{ .relative_path = ".cargo/bin/rustup", .kind = .rustup, .name = "rustup", .hint = "Review rustup toolchains and reinstall with the official rustup script; do not copy registry cache by default" },
        .{ .relative_path = ".nvm/nvm.sh", .kind = .nvm, .name = "nvm", .hint = "Review NVM versions and reinstall from the official NVM script; do not copy Node version cache blindly" },
        .{ .relative_path = ".modular/bin/mojo", .kind = .mojo, .name = "mojo", .hint = "Review Modular/Mojo installation and reinstall from the official script or package manager" },
        .{ .relative_path = ".local/bin/mojo", .kind = .mojo, .name = "mojo", .hint = "Review Modular/Mojo installation and reinstall from the official script or package manager" },
        .{ .relative_path = ".linuxbrew/bin/brew", .kind = .linuxbrew, .name = "linuxbrew", .hint = "Review Homebrew official install script and Brewfile before reinstalling" },
        .{ .relative_path = ".local/bin/lark", .kind = .feishu_cli, .name = "feishu-cli", .hint = "Review Feishu/Lark CLI installer source and reinstall from the official script" },
        .{ .relative_path = ".local/bin/feishu", .kind = .feishu_cli, .name = "feishu-cli", .hint = "Review Feishu/Lark CLI installer source and reinstall from the official script" },
        .{ .relative_path = ".config/feishu", .kind = .feishu_cli, .name = "feishu-cli", .hint = "Review Feishu/Lark CLI config and tokens manually; do not migrate credentials by default" },
    };

    for (markers) |marker| {
        if (apps.items.len >= max_script_apps) {
            truncated.* = true;
            return;
        }
        const path = try std.fs.path.join(allocator, &.{ home, marker.relative_path });
        defer allocator.free(path);
        try appendGlobalScriptMarker(io, allocator, apps, path, marker.kind, marker.name, marker.hint);
    }
}

// 检查全局路径下的脚本安装标记并追加到列表。
fn appendGlobalScriptMarker(
    io: std.Io,
    allocator: std.mem.Allocator,
    apps: *std.ArrayList(schema.ScriptInstallCandidate),
    path: []const u8,
    kind: schema.ScriptInstallKind,
    name: []const u8,
    hint: []const u8,
) !void {
    if (!probe.pathExists(io, path)) return;
    try apps.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
        .kind = kind,
        .present = true,
        .reinstall_hint = try allocator.dupe(u8, hint),
    });
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
