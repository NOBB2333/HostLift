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

test "remote validation rejects shell metacharacters" {
    try std.testing.expectError(error.InvalidRemoteHost, validateHost("root@bad host"));
    try std.testing.expectError(error.InvalidRemoteCommandToken, validateCommandToken("whoami;id"));
    try std.testing.expectError(error.InvalidTransferPath, validatePath("/tmp/app*.tar"));
    try std.testing.expectError(error.InvalidSshIdentityFile, validateSshIdentityFile("/home/me/.ssh/key;rm"));
    try std.testing.expectError(error.InvalidApprovalTicket, validateApprovalTicket("OPS-123;rm"));
    try validateApprovalTicket("OPS-123/change:456");
}
