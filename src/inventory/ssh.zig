const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描 SSH authorized_keys 摘要和 SSH 配置存在性，不读取私钥。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.SshInventory {
    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    var authorized_keys: std.ArrayList(schema.AuthorizedKeys) = .empty;
    errdefer {
        for (authorized_keys.items) |keys| {
            allocator.free(keys.user);
            allocator.free(keys.path);
        }
        authorized_keys.deinit(allocator);
    }

    for (users) |user| {
        if (user.home.len == 0 or std.mem.eql(u8, user.home, "/nonexistent")) continue;
        const path = try std.fs.path.join(allocator, &.{ user.home, ".ssh", "authorized_keys" });
        defer allocator.free(path);

        const contents = probe.readWholeFile(io, allocator, path) catch continue;
        defer allocator.free(contents);

        const key_count = probe.countMeaningfulLines(contents);
        if (key_count == 0) continue;

        try authorized_keys.append(allocator, .{
            .user = try allocator.dupe(u8, user.name),
            .path = try allocator.dupe(u8, path),
            .key_count = key_count,
        });
    }

    return .{
        .authorized_keys = try authorized_keys.toOwnedSlice(allocator),
        .sshd_config_present = probe.pathExists(io, "/etc/ssh/sshd_config"),
        .client_config_present = probe.pathExists(io, "/etc/ssh/ssh_config"),
        .sshd_config = try parseSshdConfigFile(io, allocator, "/etc/ssh/sshd_config"),
        .host_keys = try scanHostKeys(io, allocator),
    };
}

// 解析 sshd_config 中影响迁移连通性和认证语义的关键指令。
pub fn parseSshdConfig(allocator: std.mem.Allocator, contents: []const u8) ![]schema.SshdConfigFact {
    var facts: std.ArrayList(schema.SshdConfigFact) = .empty;
    errdefer freeSshdConfigFacts(allocator, facts.items);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = trimSshConfigLine(raw_line);
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const key = fields.next() orelse continue;
        if (!isInterestingSshdKey(key)) continue;
        const value_start = std.mem.indexOf(u8, line, key).? + key.len;
        const value = std.mem.trim(u8, line[value_start..], " \t");
        if (value.len == 0) continue;
        try facts.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }

    return facts.toOwnedSlice(allocator);
}

// 读取 sshd_config 文件并解析关键指令；读取失败返回空。
fn parseSshdConfigFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]schema.SshdConfigFact {
    const contents = probe.readWholeFile(io, allocator, path) catch return allocator.alloc(schema.SshdConfigFact, 0);
    defer allocator.free(contents);
    return parseSshdConfig(allocator, contents);
}

// 释放 sshd_config 事实列表。
fn freeSshdConfigFacts(allocator: std.mem.Allocator, facts: []schema.SshdConfigFact) void {
    for (facts) |fact| {
        allocator.free(fact.key);
        allocator.free(fact.value);
    }
    allocator.free(facts);
}

// 去除 SSH 配置行的注释和首尾空白。
fn trimSshConfigLine(raw_line: []const u8) []const u8 {
    const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |idx| raw_line[0..idx] else raw_line;
    return std.mem.trim(u8, without_comment, " \t\r\n");
}

// 判断 sshd_config 指令是否影响迁移连通性和认证语义。
fn isInterestingSshdKey(key: []const u8) bool {
    const interesting = [_][]const u8{
        "Port",
        "ListenAddress",
        "PermitRootLogin",
        "PasswordAuthentication",
        "PubkeyAuthentication",
        "AuthorizedKeysFile",
        "AllowUsers",
        "AllowGroups",
        "DenyUsers",
        "DenyGroups",
        "ChallengeResponseAuthentication",
        "KbdInteractiveAuthentication",
        "AuthenticationMethods",
    };
    for (interesting) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }
    return false;
}

// 扫描 SSH host key 存在性和公钥指纹，不读取私钥内容。
fn scanHostKeys(io: std.Io, allocator: std.mem.Allocator) ![]schema.SshHostKeyFact {
    const key_types = [_][]const u8{ "rsa", "ecdsa", "ed25519" };
    var facts: std.ArrayList(schema.SshHostKeyFact) = .empty;
    errdefer freeHostKeys(allocator, facts.items);

    for (key_types) |key_type| {
        const private_path = try std.fmt.allocPrint(allocator, "/etc/ssh/ssh_host_{s}_key", .{key_type});
        defer allocator.free(private_path);
        const public_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{private_path});
        defer allocator.free(public_path);
        const private_present = probe.pathExists(io, private_path);
        const public_present = probe.pathExists(io, public_path);
        if (!private_present and !public_present) continue;
        try facts.append(allocator, .{
            .key_type = try allocator.dupe(u8, key_type),
            .private_path = try allocator.dupe(u8, private_path),
            .public_path = try allocator.dupe(u8, public_path),
            .private_present = private_present,
            .public_present = public_present,
            .fingerprint = try publicKeyFingerprint(io, allocator, public_path),
        });
    }

    return facts.toOwnedSlice(allocator);
}

// 读取公钥指纹；缺 ssh-keygen 或公钥不可读时返回 null。
fn publicKeyFingerprint(io: std.Io, allocator: std.mem.Allocator, public_path: []const u8) !?[]const u8 {
    if (!probe.executableExists(io, allocator, "ssh-keygen")) return null;
    const line = probe.runFirstLine(io, allocator, &.{ "ssh-keygen", "-l", "-f", public_path }) catch return null;
    return line;
}

// 释放 SSH host key 摘要列表。
fn freeHostKeys(allocator: std.mem.Allocator, facts: []schema.SshHostKeyFact) void {
    for (facts) |fact| {
        allocator.free(fact.key_type);
        allocator.free(fact.private_path);
        allocator.free(fact.public_path);
        if (fact.fingerprint) |fingerprint| allocator.free(fingerprint);
    }
    allocator.free(facts);
}

test "sshd config parser extracts key authentication directives" {
    const facts = try parseSshdConfig(std.testing.allocator,
        \\# comment
        \\Port 2222
        \\PasswordAuthentication no
        \\AllowUsers deploy admin
        \\HostKey /etc/ssh/ssh_host_ed25519_key
    );
    defer freeSshdConfigFacts(std.testing.allocator, facts);

    try std.testing.expectEqual(@as(usize, 3), facts.len);
    try std.testing.expectEqualStrings("Port", facts[0].key);
    try std.testing.expectEqualStrings("2222", facts[0].value);
    try std.testing.expectEqualStrings("AllowUsers", facts[2].key);
    try std.testing.expectEqualStrings("deploy admin", facts[2].value);
}
