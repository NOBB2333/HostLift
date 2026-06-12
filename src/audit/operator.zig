const std = @import("std");

pub const default_operator = "unknown";

const env_keys = [_][:0]const u8{
    "HOSTLIFT_OPERATOR",
    "USER",
    "LOGNAME",
};

// 校验操作人标识，避免把空白、控制字符或 shell 元字符写入审计上下文。
pub fn validate(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidOperator;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '-', '_', '@', ':', '/', '+' => {},
            else => return error.InvalidOperator,
        }
    }
}

// 从当前进程环境变量推断操作人，供未显式传 --operator 时使用。
pub fn detectFromProcessEnv() []const u8 {
    for (env_keys) |key| {
        if (std.c.getenv(key.ptr)) |raw_value| {
            const value = std.mem.span(raw_value);
            validate(value) catch return default_operator;
            return value;
        }
    }
    return default_operator;
}

// 从可测试的环境变量 map 推断操作人。
pub fn detectFromEnvMap(env_map: std.process.Environ.Map) []const u8 {
    for (env_keys) |key| {
        if (env_map.get(key)) |value| {
            validate(value) catch return default_operator;
            return value;
        }
    }
    return default_operator;
}

test "operator validation accepts stable identity strings" {
    try validate("alice");
    try validate("ops@example.com");
    try validate("github/actions:deploy");
}

test "operator validation rejects unsafe strings" {
    try std.testing.expectError(error.InvalidOperator, validate(""));
    try std.testing.expectError(error.InvalidOperator, validate("bad user"));
    try std.testing.expectError(error.InvalidOperator, validate("alice;rm"));
}

test "operator detection prefers explicit env var" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("USER", "local-user");
    try env_map.put("HOSTLIFT_OPERATOR", "ci/deploy");
    try std.testing.expectEqualStrings("ci/deploy", detectFromEnvMap(env_map));
}

test "operator detection falls back to unknown for unsafe env value" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOSTLIFT_OPERATOR", "bad user");
    try std.testing.expectEqualStrings(default_operator, detectFromEnvMap(env_map));
}
