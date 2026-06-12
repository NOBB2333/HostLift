const std = @import("std");
const schema = @import("schema.zig");

// 将单条 rollback 记录写为 JSONL。
pub fn writeEntry(writer: anytype, entry: schema.Entry) !void {
    const JsonEntry = struct {
        schema_version: []const u8 = schema.schema_version,
        created_at: i64,
        host: []const u8,
        action_id: []const u8,
        action_type: []const u8,
        original_path: []const u8,
        backup_path: []const u8,
        subject: []const u8,
    };
    try std.json.Stringify.value(JsonEntry{
        .created_at = entry.created_at,
        .host = entry.host,
        .action_id = entry.action_id,
        .action_type = entry.action_type,
        .original_path = entry.original_path,
        .backup_path = entry.backup_path,
        .subject = entry.subject,
    }, .{}, writer);
    try writer.writeByte('\n');
}
