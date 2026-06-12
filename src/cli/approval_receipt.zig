const std = @import("std");
const approval_receipt = @import("../policy/approval_receipt.zig");

// 校验可选审批凭证文件，确保它绑定当前 approved 执行上下文。
pub fn validateOptional(
    io: std.Io,
    allocator: std.mem.Allocator,
    receipt_path: ?[]const u8,
    key_env_name: ?[]const u8,
    context: approval_receipt.Context,
) !void {
    const path = receipt_path orelse return;
    const parsed = try approval_receipt.read(io, allocator, path);
    defer parsed.deinit();
    const signature_key = if (key_env_name) |name| resolveKeyFromEnv(name) else null;
    try approval_receipt.validate(parsed.value, .{
        .ticket = context.ticket,
        .operator = context.operator,
        .host = context.host,
        .plan_hash = context.plan_hash,
        .purpose = context.purpose,
        .now = context.now,
        .signature_key = signature_key,
    });
}

// 从环境变量读取审批凭证签名密钥。
fn resolveKeyFromEnv(name: []const u8) ?[]const u8 {
    if (!envNameValid(name)) return null;
    const name_z = std.heap.smp_allocator.dupeZ(u8, name) catch return null;
    defer std.heap.smp_allocator.free(name_z);
    if (std.c.getenv(name_z.ptr)) |raw| return std.mem.span(raw);
    return null;
}

// 校验环境变量名称是否符合 POSIX 规范。
fn envNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name, 0..) |byte, index| {
        if (std.ascii.isAlphabetic(byte) or byte == '_') continue;
        if (index > 0 and std.ascii.isDigit(byte)) continue;
        return false;
    }
    return true;
}
