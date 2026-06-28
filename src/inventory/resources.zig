const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

const max_resources = 1024;
const max_resource_files = 100_000;
const max_scan_depth = 8;
const max_file_type_len = 512;
const max_dynamic_summary_len = 2048;
const max_dynamic_lines = 8;
const max_security_summary_len = 1024;
const max_security_scan_depth = 4;
const max_security_scan_entries = 2000;

const SizeSummary = struct {
    logical_size: u64 = 0,
    disk_usage: u64 = 0,
    file_count: u64 = 0,
};

// 扫描整机资源地图；以通用路径、引用关系和包归属识别脚本/手工安装资产。
pub fn scan(io: std.Io, allocator: std.mem.Allocator, modules: schema.ModuleInventory) !schema.ResourceInventory {
    var resources: std.ArrayList(schema.ResourceRef) = .empty;
    errdefer freeResources(allocator, resources.items);

    var truncated = false;
    try appendGenericRoots(io, allocator, &resources, &truncated);
    try appendHomeState(io, allocator, &resources, &truncated);
    try appendPathExecutables(io, allocator, &resources, &truncated);
    try appendProcessExecutables(io, allocator, &resources, modules.processes, &truncated);
    try appendServiceExecutables(io, allocator, &resources, modules.services, &truncated);
    try appendCronExecutables(io, allocator, &resources, modules.cron, &truncated);
    try appendProfileExecutables(io, allocator, &resources, modules.home_configs, &truncated);

    return .{
        .resources = try resources.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

// 释放资源扫描结果中的分配字段，供测试和失败路径复用。
pub fn freeInventory(allocator: std.mem.Allocator, inventory: schema.ResourceInventory) void {
    freeResources(allocator, inventory.resources);
}

fn appendGenericRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
) !void {
    const candidates = [_]struct {
        path: []const u8,
        kind: schema.ResourceKind,
        sensitivity: schema.ResourceSensitivity,
        default_action: schema.ResourceDefaultAction,
        evidence: []const u8,
    }{
        .{ .path = "/srv", .kind = .app_data, .sensitivity = .normal, .default_action = .review, .evidence = "generic app data root" },
        .{ .path = "/opt", .kind = .install_root, .sensitivity = .normal, .default_action = .review, .evidence = "generic third-party install root" },
        .{ .path = "/usr/local", .kind = .install_root, .sensitivity = .normal, .default_action = .review, .evidence = "local administrator install root" },
        .{ .path = "/var/www", .kind = .app_data, .sensitivity = .normal, .default_action = .review, .evidence = "generic web root" },
        .{ .path = "/var/lib/mysql", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "database data root" },
        .{ .path = "/var/lib/postgresql", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "database data root" },
        .{ .path = "/var/lib/redis", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "database data root" },
        .{ .path = "/var/lib/mongodb", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "database data root" },
        .{ .path = "/var/lib/elasticsearch", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "search index data root" },
        .{ .path = "/var/lib/rabbitmq", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "message queue data root" },
        .{ .path = "/var/lib/kafka", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "message queue data root" },
        .{ .path = "/var/lib/docker/volumes", .kind = .app_data, .sensitivity = .sensitive, .default_action = .review, .evidence = "container volume root" },
        .{ .path = "/tmp", .kind = .ephemeral, .sensitivity = .ephemeral, .default_action = .exclude, .evidence = "ephemeral runtime path" },
        .{ .path = "/run", .kind = .ephemeral, .sensitivity = .ephemeral, .default_action = .exclude, .evidence = "ephemeral runtime path" },
    };

    for (candidates) |candidate| {
        try appendPathResource(io, allocator, resources, truncated, .{
            .path = candidate.path,
            .kind = candidate.kind,
            .sensitivity = candidate.sensitivity,
            .default_action = candidate.default_action,
            .evidence = candidate.evidence,
            .owner = null,
            .package_owner = null,
        });
    }
}

fn appendHomeState(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
) !void {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    for (users) |user| {
        if (!isMigratableHomeUser(user)) continue;
        try appendPathResource(io, allocator, resources, truncated, .{
            .path = user.home,
            .kind = .home_state,
            .sensitivity = .sensitive,
            .default_action = .review,
            .evidence = "non-system user home",
            .owner = user.name,
            .package_owner = null,
            .file_type = null,
            .dynamic_link_summary = null,
        });

        const login_paths = [_][]const u8{ ".config", ".local/share" };
        for (login_paths) |relative| {
            const path = try std.fs.path.join(allocator, &.{ user.home, relative });
            defer allocator.free(path);
            try appendPathResource(io, allocator, resources, truncated, .{
                .path = path,
                .kind = .login_state,
                .sensitivity = .sensitive,
                .default_action = .copy,
                .evidence = "generic XDG login/application state",
                .owner = user.name,
                .package_owner = null,
                .file_type = null,
                .dynamic_link_summary = null,
            });
        }

        const cache_path = try std.fs.path.join(allocator, &.{ user.home, ".cache" });
        defer allocator.free(cache_path);
        try appendPathResource(io, allocator, resources, truncated, .{
            .path = cache_path,
            .kind = .cache,
            .sensitivity = .normal,
            .default_action = .exclude,
            .evidence = "user cache path",
            .owner = user.name,
            .package_owner = null,
            .file_type = null,
            .dynamic_link_summary = null,
        });

        try appendUserBinExecutables(io, allocator, resources, truncated, user);
        if (truncated.*) return;
    }
}

fn isMigratableHomeUser(user: schema.UserAccount) bool {
    if (user.home.len == 0 or std.mem.eql(u8, user.home, "/nonexistent")) return false;
    return !user.system or std.mem.eql(u8, user.name, "root");
}

fn appendPathExecutables(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
) !void {
    const dirs = [_][]const u8{
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/bin",
        "/snap/bin",
    };

    for (dirs) |dir_path| {
        try appendExecutableDir(io, allocator, resources, truncated, dir_path, null, "unmanaged PATH executable candidate");
        if (truncated.*) return;
    }
}

fn appendUserBinExecutables(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
    user: schema.UserAccount,
) !void {
    const relative_dirs = [_][]const u8{
        "go/bin",
        ".cargo/bin",
        ".local/bin",
        ".deno/bin",
        ".bun/bin",
        ".npm-global/bin",
    };

    for (relative_dirs) |relative| {
        const dir_path = try std.fs.path.join(allocator, &.{ user.home, relative });
        defer allocator.free(dir_path);
        try appendExecutableDir(io, allocator, resources, truncated, dir_path, user.name, "user-level bin executable candidate");
        if (truncated.*) return;
    }
}

fn appendExecutableDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
    dir_path: []const u8,
    owner: ?[]const u8,
    evidence: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        try appendExecutableCandidate(io, allocator, resources, truncated, path, evidence, owner, true);
        if (truncated.*) return;
    }
}

fn appendProcessExecutables(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    processes: schema.ProcessInventory,
    truncated: *bool,
) !void {
    for (processes.processes) |process| {
        if (firstAbsoluteCommand(process.command)) |path| {
            try appendExecutableCandidate(io, allocator, resources, truncated, path, "running process command path", null, false);
        }
        if (truncated.*) return;
    }
}

fn appendServiceExecutables(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    services: schema.ServiceInventory,
    truncated: *bool,
) !void {
    for (services.units) |unit| {
        const path = unit.path orelse continue;
        try appendExecutablesFromFile(io, allocator, resources, truncated, path, "systemd unit Exec path");
        if (truncated.*) return;
    }
    for (services.user_units) |unit| {
        try appendExecutablesFromFile(io, allocator, resources, truncated, unit.path, "user systemd unit Exec path");
        if (truncated.*) return;
    }
    for (services.xdg_autostart) |entry| {
        try appendExecutablesFromFile(io, allocator, resources, truncated, entry.path, "XDG autostart Exec path");
        if (truncated.*) return;
    }
}

fn appendCronExecutables(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    cron: schema.CronInventory,
    truncated: *bool,
) !void {
    for (cron.entries) |entry| {
        try appendExecutablesFromFile(io, allocator, resources, truncated, entry.source, "cron command path");
        if (truncated.*) return;
    }
}

fn appendProfileExecutables(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    home_configs: schema.HomeConfigInventory,
    truncated: *bool,
) !void {
    for (home_configs.configs) |config| {
        if (config.kind != .shell and config.kind != .app) continue;
        if (config.directory) continue;
        try appendExecutablesFromFile(io, allocator, resources, truncated, config.path, "profile or tool config path reference");
        if (truncated.*) return;
    }
}

const PathResourceInput = struct {
    path: []const u8,
    kind: schema.ResourceKind,
    sensitivity: schema.ResourceSensitivity,
    default_action: schema.ResourceDefaultAction,
    evidence: []const u8,
    owner: ?[]const u8,
    package_owner: ?[]const u8,
    file_type: ?[]const u8 = null,
    dynamic_link_summary: ?[]const u8 = null,
};

const SecurityFacts = struct {
    owner_group: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    mtime_unix: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    security_summary: ?[]const u8 = null,

    fn deinit(self: SecurityFacts, allocator: std.mem.Allocator) void {
        if (self.owner_group) |value| allocator.free(value);
        if (self.mode) |value| allocator.free(value);
        if (self.mtime_unix) |value| allocator.free(value);
        if (self.sha256) |value| allocator.free(value);
        if (self.security_summary) |value| allocator.free(value);
    }
};

fn appendPathResource(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
    input: PathResourceInput,
) !void {
    if (truncated.* or resources.items.len >= max_resources) {
        truncated.* = true;
        return;
    }
    if (!probe.pathExists(io, input.path)) return;
    if (containsResource(resources.items, input.path)) return;

    const directory = probe.pathIsDirectory(io, input.path);
    const size = try sizeForPath(io, allocator, input.path, directory);
    const security = try collectSecurityFacts(io, allocator, input.path, directory);
    defer security.deinit(allocator);
    const evidence = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(evidence);
    evidence[0] = try allocator.dupe(u8, input.evidence);
    errdefer allocator.free(evidence[0]);

    try resources.append(allocator, .{
        .path = try allocator.dupe(u8, input.path),
        .present = true,
        .directory = directory,
        .kind = input.kind,
        .logical_size = size.logical_size,
        .disk_usage = size.disk_usage,
        .file_count = size.file_count,
        .owner = if (input.owner) |owner| try allocator.dupe(u8, owner) else null,
        .owner_group = if (security.owner_group) |owner_group| try allocator.dupe(u8, owner_group) else null,
        .mode = if (security.mode) |mode| try allocator.dupe(u8, mode) else null,
        .mtime_unix = if (security.mtime_unix) |mtime| try allocator.dupe(u8, mtime) else null,
        .package_owner = if (input.package_owner) |owner| try allocator.dupe(u8, owner) else null,
        .evidence = evidence,
        .sha256 = if (security.sha256) |sha256| try allocator.dupe(u8, sha256) else null,
        .file_type = if (input.file_type) |file_type| try allocator.dupe(u8, file_type) else null,
        .dynamic_link_summary = if (input.dynamic_link_summary) |summary| try allocator.dupe(u8, summary) else null,
        .security_summary = if (security.security_summary) |summary| try allocator.dupe(u8, summary) else null,
        .sensitivity = input.sensitivity,
        .default_action = input.default_action,
    });
}

const ExecutableFacts = struct {
    file_type: ?[]const u8 = null,
    dynamic_link_summary: ?[]const u8 = null,

    fn deinit(self: ExecutableFacts, allocator: std.mem.Allocator) void {
        if (self.file_type) |file_type| allocator.free(file_type);
        if (self.dynamic_link_summary) |summary| allocator.free(summary);
    }
};

fn appendExecutableCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
    executable_path: []const u8,
    evidence: []const u8,
    owner: ?[]const u8,
    force_single_file: bool,
) !void {
    if (!std.mem.startsWith(u8, executable_path, "/")) return;
    if (!probe.pathExists(io, executable_path)) return;

    const package_owner = try packageOwnerForPath(io, allocator, executable_path);
    defer if (package_owner) |pkg_owner| allocator.free(pkg_owner);
    if (package_owner != null) {
        try appendPathResource(io, allocator, resources, truncated, .{
            .path = executable_path,
            .kind = .package_managed,
            .sensitivity = .normal,
            .default_action = .exclude,
            .evidence = "package manager owns executable",
            .owner = owner,
            .package_owner = package_owner,
        });
        return;
    }

    const facts = try collectExecutableFacts(io, allocator, executable_path);
    defer facts.deinit(allocator);

    const root = if (force_single_file) executable_path else installRootForExecutable(executable_path);
    try appendPathResource(io, allocator, resources, truncated, .{
        .path = root,
        .kind = if (std.mem.eql(u8, root, executable_path)) .unmanaged_executable else .install_root,
        .sensitivity = .normal,
        .default_action = if (std.mem.eql(u8, root, executable_path)) .review else .copy,
        .evidence = evidence,
        .owner = owner,
        .package_owner = null,
        .file_type = facts.file_type,
        .dynamic_link_summary = facts.dynamic_link_summary,
    });
}

fn collectExecutableFacts(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8) !ExecutableFacts {
    var facts: ExecutableFacts = .{};
    errdefer facts.deinit(allocator);

    if (probe.executableExists(io, allocator, "file")) {
        const file_line = probe.runFirstLine(io, allocator, &.{ "file", "-b", executable_path }) catch null;
        if (file_line) |line| {
            defer allocator.free(line);
            facts.file_type = try boundedDupe(allocator, line, max_file_type_len);
        }
    }

    if (facts.file_type) |file_type| {
        if (isLikelyDynamicElf(file_type)) {
            facts.dynamic_link_summary = try collectStaticDynamicLinkSummary(io, allocator, executable_path);
        }
    }

    return facts;
}

fn boundedDupe(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]const u8 {
    if (text.len <= limit) return allocator.dupe(u8, text);
    return allocator.dupe(u8, text[0..limit]);
}

fn isLikelyDynamicElf(file_type: []const u8) bool {
    if (std.mem.indexOf(u8, file_type, "ELF") == null) return false;
    if (std.mem.indexOf(u8, file_type, "statically linked") != null) return false;
    return std.mem.indexOf(u8, file_type, "dynamically linked") != null or
        std.mem.indexOf(u8, file_type, "interpreter") != null or
        std.mem.indexOf(u8, file_type, "shared object") != null;
}

fn collectStaticDynamicLinkSummary(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8) !?[]const u8 {
    if (probe.executableExists(io, allocator, "readelf")) {
        if (probe.runCommand(io, allocator, &.{ "readelf", "-d", executable_path }, 16 * 1024)) |output| {
            defer allocator.free(output);
            if (try summarizeStaticDynamicOutput(allocator, output)) |summary| return summary;
        } else |_| {}
    }

    if (probe.executableExists(io, allocator, "objdump")) {
        if (probe.runCommand(io, allocator, &.{ "objdump", "-p", executable_path }, 16 * 1024)) |output| {
            defer allocator.free(output);
            if (try summarizeStaticDynamicOutput(allocator, output)) |summary| return summary;
        } else |_| {}
    }

    const fallback = try allocator.dupe(u8, "static ELF dependency parser unavailable or found no dynamic dependency entries");
    return fallback;
}

fn summarizeStaticDynamicOutput(allocator: std.mem.Allocator, output: []const u8) !?[]const u8 {
    var summary: std.ArrayList(u8) = .empty;
    errdefer summary.deinit(allocator);

    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (!isInterestingDynamicLine(line)) continue;
        if (summary.items.len >= max_dynamic_summary_len or shown >= max_dynamic_lines) break;
        if (summary.items.len > 0) try summary.appendSlice(allocator, "; ");

        const remaining = max_dynamic_summary_len - summary.items.len;
        const take = @min(line.len, remaining);
        try summary.appendSlice(allocator, line[0..take]);
        shown += 1;
        if (take < line.len) break;
    }

    if (summary.items.len == 0) {
        summary.deinit(allocator);
        return null;
    }
    return try summary.toOwnedSlice(allocator);
}

fn isInterestingDynamicLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "(NEEDED)") != null or
        std.mem.indexOf(u8, line, "(RPATH)") != null or
        std.mem.indexOf(u8, line, "(RUNPATH)") != null or
        std.mem.startsWith(u8, line, "NEEDED") or
        std.mem.startsWith(u8, line, "RPATH") or
        std.mem.startsWith(u8, line, "RUNPATH");
}

fn appendExecutablesFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(schema.ResourceRef),
    truncated: *bool,
    path: []const u8,
    evidence: []const u8,
) !void {
    const contents = probe.readWholeFile(io, allocator, path) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var rest = line;
        while (firstAbsoluteCommand(rest)) |candidate| {
            try appendExecutableCandidate(io, allocator, resources, truncated, candidate, evidence, null, false);
            if (truncated.*) return;
            const offset = std.mem.indexOf(u8, rest, candidate) orelse break;
            rest = rest[offset + candidate.len ..];
        }
    }
}

fn sizeForPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory: bool) !SizeSummary {
    var summary = if (directory)
        walkDirectorySize(io, allocator, path, 0) catch SizeSummary{}
    else
        SizeSummary{ .logical_size = probe.fileSize(io, path) orelse 0, .file_count = 1 };

    summary.disk_usage = diskUsageBytes(io, allocator, path) orelse summary.logical_size;
    return summary;
}

fn walkDirectorySize(io: std.Io, allocator: std.mem.Allocator, path: []const u8, depth: u8) !SizeSummary {
    if (depth >= max_scan_depth) return .{};

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return .{};
    defer dir.close(io);

    var summary: SizeSummary = .{};
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (summary.file_count >= max_resource_files) break;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);

        if (entry.kind == .directory) {
            const child = try walkDirectorySize(io, allocator, child_path, depth + 1);
            summary.logical_size += child.logical_size;
            summary.file_count += child.file_count;
            continue;
        }
        summary.logical_size += probe.fileSize(io, child_path) orelse 0;
        summary.file_count += 1;
    }
    return summary;
}

fn diskUsageBytes(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?u64 {
    const output = probe.runFirstLine(io, allocator, &.{ "du", "-sk", path }) catch return null;
    defer allocator.free(output);
    var fields = std.mem.tokenizeAny(u8, output, " \t");
    const kib = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch return null;
    return kib * 1024;
}

fn collectSecurityFacts(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory: bool) !SecurityFacts {
    var facts: SecurityFacts = .{};
    errdefer facts.deinit(allocator);

    if (statForPath(io, path, directory)) |stat| {
        const mode = permissionMode(stat);
        facts.mode = try std.fmt.allocPrint(allocator, "{o}", .{mode});
        facts.mtime_unix = try std.fmt.allocPrint(allocator, "{d}", .{stat.mtime.toSeconds()});
        facts.owner_group = try ownerGroupForPath(io, allocator, path);
        facts.security_summary = try securitySummaryForPath(io, allocator, path, directory, mode);
    }
    if (!directory) {
        facts.sha256 = try sha256ForFile(io, allocator, path);
    }
    return facts;
}

fn statForPath(io: std.Io, path: []const u8, directory: bool) ?std.Io.File.Stat {
    if (directory) {
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return null;
        defer dir.close(io);
        return dir.stat(io) catch null;
    }
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    return file.stat(io) catch null;
}

fn permissionMode(stat: std.Io.File.Stat) u32 {
    if (!std.Io.File.Permissions.has_executable_bit) return 0;
    return @as(u32, @intCast(stat.permissions.toMode() & 0o7777));
}

fn ownerGroupForPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (probe.executableExists(io, allocator, "stat")) {
        if (probe.runFirstLine(io, allocator, &.{ "stat", "-c", "%U:%G", path })) |line| {
            defer allocator.free(line);
            return @as(?[]const u8, try boundedDupe(allocator, line, 128));
        } else |_| {}
        if (probe.runFirstLine(io, allocator, &.{ "stat", "-f", "%Su:%Sg", path })) |line| {
            defer allocator.free(line);
            return @as(?[]const u8, try boundedDupe(allocator, line, 128));
        } else |_| {}
    }
    return null;
}

fn sha256ForFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (probe.executableExists(io, allocator, "sha256sum")) {
        if (firstHashFromCommand(io, allocator, &.{ "sha256sum", path })) |hash| {
            return hash;
        } else |_| {}
    }
    if (probe.executableExists(io, allocator, "shasum")) {
        if (firstHashFromCommand(io, allocator, &.{ "shasum", "-a", "256", path })) |hash| {
            return hash;
        } else |_| {}
    }
    return null;
}

fn firstHashFromCommand(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const line = try probe.runFirstLine(io, allocator, argv);
    defer allocator.free(line);
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const hash = fields.next() orelse return error.EmptyOutput;
    if (!looksLikeSha256(hash)) return error.InvalidHash;
    return try allocator.dupe(u8, hash);
}

fn looksLikeSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (std.ascii.isHex(byte)) continue;
        return false;
    }
    return true;
}

const SecurityCounts = struct {
    scanned: u64 = 0,
    hidden_entries: u64 = 0,
    world_writable: u64 = 0,
    setuid_or_setgid: u64 = 0,
    truncated: bool = false,
};

fn securitySummaryForPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory: bool, mode: u32) !?[]const u8 {
    var summary: std.ArrayList(u8) = .empty;
    errdefer summary.deinit(allocator);

    try appendModeFindings(allocator, &summary, mode);
    if (pathHasHiddenComponent(path)) try appendFinding(allocator, &summary, "hidden_path");

    if (directory) {
        var counts: SecurityCounts = .{};
        try scanDirectorySecurity(io, allocator, path, 0, &counts);
        if (counts.hidden_entries > 0) try appendFindingFmt(allocator, &summary, "hidden_entries={d}", .{counts.hidden_entries});
        if (counts.world_writable > 0) try appendFindingFmt(allocator, &summary, "world_writable_entries={d}", .{counts.world_writable});
        if (counts.setuid_or_setgid > 0) try appendFindingFmt(allocator, &summary, "setuid_or_setgid_entries={d}", .{counts.setuid_or_setgid});
        if (counts.truncated) try appendFindingFmt(allocator, &summary, "security_scan_truncated_after={d}", .{counts.scanned});
    }

    if (summary.items.len == 0) {
        summary.deinit(allocator);
        return null;
    }
    return try summary.toOwnedSlice(allocator);
}

fn appendModeFindings(allocator: std.mem.Allocator, summary: *std.ArrayList(u8), mode: u32) !void {
    if ((mode & 0o0002) != 0) try appendFinding(allocator, summary, "world_writable");
    if ((mode & 0o4000) != 0) try appendFinding(allocator, summary, "setuid");
    if ((mode & 0o2000) != 0) try appendFinding(allocator, summary, "setgid");
}

fn appendFinding(allocator: std.mem.Allocator, summary: *std.ArrayList(u8), finding: []const u8) !void {
    if (summary.items.len >= max_security_summary_len) return;
    if (summary.items.len > 0) try summary.appendSlice(allocator, "; ");
    const remaining = max_security_summary_len - summary.items.len;
    try summary.appendSlice(allocator, finding[0..@min(finding.len, remaining)]);
}

fn appendFindingFmt(allocator: std.mem.Allocator, summary: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const finding = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(finding);
    try appendFinding(allocator, summary, finding);
}

fn scanDirectorySecurity(io: std.Io, allocator: std.mem.Allocator, path: []const u8, depth: u8, counts: *SecurityCounts) !void {
    if (depth >= max_security_scan_depth) {
        counts.truncated = true;
        return;
    }
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (counts.scanned >= max_security_scan_entries) {
            counts.truncated = true;
            return;
        }
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (isHiddenName(entry.name)) counts.hidden_entries += 1;

        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        const is_dir = entry.kind == .directory;
        if (entry.kind == .file or is_dir) {
            if (statForPath(io, child_path, is_dir)) |stat| {
                const mode = permissionMode(stat);
                if ((mode & 0o0002) != 0) counts.world_writable += 1;
                if ((mode & 0o6000) != 0) counts.setuid_or_setgid += 1;
            }
            counts.scanned += 1;
        }
        if (is_dir) try scanDirectorySecurity(io, allocator, child_path, depth + 1, counts);
        if (counts.truncated) return;
    }
}

fn pathHasHiddenComponent(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (isHiddenName(part)) return true;
    }
    return false;
}

fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.' and !std.mem.eql(u8, name, "..");
}

fn packageOwnerForPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (probe.executableExists(io, allocator, "dpkg")) {
        if (try packageOwnerDpkg(io, allocator, path)) |owner| return owner;
    }
    if (probe.executableExists(io, allocator, "rpm")) {
        if (try packageOwnerRpm(io, allocator, path)) |owner| return owner;
    }
    if (probe.executableExists(io, allocator, "pacman")) {
        if (try packageOwnerPacman(io, allocator, path)) |owner| return owner;
    }
    if (probe.executableExists(io, allocator, "apk")) {
        if (try packageOwnerApk(io, allocator, path)) |owner| return owner;
    }
    return null;
}

fn packageOwnerDpkg(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const line = probe.runFirstLine(io, allocator, &.{ "dpkg", "-S", path }) catch return null;
    defer allocator.free(line);
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const owner = std.mem.trim(u8, line[0..colon], " \t");
    if (owner.len == 0) return null;
    return try allocator.dupe(u8, owner);
}

fn packageOwnerRpm(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const line = probe.runFirstLine(io, allocator, &.{ "rpm", "-qf", path }) catch return null;
    if (std.mem.indexOf(u8, line, "not owned") != null) {
        allocator.free(line);
        return null;
    }
    return line;
}

fn packageOwnerPacman(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const line = probe.runFirstLine(io, allocator, &.{ "pacman", "-Qo", path }) catch return null;
    defer allocator.free(line);
    const marker = " is owned by ";
    const marker_index = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = std.mem.trim(u8, line[marker_index + marker.len ..], " \t");
    if (rest.len == 0) return null;
    var fields = std.mem.tokenizeAny(u8, rest, " \t");
    const owner = fields.next() orelse return null;
    return try allocator.dupe(u8, owner);
}

fn packageOwnerApk(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const line = probe.runFirstLine(io, allocator, &.{ "apk", "info", "--who-owns", path }) catch return null;
    defer allocator.free(line);
    const owner_start = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return null;
    const owner = std.mem.trim(u8, line[owner_start + 1 ..], " \t");
    if (owner.len == 0) return null;
    return try allocator.dupe(u8, owner);
}

fn installRootForExecutable(path: []const u8) []const u8 {
    if (isSingleFileExecutablePath(path)) return path;
    if (rootAfterPrefix(path, "/opt/")) |root| return root;
    if (rootAfterPrefix(path, "/srv/")) |root| return root;
    if (rootAfterPrefix(path, "/usr/local/")) |root| return root;
    return path;
}

fn isSingleFileExecutablePath(path: []const u8) bool {
    const dir = parentDir(path) orelse return false;
    const system_bin_dirs = [_][]const u8{
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/bin",
        "/snap/bin",
    };
    for (system_bin_dirs) |bin_dir| {
        if (std.mem.eql(u8, dir, bin_dir)) return true;
    }

    const user_bin_suffixes = [_][]const u8{
        "/go/bin",
        "/.cargo/bin",
        "/.local/bin",
        "/.deno/bin",
        "/.bun/bin",
        "/.npm-global/bin",
    };
    for (user_bin_suffixes) |suffix| {
        if (dir.len > suffix.len and std.mem.endsWith(u8, dir, suffix)) return true;
    }
    return false;
}

fn parentDir(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return path[0..1];
    return path[0..slash];
}

fn rootAfterPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return path;
    if (slash == 0) return null;
    return path[0 .. prefix.len + slash];
}

fn firstAbsoluteCommand(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n\"'()[]{}<>;");
    while (tokens.next()) |raw_token| {
        const trimmed = std.mem.trim(u8, raw_token, ",");
        const token = if (std.mem.lastIndexOfScalar(u8, trimmed, '=')) |idx| trimmed[idx + 1 ..] else trimmed;
        if (!std.mem.startsWith(u8, token, "/")) continue;
        if (std.mem.indexOfAny(u8, token, "*?$`")) |_| continue;
        if (std.mem.endsWith(u8, token, "/")) continue;
        return token;
    }
    return null;
}

fn containsResource(resources: []const schema.ResourceRef, path: []const u8) bool {
    for (resources) |resource| {
        if (std.mem.eql(u8, resource.path, path)) return true;
    }
    return false;
}

fn freeResources(allocator: std.mem.Allocator, resources: []schema.ResourceRef) void {
    for (resources) |resource| {
        allocator.free(resource.path);
        if (resource.owner) |owner| allocator.free(owner);
        if (resource.owner_group) |owner_group| allocator.free(owner_group);
        if (resource.mode) |mode| allocator.free(mode);
        if (resource.mtime_unix) |mtime| allocator.free(mtime);
        if (resource.package_owner) |owner| allocator.free(owner);
        for (resource.evidence) |evidence| allocator.free(evidence);
        allocator.free(resource.evidence);
        if (resource.sha256) |sha256| allocator.free(sha256);
        if (resource.file_type) |file_type| allocator.free(file_type);
        if (resource.dynamic_link_summary) |summary| allocator.free(summary);
        if (resource.security_summary) |summary| allocator.free(summary);
    }
    allocator.free(resources);
}

test "resource command parser extracts absolute executable" {
    const command = firstAbsoluteCommand("ExecStart=/opt/myapp/bin/server --config /etc/myapp.conf").?;
    try std.testing.expectEqualStrings("/opt/myapp/bin/server", command);
}

test "install root keeps direct bin executables as single files" {
    try std.testing.expectEqualStrings("/usr/local/bin/tool", installRootForExecutable("/usr/local/bin/tool"));
    try std.testing.expectEqualStrings("/usr/local/sbin/tool", installRootForExecutable("/usr/local/sbin/tool"));
    try std.testing.expectEqualStrings("/opt/bin/tool", installRootForExecutable("/opt/bin/tool"));
    try std.testing.expectEqualStrings("/snap/bin/tool", installRootForExecutable("/snap/bin/tool"));
    try std.testing.expectEqualStrings("/home/alice/.cargo/bin/tool", installRootForExecutable("/home/alice/.cargo/bin/tool"));
    try std.testing.expectEqualStrings("/home/alice/.local/bin/tool", installRootForExecutable("/home/alice/.local/bin/tool"));
    try std.testing.expectEqualStrings("/root/go/bin/tool", installRootForExecutable("/root/go/bin/tool"));
}

test "install root groups explicit app roots" {
    try std.testing.expectEqualStrings("/opt/myapp", installRootForExecutable("/opt/myapp/bin/server"));
    try std.testing.expectEqualStrings("/usr/local/myapp", installRootForExecutable("/usr/local/myapp/bin/tool"));
    try std.testing.expectEqualStrings("/srv/app", installRootForExecutable("/srv/app/bin/server"));
}

test "static dynamic summary is bounded and line based" {
    const summary = (try summarizeStaticDynamicOutput(
        std.testing.allocator,
        "0x0000000000000001 (NEEDED) Shared library: [libc.so.6]\n0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN]\nignored line\n",
    )).?;
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "libc.so.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "RUNPATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "; ") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ignored line") == null);
}

test "resource security helpers detect hidden path and sha256" {
    try std.testing.expect(pathHasHiddenComponent("/home/alice/.local/bin/tool"));
    try std.testing.expect(!pathHasHiddenComponent("/usr/local/bin/tool"));
    try std.testing.expect(looksLikeSha256("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    try std.testing.expect(!looksLikeSha256("not-a-hash"));
}
