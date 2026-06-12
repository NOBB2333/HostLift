const std = @import("std");
const audit_log = @import("log.zig");

// 把审计事件编码成单行 JSON，并更新 hash chain。
pub fn encodeChained(allocator: std.mem.Allocator, chain: *audit_log.Chain, event: audit_log.Event) !std.ArrayList(u8) {
    var buffer: std.ArrayList(u8) = .empty;
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    try audit_log.writeChainedEvent(allocator, &writer.writer, chain, event);
    return writer.toArrayList();
}

