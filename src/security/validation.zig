const std = @import("std");

// 校验 SSH host 字符串，避免把 shell 元字符带入命令边界。
pub fn validateHost(host: []const u8) !void {
    if (host.len == 0 or host.len > 255) return error.InvalidRemoteHost;
    for (host) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '-', '_', '@', ':', '[', ']' => {},
            else => return error.InvalidRemoteHost,
        }
    }
}

// 校验远程命令的单个 argv token；当前只允许保守字符集。
pub fn validateCommandToken(token: []const u8) !void {
    if (token.len == 0 or token.len > 512) return error.InvalidRemoteCommandToken;
    for (token) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '/', '.', '_', '-', ':', '=', '@', '%', '+', ',' => {},
            else => return error.InvalidRemoteCommandToken,
        }
    }
}

// 校验传输路径，拒绝空白、通配符和常见 shell 元字符。
pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096) return error.InvalidTransferPath;
    for (path) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidTransferPath;
        switch (byte) {
            '\'', '"', ';', '&', '|', '`', '$', '<', '>', '\\', '*', '?', '[', ']', '!' => return error.InvalidTransferPath,
            else => {},
        }
    }
}

// 校验 SSH identity file 路径，避免把 key 路径作为 shell 片段传入 ssh/scp/rsync。
pub fn validateSshIdentityFile(path: []const u8) !void {
    validatePath(path) catch return error.InvalidSshIdentityFile;
}

// 校验审批票据标识，避免把自由文本写入审计和策略上下文。
pub fn validateApprovalTicket(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidApprovalTicket;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '_', '.', '/', ':' => {},
            else => return error.InvalidApprovalTicket,
        }
    }
}

// 校验只读 systemd 探针的 unit 名，拒绝路径、选项和 shell 字符。
pub fn validateSystemdProbeTarget(value: []const u8) !void {
    if (value.len == 0 or value.len > 256 or value[0] == '-') return error.InvalidSystemdProbeTarget;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '_', '-', '@', ':' => {},
            else => return error.InvalidSystemdProbeTarget,
        }
    }
    if (!std.mem.endsWith(u8, value, ".service")) return error.InvalidSystemdProbeTarget;
}

pub const ContainerProbeTarget = struct {
    runtime: []const u8,
    name: []const u8,
};

// 解析并校验 runtime:name 容器探针目标；只允许 Docker/Podman 和保守容器名。
pub fn parseContainerProbeTarget(value: []const u8) !ContainerProbeTarget {
    const separator = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidContainerProbeTarget;
    if (std.mem.indexOfScalarPos(u8, value, separator + 1, ':') != null) return error.InvalidContainerProbeTarget;
    const runtime = value[0..separator];
    const name = value[separator + 1 ..];
    if ((!std.mem.eql(u8, runtime, "docker") and !std.mem.eql(u8, runtime, "podman")) or name.len == 0 or name.len > 255) {
        return error.InvalidContainerProbeTarget;
    }
    if (!std.ascii.isAlphanumeric(name[0])) return error.InvalidContainerProbeTarget;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '_', '-' => {},
            else => return error.InvalidContainerProbeTarget,
        }
    }
    return .{ .runtime = runtime, .name = name };
}

pub const TcpProbeTarget = struct {
    host: []const u8,
    port: u16,
};

// 解析并校验 host:port TCP 探针目标；首版保守限制为 DNS 名或 IPv4 文本。
pub fn parseTcpProbeTarget(value: []const u8) !TcpProbeTarget {
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidTcpProbeTarget;
    const host = value[0..separator];
    const port_text = value[separator + 1 ..];
    if (host.len == 0 or host.len > 253 or port_text.len == 0 or host[0] == '-') return error.InvalidTcpProbeTarget;
    for (host) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '-', '_' => {},
            else => return error.InvalidTcpProbeTarget,
        }
    }
    const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.InvalidTcpProbeTarget;
    if (port == 0) return error.InvalidTcpProbeTarget;
    return .{ .host = host, .port = port };
}

// 校验 HTTP(S) 探针 URL；拒绝 userinfo、query、fragment 和不能安全进入远程 argv 的字符。
pub fn validateHttpProbeTarget(value: []const u8) !void {
    if (value.len == 0 or value.len > 2048) return error.InvalidHttpProbeTarget;
    const uri = std.Uri.parse(value) catch return error.InvalidHttpProbeTarget;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidHttpProbeTarget;
    if (uri.host == null or uri.host.?.isEmpty() or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidHttpProbeTarget;
    validateCommandToken(value) catch return error.InvalidHttpProbeTarget;
}

// 校验可下载 artifact 的 HTTPS URL；拒绝凭据、query、fragment 和降级到明文 HTTP 的来源。
pub fn validateHttpsArtifactUrl(value: []const u8) !void {
    if (value.len == 0 or value.len > 2048) return error.InvalidHttpsArtifactUrl;
    const uri = std.Uri.parse(value) catch return error.InvalidHttpsArtifactUrl;
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.InvalidHttpsArtifactUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidHttpsArtifactUrl;
    }
    validateCommandToken(value) catch return error.InvalidHttpsArtifactUrl;
}

test "remote validation rejects shell metacharacters" {
    try std.testing.expectError(error.InvalidRemoteHost, validateHost("root@bad host"));
    try std.testing.expectError(error.InvalidRemoteCommandToken, validateCommandToken("whoami;id"));
    try std.testing.expectError(error.InvalidTransferPath, validatePath("/tmp/app*.tar"));
    try std.testing.expectError(error.InvalidSshIdentityFile, validateSshIdentityFile("/home/me/.ssh/key;rm"));
    try std.testing.expectError(error.InvalidApprovalTicket, validateApprovalTicket("OPS-123;rm"));
    try validateApprovalTicket("OPS-123/change:456");
}

test "manual probe targets are strict and structured" {
    try validateSystemdProbeTarget("worker@1.service");
    try std.testing.expectError(error.InvalidSystemdProbeTarget, validateSystemdProbeTarget("../../worker.service"));

    const container = try parseContainerProbeTarget("podman:api-1");
    try std.testing.expectEqualStrings("podman", container.runtime);
    try std.testing.expectEqualStrings("api-1", container.name);
    try std.testing.expectError(error.InvalidContainerProbeTarget, parseContainerProbeTarget("docker:api;rm"));

    const tcp = try parseTcpProbeTarget("db.internal:5432");
    try std.testing.expectEqual(@as(u16, 5432), tcp.port);
    try std.testing.expectError(error.InvalidTcpProbeTarget, parseTcpProbeTarget("db.internal:0"));

    try validateHttpProbeTarget("https://health.example.test/ready");
    try std.testing.expectError(error.InvalidHttpProbeTarget, validateHttpProbeTarget("https:///ready"));
    try std.testing.expectError(error.InvalidHttpProbeTarget, validateHttpProbeTarget("https://health.example.test:0/ready"));
    try std.testing.expectError(error.InvalidHttpProbeTarget, validateHttpProbeTarget("https://user:pass@health.example.test/ready"));
    try std.testing.expectError(error.InvalidHttpProbeTarget, validateHttpProbeTarget("https://health.example.test/ready?token=x"));

    try validateHttpsArtifactUrl("https://downloads.example.test/tool/install.sh");
    try std.testing.expectError(error.InvalidHttpsArtifactUrl, validateHttpsArtifactUrl("http://downloads.example.test/install.sh"));
    try std.testing.expectError(error.InvalidHttpsArtifactUrl, validateHttpsArtifactUrl("https://downloads.example.test/install.sh?token=secret"));
}
