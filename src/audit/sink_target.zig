const std = @import("std");
const security_validation = @import("../security/validation.zig");

// 审计 sink 目标类型。
pub const TargetKind = enum {
    file,
    http,
    syslog,
};

pub const Target = union(TargetKind) {
    file: []const u8,
    http: []const u8,
    syslog: []const u8,
};

// 解析审计 sink 目标；当前只有 file 目标可执行，集中 sink 先只做安全校验。
pub fn parse(value: []const u8) !Target {
    if (std.mem.startsWith(u8, value, "file:")) {
        const path = value["file:".len..];
        try security_validation.validatePath(path);
        return .{ .file = path };
    }
    if (std.mem.startsWith(u8, value, "https://")) {
        try validateHttpsEndpoint(value);
        return .{ .http = value };
    }
    if (std.mem.startsWith(u8, value, "syslog:")) {
        const facility = value["syslog:".len..];
        try validateSyslogFacility(facility);
        return .{ .syslog = facility };
    }
    return error.InvalidAuditSink;
}

// 校验 HTTPS 审计端点；当前不联网，只固定后续 HTTP sink 的输入边界。
pub fn validateHttpsEndpoint(value: []const u8) !void {
    if (value.len <= "https://".len or value.len > 2048) return error.InvalidAuditSink;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidAuditSink;
        switch (byte) {
            '\'', '"', '`', '$', '<', '>', '\\' => return error.InvalidAuditSink,
            else => {},
        }
    }
}

// 校验 syslog facility 名称；后续 syslog adapter 会复用同一边界。
pub fn validateSyslogFacility(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidAuditSink;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '_', '-' => {},
            else => return error.InvalidAuditSink,
        }
    }
}

test "audit sink target parser validates supported target shapes" {
    try std.testing.expectEqual(TargetKind.file, std.meta.activeTag(try parse("file:/tmp/hostlift-audit.jsonl")));
    try std.testing.expectEqual(TargetKind.http, std.meta.activeTag(try parse("https://audit.example.test/v1/events")));
    try std.testing.expectEqual(TargetKind.syslog, std.meta.activeTag(try parse("syslog:local0")));

    try std.testing.expectError(error.InvalidAuditSink, parse("http://audit.example.test/insecure"));
    try std.testing.expectError(error.InvalidAuditSink, parse("https://audit.example.test/bad path"));
    try std.testing.expectError(error.InvalidAuditSink, parse("syslog:local0;rm"));
    try std.testing.expectError(error.InvalidTransferPath, parse("file:/tmp/audit*.jsonl"));
}
