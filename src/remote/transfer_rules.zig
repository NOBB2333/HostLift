const std = @import("std");
const schema = @import("schema.zig");

pub const default_chunk_size_bytes: u64 = 8 * 1024 * 1024;

// 传输规则输入参数。
pub const Input = struct {
    source_host: ?[]const u8 = null,
    recursive: bool = false,
    transport: schema.TransferTransport = .scp,
    partial: bool = false,
    resumable: bool = false,
    bandwidth_limit_kbps: ?u32 = null,
};

// 校验传输后端组合规则；不支持的组合必须在计划阶段失败关闭。
pub fn validate(input: Input) !void {
    if (input.bandwidth_limit_kbps) |value| {
        if (value == 0) return error.InvalidTransferBandwidthLimit;
    }
    if (input.partial and input.transport != .rsync) return error.PartialTransferRequiresRsync;
    if (input.resumable and input.transport != .rsync) return error.ResumeTransferRequiresRsync;
    if (input.source_host != null and input.transport == .rsync) return error.RsyncRemoteToRemoteUnsupported;
    if (input.source_host != null and input.transport == .chunk) return error.ChunkRemoteToRemoteUnsupported;
    if (input.transport == .chunk and !input.recursive) return error.ChunkTransferRequiresRecursive;
}

// 计算传输计划最终 partial 语义；resume 会隐式启用 partial。
pub fn effectivePartial(partial: bool, resumable: bool) bool {
    return partial or resumable;
}

// 返回指定传输后端的 chunk 大小；非 chunk 后端没有该字段。
pub fn chunkSize(transport: schema.TransferTransport) ?u64 {
    return if (transport == .chunk) default_chunk_size_bytes else null;
}

test "transfer rules require rsync for partial and resume" {
    try std.testing.expectError(
        error.PartialTransferRequiresRsync,
        validate(.{ .transport = .scp, .partial = true }),
    );
    try std.testing.expectError(
        error.ResumeTransferRequiresRsync,
        validate(.{ .transport = .scp, .resumable = true }),
    );
    try validate(.{ .transport = .rsync, .partial = true, .resumable = true });
}

test "transfer rules reject unsupported remote source transports" {
    try std.testing.expectError(
        error.RsyncRemoteToRemoteUnsupported,
        validate(.{ .source_host = "root@192.0.2.11", .recursive = true, .transport = .rsync }),
    );
    try std.testing.expectError(
        error.ChunkRemoteToRemoteUnsupported,
        validate(.{ .source_host = "root@192.0.2.11", .recursive = true, .transport = .chunk }),
    );
}

test "transfer rules reject non-recursive chunk plans" {
    try std.testing.expectError(
        error.ChunkTransferRequiresRecursive,
        validate(.{ .recursive = false, .transport = .chunk }),
    );
    try validate(.{ .recursive = true, .transport = .chunk });
}

test "transfer rules reject zero bandwidth limit" {
    try std.testing.expectError(
        error.InvalidTransferBandwidthLimit,
        validate(.{ .bandwidth_limit_kbps = 0 }),
    );
    try validate(.{ .bandwidth_limit_kbps = 1 });
}

test "transfer rules expose derived transport fields" {
    try std.testing.expect(effectivePartial(false, true));
    try std.testing.expectEqual(@as(?u64, default_chunk_size_bytes), chunkSize(.chunk));
    try std.testing.expectEqual(@as(?u64, null), chunkSize(.rsync));
}
