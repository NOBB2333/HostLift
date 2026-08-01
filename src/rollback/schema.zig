const std = @import("std");
const remote_planner = @import("../remote/planner.zig");
const postgresql_artifacts = @import("../postgresql/artifacts.zig");

pub const schema_version = "hostlift.rollback.v1";

// rollback manifest 单行记录，描述一次需要回滚的操作。
pub const Entry = struct {
    schema_version: []const u8 = schema_version,
    created_at: i64,
    host: []const u8,
    action_id: []const u8,
    action_type: []const u8,
    original_path: []const u8,
    backup_path: []const u8,
    subject: []const u8 = "",
};

// 校验 rollback manifest 单行记录是否属于当前支持的 schema 和路径约束。
pub fn validateEntry(entry: Entry) !void {
    if (!std.mem.eql(u8, entry.schema_version, schema_version)) return error.InvalidRollbackManifestEntry;
    try remote_planner.validateHost(entry.host);
    try validateToken(entry.action_id);
    try validateToken(entry.action_type);

    if (std.mem.eql(u8, entry.action_type, "postgresql_manual_recovery")) {
        if (entry.original_path.len != 0) return error.InvalidRollbackManifestEntry;
        try remote_planner.validatePath(entry.backup_path);
        if (!std.mem.endsWith(u8, entry.backup_path, "/" ++ postgresql_artifacts.target_baseline_name)) return error.InvalidRollbackManifestEntry;
        const root = entry.backup_path[0 .. entry.backup_path.len - 1 - postgresql_artifacts.target_baseline_name.len];
        postgresql_artifacts.validateRoot(root) catch return error.InvalidRollbackManifestEntry;
        try validateSha256Subject(entry.subject);
        return;
    }

    if (std.mem.eql(u8, entry.action_type, "delete_created_path")) {
        try remote_planner.validatePath(entry.original_path);
        if (!std.mem.startsWith(u8, entry.original_path, "/")) return error.InvalidRollbackManifestEntry;
        if (entry.original_path.len <= 1 or entry.backup_path.len != 0 or entry.subject.len == 0) return error.InvalidRollbackManifestEntry;
        try validateCreatedPathBaseline(entry.subject);
        return;
    }

    if (isFileBacked(entry)) {
        if (entry.subject.len > 0) try validateToken(entry.subject);
        try remote_planner.validatePath(entry.original_path);
        try remote_planner.validatePath(entry.backup_path);
        if (!std.mem.startsWith(u8, entry.original_path, "/")) return error.InvalidRollbackManifestEntry;
        if (!std.mem.startsWith(u8, entry.backup_path, "/")) return error.InvalidRollbackManifestEntry;
        if (entry.original_path.len <= 1 or entry.backup_path.len <= 1) return error.InvalidRollbackManifestEntry;
        return;
    }

    if (isTokenSubjectAction(entry.action_type)) {
        if (entry.subject.len == 0) return error.InvalidRollbackManifestEntry;
        try validateToken(entry.subject);
        if (entry.original_path.len != 0 or entry.backup_path.len != 0) return error.InvalidRollbackManifestEntry;
        return;
    }

    if (std.mem.eql(u8, entry.action_type, "start_compose_project")) {
        if (entry.subject.len == 0) return error.InvalidRollbackManifestEntry;
        try remote_planner.validatePath(entry.subject);
        if (!std.mem.startsWith(u8, entry.subject, "/")) return error.InvalidRollbackManifestEntry;
        if (entry.original_path.len != 0 or entry.backup_path.len != 0) return error.InvalidRollbackManifestEntry;
        return;
    }

    return error.InvalidRollbackManifestEntry;
}

fn validateSha256Subject(value: []const u8) !void {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, value, prefix) or value.len != prefix.len + 64) return error.InvalidRollbackManifestEntry;
    for (value[prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidRollbackManifestEntry;
    }
}

fn validateCreatedPathBaseline(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "stat:v1:")) return error.InvalidRollbackManifestEntry;
    var fields = std.mem.splitScalar(u8, value["stat:v1:".len..], ':');
    var seen: usize = 0;
    while (fields.next()) |field| {
        if (field.len == 0) return error.InvalidRollbackManifestEntry;
        for (field) |byte| {
            if (byte < '0' or byte > '9') return error.InvalidRollbackManifestEntry;
        }
        seen += 1;
    }
    if (seen != 3) return error.InvalidRollbackManifestEntry;
}

// 判断 rollback entry 是否由文件备份支撑。
fn isFileBacked(entry: Entry) bool {
    return entry.original_path.len > 0 or entry.backup_path.len > 0;
}

// 判断 action 类型是否属于基于 token 的 subject 操作。
fn isTokenSubjectAction(action_type: []const u8) bool {
    return std.mem.eql(u8, action_type, "enable_systemd_unit") or
        std.mem.eql(u8, action_type, "enable_user_systemd_unit") or
        std.mem.eql(u8, action_type, "enable_openrc_service") or
        std.mem.eql(u8, action_type, "disable_openrc_service") or
        std.mem.eql(u8, action_type, "enable_sysv_init") or
        std.mem.eql(u8, action_type, "disable_sysv_init") or
        std.mem.eql(u8, action_type, "install_package") or
        std.mem.eql(u8, action_type, "create_user") or
        std.mem.eql(u8, action_type, "create_group");
}

// 校验 rollback action 字段，避免 JSONL 中出现 shell 元字符。
fn validateToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 512) return error.InvalidRollbackManifestEntry;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidRollbackManifestEntry;
        switch (byte) {
            '\'', '"', ';', '&', '|', '`', '$', '<', '>', '\\', '*', '?', '[', ']', '!' => return error.InvalidRollbackManifestEntry,
            else => {},
        }
    }
}
